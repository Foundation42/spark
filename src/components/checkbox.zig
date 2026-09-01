//! `:::checkbox` — a labelled on/off box that flips a state path.
//!
//! Attribute grammar:
//!
//!     :::checkbox {label="Wireframe" target=state.wire checked=${state.wire}}
//!     :::
//!
//! - `label`   (required) — text to the right of the box.
//! - `target`  (required) — `state.path` to flip on click. A bare path
//!   without the `state.` prefix is accepted and means the same thing;
//!   a checkbox has nowhere else to write, so there is no second arm to
//!   disambiguate against.
//! - `checked` (optional) — what to DRAW. Truthy by `button.isTruthy`,
//!   so `0` / `0.000` / `false` / `off` / empty all read as unchecked.
//! - `color` / `border` / `tick` (optional) — palette, same shape as
//!   `:::button`'s and `:::slider`'s.
//!
//! ### Why `checked=` is separate from `target=`
//!
//! It looks redundant — `target=state.wire checked=${state.wire}` names
//! one path twice — and it is the same shape `:::button`'s `active=`
//! already has, for the same two reasons.
//!
//! What a box DISPLAYS and what it WRITES are not always the same path.
//! In matryoshka a control is typically mirrored: the document writes
//! its own state, the plane accepts or clamps the write, and the readback
//! is what should be shown. A box that drew from its own click would lie
//! whenever the plane disagreed, and would go on lying until something
//! else forced a re-render.
//!
//! And the `${}` is what SUBSCRIBES. A path with no interpolation has no
//! binding, so nothing re-resolves the attrs when it changes and the box
//! never learns that a console line, a rill, or the panel next door
//! turned the thing off. Visibility is not authorship; a control shows
//! the world's value, not its own memory of what it last did.
//!
//! ### The click, and the re-entrancy under it
//!
//! Clicking anywhere on the ROW toggles — box or label. A 14px target is
//! a 14px target whatever the label next to it says, and every desktop
//! toolkit made that call decades ago.
//!
//! The flip writes `"1"` / `"0"` rather than `"true"` / `"false"`, which
//! is not a spelling preference: matryoshka's `Panel.writeBack` parses
//! document state with `parseFloat` before pushing at the plane, so a
//! word is a write that silently never lands. `:::button`'s `flip=` uses
//! the same two characters and `toggleValue` is the one place either
//! decides.
//!
//! A box with `target=state.x checked=${state.x}` is its own subscriber,
//! and `State.set` notifies synchronously — so the click re-enters this
//! component's own `ingest` while `onInput` still holds a slice of
//! `self.target`. That is the trackball segfault; `ingest` routes every
//! string through `component.adoptString` and `onInput` touches nothing
//! after the write.
//!
//! ### Drawn entirely in the TRIANGLE layer
//!
//! Including the box, which would rather be a rounded quad. The tick is
//! diagonal, so it can only be `relief.stroke`, so it is triangles — and
//! the renderer draws the WHOLE triangle layer beneath the WHOLE quad
//! layer, not in emission order. A quad box would hide its own tick.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
const button = @import("button.zig");
const relief = @import("relief.zig");

pub const Error = error{
    CheckboxMissingLabel,
    CheckboxMissingTarget,
    CheckboxNotInstalled,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("checkbox", factory);
}

/// The other of the two values a flip can write, given what is there
/// now. The single place `:::checkbox` and `:::button {flip}` agree on
/// the spelling — see the header for why it is digits and not words.
pub fn toggleValue(current: []const u8) []const u8 {
    return button.flagValue(!button.isTruthy(current));
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    /// The state path to flip, with any `state.` prefix stripped.
    target: []u8,
    checked: bool = false,
    color: [4]f32 = BOX_BG,
    border: [4]f32 = BOX_BORDER,
    tick: [4]f32 = TICK,
    /// Bumped on every spec ingest so the retained layout cache
    /// re-walks the box when its attrs change.
    version: u64 = 0,
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var label_raw: ?[]const u8 = null;
        var target_raw: ?[]const u8 = null;
        var checked_opt: bool = false;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "checked")) {
                checked_opt = button.isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.color = v;
            } else if (std.mem.eql(u8, attr.key, "border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.border = v;
            } else if (std.mem.eql(u8, attr.key, "tick")) {
                if (box_helpers.parseColor(attr.value)) |v| self.tick = v;
            }
        }

        const label = label_raw orelse return Error.CheckboxMissingLabel;
        const target_full = target_raw orelse return Error.CheckboxMissingTarget;
        const target = if (std.mem.startsWith(u8, target_full, "state."))
            target_full["state.".len..]
        else
            target_full;

        // `adoptString` because the box subscribes to the path it
        // writes — see the header. Unconditional free-and-dupe is how
        // the trackball crashed.
        try component_mod.adoptString(a, &self.label, label);
        try component_mod.adoptString(a, &self.target, target);
        self.checked = checked_opt;
        self.version +%= 1;
    }
};

fn create(_: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, ""),
    };
    errdefer {
        allocator.free(c.label);
        allocator.free(c.target);
    }
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.label);
    allocator.free(c.target);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Visual constants ────────────────────────────────────────────────

/// The box is a small square CUT into the panel — a neutral darkening
/// with a black edge, the same idiom `:::button`'s fill and
/// `:::slider`'s recess use, so it takes the tint of whatever panel it
/// sits on instead of imposing one.
const BOX_BG: [4]f32 = .{ 0.0, 0.0, 0.0, 0.34 };
const BOX_BORDER: [4]f32 = .{ 0.02, 0.02, 0.03, 0.92 };
/// The tick is the shell's ONE lit colour: the same amber as the grip,
/// the dial's home mark, a pressed key and a focused field. "This one is
/// on" is one colour everywhere or it is decoration.
const TICK: [4]f32 = .{ 1.0, 0.78, 0.20, 1.0 };
const LABEL: [4]f32 = .{ 0.86, 0.87, 0.91, 1.0 };
/// Matched to `:::button`'s 24px height so a column of mixed controls
/// lines up on one rhythm.
const ROW_HEIGHT: f32 = 24;
const BOX_SIZE: f32 = 14;
const BOX_BORDER_PX: f32 = 1.0;
/// Between the box and its label.
const LABEL_GAP: f32 = 8;
const TICK_WIDTH: f32 = 2.0;

/// The tick's three points in the box's unit square, as fractions of
/// `BOX_SIZE`. A checkmark is a short down-stroke into a long up-stroke;
/// the long arm leaving the top-right corner is what makes it read as a
/// tick rather than as a `v`.
const TICK_PTS: [3][2]f32 = .{
    .{ 0.22, 0.52 },
    .{ 0.43, 0.72 },
    .{ 0.78, 0.28 },
};

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

    const run = try shape.shapeUtf8(aa, hb, c.label);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const h = ROW_HEIGHT;
    const intrinsic_w = BOX_SIZE + LABEL_GAP + text_w;
    const w: f32 = if (std.math.isFinite(constraints.max_w))
        @min(constraints.max_w, intrinsic_w)
    else
        intrinsic_w;

    // Whole pixels: a 1px border landing on a half-pixel spreads over
    // two rows at half strength and the box goes soft and grey. Same
    // reason `element_layout.seamRows` rounds.
    const bx = @round(origin[0]);
    const by = @round(origin[1] + (h - BOX_SIZE) * 0.5);

    // Everything below is TRIANGLES, including the box — see the header.
    // The border first, then the fill inset into it.
    try relief.rect(out, lc, bx, by, BOX_SIZE, BOX_SIZE, c.border);
    try relief.rect(
        out,
        lc,
        bx + BOX_BORDER_PX,
        by + BOX_BORDER_PX,
        BOX_SIZE - 2 * BOX_BORDER_PX,
        BOX_SIZE - 2 * BOX_BORDER_PX,
        c.color,
    );
    // The lit lower lip and the shadow under the top one, so an empty
    // box still reads as a hole rather than as a printed outline.
    try relief.groove(out, lc, bx + BOX_BORDER_PX, by + BOX_BORDER_PX, BOX_SIZE - 2 * BOX_BORDER_PX, BOX_SIZE - 2 * BOX_BORDER_PX, false);

    if (c.checked) {
        // Two strokes sharing their middle point, which OVERLAP there
        // rather than butt — `relief.stroke` feathers its caps, and two
        // feathered caps meeting exactly leave a seam of half-alpha
        // down the join.
        const p = [3][2]f32{
            .{ bx + TICK_PTS[0][0] * BOX_SIZE, by + TICK_PTS[0][1] * BOX_SIZE },
            .{ bx + TICK_PTS[1][0] * BOX_SIZE, by + TICK_PTS[1][1] * BOX_SIZE },
            .{ bx + TICK_PTS[2][0] * BOX_SIZE, by + TICK_PTS[2][1] * BOX_SIZE },
        };
        try relief.stroke(out, lc, p[0], p[1], TICK_WIDTH, c.tick);
        try relief.stroke(out, lc, p[1], p[2], TICK_WIDTH, c.tick);
    }

    const baseline_y = origin[1] + (h - m.line_height) * 0.5 + m.ascender;
    if (c.label.len > 0) {
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
            &out.glyph_targets,
            lc.current_target_dispatch_index,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            run,
            style.font_id,
            bx + BOX_SIZE + LABEL_GAP,
            baseline_y,
            LABEL,
            style.hot_color,
            style.attention,
            lc.zoom,
        );
    }

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = baseline_y,
    };
    c.last_box = box;

    // The WHOLE ROW is the hit target, label included. A 14px box is a
    // 14px box however wide its label is, and every desktop toolkit
    // settled this decades ago.
    try out.hits.append(.{
        .box = box,
        .vtable = &vtable,
        .ctx = @ptrCast(c),
        .state = lc.state,
    });

    return box;
}

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_ptr: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .mouse_up => |mouse| {
            if (mouse.button != 0) return; // primary only
            if (c.target.len == 0) return;
            const state: *state_mod.State = @ptrCast(@alignCast(state_ptr));
            const next = toggleValue(state.get(c.target) orelse "");

            // NOTHING may touch `c` after this line, and nothing does.
            // `State.set` notifies synchronously, so a box carrying
            // `checked=${state.x}` on the path it writes re-enters its
            // own `ingest` from inside this call. `adoptString` keeps
            // that from freeing `c.target` out from under `set` (which
            // hashes its key twice); returning straight after is the
            // rest of the guarantee.
            state.set(c.target, next) catch |e| {
                std.log.warn(":::checkbox: state.set failed: err={s}", .{@errorName(e)});
            };
        },
        else => {},
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "checkbox: ingest strips the state. prefix, and takes it either way" {
    const with_prefix = [_]components.Attr{
        .{ .key = "label", .value = "Wireframe" },
        .{ .key = "target", .value = "state.wire" },
    };
    const spec: components.Spec = .{ .name = "checkbox", .attrs = &with_prefix };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("wire", c.target);
    try testing.expectEqualStrings("Wireframe", c.label);

    const bare = [_]components.Attr{
        .{ .key = "label", .value = "Wireframe" },
        .{ .key = "target", .value = "wire" },
    };
    const spec2: components.Spec = .{ .name = "checkbox", .attrs = &bare };
    try update(inst.ctx, &spec2);
    try testing.expectEqualStrings("wire", c.target);
}

test "checkbox: label and target are both required" {
    const no_label = [_]components.Attr{.{ .key = "target", .value = "state.x" }};
    const s1: components.Spec = .{ .name = "checkbox", .attrs = &no_label };
    try testing.expectError(Error.CheckboxMissingLabel, create(&_test_spark, testing.allocator, &s1));

    // A box with nowhere to write looks like a control and is not one,
    // which is worse than a parse error.
    const no_target = [_]components.Attr{.{ .key = "label", .value = "x" }};
    const s2: components.Spec = .{ .name = "checkbox", .attrs = &no_target };
    try testing.expectError(Error.CheckboxMissingTarget, create(&_test_spark, testing.allocator, &s2));
}

test "checkbox: click flips the path, and unset counts as off" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Wireframe" },
        .{ .key = "target", .value = "state.wire" },
    };
    const spec: components.Spec = .{ .name = "checkbox", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const click: element.InputEvent =
        .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } };

    // Unset reads as off, so the first click turns it ON. A box whose
    // first click did nothing is the bug reported as "I have to click
    // it twice".
    try onInput(inst.ctx, click, @ptrCast(&state));
    try testing.expectEqualStrings("1", state.get("wire").?);
    try onInput(inst.ctx, click, @ptrCast(&state));
    try testing.expectEqualStrings("0", state.get("wire").?);
}

test "checkbox: a right-click is not a click" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "target", .value = "state.x" },
    };
    const spec: components.Spec = .{ .name = "checkbox", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 1, .button_down = false } }, @ptrCast(&state));
    try testing.expect(state.get("x") == null);
}

test "checkbox: what it DRAWS comes from `checked`, not from the click" {
    // The box shows the world's value, not its own memory of what it
    // last did. A plane that clamps or refuses a write must be able to
    // leave the box unticked, and it can only do that through `checked`.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "target", .value = "state.x" },
        .{ .key = "checked", .value = "0" },
    };
    const spec: components.Spec = .{ .name = "checkbox", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqualStrings("1", state.get("x").?);
    // Still unticked: nothing has re-resolved `checked=` yet. The
    // binding does that, and this test deliberately has none.
    try testing.expect(!c.checked);
}

test "checkbox: toggleValue reads the plane's spellings and writes digits" {
    // A readback arrives as `{d}` on an f32. And what goes back must be
    // a NUMBER: `Panel.writeBack` parses document state with parseFloat
    // before pushing at the plane, so a "true" here is a write that
    // silently never lands.
    try testing.expectEqualStrings("1", toggleValue(""));
    try testing.expectEqualStrings("1", toggleValue("0"));
    try testing.expectEqualStrings("1", toggleValue("0.000"));
    try testing.expectEqualStrings("1", toggleValue("false"));
    try testing.expectEqualStrings("0", toggleValue("1"));
    try testing.expectEqualStrings("0", toggleValue("1.000"));
    try testing.expectEqualStrings("0", toggleValue("true"));
}

test "checkbox: an ingest that changes nothing frees nothing" {
    // The trackball segfault's shape: the box subscribes to the path it
    // writes, `State.set` notifies synchronously, so the click re-enters
    // this ingest while `onInput` holds a slice of `self.target`.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Wireframe" },
        .{ .key = "target", .value = "state.wire" },
        .{ .key = "checked", .value = "0" },
    };
    const spec: components.Spec = .{ .name = "checkbox", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const label_ptr = c.label.ptr;
    const target_ptr = c.target.ptr;

    // Exactly what a re-entrant update looks like: same strings, only
    // `checked=` moved — which is what the write itself changed.
    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "Wireframe" },
        .{ .key = "target", .value = "state.wire" },
        .{ .key = "checked", .value = "1" },
    };
    const spec2: components.Spec = .{ .name = "checkbox", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);

    try testing.expectEqual(label_ptr, c.label.ptr);
    try testing.expectEqual(target_ptr, c.target.ptr);
    try testing.expect(c.checked);
}
