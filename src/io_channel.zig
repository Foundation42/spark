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
};

pub const Request = union(RequestKind) {
    http_get: HttpGetRequest,
};

pub const HttpGetRequest = struct {
    /// Borrowed reference; IoChannel dupes internally.
    url: []const u8,
    /// Hard cap on the response body. Same default as the previous
    /// synchronous cachedFetch.
    max_bytes: usize = 8 * 1024 * 1024,
};

pub const ResultKind = enum {
    ok,
    err,
};

pub const Result = union(ResultKind) {
    /// Body bytes; owned by the channel's allocator. Free with
    /// [`IoChannel.releaseOk`] or `channel.allocator.free(body)`.
    ok: []u8,
    err: anyerror,
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
                .err => {},
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
            .err => {},
        }
    };
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
