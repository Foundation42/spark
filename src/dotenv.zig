//! `~/.env`-style file loader.
//!
//! Parses lines of the form `KEY=VALUE`. Blank lines and lines whose
//! first non-whitespace character is `#` are ignored. Values may be
//! optionally wrapped in matching single or double quotes; the
//! quotes are stripped. There is no `\n`-escape handling — values
//! are taken literally up to the end of the line.
//!
//! Lifetime: keys + values are duped into the supplied allocator.
//! `deinit` frees both.
//!
//! This is a deliberately tiny loader — it does not call out to a
//! shell, does not handle multi-line values, and does not honour
//! Bash export/unset syntax. Good enough for stashing API keys for
//! `:::llm-stream` and similar; revisit if we ever need anything
//! richer.

const std = @import("std");

pub const Error = error{
    InvalidLine,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError;

pub const DotEnv = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn init(allocator: std.mem.Allocator) DotEnv {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DotEnv) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    /// Look up a key. Returned slice is borrowed from the map and
    /// invalidated by `deinit`.
    pub fn get(self: *const DotEnv, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    /// Parse a buffer (already in memory) into key/value pairs.
    pub fn parse(self: *DotEnv, source: []const u8) !void {
        var line_it = std.mem.splitScalar(u8, source, '\n');
        while (line_it.next()) |raw_line| {
            // Strip CR for CRLF files.
            const line = std.mem.trimRight(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                return Error.InvalidLine;
            };
            const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
            var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
            if (key.len == 0) return Error.InvalidLine;

            // Strip matching surrounding quotes if present.
            if (value.len >= 2) {
                const f = value[0];
                if ((f == '"' or f == '\'') and value[value.len - 1] == f) {
                    value = value[1 .. value.len - 1];
                }
            }

            const k_dup = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(k_dup);
            const v_dup = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(v_dup);

            // Last write wins — replace any prior value under the
            // same key, freeing the old.
            if (self.map.fetchRemove(k_dup)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
            try self.map.put(self.allocator, k_dup, v_dup);
        }
    }

    /// Convenience: open a file, read it, parse it. Logs a debug
    /// message if the file is missing (most processes don't care)
    /// and returns silently; other read/parse errors propagate.
    pub fn loadFromPath(self: *DotEnv, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        // Reasonable cap — .env files are KV pairs, not databases.
        const bytes = try file.readToEndAlloc(self.allocator, 1 * 1024 * 1024);
        defer self.allocator.free(bytes);
        try self.parse(bytes);
    }

    /// Helper for the very common "look in ~/.env" case.
    pub fn loadDefault(self: *DotEnv) !void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
        defer self.allocator.free(home);
        const path = try std.fs.path.join(self.allocator, &.{ home, ".env" });
        defer self.allocator.free(path);
        try self.loadFromPath(path);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "DotEnv: parses KEY=VALUE pairs" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.parse("FOO=bar\nBAZ=qux\n");
    try testing.expectEqualStrings("bar", env.get("FOO").?);
    try testing.expectEqualStrings("qux", env.get("BAZ").?);
}

test "DotEnv: skips comments and blank lines" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.parse(
        \\# this is a comment
        \\
        \\KEY1=value1
        \\   # indented comment
        \\KEY2=value2
        \\
    );
    try testing.expectEqualStrings("value1", env.get("KEY1").?);
    try testing.expectEqualStrings("value2", env.get("KEY2").?);
    try testing.expect(env.get("# this is a comment") == null);
}

test "DotEnv: strips matching surrounding quotes" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.parse(
        \\A="quoted value"
        \\B='single quoted'
        \\C=unquoted
        \\D="mismatched'
        \\
    );
    try testing.expectEqualStrings("quoted value", env.get("A").?);
    try testing.expectEqualStrings("single quoted", env.get("B").?);
    try testing.expectEqualStrings("unquoted", env.get("C").?);
    try testing.expectEqualStrings("\"mismatched'", env.get("D").?);
}

test "DotEnv: handles CRLF" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.parse("KEY=value\r\nOTHER=foo\r\n");
    try testing.expectEqualStrings("value", env.get("KEY").?);
    try testing.expectEqualStrings("foo", env.get("OTHER").?);
}

test "DotEnv: last write wins on duplicate keys" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.parse("K=first\nK=second\n");
    try testing.expectEqualStrings("second", env.get("K").?);
}

test "DotEnv: malformed line returns error" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try testing.expectError(Error.InvalidLine, env.parse("no_equals_sign\n"));
}

test "DotEnv: empty key is rejected" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try testing.expectError(Error.InvalidLine, env.parse("=value\n"));
}

test "DotEnv: loadFromPath on missing file is silent" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.loadFromPath("/tmp/this-file-definitely-does-not-exist-text-engine.env");
}

test "DotEnv: value may contain = signs after the first" {
    var env = DotEnv.init(testing.allocator);
    defer env.deinit();
    try env.parse("URL=https://x.example.com/path?a=1&b=2\n");
    try testing.expectEqualStrings("https://x.example.com/path?a=1&b=2", env.get("URL").?);
}
