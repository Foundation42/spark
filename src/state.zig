//! Reactive state container — stage 7d (static interpolation half).
//!
//! Stage 7d ships:
//!   * `State` — a flat string→string store, the live-document
//!     analogue of YAML frontmatter's `state:` block.
//!   * `parseFrontmatter` — hand-rolled YAML subset that recognises
//!     `state: { key: value }` pairs at one indent level. Quoted
//!     strings get unquoted; bare values captured verbatim.
//!
//! Stage 7e adds subscribers + mutation propagation (the "reactive"
//! half). For 7d the state is read once during parse, attribute
//! values are substituted from it, and that's the whole story —
//! enough to demo "edit frontmatter → re-parse → component attrs
//! reflect the new state."
//!
//! ### YAML scope
//!
//! Bare-minimum subset:
//!
//!     state:
//!       box_color: blue
//!       box_width: 240
//!       target_id: "SAT-04"
//!
//! Limits — surface as `error.InvalidFrontmatter` when violated, or
//! silently skip:
//!   * Only the `state:` top-level key is parsed. Other top-level
//!     keys are ignored (room for future `meta:`, `scripts:`, etc.).
//!   * Values are strings. Numbers / booleans / null / lists / nested
//!     maps are out of scope — components parse strings themselves
//!     (parseLength, parseColor) so the type system stays out of the
//!     state layer.
//!   * Indentation: any non-zero indent under `state:` counts as a
//!     kv pair line. Single-line `state: { a: 1 }` flow syntax not
//!     supported.
//!   * Comments (`# ...`) are honoured to end-of-line.
//!
//! Hand-rolled instead of vendoring a YAML library because the
//! surface we need is tiny and a real YAML parser pulls in a parser
//! generator's worth of code we don't want. Revisit if content
//! starts demanding flow-style / multi-line strings / anchor refs.

const std = @import("std");

pub const Error = error{
    InvalidFrontmatter,
} || std.mem.Allocator.Error;

pub const State = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    /// Free both the map storage and every key/value the parser
    /// arena-duped during construction. Hosts that don't want to
    /// keep the state across re-parses call this and rebuild.
    pub fn deinit(self: *State) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn set(self: *State, key: []const u8, value: []const u8) Error!void {
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    /// Returns null when `path` isn't set. Callers can choose to
    /// leave the surrounding `${path}` literal so authors notice
    /// typos — see [[project-text-engine]] notes on visible failure
    /// modes.
    pub fn get(self: *const State, path: []const u8) ?[]const u8 {
        return self.map.get(path);
    }
};

/// Parse the inside of a `--- ... ---` YAML frontmatter block (the
/// delimiters themselves stripped by the caller). Returns a `State`
/// populated from any `state:` block; other top-level keys are
/// ignored. An empty frontmatter or a missing `state:` block produces
/// an empty State, not an error.
pub fn parseFrontmatter(allocator: std.mem.Allocator, source: []const u8) Error!State {
    var state = State.init(allocator);
    errdefer state.deinit();

    var in_state = false;
    var state_indent: usize = 0;
    var saw_state_first_line = false;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = stripComment(std.mem.trimRight(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;

        const indent = leadingIndent(line);
        const content = line[indent..];

        if (indent == 0) {
            // Top-level key. We only care about `state:`; anything
            // else (e.g. `meta:`) we silently leave for future stages.
            in_state = std.mem.startsWith(u8, content, "state:");
            saw_state_first_line = in_state;
            state_indent = 0;
            continue;
        }

        if (!in_state) continue;

        if (saw_state_first_line) {
            state_indent = indent;
            saw_state_first_line = false;
        }

        // Bail out if indentation shrunk back to / below the `state:`
        // line — we'd be looking at a different top-level block.
        if (indent < state_indent) {
            in_state = false;
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, content, ':') orelse continue;
        const key = std.mem.trim(u8, content[0..colon], " \t");
        if (key.len == 0) continue;
        const value_raw = std.mem.trim(u8, content[colon + 1 ..], " \t");
        const value = stripQuotes(value_raw);
        try state.set(key, value);
    }
    return state;
}

/// If `source` opens with a YAML frontmatter block (`---\n` ... `\n---\n`),
/// returns the inside slice + the source slice that follows. When
/// there's no frontmatter, returns null. Recognises both LF and CRLF
/// line endings on the closing fence so demo content saved on either
/// platform parses cleanly.
pub fn extractFrontmatter(source: []const u8) ?struct { body: []const u8, rest: []const u8 } {
    const open_lf = "---\n";
    const open_crlf = "---\r\n";
    var start: usize = 0;
    if (std.mem.startsWith(u8, source, open_lf)) {
        start = open_lf.len;
    } else if (std.mem.startsWith(u8, source, open_crlf)) {
        start = open_crlf.len;
    } else {
        return null;
    }

    // Find the closing fence — must be a line that's exactly `---`
    // (whitespace tolerated). Linear scan over remaining source.
    var i: usize = start;
    while (i < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[i..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            const body = source[start..i];
            const next = if (line_end < source.len) line_end + 1 else source.len;
            return .{ .body = body, .rest = source[next..] };
        }
        if (line_end >= source.len) break;
        i = line_end + 1;
    }
    return null;
}

// ── Helpers ────────────────────────────────────────────────────────

fn leadingIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return n;
}

fn stripComment(line: []const u8) []const u8 {
    // Honour `#` as a comment start, but only when it's outside a
    // quoted region. Hand-roll just enough to handle bare `# comment`
    // and trailing `key: value  # comment` cases; full YAML escape
    // handling deferred.
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quotes = !in_quotes;
        if (c == '#' and !in_quotes) {
            return std.mem.trimRight(u8, line[0..i], " \t");
        }
    }
    return line;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "State: set + get + replace" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.set("foo", "bar");
    try testing.expectEqualStrings("bar", s.get("foo").?);
    try testing.expect(s.get("missing") == null);
    try s.set("foo", "baz"); // replace existing
    try testing.expectEqualStrings("baz", s.get("foo").?);
}

test "parseFrontmatter: state block" {
    var s = try parseFrontmatter(testing.allocator,
        \\state:
        \\  box_color: blue
        \\  box_width: 240
        \\  target_id: "SAT-04"
    );
    defer s.deinit();
    try testing.expectEqualStrings("blue", s.get("box_color").?);
    try testing.expectEqualStrings("240", s.get("box_width").?);
    try testing.expectEqualStrings("SAT-04", s.get("target_id").?);
}

test "parseFrontmatter: ignores non-state top-level keys" {
    var s = try parseFrontmatter(testing.allocator,
        \\meta:
        \\  author: me
        \\state:
        \\  flag: on
    );
    defer s.deinit();
    try testing.expect(s.get("author") == null);
    try testing.expectEqualStrings("on", s.get("flag").?);
}

test "parseFrontmatter: tolerates blank lines + comments" {
    var s = try parseFrontmatter(testing.allocator,
        \\# Trailing comment
        \\state:
        \\
        \\  # Inner comment
        \\  key: value  # trailing
    );
    defer s.deinit();
    try testing.expectEqualStrings("value", s.get("key").?);
}

test "parseFrontmatter: empty input" {
    var s = try parseFrontmatter(testing.allocator, "");
    defer s.deinit();
    try testing.expect(s.get("anything") == null);
}

test "extractFrontmatter: present" {
    const got = extractFrontmatter(
        \\---
        \\state:
        \\  x: 1
        \\---
        \\# Heading
        \\body
        \\
    );
    try testing.expect(got != null);
    try testing.expect(std.mem.indexOf(u8, got.?.body, "state:") != null);
    try testing.expect(std.mem.startsWith(u8, got.?.rest, "# Heading"));
}

test "extractFrontmatter: absent" {
    try testing.expect(extractFrontmatter("# No frontmatter\n") == null);
    try testing.expect(extractFrontmatter("") == null);
    // `---` not at start-of-file → not a frontmatter delimiter.
    try testing.expect(extractFrontmatter("\n---\nx: 1\n---\n") == null);
}
