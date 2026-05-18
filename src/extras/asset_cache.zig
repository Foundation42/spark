//! `AssetCache` — persistent content-addressable cache for expensive
//! HTTP assets (Recraft SVG envelopes, Gemini image envelopes, future
//! remote responses worth keeping across restarts).
//!
//! ### Browser-style layout
//!
//! One flat directory holds `<hex-sha256>` files plus a `manifest.json`
//! tracking per-entry metadata. The manifest is rewritten atomically
//! (tmp + rename) on every `put` / eviction; `get` updates
//! `last_accessed_at_ms` in memory only and flushes on `deinit`. A
//! crash between `get` and `deinit` loses LRU ordering but never
//! loses bytes.
//!
//! ### Budget + eviction
//!
//! `put` enforces a configurable byte budget (default set by the
//! caller — 500 MB in the host). When `total + new > budget`, entries
//! are sorted by `last_accessed_at_ms` ascending and deleted until
//! the new entry fits. `prune(older_than_ms)` / `pruneAll()` /
//! `setBudget(new_bytes)` are the manual knobs.
//!
//! ### Thread safety
//!
//! All operations are main-thread only — the host's drain handler
//! runs on main, and the cache-hit fast path in consumers runs on
//! main. No internal locking. If a future consumer needs worker-side
//! lookup, add a mutex around `entries` and the dirty flag.

const std = @import("std");

pub const Key = [32]u8;
pub const HexKey = [64]u8;

pub const PutOpts = struct {
    /// Optional human-readable descriptor (e.g.
    /// `"openrouter:google/gemini-3.1-flash-image-preview"`). Stored
    /// in the manifest for tooling / future prune-by-source. Duped
    /// into the cache allocator.
    source: ?[]const u8 = null,
    /// Optional MIME-ish hint (`"application/json"`,
    /// `"image/svg+xml"`, etc.). Stored only — the cache doesn't
    /// interpret it.
    content_type: ?[]const u8 = null,
};

pub const Entry = struct {
    key: Key,
    size: u64,
    created_at_ms: i64,
    last_accessed_at_ms: i64,
    source: ?[]u8,
    content_type: ?[]u8,
};

pub const Stats = struct {
    entry_count: u32,
    total_bytes: u64,
    budget_bytes: u64,
};

pub const Error = error{
    InvalidManifest,
    EntryExceedsBudget,
};

const MANIFEST_NAME = "manifest.json";
const MANIFEST_TMP_NAME = "manifest.json.tmp";
const MANIFEST_VERSION: u32 = 1;

pub const AssetCache = struct {
    allocator: std.mem.Allocator,
    /// Owned absolute path to the cache directory. Used for error
    /// messages + manifest read/write.
    dir_path: []u8,
    /// Open handle to the cache directory; entries are read/written
    /// relative to this. Closed on deinit.
    dir: std.fs.Dir,
    budget_bytes: u64,
    /// `Key → *Entry`. Entries owned by `allocator`; freed on
    /// eviction or deinit.
    entries: std.AutoHashMapUnmanaged(Key, *Entry) = .{},
    total_bytes: u64 = 0,
    /// Set on every metadata mutation (put, get-update-access-time,
    /// eviction, prune, setBudget). Flushed by `flushManifest` and
    /// cleared.
    index_dirty: bool = false,

    /// Open (or create) the cache at `dir_path` with the given byte
    /// budget. Creates the directory tree if it doesn't exist; loads
    /// any existing manifest (or starts empty + logs if it's corrupt).
    /// Stale entries — manifest references with no on-disk file — are
    /// dropped silently.
    pub fn init(
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        budget_bytes: u64,
    ) !*AssetCache {
        try std.fs.cwd().makePath(dir_path);
        var dir = try std.fs.cwd().openDir(dir_path, .{});
        errdefer dir.close();

        const path_owned = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(path_owned);

        const self = try allocator.create(AssetCache);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .dir_path = path_owned,
            .dir = dir,
            .budget_bytes = budget_bytes,
        };

        self.loadManifest() catch |e| switch (e) {
            error.FileNotFound => {}, // fresh cache, no manifest yet
            else => {
                std.log.warn("asset_cache: manifest load failed ({s}); starting empty", .{@errorName(e)});
                self.dropAllEntries();
            },
        };

        return self;
    }

    pub fn deinit(self: *AssetCache) void {
        if (self.index_dirty) {
            self.flushManifest() catch |e| {
                std.log.warn("asset_cache: final flush failed: {s}", .{@errorName(e)});
            };
        }

        self.dropAllEntries();
        self.entries.deinit(self.allocator);
        self.dir.close();
        self.allocator.free(self.dir_path);
        self.allocator.destroy(self);
    }

    // ── Lookup ───────────────────────────────────────────────────────

    pub fn contains(self: *AssetCache, key: Key) bool {
        return self.entries.contains(key);
    }

    /// Read the entry's bytes off disk. Returns owned bytes (caller
    /// frees via `self.allocator.free`) or null on miss. Updates
    /// `last_accessed_at_ms` in memory; flushed on next `put` or
    /// `deinit`.
    ///
    /// If the on-disk file has disappeared since the manifest was
    /// written (manual `rm` outside the process, for instance), the
    /// entry is dropped from the index and the call reports a miss.
    pub fn get(self: *AssetCache, key: Key) !?[]u8 {
        const entry = self.entries.get(key) orelse return null;

        var hex: HexKey = undefined;
        toHex(key, &hex);

        const file = self.dir.openFile(&hex, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                _ = self.entries.remove(key);
                self.total_bytes -|= entry.size;
                self.freeEntry(entry);
                self.index_dirty = true;
                return null;
            },
            else => return e,
        };
        defer file.close();

        const size = try file.getEndPos();
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        const n = try file.readAll(bytes);
        if (n != size) return error.UnexpectedEndOfFile;

        entry.last_accessed_at_ms = std.time.milliTimestamp();
        self.index_dirty = true;
        return bytes;
    }

    // ── Write ────────────────────────────────────────────────────────

    /// Store `bytes` under `key`. If the entry would push us past the
    /// budget, LRU entries are evicted until it fits. If `bytes`
    /// alone exceeds the entire budget, returns `EntryExceedsBudget`
    /// and writes nothing.
    pub fn put(self: *AssetCache, key: Key, bytes: []const u8, opts: PutOpts) !void {
        if (@as(u64, bytes.len) > self.budget_bytes) return Error.EntryExceedsBudget;

        // If the key already exists, treat this as a replace —
        // subtract the old size from the running total before
        // eviction math, then drop the old entry. The on-disk file
        // gets overwritten by the create-and-write below.
        if (self.entries.get(key)) |existing| {
            self.total_bytes -|= existing.size;
            _ = self.entries.remove(key);
            self.freeEntry(existing);
        }

        // Evict LRU until the new entry fits.
        while (self.total_bytes + @as(u64, bytes.len) > self.budget_bytes) {
            const victim = self.findLRU() orelse break;
            try self.evictByKey(victim);
        }

        var hex: HexKey = undefined;
        toHex(key, &hex);

        const file = try self.dir.createFile(&hex, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);

        const now = std.time.milliTimestamp();
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        const source_dup: ?[]u8 = if (opts.source) |s| try self.allocator.dupe(u8, s) else null;
        errdefer if (source_dup) |d| self.allocator.free(d);
        const ct_dup: ?[]u8 = if (opts.content_type) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (ct_dup) |d| self.allocator.free(d);

        entry.* = .{
            .key = key,
            .size = bytes.len,
            .created_at_ms = now,
            .last_accessed_at_ms = now,
            .source = source_dup,
            .content_type = ct_dup,
        };
        try self.entries.put(self.allocator, key, entry);
        self.total_bytes += bytes.len;
        self.index_dirty = true;

        // Flush the manifest immediately. `get` only marks dirty; if
        // a crash happens after a successful put, we want the
        // manifest to know the entry exists so the bytes aren't
        // orphaned.
        try self.flushManifest();
    }

    // ── Manual eviction ──────────────────────────────────────────────

    pub fn setBudget(self: *AssetCache, new_budget_bytes: u64) !void {
        self.budget_bytes = new_budget_bytes;
        while (self.total_bytes > self.budget_bytes) {
            const victim = self.findLRU() orelse break;
            try self.evictByKey(victim);
        }
        try self.flushManifest();
    }

    /// Evict every entry whose `last_accessed_at_ms` is older than
    /// `cutoff_ms` (in absolute epoch milliseconds — caller computes).
    /// Returns the evicted count.
    pub fn pruneOlderThan(self: *AssetCache, cutoff_ms: i64) !u32 {
        var keys_to_evict: std.ArrayListUnmanaged(Key) = .{};
        defer keys_to_evict.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.last_accessed_at_ms < cutoff_ms) {
                try keys_to_evict.append(self.allocator, kv.key_ptr.*);
            }
        }

        for (keys_to_evict.items) |k| try self.evictByKey(k);
        if (keys_to_evict.items.len > 0) try self.flushManifest();
        return @intCast(keys_to_evict.items.len);
    }

    pub fn pruneAll(self: *AssetCache) !void {
        var keys_to_evict: std.ArrayListUnmanaged(Key) = .{};
        defer keys_to_evict.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            try keys_to_evict.append(self.allocator, kv.key_ptr.*);
        }

        for (keys_to_evict.items) |k| try self.evictByKey(k);
        try self.flushManifest();
    }

    pub fn stats(self: *const AssetCache) Stats {
        return .{
            .entry_count = @intCast(self.entries.count()),
            .total_bytes = self.total_bytes,
            .budget_bytes = self.budget_bytes,
        };
    }

    // ── Key derivation ───────────────────────────────────────────────

    /// Derive a sha256 key from a list of arbitrary byte slices. Each
    /// part is fed through the hasher in order with a length-prefixed
    /// frame, so `["a", "bc"]` and `["ab", "c"]` produce distinct
    /// keys (avoids length-extension ambiguity).
    pub fn keyFor(parts: []const []const u8) Key {
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        for (parts) |p| {
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, p.len, .little);
            sha.update(&len_buf);
            sha.update(p);
        }
        var out: Key = undefined;
        sha.final(&out);
        return out;
    }

    pub fn keyHex(key: Key) HexKey {
        var hex: HexKey = undefined;
        toHex(key, &hex);
        return hex;
    }

    // ── Internal ────────────────────────────────────────────────────

    fn dropAllEntries(self: *AssetCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.freeEntry(kv.value_ptr.*);
        }
        self.entries.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    fn freeEntry(self: *AssetCache, entry: *Entry) void {
        if (entry.source) |s| self.allocator.free(s);
        if (entry.content_type) |c| self.allocator.free(c);
        self.allocator.destroy(entry);
    }

    fn findLRU(self: *AssetCache) ?Key {
        var oldest_key: ?Key = null;
        var oldest_at: i64 = std.math.maxInt(i64);
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const at = kv.value_ptr.*.last_accessed_at_ms;
            if (at < oldest_at) {
                oldest_at = at;
                oldest_key = kv.key_ptr.*;
            }
        }
        return oldest_key;
    }

    fn evictByKey(self: *AssetCache, key: Key) !void {
        const entry = self.entries.get(key) orelse return;
        var hex: HexKey = undefined;
        toHex(key, &hex);
        self.dir.deleteFile(&hex) catch |e| switch (e) {
            error.FileNotFound => {}, // already gone — drop index entry anyway
            else => return e,
        };
        self.total_bytes -|= entry.size;
        _ = self.entries.remove(key);
        self.freeEntry(entry);
        self.index_dirty = true;
    }

    // ── Manifest serialization ──────────────────────────────────────

    fn loadManifest(self: *AssetCache) !void {
        const file = try self.dir.openFile(MANIFEST_NAME, .{});
        defer file.close();
        const size = try file.getEndPos();
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);
        const n = try file.readAll(buf);
        if (n != size) return Error.InvalidManifest;
        try self.parseManifest(buf);
    }

    fn parseManifest(self: *AssetCache, bytes: []const u8) !void {
        const ManifestEntry = struct {
            key: []const u8, // hex
            size: u64,
            created_at_ms: i64,
            last_accessed_at_ms: i64,
            source: ?[]const u8 = null,
            content_type: ?[]const u8 = null,
        };
        const Manifest = struct {
            version: u32,
            budget_bytes: u64,
            entries: []const ManifestEntry,
        };

        var parsed = std.json.parseFromSlice(Manifest, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return Error.InvalidManifest;
        defer parsed.deinit();
        if (parsed.value.version != MANIFEST_VERSION) return Error.InvalidManifest;

        // Honour the on-disk budget only if no caller-set override
        // already changed ours from the default — but here we just
        // accept the on-disk value verbatim and let the caller's
        // post-init `setBudget` override if they want a different
        // size. Simpler than tracking "default vs user-set".
        self.budget_bytes = parsed.value.budget_bytes;

        for (parsed.value.entries) |me| {
            if (me.key.len != 64) continue; // skip malformed
            var key: Key = undefined;
            hexDecode(me.key, &key) catch continue;

            // Verify the file exists; skip stale references.
            var hex: HexKey = undefined;
            toHex(key, &hex);
            self.dir.access(&hex, .{}) catch continue;

            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            const source_dup: ?[]u8 = if (me.source) |s| try self.allocator.dupe(u8, s) else null;
            errdefer if (source_dup) |d| self.allocator.free(d);
            const ct_dup: ?[]u8 = if (me.content_type) |c| try self.allocator.dupe(u8, c) else null;
            errdefer if (ct_dup) |d| self.allocator.free(d);

            entry.* = .{
                .key = key,
                .size = me.size,
                .created_at_ms = me.created_at_ms,
                .last_accessed_at_ms = me.last_accessed_at_ms,
                .source = source_dup,
                .content_type = ct_dup,
            };
            try self.entries.put(self.allocator, key, entry);
            self.total_bytes += me.size;
        }
    }

    fn flushManifest(self: *AssetCache) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"version\":");
        try std.fmt.format(w, "{d}", .{MANIFEST_VERSION});
        try w.writeAll(",\"budget_bytes\":");
        try std.fmt.format(w, "{d}", .{self.budget_bytes});
        try w.writeAll(",\"entries\":[");

        var first = true;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!first) try w.writeAll(",");
            first = false;
            const e = kv.value_ptr.*;
            var hex: HexKey = undefined;
            toHex(e.key, &hex);
            try w.writeAll("{\"key\":\"");
            try w.writeAll(&hex);
            try w.writeAll("\",\"size\":");
            try std.fmt.format(w, "{d}", .{e.size});
            try w.writeAll(",\"created_at_ms\":");
            try std.fmt.format(w, "{d}", .{e.created_at_ms});
            try w.writeAll(",\"last_accessed_at_ms\":");
            try std.fmt.format(w, "{d}", .{e.last_accessed_at_ms});
            if (e.source) |s| {
                try w.writeAll(",\"source\":");
                try std.json.stringify(s, .{}, w);
            }
            if (e.content_type) |c| {
                try w.writeAll(",\"content_type\":");
                try std.json.stringify(c, .{}, w);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}\n");

        // Atomic write: tmp + rename. POSIX rename is atomic within a
        // directory; tmp file lives in the same directory so we
        // never cross filesystem boundaries.
        {
            const tmp = try self.dir.createFile(MANIFEST_TMP_NAME, .{ .truncate = true });
            defer tmp.close();
            try tmp.writeAll(buf.items);
            try tmp.sync(); // fsync — manifest must hit disk before rename
        }
        try self.dir.rename(MANIFEST_TMP_NAME, MANIFEST_NAME);
        self.index_dirty = false;
    }
};

// ── Hex helpers ──────────────────────────────────────────────────────

fn toHex(key: Key, out: *HexKey) void {
    const charset = "0123456789abcdef";
    for (key, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
}

fn hexDecode(hex: []const u8, out: *Key) !void {
    if (hex.len != 64) return error.InvalidHex;
    for (0..32) |i| {
        const hi = try nibble(hex[i * 2]);
        const lo = try nibble(hex[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
}

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDir() ![]u8 {
    // testing.tmpDir is per-test but lives under zig-cache/tmp; for
    // these tests we want a real isolated dir, so build one under
    // /tmp/asset_cache_test-<pid>-<counter>.
    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var hex: [32]u8 = undefined;
    toHexHalf(rand_buf, &hex);
    const path = try std.fmt.allocPrint(testing.allocator, "/tmp/asset_cache_test-{s}", .{hex});
    return path;
}

fn toHexHalf(in: [16]u8, out: *[32]u8) void {
    const charset = "0123456789abcdef";
    for (in, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
}

fn cleanup(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    testing.allocator.free(path);
}

test "AssetCache: put then get roundtrips bytes" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 1024);
    defer cache.deinit();

    const key = AssetCache.keyFor(&.{ "model:foo", "prompt:bar" });
    try cache.put(key, "hello world", .{ .source = "test", .content_type = "text/plain" });

    try testing.expect(cache.contains(key));

    const got = (try cache.get(key)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello world", got);

    const s = cache.stats();
    try testing.expectEqual(@as(u32, 1), s.entry_count);
    try testing.expectEqual(@as(u64, 11), s.total_bytes);
    try testing.expectEqual(@as(u64, 1024), s.budget_bytes);
}

test "AssetCache: get miss returns null" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 1024);
    defer cache.deinit();

    const key = AssetCache.keyFor(&.{"never-put"});
    try testing.expect(!cache.contains(key));
    try testing.expectEqual(@as(?[]u8, null), try cache.get(key));
}

test "AssetCache: put replaces same-key entry" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 1024);
    defer cache.deinit();

    const key = AssetCache.keyFor(&.{"k"});
    try cache.put(key, "v1", .{});
    try cache.put(key, "v2-longer", .{});

    const got = (try cache.get(key)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("v2-longer", got);
    try testing.expectEqual(@as(u32, 1), cache.stats().entry_count);
    try testing.expectEqual(@as(u64, 9), cache.stats().total_bytes);
}

test "AssetCache: LRU eviction when budget exceeded" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 20);
    defer cache.deinit();

    const k1 = AssetCache.keyFor(&.{"a"});
    const k2 = AssetCache.keyFor(&.{"b"});
    const k3 = AssetCache.keyFor(&.{"c"});

    try cache.put(k1, "0123456789", .{}); // 10
    std.time.sleep(5 * std.time.ns_per_ms);
    try cache.put(k2, "0123456789", .{}); // 20, total now 20
    std.time.sleep(5 * std.time.ns_per_ms);

    // Bump k1 access so k2 becomes LRU. Need a sleep both before and
    // after so the get's milliTimestamp lands in its own tick.
    const got = (try cache.get(k1)).?;
    testing.allocator.free(got);
    std.time.sleep(5 * std.time.ns_per_ms);

    try cache.put(k3, "0123456789", .{}); // would push to 30; k2 evicts

    try testing.expect(cache.contains(k1));
    try testing.expect(!cache.contains(k2));
    try testing.expect(cache.contains(k3));
    try testing.expectEqual(@as(u64, 20), cache.stats().total_bytes);
}

test "AssetCache: EntryExceedsBudget for oversized put" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 10);
    defer cache.deinit();

    const key = AssetCache.keyFor(&.{"big"});
    try testing.expectError(Error.EntryExceedsBudget, cache.put(key, "way more than ten bytes", .{}));
    try testing.expect(!cache.contains(key));
}

test "AssetCache: manifest persists across reopen" {
    const path = try tmpDir();
    defer cleanup(path);

    const key = AssetCache.keyFor(&.{"persist-me"});

    {
        const c1 = try AssetCache.init(testing.allocator, path, 1024);
        defer c1.deinit();
        try c1.put(key, "persistent bytes", .{ .source = "first-run" });
    }

    {
        const c2 = try AssetCache.init(testing.allocator, path, 1024);
        defer c2.deinit();
        try testing.expect(c2.contains(key));
        const got = (try c2.get(key)).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("persistent bytes", got);
    }
}

test "AssetCache: pruneOlderThan drops old entries only" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 1024);
    defer cache.deinit();

    const k_old = AssetCache.keyFor(&.{"old"});
    try cache.put(k_old, "old", .{});
    std.time.sleep(5 * std.time.ns_per_ms);

    const cutoff = std.time.milliTimestamp();
    std.time.sleep(5 * std.time.ns_per_ms);
    const k_new = AssetCache.keyFor(&.{"new"});
    try cache.put(k_new, "new", .{});

    const evicted = try cache.pruneOlderThan(cutoff);
    try testing.expectEqual(@as(u32, 1), evicted);
    try testing.expect(!cache.contains(k_old));
    try testing.expect(cache.contains(k_new));
}

test "AssetCache: pruneAll wipes everything" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 1024);
    defer cache.deinit();

    try cache.put(AssetCache.keyFor(&.{"a"}), "aa", .{});
    try cache.put(AssetCache.keyFor(&.{"b"}), "bb", .{});

    try cache.pruneAll();
    try testing.expectEqual(@as(u32, 0), cache.stats().entry_count);
    try testing.expectEqual(@as(u64, 0), cache.stats().total_bytes);
}

test "AssetCache: keyFor disambiguates concatenations" {
    const k1 = AssetCache.keyFor(&.{ "a", "bc" });
    const k2 = AssetCache.keyFor(&.{ "ab", "c" });
    try testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "AssetCache: stale-file disappearance reports miss + clears index" {
    const path = try tmpDir();
    defer cleanup(path);

    const cache = try AssetCache.init(testing.allocator, path, 1024);
    defer cache.deinit();

    const key = AssetCache.keyFor(&.{"vanish"});
    try cache.put(key, "data", .{});
    try testing.expect(cache.contains(key));

    // Externally delete the bytes file.
    var hex: HexKey = undefined;
    toHex(key, &hex);
    try cache.dir.deleteFile(&hex);

    try testing.expectEqual(@as(?[]u8, null), try cache.get(key));
    try testing.expect(!cache.contains(key));
}
