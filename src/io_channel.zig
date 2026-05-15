//! `IoChannel` — fire-and-forget async I/O on top of the work-stealing
//! [`JobSystem`](jobs.zig).
//!
//! The mismatch we're papering over: `JobSystem` is fork-join. The
//! caller schedules N jobs, then `waitFor(counter)` blocks until they
//! all finish. That's wrong for I/O — an HTTP fetch holds a worker
//! for hundreds of ms, and the renderer must not wait. We want:
//!
//!   1. **Submit** a Request on the main thread, get a [`Handle`] back,
//!      keep rendering.
//!   2. A worker picks up the Job, does the blocking I/O.
//!   3. Worker pushes a [`Completion`] onto a mutex-guarded MPSC queue.
//!   4. Main thread calls [`drain`] once per frame to flush completions
//!      through a caller-supplied handler.
//!
//! ### Why a mutex queue, not a lock-free MPSC?
//!
//! Completion volume is small — a handful of fetches per second,
//! drained at 60+ Hz on the main thread. Contention is essentially
//! zero, and a lock-free MPSC ring would add complexity that's not
//! load-bearing yet. Swap in a Vyukov MPSC when the load justifies.
//!
//! ### Memory ownership
//!
//! * `Request.http_get.url` — caller's; we dupe internally so the
//!   caller can free or reuse it the moment `submit` returns.
//! * `Completion.result.ok.body` — owned by the IoChannel allocator.
//!   The handler is responsible for either consuming it in place or
//!   freeing via [`releaseOk`].
//! * Completions left undrained at deinit have their bodies released
//!   automatically.
//!
//! ### Generations and stale completions
//!
//! Callers stash an opaque `user_data: usize` at submit time — most
//! often a packed (component-pointer, generation) pair. When the
//! completion lands, the handler verifies the generation against the
//! current state of the target before applying. The IoChannel itself
//! does not interpret `user_data`; it only round-trips it.

const std = @import("std");
const jobs_mod = @import("jobs.zig");

pub const Error = error{
    HttpStatusNotOk,
} || std.mem.Allocator.Error;

pub const RequestKind = enum {
    http_get,
    http_stream,
};

pub const Request = union(RequestKind) {
    http_get: HttpGetRequest,
    http_stream: HttpStreamRequest,
};

pub const HttpGetRequest = struct {
    /// Borrowed reference; IoChannel dupes internally.
    url: []const u8,
    /// Hard cap on the response body. Same default as the previous
    /// synchronous cachedFetch.
    max_bytes: usize = 8 * 1024 * 1024,
};

pub const HttpMethod = enum { GET, POST };

pub const HttpStreamRequest = struct {
    /// Borrowed reference; IoChannel dupes internally.
    url: []const u8,
    method: HttpMethod = .POST,
    /// Optional request body (e.g. JSON for an LLM chat call).
    /// Duped internally so caller may free post-submit.
    body: ?[]const u8 = null,
    /// Optional content-type header. `null` defaults to
    /// `application/json` when `body` is set, omitted otherwise.
    content_type: ?[]const u8 = null,
    /// Additional request headers (Bearer auth, x-api-key, etc).
    /// Both name and value are duped into the worker context, so
    /// the caller's slice may be freed immediately after submit.
    extra_headers: ?[]const Header = null,
    /// Read-buffer size — the granularity at which the worker
    /// observes the response and posts `chunk` completions. Bigger
    /// = fewer completions / less main-thread routing overhead;
    /// smaller = lower latency per token.
    chunk_size: usize = 2048,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Owned counterpart used inside the worker context (post-dupe).
const OwnedHeader = struct {
    name: []u8,
    value: []u8,
};

pub const ResultKind = enum {
    ok,
    err,
    chunk,
    end,
    end_err,
};

pub const Result = union(ResultKind) {
    /// One-shot fetch success. Body bytes owned by the channel's
    /// allocator; free with [`IoChannel.releaseOk`] or
    /// `channel.allocator.free(body)`.
    ok: []u8,
    /// One-shot fetch error.
    err: anyerror,
    /// Streaming chunk — more completions follow under the same
    /// Handle. Bytes owned by the channel's allocator (same release
    /// path as `.ok`).
    chunk: []u8,
    /// Stream finished cleanly. The Handle is retired; no more
    /// completions will arrive for it.
    end: void,
    /// Stream errored mid-flight. The Handle is retired.
    end_err: anyerror,
};

pub const Handle = u64;

pub const Completion = struct {
    handle: Handle,
    /// Opaque tag set by the caller at submit time. Round-tripped
    /// unchanged. Use it to route the completion back to whatever
    /// owns the in-flight request.
    user_data: usize,
    result: Result,
};

/// Polymorphic completion header. By convention every owner-side
/// "Pending" struct begins with one of these; `user_data` is then
/// `@intFromPtr(&pending)`, and the host's drain loop reads the
/// first usize at `user_data` to dispatch.
///
/// Pre-stage-13d.3 the host's drainHandler routed by Result kind
/// (`.ok/.err` → embedded-document, `.chunk/.end/.end_err` →
/// llm-stream). That broke the moment a second `.chunk`-shaped
/// consumer (svg-stream) needed routing too. This header lets each
/// pending fetch carry its own completion handler — `svg-stream`
/// and `llm-stream` produce the same Result variants but route to
/// different code without the host having to special-case either.
pub const PendingHeader = struct {
    handle_completion: *const fn (Completion) void,
};

pub const IoChannel = struct {
    allocator: std.mem.Allocator,
    jobs: *jobs_mod.JobSystem,

    mutex: std.Thread.Mutex = .{},
    completions: std.ArrayListUnmanaged(Completion) = .{},

    next_handle: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn init(allocator: std.mem.Allocator, jobs: *jobs_mod.JobSystem) IoChannel {
        return .{ .allocator = allocator, .jobs = jobs };
    }

    pub fn deinit(self: *IoChannel) void {
        // Drain any leftover completions so their owned bodies don't
        // leak. The JobSystem is the caller's responsibility — they
        // should have called its deinit (which joins worker threads)
        // before deiniting the channel, otherwise late-arriving
        // completions would race with this teardown.
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.completions.items) |c| {
            switch (c.result) {
                .ok => |body| self.allocator.free(body),
                .chunk => |bytes| self.allocator.free(bytes),
                .err, .end, .end_err => {},
            }
        }
        self.completions.deinit(self.allocator);
    }

    /// Issue an async HTTP GET. Returns a [`Handle`] that will appear
    /// on the matching [`Completion`] when it arrives. `url` is
    /// copied internally — caller may free immediately after this
    /// returns. `user_data` rides along with the completion.
    pub fn submitHttpGet(self: *IoChannel, url: []const u8, user_data: usize) !Handle {
        const handle = self.next_handle.fetchAdd(1, .monotonic);

        const ctx = try self.allocator.create(HttpGetCtx);
        errdefer self.allocator.destroy(ctx);

        const url_dup = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_dup);

        ctx.* = .{
            .channel = self,
            .url = url_dup,
            .handle = handle,
            .user_data = user_data,
            .max_bytes = 8 * 1024 * 1024,
        };

        var job = jobs_mod.Job{ .func = httpGetJob };
        job.setData(*HttpGetCtx, ctx);
        self.jobs.schedule(job);

        return handle;
    }

    /// Add a streaming HTTP request to the worker pool. Each chunk
    /// arriving on the wire produces a `.chunk` Completion (caller
    /// must free via [`releaseOk`] — same release path); the stream
    /// is terminated by exactly one `.end` or `.end_err`. All
    /// carry the same Handle.
    pub fn submitHttpStream(
        self: *IoChannel,
        req: HttpStreamRequest,
        user_data: usize,
    ) !Handle {
        const handle = self.next_handle.fetchAdd(1, .monotonic);
        const a = self.allocator;

        const ctx = try a.create(HttpStreamCtx);
        errdefer a.destroy(ctx);

        const url_dup = try a.dupe(u8, req.url);
        errdefer a.free(url_dup);

        const body_dup: ?[]u8 = if (req.body) |b| try a.dupe(u8, b) else null;
        errdefer if (body_dup) |b| a.free(b);

        const ct_dup: ?[]u8 = if (req.content_type) |ct| try a.dupe(u8, ct) else null;
        errdefer if (ct_dup) |ct| a.free(ct);

        // Dupe extra headers into a flat slice we can hand to the
        // worker. Failure mid-loop unwinds via errdefer freeing what's
        // already been allocated.
        const headers_src: []const Header = req.extra_headers orelse &.{};
        const headers_dup = try a.alloc(OwnedHeader, headers_src.len);
        var headers_filled: usize = 0;
        errdefer {
            for (headers_dup[0..headers_filled]) |h| {
                a.free(h.name);
                a.free(h.value);
            }
            a.free(headers_dup);
        }
        for (headers_src, 0..) |h, i| {
            const n = try a.dupe(u8, h.name);
            errdefer a.free(n);
            const v = try a.dupe(u8, h.value);
            errdefer a.free(v);
            headers_dup[i] = .{ .name = n, .value = v };
            headers_filled = i + 1;
        }

        ctx.* = .{
            .channel = self,
            .url = url_dup,
            .method = req.method,
            .body = body_dup,
            .content_type = ct_dup,
            .extra_headers = headers_dup,
            .handle = handle,
            .user_data = user_data,
            .chunk_size = req.chunk_size,
        };

        var job = jobs_mod.Job{ .func = httpStreamJob };
        job.setData(*HttpStreamCtx, ctx);
        self.jobs.schedule(job);
        return handle;
    }

    /// Test/synthetic-event hook: queue an arbitrary Completion as
    /// if a worker had produced it. Used by unit tests so they don't
    /// need a real HTTP server, and reserved for future synthetic
    /// channel sources (timers, fake LLM streams in fixtures, etc).
    pub fn postCompletion(self: *IoChannel, c: Completion) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.completions.append(self.allocator, c);
    }

    /// Drain all pending completions through a caller-supplied
    /// handler. Returns the count drained. The handler runs OUTSIDE
    /// the queue lock so it's safe to call back into `submitHttpGet`
    /// (chain a follow-up fetch) without self-deadlock.
    ///
    /// Handler signature: `fn(@TypeOf(ctx), Completion) void`.
    pub fn drain(
        self: *IoChannel,
        ctx: anytype,
        comptime handler: fn (@TypeOf(ctx), Completion) void,
    ) usize {
        // Swap the items out under the lock into a local buffer, then
        // release the lock before invoking handlers. Workers can keep
        // posting fresh completions while handlers run.
        var local: std.ArrayListUnmanaged(Completion) = .{};
        defer local.deinit(self.allocator);

        self.mutex.lock();
        const tmp = self.completions;
        self.completions = .{};
        self.mutex.unlock();
        local = tmp;

        for (local.items) |c| handler(ctx, c);
        return local.items.len;
    }

    /// Convenience helper: free a successful response body.
    pub fn releaseOk(self: *IoChannel, body: []u8) void {
        self.allocator.free(body);
    }

    /// For metrics / debug: current queue depth.
    pub fn pending(self: *IoChannel) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completions.items.len;
    }
};

// ── HTTP GET job ─────────────────────────────────────────────────────

const HttpGetCtx = struct {
    channel: *IoChannel,
    url: []u8,
    handle: Handle,
    user_data: usize,
    max_bytes: usize,
};

fn httpGetJob(job: *jobs_mod.Job) void {
    const ctx = job.getData(*HttpGetCtx);
    const ch = ctx.channel;
    const a = ch.allocator;

    // Always free the request context + url copy when the worker is
    // done with them, regardless of fetch outcome.
    defer {
        a.free(ctx.url);
        a.destroy(ctx);
    }

    var client = std.http.Client{ .allocator = a };
    defer client.deinit();

    var body = std.ArrayList(u8).init(a);
    // Ownership transfers to the Completion on success; explicit
    // free on every error path below.
    var body_owned = false;
    defer if (!body_owned) body.deinit();

    const fetch_result = client.fetch(.{
        .location = .{ .url = ctx.url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = ctx.max_bytes,
    });

    var completion: Completion = .{
        .handle = ctx.handle,
        .user_data = ctx.user_data,
        .result = undefined,
    };

    if (fetch_result) |res| {
        if (res.status == .ok) {
            const owned = body.toOwnedSlice() catch |e| {
                completion.result = .{ .err = e };
                postOrLeak(ch, completion);
                return;
            };
            body_owned = true;
            completion.result = .{ .ok = owned };
        } else {
            completion.result = .{ .err = Error.HttpStatusNotOk };
        }
    } else |e| {
        completion.result = .{ .err = e };
    }

    postOrLeak(ch, completion);
}

/// If posting the completion itself fails (OOM on the completion
/// queue grow), release any owned body so we don't leak it.
fn postOrLeak(ch: *IoChannel, c: Completion) void {
    ch.postCompletion(c) catch {
        switch (c.result) {
            .ok => |body| ch.allocator.free(body),
            .chunk => |bytes| ch.allocator.free(bytes),
            .err, .end, .end_err => {},
        }
    };
}

// ── HTTP stream job (POST + chunked response) ───────────────────────

const HttpStreamCtx = struct {
    channel: *IoChannel,
    url: []u8,
    method: HttpMethod,
    body: ?[]u8,
    content_type: ?[]u8,
    extra_headers: []OwnedHeader, // empty slice if none
    handle: Handle,
    user_data: usize,
    chunk_size: usize,
};

fn httpStreamJob(job: *jobs_mod.Job) void {
    const ctx = job.getData(*HttpStreamCtx);
    const ch = ctx.channel;
    const a = ch.allocator;

    defer {
        a.free(ctx.url);
        if (ctx.body) |b| a.free(b);
        if (ctx.content_type) |ct| a.free(ct);
        for (ctx.extra_headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(ctx.extra_headers);
        a.destroy(ctx);
    }

    const endWithErr = struct {
        fn call(channel: *IoChannel, h: Handle, ud: usize, e: anyerror) void {
            postOrLeak(channel, .{
                .handle = h,
                .user_data = ud,
                .result = .{ .end_err = e },
            });
        }
    }.call;

    var client = std.http.Client{ .allocator = a };
    defer client.deinit();

    const uri = std.Uri.parse(ctx.url) catch |e| {
        endWithErr(ch, ctx.handle, ctx.user_data, e);
        return;
    };

    var server_header_buffer: [16 * 1024]u8 = undefined;

    const method: std.http.Method = switch (ctx.method) {
        .GET => .GET,
        .POST => .POST,
    };

    // Assemble the std.http header list: one slot for content-type
    // (if a body is set), plus any caller-supplied auth/custom
    // headers. Allocated dynamically — the count is request-shaped
    // and >0-arg flat arrays don't play well with Zig's
    // const-anyway eval here.
    const ct_count: usize = if (ctx.body != null) 1 else 0;
    const total = ct_count + ctx.extra_headers.len;
    const hdr_list = a.alloc(std.http.Header, total) catch |e| {
        endWithErr(ch, ctx.handle, ctx.user_data, e);
        return;
    };
    defer a.free(hdr_list);
    if (ctx.body != null) {
        hdr_list[0] = .{
            .name = "content-type",
            .value = ctx.content_type orelse "application/json",
        };
    }
    for (ctx.extra_headers, 0..) |h, i| {
        hdr_list[ct_count + i] = .{ .name = h.name, .value = h.value };
    }

    var req = client.open(method, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = hdr_list,
    }) catch |e| {
        endWithErr(ch, ctx.handle, ctx.user_data, e);
        return;
    };
    defer req.deinit();

    if (ctx.body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
    }

    req.send() catch |e| {
        endWithErr(ch, ctx.handle, ctx.user_data, e);
        return;
    };

    if (ctx.body) |b| {
        req.writeAll(b) catch |e| {
            endWithErr(ch, ctx.handle, ctx.user_data, e);
            return;
        };
        req.finish() catch |e| {
            endWithErr(ch, ctx.handle, ctx.user_data, e);
            return;
        };
    }

    req.wait() catch |e| {
        endWithErr(ch, ctx.handle, ctx.user_data, e);
        return;
    };

    if (req.response.status != .ok) {
        endWithErr(ch, ctx.handle, ctx.user_data, Error.HttpStatusNotOk);
        return;
    }

    // Read loop. Each successful read posts one `.chunk` completion
    // owning a freshly-duped slice of `bytes_read` bytes.
    while (true) {
        const chunk_buf = a.alloc(u8, ctx.chunk_size) catch |e| {
            endWithErr(ch, ctx.handle, ctx.user_data, e);
            return;
        };
        const n = req.read(chunk_buf) catch |e| {
            a.free(chunk_buf);
            endWithErr(ch, ctx.handle, ctx.user_data, e);
            return;
        };
        if (n == 0) {
            a.free(chunk_buf);
            break;
        }
        // Trim to actual read size to avoid streaming garbage past
        // the wire-truthful slice; resize-in-place is cheap.
        const trimmed: []u8 = if (a.resize(chunk_buf, n)) chunk_buf[0..n] else blk: {
            const tight = a.alloc(u8, n) catch {
                a.free(chunk_buf);
                endWithErr(ch, ctx.handle, ctx.user_data, error.OutOfMemory);
                return;
            };
            @memcpy(tight, chunk_buf[0..n]);
            a.free(chunk_buf);
            break :blk tight;
        };
        postOrLeak(ch, .{
            .handle = ctx.handle,
            .user_data = ctx.user_data,
            .result = .{ .chunk = trimmed },
        });
    }

    postOrLeak(ch, .{
        .handle = ctx.handle,
        .user_data = ctx.user_data,
        .result = .{ .end = {} },
    });
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "IoChannel: synthetic postCompletion → drain roundtrip" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);
    defer ch.deinit();

    try ch.postCompletion(.{
        .handle = 7,
        .user_data = 0xC0FFEE,
        .result = .{ .err = error.TestSentinel },
    });

    var seen: usize = 0;
    var saw_user_data: usize = 0;
    var saw_handle: Handle = 0;

    const Ctx = struct {
        seen: *usize,
        saw_user_data: *usize,
        saw_handle: *Handle,
    };
    var ctx = Ctx{ .seen = &seen, .saw_user_data = &saw_user_data, .saw_handle = &saw_handle };

    const n = ch.drain(&ctx, struct {
        fn h(c: *Ctx, comp: Completion) void {
            c.seen.* += 1;
            c.saw_user_data.* = comp.user_data;
            c.saw_handle.* = comp.handle;
        }
    }.h);

    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 1), seen);
    try testing.expectEqual(@as(usize, 0xC0FFEE), saw_user_data);
    try testing.expectEqual(@as(Handle, 7), saw_handle);
}

test "IoChannel: drain returns zero when empty" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);
    defer ch.deinit();

    var calls: usize = 0;
    const Ctx = struct { calls: *usize };
    var ctx = Ctx{ .calls = &calls };
    const n = ch.drain(&ctx, struct {
        fn h(c: *Ctx, _: Completion) void {
            c.calls.* += 1;
        }
    }.h);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(usize, 0), calls);
}

test "IoChannel: handles are monotonically unique" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);
    defer ch.deinit();

    // Bypass submit (no network in tests): mutate next_handle directly
    // and check it advances. Equivalent to what submitHttpGet does
    // internally, without launching a real fetch.
    const h1 = ch.next_handle.fetchAdd(1, .monotonic);
    const h2 = ch.next_handle.fetchAdd(1, .monotonic);
    const h3 = ch.next_handle.fetchAdd(1, .monotonic);
    try testing.expect(h2 == h1 + 1);
    try testing.expect(h3 == h2 + 1);
}

test "IoChannel: deinit releases ok-bodies of undrained completions" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);

    const body1 = try testing.allocator.dupe(u8, "hello");
    const body2 = try testing.allocator.dupe(u8, "world!");
    try ch.postCompletion(.{
        .handle = 1,
        .user_data = 0,
        .result = .{ .ok = body1 },
    });
    try ch.postCompletion(.{
        .handle = 2,
        .user_data = 0,
        .result = .{ .ok = body2 },
    });

    // Leave them undrained on purpose — deinit should free both
    // without a leak report.
    ch.deinit();
}

test "IoChannel: handler can post a follow-up completion without deadlock" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);
    defer ch.deinit();

    try ch.postCompletion(.{
        .handle = 1,
        .user_data = 0,
        .result = .{ .err = error.First },
    });

    const Ctx = struct { channel: *IoChannel };
    var ctx = Ctx{ .channel = &ch };
    const n1 = ch.drain(&ctx, struct {
        fn h(c: *Ctx, _: Completion) void {
            c.channel.postCompletion(.{
                .handle = 2,
                .user_data = 0,
                .result = .{ .err = error.Followup },
            }) catch {};
        }
    }.h);
    try testing.expectEqual(@as(usize, 1), n1);

    // The follow-up should now be drainable.
    var saw: usize = 0;
    const C2 = struct { saw: *usize };
    var c2 = C2{ .saw = &saw };
    const n2 = ch.drain(&c2, struct {
        fn h(c: *C2, _: Completion) void {
            c.saw.* += 1;
        }
    }.h);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqual(@as(usize, 1), saw);
}

test "IoChannel: stream variants — chunks then end, in order, freed on undrained deinit" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);

    // Three chunk completions + one end. Build owned slices so the
    // deinit path has to free the chunk bytes (undrained on purpose).
    const c1 = try testing.allocator.dupe(u8, "alpha");
    const c2 = try testing.allocator.dupe(u8, "beta");
    const c3 = try testing.allocator.dupe(u8, "gamma");
    try ch.postCompletion(.{ .handle = 42, .user_data = 0, .result = .{ .chunk = c1 } });
    try ch.postCompletion(.{ .handle = 42, .user_data = 0, .result = .{ .chunk = c2 } });
    try ch.postCompletion(.{ .handle = 42, .user_data = 0, .result = .{ .chunk = c3 } });
    try ch.postCompletion(.{ .handle = 42, .user_data = 0, .result = .{ .end = {} } });

    // Leave them undrained — deinit must release the chunk bytes
    // without leaking (testing.allocator catches any leak).
    ch.deinit();
}

test "IoChannel: stream — drained chunks land in order under same handle" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);
    defer ch.deinit();

    const c1 = try testing.allocator.dupe(u8, "Hello, ");
    const c2 = try testing.allocator.dupe(u8, "world!");
    try ch.postCompletion(.{ .handle = 7, .user_data = 0, .result = .{ .chunk = c1 } });
    try ch.postCompletion(.{ .handle = 7, .user_data = 0, .result = .{ .chunk = c2 } });
    try ch.postCompletion(.{ .handle = 7, .user_data = 0, .result = .{ .end = {} } });

    const Acc = struct {
        ch: *IoChannel,
        buf: *std.ArrayList(u8),
        ended: *bool,
        order_ok: *bool,
        last_handle: *Handle,
    };
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    var ended = false;
    var order_ok = true;
    var last_handle: Handle = 0;
    var acc = Acc{
        .ch = &ch,
        .buf = &buf,
        .ended = &ended,
        .order_ok = &order_ok,
        .last_handle = &last_handle,
    };

    const n = ch.drain(&acc, struct {
        fn h(a: *Acc, comp: Completion) void {
            if (a.last_handle.* != 0 and a.last_handle.* != comp.handle) {
                a.order_ok.* = false;
            }
            a.last_handle.* = comp.handle;
            switch (comp.result) {
                .chunk => |bytes| {
                    a.buf.appendSlice(bytes) catch {};
                    a.ch.releaseOk(bytes);
                },
                .end => a.ended.* = true,
                .end_err => a.ended.* = true,
                else => {},
            }
        }
    }.h);

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Hello, world!", buf.items);
    try testing.expect(ended);
    try testing.expect(order_ok);
}

test "IoChannel: worker-thread postCompletion via scheduled job" {
    const jobs = try jobs_mod.JobSystem.init(testing.allocator, 2);
    defer jobs.deinit();

    var ch = IoChannel.init(testing.allocator, jobs);
    defer ch.deinit();

    const SyntheticCtx = struct {
        channel: *IoChannel,
        handle: Handle,
        user_data: usize,
    };
    const sctx = try testing.allocator.create(SyntheticCtx);
    sctx.* = .{ .channel = &ch, .handle = 99, .user_data = 0xDEADBEEF };

    var counter = jobs_mod.Counter.init(0);
    var job = jobs_mod.Job{
        .func = struct {
            fn run(j: *jobs_mod.Job) void {
                const c = j.getData(*SyntheticCtx);
                c.channel.postCompletion(.{
                    .handle = c.handle,
                    .user_data = c.user_data,
                    .result = .{ .err = error.SyntheticFromWorker },
                }) catch {};
            }
        }.run,
        .counter = &counter,
    };
    job.setData(*SyntheticCtx, sctx);
    jobs.schedule(job);
    jobs.waitFor(&counter);
    testing.allocator.destroy(sctx);

    var seen_handle: Handle = 0;
    var seen_user: usize = 0;
    const Ctx = struct { h: *Handle, u: *usize };
    var ctx = Ctx{ .h = &seen_handle, .u = &seen_user };
    const drained = ch.drain(&ctx, struct {
        fn h(c: *Ctx, comp: Completion) void {
            c.h.* = comp.handle;
            c.u.* = comp.user_data;
        }
    }.h);
    try testing.expectEqual(@as(usize, 1), drained);
    try testing.expectEqual(@as(Handle, 99), seen_handle);
    try testing.expectEqual(@as(usize, 0xDEADBEEF), seen_user);
}
