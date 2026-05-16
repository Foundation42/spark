//! Reactive state container.
//!
//! Two-phase build-up across stages 7d + 7e:
//!
//! **Stage 7d (static interpolation):**
//!   * `State` — a flat string→string store, the live-document
//!     analogue of YAML frontmatter's `state:` block.
//!   * `parseFrontmatter` — hand-rolled YAML subset that recognises
//!     `state: { key: value }` pairs at one indent level.
//!
//! **Stage 7e (reactivity):**
//!   * `subscribe(path, cb)` — register a callback that fires when
//!     the given path mutates.
//!   * `set(path, value)` — mutate + notify. Walks subscribers for
//!     that exact path and invokes each.
//!   * `dirty` flag — bumped on any mutation so the host's frame
//!     loop knows to re-run layout.
//!
//! Subscribers are heap-allocated for pointer stability across
//! ArrayList growth. `unsubscribe` soft-deletes (sets `active=false`)
//! rather than compacting the list — keeps pointers stable for any
//! callbacks still in flight when an unrelated subscription is
//! revoked. Compaction can land later if subscriber churn becomes a
//! memory concern; for stage 7e it doesn't.
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

/// One reactive callback. Heap-allocated by `subscribe` for pointer
/// stability — the returned pointer is the unsubscribe handle.
pub const Subscriber = struct {
    callback: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,
    /// Soft-delete flag. `set` skips inactive subscribers; the
    /// memory stays in the per-path list until the State is
    /// deinit'd. Cheap to check, no pointer invalidation when
    /// unrelated subscribers come and go.
    active: bool = true,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8) = .{},
    subscribers: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*Subscriber)) = .{},
    /// Bumped by every `set`. Hosts read it from their frame loop
    /// and call layout on a true→false transition.
    dirty: bool = false,
    /// Independent of `dirty` — bumped by every `set` and cleared by
    /// `clearPersistDirty`. Lets a host run a throttled "if dirty,
    /// flush to disk" check on its own cadence without interfering
    /// with the render-loop dirty signal.
    persist_dirty: bool = false,
    /// Optional pointer up the document-composition chain (stage 9).
    /// When an embedded document is created, its child State's
    /// `parent` is set to the embedding document's State. `set`
    /// flips `dirty` all the way up the chain so the host's frame
    /// loop (which only watches the root State.dirty) sees mutations
    /// in any nested document. Subscriber firing stays local — each
    /// State manages its own subscribers — so the bubble is *only*
    /// about waking the renderer.
    parent: ?*State = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    /// Free the map storage, every key/value the parser duped, and
    /// every Subscriber struct. Subscriber callbacks themselves
    /// reference Registry-owned memory — that lifetime is the host's
    /// responsibility, not the State's.
    pub fn deinit(self: *State) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);

        var sit = self.subscribers.iterator();
        while (sit.next()) |entry| {
            for (entry.value_ptr.items) |sub| self.allocator.destroy(sub);
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscribers.deinit(self.allocator);

        self.* = undefined;
    }

    /// Set a path's value. Fires any subscribers registered for that
    /// exact path. Sets `dirty=true` regardless of whether the value
    /// actually changed — callers debounce if they care. Dirty
    /// bubbles up through `parent` so a root-watching renderer wakes
    /// even when the mutation happened inside an embedded document.
    pub fn set(self: *State, key: []const u8, value: []const u8) Error!void {
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
        self.dirty = true;
        self.persist_dirty = true;
        var p = self.parent;
        while (p) |s| : (p = s.parent) s.dirty = true;

        if (self.subscribers.getPtr(key)) |list| {
            // Snapshot the items pointer in case a callback adds /
            // removes subscriptions during the walk. New
            // subscriptions go onto the same slice (ArrayList grows
            // at the end); we'll see them next time. Removals are
            // soft, so existing pointers stay valid.
            for (list.items) |sub| {
                if (sub.active) {
                    // Subscriber errors are non-fatal: swallow so a
                    // failing callback doesn't abort other
                    // subscribers' notifications. Future stage can
                    // route through a structured logger.
                    sub.callback(sub.ctx) catch {};
                }
            }
        }
    }

    /// Returns null when `path` isn't set. Callers can choose to
    /// leave the surrounding `${path}` literal so authors notice
    /// typos — see [[project-text-engine]] notes on visible failure
    /// modes.
    pub fn get(self: *const State, path: []const u8) ?[]const u8 {
        return self.map.get(path);
    }

    /// Register a callback for mutations to `path`. The returned
    /// pointer is the unsubscribe handle. Multiple subscribers per
    /// path are supported and fire in registration order.
    pub fn subscribe(
        self: *State,
        path: []const u8,
        callback: *const fn (ctx: *anyopaque) anyerror!void,
        ctx: *anyopaque,
    ) Error!*Subscriber {
        const sub = try self.allocator.create(Subscriber);
        sub.* = .{ .callback = callback, .ctx = ctx };

        const gop = try self.subscribers.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, path);
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(self.allocator, sub);
        return sub;
    }

    /// Soft-revoke a subscription. The Subscriber struct stays
    /// allocated until State.deinit (no list compaction). Pointers
    /// to other subscribers stay valid even across an unsubscribe,
    /// which matters because a subscriber's callback might unwind
    /// some peer subscription mid-fire.
    pub fn unsubscribe(_: *State, sub: *Subscriber) void {
        sub.active = false;
    }

    /// Clear the dirty flag. Host calls after running the layout
    /// pass triggered by the mutation.
    pub fn clearDirty(self: *State) void {
        self.dirty = false;
    }

    /// Clear the persistence-dirty flag. Host calls after writing
    /// state to disk.
    pub fn clearPersistDirty(self: *State) void {
        self.persist_dirty = false;
    }

    /// Serialize the map to a JSON file at `path`. Atomic write (tmp
    /// + rename within the same directory) so a crash leaves either
    /// the old file or the new one — never a partial. Parent
    /// directories are created if missing.
    ///
    /// Format: `{"version":1,"entries":{"key":"value", ...}}`.
    /// All values are strings — same shape as the in-memory map.
    pub fn saveToFile(self: *const State, path: []const u8) !void {
        const dirname = std.fs.path.dirname(path) orelse ".";
        const basename = std.fs.path.basename(path);
        try std.fs.cwd().makePath(dirname);
        var dir = try std.fs.cwd().openDir(dirname, .{});
        defer dir.close();

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();
        try w.writeAll("{\"version\":1,\"entries\":{");
        var first = true;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (!first) try w.writeAll(",");
            first = false;
            try std.json.stringify(kv.key_ptr.*, .{}, w);
            try w.writeAll(":");
            try std.json.stringify(kv.value_ptr.*, .{}, w);
        }
        try w.writeAll("}}\n");

        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{basename});
        defer self.allocator.free(tmp_name);

        {
            const file = try dir.createFile(tmp_name, .{ .truncate = true });
            defer file.close();
            try file.writeAll(buf.items);
            try file.sync();
        }
        try dir.rename(tmp_name, basename);
    }

    /// Load state values from a JSON file written by `saveToFile`.
    /// Missing file is silent (returns `FileNotFound`); malformed
    /// JSON / unknown version returns an error so the caller can
    /// log + continue with defaults. Loaded values overwrite
    /// existing same-key entries via `set()` (so subscribers fire
    /// like a normal mutation would — relevant if loading happens
    /// after components have subscribed). `persist_dirty` is
    /// cleared after a successful load so the freshly-loaded state
    /// doesn't immediately re-flush.
    pub fn loadFromFile(self: *State, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidStateFile;
        const root = parsed.value.object;

        const version_v = root.get("version") orelse return error.InvalidStateFile;
        if (version_v != .integer or version_v.integer != 1) return error.InvalidStateFile;

        const entries_v = root.get("entries") orelse return error.InvalidStateFile;
        if (entries_v != .object) return error.InvalidStateFile;

        var it = entries_v.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue; // skip malformed
            try self.set(entry.key_ptr.*, entry.value_ptr.string);
        }
        self.persist_dirty = false;
    }
};

/// Convenience: extract frontmatter from `source` (if present) and
/// parse it into a host-owned State. Returns null when there's no
/// `--- ... ---` block at the head of `source`. Caller owns the
/// returned State and is responsible for `deinit`'ing it.
pub fn fromSource(allocator: std.mem.Allocator, source: []const u8) Error!?State {
    const fm = extractFrontmatter(source) orelse return null;
    return try parseFrontmatter(allocator, fm.body);
}

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

// ── Reactive layer tests ───────────────────────────────────────────

const TestCb = struct {
    counter: u32 = 0,

    fn cb(ctx: *anyopaque) anyerror!void {
        const self: *TestCb = @ptrCast(@alignCast(ctx));
        self.counter += 1;
    }
};

test "subscribe + set fires callback" {
    var s = State.init(testing.allocator);
    defer s.deinit();

    var probe = TestCb{};
    _ = try s.subscribe("x", TestCb.cb, @ptrCast(&probe));
    try testing.expectEqual(@as(u32, 0), probe.counter);
    try s.set("x", "1");
    try testing.expectEqual(@as(u32, 1), probe.counter);
    try s.set("x", "2");
    try testing.expectEqual(@as(u32, 2), probe.counter);
    // Different path doesn't fire this subscriber.
    try s.set("y", "anything");
    try testing.expectEqual(@as(u32, 2), probe.counter);
}

test "unsubscribe stops the callback" {
    var s = State.init(testing.allocator);
    defer s.deinit();

    var probe = TestCb{};
    const sub = try s.subscribe("x", TestCb.cb, @ptrCast(&probe));
    try s.set("x", "1");
    try testing.expectEqual(@as(u32, 1), probe.counter);
    s.unsubscribe(sub);
    try s.set("x", "2");
    try testing.expectEqual(@as(u32, 1), probe.counter);
}

test "multiple subscribers on same path" {
    var s = State.init(testing.allocator);
    defer s.deinit();

    var a = TestCb{};
    var b = TestCb{};
    _ = try s.subscribe("x", TestCb.cb, @ptrCast(&a));
    _ = try s.subscribe("x", TestCb.cb, @ptrCast(&b));
    try s.set("x", "go");
    try testing.expectEqual(@as(u32, 1), a.counter);
    try testing.expectEqual(@as(u32, 1), b.counter);
}

test "dirty flag is set by set() and cleared by clearDirty()" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.dirty);
    try s.set("x", "1");
    try testing.expect(s.dirty);
    s.clearDirty();
    try testing.expect(!s.dirty);
}

test "fromSource extracts + parses frontmatter" {
    const opt = try fromSource(testing.allocator,
        \\---
        \\state:
        \\  x: 1
        \\---
        \\# body
    );
    try testing.expect(opt != null);
    var s = opt.?;
    defer s.deinit();
    try testing.expectEqualStrings("1", s.get("x").?);
}

test "fromSource returns null when no frontmatter" {
    const opt = try fromSource(testing.allocator, "# just body\n");
    try testing.expect(opt == null);
}

test "dirty bubbles up through parent chain" {
    var root = State.init(testing.allocator);
    defer root.deinit();
    var child = State.init(testing.allocator);
    defer child.deinit();
    var grandchild = State.init(testing.allocator);
    defer grandchild.deinit();

    child.parent = &root;
    grandchild.parent = &child;

    try testing.expect(!root.dirty);
    try testing.expect(!child.dirty);
    try testing.expect(!grandchild.dirty);

    try grandchild.set("x", "1");
    try testing.expect(grandchild.dirty);
    try testing.expect(child.dirty);
    try testing.expect(root.dirty);

    // Clearing one level doesn't affect the others — that's the
    // host's job; clearDirty is local.
    grandchild.clearDirty();
    try testing.expect(!grandchild.dirty);
    try testing.expect(child.dirty);
    try testing.expect(root.dirty);
}

test "subscribers fire only on the state where set was called" {
    var root = State.init(testing.allocator);
    defer root.deinit();
    var child = State.init(testing.allocator);
    defer child.deinit();
    child.parent = &root;

    var root_probe = TestCb{};
    var child_probe = TestCb{};
    _ = try root.subscribe("x", TestCb.cb, @ptrCast(&root_probe));
    _ = try child.subscribe("x", TestCb.cb, @ptrCast(&child_probe));

    try child.set("x", "v");
    try testing.expectEqual(@as(u32, 0), root_probe.counter); // root not fired
    try testing.expectEqual(@as(u32, 1), child_probe.counter);
}

// ── Persistence (stage 13b.2) ─────────────────────────────────────────

fn persistTmpPath() ![]u8 {
    var rand_buf: [12]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var hex_buf: [24]u8 = undefined;
    const charset = "0123456789abcdef";
    for (rand_buf, 0..) |b, i| {
        hex_buf[i * 2] = charset[b >> 4];
        hex_buf[i * 2 + 1] = charset[b & 0x0f];
    }
    return try std.fmt.allocPrint(testing.allocator, "/tmp/state-test-{s}.json", .{hex_buf});
}

test "persist: set flips persist_dirty; clearPersistDirty resets it" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.persist_dirty);
    try s.set("a", "1");
    try testing.expect(s.persist_dirty);
    s.clearPersistDirty();
    try testing.expect(!s.persist_dirty);
    // dirty stays independent.
    try testing.expect(s.dirty);
}

test "persist: save + load roundtrip preserves values" {
    const path = try persistTmpPath();
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        var s = State.init(testing.allocator);
        defer s.deinit();
        try s.set("box_color", "red");
        try s.set("box_radius", "12.50");
        try s.set("nested.path", "deep");
        try s.saveToFile(path);
    }

    {
        var s = State.init(testing.allocator);
        defer s.deinit();
        try s.loadFromFile(path);
        try testing.expectEqualStrings("red", s.get("box_color").?);
        try testing.expectEqualStrings("12.50", s.get("box_radius").?);
        try testing.expectEqualStrings("deep", s.get("nested.path").?);
        // Load clears persist_dirty so we don't immediately re-flush.
        try testing.expect(!s.persist_dirty);
    }
}

test "persist: load overlays onto existing values (persisted wins)" {
    const path = try persistTmpPath();
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        var s = State.init(testing.allocator);
        defer s.deinit();
        try s.set("box_color", "red"); // last session's value
        try s.saveToFile(path);
    }

    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.set("box_color", "blue"); // frontmatter default
    try s.set("untouched", "keepme"); // not in saved file
    try s.loadFromFile(path);
    try testing.expectEqualStrings("red", s.get("box_color").?); // persisted wins
    try testing.expectEqualStrings("keepme", s.get("untouched").?); // pre-existing kept
}

test "persist: load on missing file returns FileNotFound" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try testing.expectError(error.FileNotFound, s.loadFromFile("/tmp/definitely-does-not-exist-state-test.json"));
}

test "persist: load rejects malformed JSON" {
    const path = try persistTmpPath();
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("this is not json {{{");
    }

    var s = State.init(testing.allocator);
    defer s.deinit();
    try testing.expectError(error.SyntaxError, s.loadFromFile(path));
}

test "persist: load rejects wrong version" {
    const path = try persistTmpPath();
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("{\"version\":99,\"entries\":{}}");
    }

    var s = State.init(testing.allocator);
    defer s.deinit();
    try testing.expectError(error.InvalidStateFile, s.loadFromFile(path));
}

test "persist: save is atomic — partial write would leave tmp file" {
    // We can't easily simulate a partial write in-process, but verify
    // the steady-state: after a successful save, no .tmp file remains
    // alongside the target.
    const path = try persistTmpPath();
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var s = State.init(testing.allocator);
    defer s.deinit();
    try s.set("x", "y");
    try s.saveToFile(path);

    const tmp_path = try std.fmt.allocPrint(testing.allocator, "{s}.tmp", .{path});
    defer testing.allocator.free(tmp_path);
    try testing.expectError(error.FileNotFound, std.fs.cwd().openFile(tmp_path, .{}));
}
