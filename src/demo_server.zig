//! Minimal local HTTP server (stage 11 demo support).
//!
//! Serves files from `src/widgets/` on `127.0.0.1:8080` so the demo
//! can exercise `:::embedded-document {src="http://..."}` without an
//! external dependency. Single-threaded accept loop, GET-only,
//! permissive about request parsing (extracts the path; ignores
//! everything else). Plenty for a demo; emphatically NOT a
//! production server.
//!
//! Lifecycle: `start()` binds the listener synchronously (so the
//! `:::embedded-document` parse can fetch immediately) and spawns
//! a detached worker thread. `stop()` closes the listener; the
//! worker's pending `accept()` returns an error and the loop
//! exits.

const std = @import("std");

pub const Server = struct {
    listener: std.net.Server,
    widgets_dir: []const u8,
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,

    pub fn start(allocator: std.mem.Allocator, widgets_dir: []const u8, port: u16) !*Server {
        const addr = try std.net.Address.parseIp("127.0.0.1", port);
        const listener = try addr.listen(.{ .reuse_address = true });
        const s = try allocator.create(Server);
        s.* = .{
            .listener = listener,
            .widgets_dir = widgets_dir,
            .allocator = allocator,
            .thread = null,
        };
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
        return s;
    }

    pub fn stop(self: *Server) void {
        // `shutdown(.both)` on the listening socket is what actually
        // wakes the worker's blocked `accept()` with an error — plain
        // `close()` doesn't reliably do that on Linux (the accept can
        // sit indefinitely waiting on a now-dead fd). After the
        // shutdown the worker exits its loop, we join it, then
        // release the listener's resources.
        std.posix.shutdown(self.listener.stream.handle, .both) catch {};
        if (self.thread) |t| t.join();
        self.listener.deinit();
        self.allocator.destroy(self);
    }
};

fn loop(s: *Server) void {
    while (true) {
        const conn = s.listener.accept() catch return;
        defer conn.stream.close();
        handle(conn, s.widgets_dir, s.allocator) catch {};
    }
}

fn handle(conn: std.net.Server.Connection, widgets_dir: []const u8, allocator: std.mem.Allocator) !void {
    // Read up to 2 KiB of the request — enough for a GET line +
    // typical headers. We only look at the request line.
    var buf: [2048]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    const line_end = std.mem.indexOfScalar(u8, request, '\n') orelse request.len;
    const request_line = std.mem.trimRight(u8, request[0..line_end], " \t\r");

    // "GET /path HTTP/1.1"
    var it = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = it.next() orelse return;
    const path_raw = it.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) {
        try writeStatus(conn.stream, 405, "Method Not Allowed", null);
        return;
    }

    // Strip leading "/" and reject any ".." for trivial path-traversal
    // safety. The server's job is to serve markdown widgets to a
    // localhost demo — anything fancier is out of scope.
    if (path_raw.len == 0 or path_raw[0] != '/') {
        try writeStatus(conn.stream, 400, "Bad Request", null);
        return;
    }
    const rel = path_raw[1..];
    if (std.mem.indexOf(u8, rel, "..") != null) {
        try writeStatus(conn.stream, 400, "Bad Request", null);
        return;
    }

    var full_path_buf: [512]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ widgets_dir, rel }) catch {
        try writeStatus(conn.stream, 414, "URI Too Long", null);
        return;
    };

    const body = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch |err| {
        const status: u16 = if (err == error.FileNotFound) 404 else 500;
        try writeStatus(conn.stream, status, if (status == 404) "Not Found" else "Internal Server Error", null);
        return;
    };
    defer allocator.free(body);

    try writeStatus(conn.stream, 200, "OK", body);
}

fn writeStatus(stream: std.net.Stream, status: u16, reason: []const u8, body: ?[]const u8) !void {
    var header_buf: [256]u8 = undefined;
    const ct = "text/markdown; charset=utf-8";
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, reason, ct, if (body) |b| b.len else 0 },
    );
    _ = try stream.write(header);
    if (body) |b| _ = try stream.writeAll(b);
}
