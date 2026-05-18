//! `:::embedded-document` HTTP/HTTPS source handler — extras. The
//! core `embedded_document` factory handles file:// and bare paths
//! synchronously. URL paths require this extras module: it owns a
//! per-Spark URL→bytes cache and submits async `IoChannel.http_get`
//! jobs on cache miss. The completion handler is a member function
//! invoked through `PendingFetch.spark.embedded_http`.
//!
//! Per-Spark isolation: `url_cache` lives on the `EmbeddedDocumentHttp`
//! instance, not as a module-global. Two `Spark` instances in one
//! process don't share cached URL bodies (memory accounting +
//! cache-clear semantics stay per-instance, matching the discipline
//! Phase 1 enforced when it purged `_ref` module-globals).
//!
//! Async lifecycle (mirrors the core comment from the file:// path):
//!
//!   1. **submit**: cache hit → synchronous `fulfillFromBytes`.
//!      Cache miss → snapshot non-`src` overlay attrs into a
//!      `PendingFetch`, submit an `IoChannel.http_get` with the
//!      Pending pointer as `user_data`, set `c.phase = .loading`.
//!   2. **handleCompletion** (host's drain, main thread):
//!      `ok` → dupe body into `url_cache`, call `fulfillFromBytesWithOverlays`,
//!      bubble `host_state.dirty`; `err` → flip to `.failed`.
//!   3. **cancellation**: if the Component is destroyed mid-flight,
//!      core's `deinit_` nulls `pending.component`. Completion sees
//!      the null and skips the parse but still caches the body so
//!      the next mount of the same URL gets the sync path.

const std = @import("std");
const components = @import("../markdown_components.zig");
const io = @import("../io_channel.zig");
const spark_mod = @import("../spark.zig");
const embedded_document = @import("../components/embedded_document.zig");

pub const Error = error{
    /// Returned by `install` if its preconditions aren't met. None today
    /// (HTTP needs only `IoChannel`, which is always present in core),
    /// but reserved here so future preconditions land with a typed name.
    EmbeddedDocumentHttpInstallFailed,
};

/// Per-Spark URL fetch state. Owns the URL→bytes cache; methods
/// drive the async fetch lifecycle for the core `embedded-document`
/// factory's URL branch.
pub const EmbeddedDocumentHttp = struct {
    allocator: std.mem.Allocator,
    /// URL → fetched body bytes. Both key + value owned by `allocator`.
    /// Entries persist for the EmbeddedDocumentHttp's lifetime (i.e.
    /// the Spark's lifetime).
    url_cache: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) EmbeddedDocumentHttp {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EmbeddedDocumentHttp) void {
        var it = self.url_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.url_cache.deinit(self.allocator);
        self.* = undefined;
    }

    /// Entry point invoked from core's `create()` on the URL branch.
    /// Cache hit → synchronous fulfilment; miss → async fetch.
    pub fn submit(
        self: *EmbeddedDocumentHttp,
        c: *embedded_document.Component,
        url: []const u8,
        spec: *const components.Spec,
    ) anyerror!void {
        if (self.url_cache.get(url)) |cached| {
            // Cache hit: synchronous, spec is still alive.
            try embedded_document.fulfillFromBytes(c, cached, spec);
            return;
        }
        // Cache miss: apply parent overlays NOW so any `update()`
        // landing before the completion sees coherent child_state.
        // Frontmatter is applied later by handleCompletion + then
        // overlays re-applied (parent-wins rule preserved).
        try embedded_document.applyParentOverlays(c.child_state, spec);
        try self.submitAsyncFetch(c, url, spec);
    }

    fn submitAsyncFetch(
        self: *EmbeddedDocumentHttp,
        c: *embedded_document.Component,
        url: []const u8,
        spec: *const components.Spec,
    ) !void {
        const ch = c.spark.io_channel;
        const a = c.allocator;

        const pending = try a.create(embedded_document.PendingFetch);
        errdefer a.destroy(pending);

        const url_copy = try a.dupe(u8, url);
        errdefer a.free(url_copy);

        var overlay_list: std.ArrayListUnmanaged(embedded_document.OverlayKV) = .{};
        errdefer {
            for (overlay_list.items) |kv| {
                a.free(kv.key);
                a.free(kv.value);
            }
            overlay_list.deinit(a);
        }
        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "src")) continue;
            const k = try a.dupe(u8, attr.key);
            errdefer a.free(k);
            const v = try a.dupe(u8, attr.value);
            errdefer a.free(v);
            try overlay_list.append(a, .{ .key = k, .value = v });
        }
        const overlays = try overlay_list.toOwnedSlice(a);
        errdefer a.free(overlays);

        pending.* = .{
            .header = .{ .handle_completion = handleCompletion },
            .allocator = a,
            .component = c,
            .handle = 0,
            .url = url_copy,
            .overlays = overlays,
            .spark = c.spark,
        };

        const handle = try ch.submitHttpGet(url, @intFromPtr(pending));
        pending.handle = handle;
        c.pending = pending;
        c.phase = .loading;
        _ = self;
    }

    /// Drain target. Main thread calls this once per frame via
    /// `IoChannel.drain`. Resolves a completion against the originating
    /// Pending: caches the body, finishes the parse, bubbles dirty.
    /// Owned bodies are released here in all paths.
    pub fn handleCompletion(comp: io.Completion) void {
        const p: *embedded_document.PendingFetch = @ptrFromInt(comp.user_data);
        defer freePending(p);

        const c_opt = p.component;
        // Decouple the Pending↔Component link regardless of outcome so
        // deinit_ doesn't try to follow a freed pointer later.
        if (c_opt) |c| c.pending = null;

        const ch = p.spark.io_channel;
        const host_state = p.spark.host_state;
        // The EmbeddedDocumentHttp is owned by Spark and outlives any
        // single PendingFetch; safe to unwrap.
        const self = p.spark.embedded_http orelse {
            // Defensive: should be unreachable — submitAsyncFetch only
            // runs when `spark.embedded_http != null`. If we land here
            // anyway, release the body and bail without writing into
            // the (gone) cache.
            switch (comp.result) {
                .ok => |body| ch.releaseOk(body),
                .chunk => |bytes| ch.releaseOk(bytes),
                else => {},
            }
            return;
        };

        switch (comp.result) {
            // Stream variants don't apply to embedded-document — it only
            // issues http_get. Defensive: never hits the wire.
            .chunk, .end, .end_err => {
                switch (comp.result) {
                    .chunk => |bytes| ch.releaseOk(bytes),
                    else => {},
                }
                return;
            },
            .err => {
                if (c_opt) |c| {
                    c.phase = .failed;
                    host_state.dirty = true;
                }
            },
            .ok => |body_owned| {
                // Always cache the bytes — the next mount of the same
                // URL gets the fast sync path, even if THIS Component
                // was cancelled. Cache ownership: dupe into self.allocator;
                // the io-channel-owned slice is freed immediately after.
                const a = self.allocator;
                const cached_copy = a.dupe(u8, body_owned) catch {
                    ch.releaseOk(body_owned);
                    return;
                };
                ch.releaseOk(body_owned);

                if (self.url_cache.get(p.url) == null) {
                    const key = a.dupe(u8, p.url) catch {
                        a.free(cached_copy);
                        return;
                    };
                    self.url_cache.put(a, key, cached_copy) catch {
                        a.free(key);
                        a.free(cached_copy);
                        return;
                    };
                } else {
                    a.free(cached_copy);
                }

                if (c_opt) |c| {
                    const bytes = self.url_cache.get(p.url) orelse return;
                    embedded_document.fulfillFromBytesWithOverlays(c, bytes, p.overlays) catch {
                        c.phase = .failed;
                    };
                    host_state.dirty = true;
                }
            },
        }
    }

    fn freePending(p: *embedded_document.PendingFetch) void {
        const a = p.allocator;
        for (p.overlays) |kv| {
            a.free(kv.key);
            a.free(kv.value);
        }
        a.free(p.overlays);
        a.free(p.url);
        a.destroy(p);
    }
};

/// Install the HTTP/HTTPS source handler on `spark`. Idempotent;
/// repeated calls are no-ops. Required precondition: none beyond
/// core (HTTP rides on `spark.io_channel` which always exists).
/// Allocates `EmbeddedDocumentHttp` from `spark.allocator`; the
/// resource is owned by Spark and freed in `Spark.deinit`.
pub fn install(spark: *spark_mod.Spark) !void {
    if (spark.embedded_http != null) return;
    const ext = try spark.allocator.create(EmbeddedDocumentHttp);
    errdefer spark.allocator.destroy(ext);
    ext.* = EmbeddedDocumentHttp.init(spark.allocator);
    spark.embedded_http = ext;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "freePending: releases all owned slices (testing-allocator leak check)" {
    const a = testing.allocator;
    const k = try a.dupe(u8, "k");
    const v = try a.dupe(u8, "v");
    var overlays = try a.alloc(embedded_document.OverlayKV, 1);
    overlays[0] = .{ .key = k, .value = v };

    const url = try a.dupe(u8, "http://example/");
    var test_spark = spark_mod.Spark.testStub(a);
    const p = try a.create(embedded_document.PendingFetch);
    p.* = .{
        .header = .{ .handle_completion = EmbeddedDocumentHttp.handleCompletion },
        .allocator = a,
        .component = null,
        .handle = 0,
        .url = url,
        .overlays = overlays,
        .spark = &test_spark,
    };
    EmbeddedDocumentHttp.freePending(p);
    // testing.allocator will fail the test on any unfreed allocation.
}

test "EmbeddedDocumentHttp.init/deinit: clean lifecycle (no leaks)" {
    const a = testing.allocator;
    var ext = EmbeddedDocumentHttp.init(a);
    ext.deinit();
}
