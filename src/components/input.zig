//! `:::input` — single-line editable text field that dispatches on
//! Enter (stage 13c). Counterpart to `:::button`: button fires a
//! fixed `body=...` literal at its target; input fires whatever the
//! user typed.
//!
//! Attribute grammar:
//!
//!     :::input {target=#chat_local action=start placeholder="Ask…" width=480}
//!     :::
//!
//! - `target` (required) — `#id` of the component to dispatch onto.
//!   `#` prefix optional; stripped.
//! - `action` (required) — verb passed to the target's
//!   `Factory.handle_update(ctx, action, body)`. Pair this with the
//!   already-supported `start` action on `:::llm-stream` (which now
//!   replaces its prompt from `body` when body is non-empty — see
//!   `llm_stream.handleUpdate`).
//! - `placeholder` (optional) — greyed-out text shown when the
//!   buffer is empty. Default `""`.
//! - `initial` (optional) — pre-fill text. Default `""`.
//! - `width`  (optional) — pixel literal or `100%`. Default 480.
//! - `height` (optional) — pixel literal. Default 36.
//!
//! ### Focus + keyboard
//!
//! Emits a `Hit` with `focusable=true`. Click → dispatcher grabs
//! focus (previous focus-holder receives `.focus_lost`). Once
//! focused:
//!
//!   * `.char_input`         → insert codepoint as UTF-8 at cursor
//!   * `.key_down BACKSPACE` → delete codepoint before cursor
//!   * `.key_down DELETE`    → delete codepoint at cursor
//!   * `.key_down LEFT/RIGHT`→ move cursor by one codepoint
//!   * `.key_down HOME/END`  → cursor to buffer ends
//!   * `.key_down ENTER`     → dispatch
//!     `registry.handleUpdate(target, action, buffer.items)`
//!   * `.key_down ESC`       → handled by the host dispatcher,
//!     which clears focus → we get `.focus_lost`
//!
//! Selection / multiline / IME are deferred — v0 is single-line,
//! caret-only. The codepoint walks step by UTF-8 byte length so
//! multi-byte chars don't split. No history (undo/redo) yet either.
//!
//! ### Cursor rendering
//!
//! Caret is a 2-pixel-wide vertical bar at the cursor's screen x,
//! computed by shaping the buffer prefix `[0..cursor]` and summing
//! its advances. Cheap because v0 buffers are short (`prompt` /
//! `query` scale, not document scale). Blink is time-based — half-
//! second on, half-second off — driven by `std.time.milliTimestamp`
//! from layoutAndRender, so it animates on every layout pass (which
//! happens every frame while focused because we mark
//! `state.dirty = true` to drive the blink).

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    InputMissingTarget,
    InputMissingAction,
    InputNotInstalled,
};

// Module global — set by install(). Used by onInput to dispatch on
// Enter and to flag state dirty for caret blink.
var registry_ref: ?*component_mod.Registry = null;
var parent_state_ref: ?*state_mod.State = null;

pub fn install(
    registry: *component_mod.Registry,
    parent_state: *state_mod.State,
) !void {
    registry_ref = registry;
    parent_state_ref = parent_state;
    try registry.register("input", factory);
}

pub fn deinitGlobals() void {
    registry_ref = null;
    parent_state_ref = null;
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    target: []u8, // stripped of leading `#`
    action: []u8,
    placeholder: []u8,
    width: box_helpers.Length,
    height: f32,

    /// Raw UTF-8 buffer; cursor is a byte offset that must always
    /// land on a codepoint boundary.
    buffer: std.ArrayListUnmanaged(u8) = .{},
    cursor: usize = 0,

    focused: bool = false,
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var target_raw: ?[]const u8 = null;
        var action_raw: ?[]const u8 = null;
        var placeholder_raw: []const u8 = "";
        var initial_raw: ?[]const u8 = null;
        var width_opt: box_helpers.Length = self.width;
        var height_opt: f32 = self.height;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "action")) {
                action_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "placeholder")) {
                placeholder_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "initial")) {
                initial_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| width_opt = l;
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    height_opt = switch (l) {
                        .pixels => |p| p,
                        else => height_opt,
                    };
                }
            }
        }

        const target_full = target_raw orelse return Error.InputMissingTarget;
        const action = action_raw orelse return Error.InputMissingAction;
        const target = if (target_full.len > 0 and target_full[0] == '#')
            target_full[1..]
        else
            target_full;

        const new_target = try a.dupe(u8, target);
        errdefer a.free(new_target);
        const new_action = try a.dupe(u8, action);
        errdefer a.free(new_action);
        const new_placeholder = try a.dupe(u8, placeholder_raw);
        errdefer a.free(new_placeholder);

        // Only seed buffer from `initial` on first ingest (i.e. when
        // buffer is empty AND cursor is 0). A subsequent attr update
        // mustn't wipe what the user typed.
        if (initial_raw) |init_text| {
            if (self.buffer.items.len == 0 and self.cursor == 0 and init_text.len > 0) {
                try self.buffer.appendSlice(a, init_text);
                self.cursor = init_text.len;
            }
        }

        a.free(self.target);
        a.free(self.action);
        a.free(self.placeholder);
        self.target = new_target;
        self.action = new_action;
        self.placeholder = new_placeholder;
        self.width = width_opt;
        self.height = height_opt;
    }
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    if (registry_ref == null) return Error.InputNotInstalled;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .target = try allocator.dupe(u8, ""),
        .action = try allocator.dupe(u8, ""),
        .placeholder = try allocator.dupe(u8, ""),
        .width = .{ .pixels = 480 },
        .height = 36,
    };
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.target);
    allocator.free(c.action);
    allocator.free(c.placeholder);
    c.buffer.deinit(allocator);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .focusable = true,
    // Caret blinks on a wall-clock timer + the field re-renders every
    // keystroke. Either could be plumbed through a version counter,
    // but the field is cheap to walk (one quad, one underline, one
    // shape() of the buffer) and caching it would mean bumping per
    // frame anyway. Walk fresh, save the bookkeeping.
    .disable_cache = true,
};

// ── Visual constants ────────────────────────────────────────────────

const FIELD_BG: [4]f32 = .{ 0.10, 0.12, 0.16, 0.90 };
const FIELD_BG_FOCUSED: [4]f32 = .{ 0.13, 0.16, 0.22, 0.95 };
const FIELD_BORDER: [4]f32 = .{ 0.36, 0.42, 0.50, 0.90 };
const FIELD_BORDER_FOCUSED: [4]f32 = .{ 0.45, 0.68, 0.95, 1.0 };
const TEXT_COLOR: [4]f32 = .{ 0.95, 0.96, 0.98, 1.0 };
const PLACEHOLDER_COLOR: [4]f32 = .{ 0.55, 0.60, 0.66, 1.0 };
const CARET_COLOR: [4]f32 = .{ 0.92, 0.95, 1.0, 1.0 };
const BORDER_PX: f32 = 1.5;
const BORDER_PX_FOCUSED: f32 = 2.0;
const RADIUS: f32 = 6;
const PAD_X: f32 = 12;
const CARET_W: f32 = 2.0;
const BLINK_PERIOD_MS: i64 = 1000; // half on, half off

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const style = lc.theme.body;

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const hb = lc.fonts.hbFont(style.font_id);
    const fscale = lc.fonts.scale(style.font_id);
    const m = lc.fonts.metrics(style.font_id);

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 480;
    const w: f32 = c.width.resolve(max_w, fallback_w);
    const h = c.height;

    const border_px = if (c.focused) BORDER_PX_FOCUSED else BORDER_PX;
    const border_rgba = if (c.focused) FIELD_BORDER_FOCUSED else FIELD_BORDER;
    const bg_rgba = if (c.focused) FIELD_BG_FOCUSED else FIELD_BG;

    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = border_rgba,
        .radius = RADIUS,
    });
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + border_px, origin[1] + border_px },
        .dst_size = .{ w - 2 * border_px, h - 2 * border_px },
        .color = bg_rgba,
        .radius = @max(0, RADIUS - border_px),
    });

    const baseline_y = origin[1] + (h - m.line_height) * 0.5 + m.ascender;
    const text_x = origin[0] + PAD_X;

    // Draw buffer (or placeholder if empty).
    const show_buffer = c.buffer.items.len > 0;
    const display_text: []const u8 = if (show_buffer) c.buffer.items else c.placeholder;
    const display_color: [4]f32 = if (show_buffer) TEXT_COLOR else PLACEHOLDER_COLOR;

    var prefix_w: f32 = 0;
    if (display_text.len > 0) {
        const run = try shape.shapeUtf8(aa, hb, display_text);
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            run,
            style.font_id,
            text_x,
            baseline_y,
            display_color,
            style.hot_color,
            style.attention,
        );
        if (show_buffer and c.cursor > 0 and c.cursor <= c.buffer.items.len) {
            // Shape the prefix separately to get caret x. Cheap for
            // the lengths a v0 input field deals with; if this ever
            // hurts we can sum advances from `run` based on cluster
            // index instead.
            const prefix_run = try shape.shapeUtf8(aa, hb, c.buffer.items[0..c.cursor]);
            for (prefix_run.glyphs) |g| prefix_w += g.x_advance * fscale;
        }
    }

    // Caret — only when focused, and only on the "on" half of the
    // blink cycle. Drives `state.dirty` next frame so the next layout
    // pass re-evaluates the blink (otherwise the box would stay
    // frozen mid-cycle).
    if (c.focused) {
        const ms = std.time.milliTimestamp();
        const phase = @mod(ms, BLINK_PERIOD_MS);
        const blink_on = phase < @divTrunc(BLINK_PERIOD_MS, 2);
        if (blink_on) {
            const caret_x = text_x + prefix_w;
            const caret_y = origin[1] + (h - m.line_height) * 0.5 + 2;
            const caret_h = m.line_height - 4;
            try out.quads.append(.{
                .dst_pos = .{ caret_x, caret_y },
                .dst_size = .{ CARET_W, caret_h },
                .color = CARET_COLOR,
                .radius = 0,
            });
        }
        if (parent_state_ref) |ps| ps.dirty = true;
    }

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = baseline_y,
    };
    c.last_box = box;
    // No manual `out.hits.append` — the element_layout walker emits
    // a Hit for any custom whose vtable has `on_input != null`, and
    // it now also propagates `vtable.focusable` onto that Hit. A
    // second append here would just duplicate (and the walker's
    // would shadow ours anyway since it appends last).
    return box;
}

// GLFW key codes we care about. Re-declared here as private
// constants to keep this file independent of `win.zig` (component
// modules don't depend on GLFW directly). These values are stable
// across GLFW 3.x.
const KEY_BACKSPACE: i32 = 259;
const KEY_DELETE: i32 = 261;
const KEY_LEFT: i32 = 263;
const KEY_RIGHT: i32 = 262;
const KEY_HOME: i32 = 268;
const KEY_END: i32 = 269;
const KEY_ENTER: i32 = 257;
const KEY_KP_ENTER: i32 = 335;

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    _: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .focus_gained => {
            c.focused = true;
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        .focus_lost => {
            c.focused = false;
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        .char_input => |cp| {
            try insertCodepoint(c, cp);
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        .key_down => |k| {
            try handleKey(c, k);
        },
        else => {},
    }
}

fn insertCodepoint(c: *Component, cp: u32) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return;
    try c.buffer.ensureUnusedCapacity(c.allocator, n);
    // Shift tail right by n, then write.
    const old_len = c.buffer.items.len;
    c.buffer.items.len = old_len + n;
    if (c.cursor < old_len) {
        std.mem.copyBackwards(
            u8,
            c.buffer.items[c.cursor + n .. old_len + n],
            c.buffer.items[c.cursor..old_len],
        );
    }
    @memcpy(c.buffer.items[c.cursor .. c.cursor + n], buf[0..n]);
    c.cursor += n;
}

fn handleKey(c: *Component, k: element.KeyEvent) !void {
    switch (k.key) {
        KEY_BACKSPACE => {
            if (c.cursor == 0) return;
            const start = prevCodepointStart(c.buffer.items, c.cursor);
            const drop = c.cursor - start;
            std.mem.copyForwards(
                u8,
                c.buffer.items[start..],
                c.buffer.items[c.cursor..],
            );
            c.buffer.items.len -= drop;
            c.cursor = start;
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        KEY_DELETE => {
            if (c.cursor >= c.buffer.items.len) return;
            const end = nextCodepointEnd(c.buffer.items, c.cursor);
            const drop = end - c.cursor;
            std.mem.copyForwards(
                u8,
                c.buffer.items[c.cursor..],
                c.buffer.items[end..],
            );
            c.buffer.items.len -= drop;
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        KEY_LEFT => {
            if (c.cursor == 0) return;
            c.cursor = prevCodepointStart(c.buffer.items, c.cursor);
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        KEY_RIGHT => {
            if (c.cursor >= c.buffer.items.len) return;
            c.cursor = nextCodepointEnd(c.buffer.items, c.cursor);
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        KEY_HOME => {
            c.cursor = 0;
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        KEY_END => {
            c.cursor = c.buffer.items.len;
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        KEY_ENTER, KEY_KP_ENTER => {
            if (c.target.len == 0 or c.action.len == 0) return;
            const r = registry_ref orelse return;
            r.handleUpdate(c.target, c.action, c.buffer.items) catch |e| {
                std.log.warn(":::input: dispatch failed: target=#{s} action={s} err={s}", .{
                    c.target, c.action, @errorName(e),
                });
            };
        },
        else => {},
    }
}

/// Walk back from byte offset `pos` to the previous UTF-8 codepoint
/// start. Buffer is assumed well-formed (we only insert validated
/// UTF-8). Returns 0 if pos is 0 or buffer is malformed.
fn prevCodepointStart(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Walk forward from byte offset `pos` to the start of the next
/// codepoint (i.e. the byte after the current one).
fn nextCodepointEnd(bytes: []const u8, pos: usize) usize {
    if (pos >= bytes.len) return bytes.len;
    const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch 1;
    const end = pos + len;
    return if (end > bytes.len) bytes.len else end;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "input: prevCodepointStart steps over ASCII" {
    try testing.expectEqual(@as(usize, 0), prevCodepointStart("hello", 1));
    try testing.expectEqual(@as(usize, 2), prevCodepointStart("hello", 3));
    try testing.expectEqual(@as(usize, 0), prevCodepointStart("hello", 0));
}

test "input: prevCodepointStart steps over multi-byte UTF-8" {
    // "é" = 0xC3 0xA9 (2 bytes); "🎉" = 0xF0 0x9F 0x8E 0x89 (4 bytes).
    const s = "aé🎉";
    try testing.expectEqual(@as(usize, 0), prevCodepointStart(s, 1)); // before 'é'
    try testing.expectEqual(@as(usize, 1), prevCodepointStart(s, 3)); // before '🎉'
    try testing.expectEqual(@as(usize, 3), prevCodepointStart(s, 7)); // before end
}

test "input: nextCodepointEnd steps forward over multi-byte" {
    const s = "aé🎉";
    try testing.expectEqual(@as(usize, 1), nextCodepointEnd(s, 0));
    try testing.expectEqual(@as(usize, 3), nextCodepointEnd(s, 1));
    try testing.expectEqual(@as(usize, 7), nextCodepointEnd(s, 3));
    try testing.expectEqual(@as(usize, 7), nextCodepointEnd(s, 7));
}

test "input: ingest requires target + action; strips # prefix" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const ok_attrs = [_]components.Attr{
        .{ .key = "target", .value = "#chat" },
        .{ .key = "action", .value = "start" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &ok_attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("chat", c.target);
    try testing.expectEqualStrings("start", c.action);
}

test "input: missing target rejected" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const attrs = [_]components.Attr{
        .{ .key = "action", .value = "start" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    try testing.expectError(Error.InputMissingTarget, create(testing.allocator, &spec));
}

test "input: missing action rejected" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "x" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    try testing.expectError(Error.InputMissingAction, create(testing.allocator, &spec));
}

test "input: char_input + backspace + cursor moves" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Focus → type "hi" → backspace → type "ello"
    var dummy_state: u8 = 0;
    try onInput(inst.ctx, .focus_gained, @ptrCast(&dummy_state));
    try testing.expect(c.focused);

    try onInput(inst.ctx, .{ .char_input = 'h' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'i' }, @ptrCast(&dummy_state));
    try testing.expectEqualStrings("hi", c.buffer.items);
    try testing.expectEqual(@as(usize, 2), c.cursor);

    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_BACKSPACE, .mods = 0 } }, @ptrCast(&dummy_state));
    try testing.expectEqualStrings("h", c.buffer.items);
    try testing.expectEqual(@as(usize, 1), c.cursor);

    try onInput(inst.ctx, .{ .char_input = 'e' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'l' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'l' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'o' }, @ptrCast(&dummy_state));
    try testing.expectEqualStrings("hello", c.buffer.items);
}

test "input: arrows + home + end move cursor" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
        .{ .key = "initial", .value = "abc" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(usize, 3), c.cursor); // initial seeds cursor at end

    var ds: u8 = 0;
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_LEFT, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 2), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_HOME, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 0), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_RIGHT, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 1), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_END, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 3), c.cursor);
}

test "input: multi-byte char + backspace removes whole codepoint" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    var ds: u8 = 0;
    try onInput(inst.ctx, .{ .char_input = 0x1F389 }, @ptrCast(&ds)); // 🎉
    try testing.expectEqual(@as(usize, 4), c.buffer.items.len);
    try testing.expectEqual(@as(usize, 4), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_BACKSPACE, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 0), c.buffer.items.len);
    try testing.expectEqual(@as(usize, 0), c.cursor);
}

test "input: initial attr seeds buffer + cursor" {
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    registry_ref = &reg;
    defer registry_ref = null;

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
        .{ .key = "initial", .value = "preset" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("preset", c.buffer.items);
    try testing.expectEqual(@as(usize, 6), c.cursor);
}
