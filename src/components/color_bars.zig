//! `:::color_bars` — the same three numbers as `:::trackball`, drawn as
//! Resolve's "primaries bars" instead of its colour wheels: one vertical
//! bar per channel, plus a master that moves all three together.
//!
//! The attribute grammar is deliberately IDENTICAL to `:::trackball`'s,
//! so swapping one directive name for the other changes the view and
//! nothing else. Two panels bound to the same paths track each other
//! through the document's plane mirror without either knowing the other
//! is there — which is the two-way wheel/slider mirror
//! `web/apps/color-grader` builds by hand, arriving here for free.
//!
//!     :::color_bars {label="Lift" r=lift_r g=lift_g b=lift_b
//!                    min=-0.3 max=0.3 neutral=0
//!                    value_r=${state.lift_r}
//!                    value_g=${state.lift_g}
//!                    value_b=${state.lift_b}
//!                    height=110}
//!     :::
//!
//! See `trackball.zig` for the attribute list. The two extras here:
//!
//! - `height` — the bar area in pixels, not counting the label or the
//!   readout. Default 110.
//! - `width` — the whole widget. Default: whatever four readout cells
//!   need, which is what keeps the numbers under the bars they belong
//!   to.
//!
//! ## Where the master bar differs from the other three
//!
//! Dragging R sets R and lets `Balance.inverse` re-derive the balance.
//! Dragging MASTER holds the balance and moves the level, so all three
//! channels travel together and their spread is preserved. That is the
//! same split as the trackball's disc-versus-dial, which is the point:
//! four bars is a different picture of one control, not a different
//! control.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const color = @import("color.zig");
const relief = @import("relief.zig");
const trackball = @import("trackball.zig");

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("color_bars", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Visual constants ────────────────────────────────────────────────

const TRACK_COLOR: [4]f32 = .{ 0.0, 0.0, 0.0, 0.34 };
const NEUTRAL_TICK_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.30 };
const THUMB_COLOR: [4]f32 = .{ 0.97, 0.97, 1.0, 1.0 };
const LABEL_COLOR: [4]f32 = .{ 0.92, 0.93, 0.97, 1.0 };

const BAR_W: f32 = 9.0;
const TRACK_W: f32 = 5.0;
const THUMB_H: f32 = 3.0;
const LABEL_GAP: f32 = 4.0;
const READOUT_GAP: f32 = 6.0;
const DEFAULT_BAR_H: f32 = 110.0;
/// Matches `trackball.READOUT_TEMPLATE` — the two views must be the same
/// width, or swapping one for the other in a panel reflows it.
const READOUT_TEMPLATE = "-0.00";

/// Column index of the master bar. The first three are r/g/b.
const MASTER: usize = 3;

const Component = struct {
    allocator: std.mem.Allocator,
    paths: [3][]u8,
    label: []u8,
    bal: color.Balance,
    bar_h: f32,

    /// See `trackball.Component.last_written` — same gate, same reason.
    last_written: [3]f32 = .{ 0, 0, 0 },

    // Local geometry, recorded at layout. Origin-independent, so a
    // cached ancestor blitting the widget elsewhere cannot stale it.
    cell_w: f32 = 40,
    bars_top: f32 = 0,
    content_w: f32 = 160,

    /// Which column a press grabbed, latched at mouse_down. `null` means
    /// the press missed every bar, and the drag does nothing.
    grabbed: ?usize = null,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var raw: [3]?[]const u8 = .{ null, null, null };
        var values: [3]?f32 = .{ null, null, null };
        var min: ?f32 = null;
        var max: ?f32 = null;
        var neutral: ?f32 = null;

        for (spec.attrs) |attr| {
            const k = attr.key;
            if (std.mem.eql(u8, k, "r")) {
                raw[0] = attr.value;
            } else if (std.mem.eql(u8, k, "g")) {
                raw[1] = attr.value;
            } else if (std.mem.eql(u8, k, "b")) {
                raw[2] = attr.value;
            } else if (std.mem.eql(u8, k, "value_r")) {
                values[0] = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "value_g")) {
                values[1] = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "value_b")) {
                values[2] = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "min")) {
                min = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "max")) {
                max = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "neutral")) {
                neutral = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "height")) {
                if (parseF32(attr.value)) |v| {
                    if (v > 16) self.bar_h = v;
                }
            } else if (std.mem.eql(u8, k, "label")) {
                const dup = try a.dupe(u8, attr.value);
                a.free(self.label);
                self.label = dup;
            }
        }

        // The paths, and the re-entrant free that made the trackball
        // segfault — read the long note in `trackball.zig`'s `ingest`.
        // `state.set` notifies subscribers synchronously, this component
        // is one of them, and freeing a path here pulls the key out from
        // under the `set` still on the stack. Unchanged paths are never
        // reallocated, and a gesture holds the swap off entirely.
        const gesture = self.grabbed != null;
        if (!gesture) {
            for (raw, 0..) |maybe, i| {
                if (maybe) |v| {
                    if (std.mem.eql(u8, self.paths[i], v)) continue;
                    const dup = try a.dupe(u8, v);
                    a.free(self.paths[i]);
                    self.paths[i] = dup;
                }
            }
        }

        // Range before values — see the trackball's test of the same
        // ordering.
        if (min) |v| self.bal.min = v;
        if (max) |v| self.bal.max = v;
        if (neutral) |v| {
            self.bal.neutral = v;
        } else if (min != null or max != null) {
            self.bal.neutral = (self.bal.min + self.bal.max) * 0.5;
        }

        // During a gesture the widget is the authority — see the long
        // note on `trackball.Component.ingest`. It bites less visibly
        // here (a bar's own column is absolute, so it tracks the cursor
        // either way) and it still bites: the master column writes all
        // three paths one at a time, so the ingest fired by the first
        // re-derives the balance from a triple that is two-thirds stale.
        if (!gesture and
            (values[0] != null or values[1] != null or values[2] != null))
        {
            var next = self.bal.cur;
            for (values, 0..) |maybe, i| {
                if (maybe) |v| next[i] = v;
            }
            self.bal.setChannels(next);
            self.last_written = self.bal.cur;
        }

        self.version +%= 1;
    }

    fn writeChannels(self: *Component, state: *state_mod.State) !void {
        for (self.paths, self.bal.cur, 0..) |path, v, i| {
            if (path.len == 0) continue;
            if (v == self.last_written[i]) continue;
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.4}", .{v}) catch continue;
            try state.set(path, s);
            self.last_written[i] = v;
        }
    }
};

fn parseF32(s: []const u8) ?f32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t\r\n")) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .paths = .{ &.{}, &.{}, &.{} },
        .label = &.{},
        .bal = .{},
        .bar_h = DEFAULT_BAR_H,
    };
    for (&c.paths) |*p| p.* = try allocator.dupe(u8, "");
    errdefer for (c.paths) |p| allocator.free(p);
    c.label = try allocator.dupe(u8, "");
    errdefer allocator.free(c.label);

    try c.ingest(spec);
    if (c.bal.cur[0] == c.bal.cur[1] and c.bal.cur[1] == c.bal.cur[2] and c.bal.push == 0) {
        c.bal.neutralise();
        c.last_written = c.bal.cur;
    }
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    for (c.paths) |p| allocator.free(p);
    allocator.free(c.label);
    allocator.destroy(c);
}

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
};

// ── Paint ───────────────────────────────────────────────────────────

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    _ = constraints; // intrinsically sized, like the trackball

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = lc.theme.body;
    const num_font = lc.theme.code_inline_font_id;
    const num_scale = lc.fonts.scale(num_font);
    const num_metrics = lc.fonts.metrics(num_font);

    const cell_w = blk: {
        const hb = lc.fonts.hbFont(num_font);
        const run = try shape.shapeUtf8(aa, hb, READOUT_TEMPLATE);
        var w: f32 = 0;
        for (run.glyphs) |g| w += g.x_advance * num_scale;
        break :blk w + 6;
    };
    const content_w = cell_w * 4;

    var y = origin[1];
    if (c.label.len > 0) {
        const label_m = lc.fonts.metrics(body.font_id);
        const hb = lc.fonts.hbFont(body.font_id);
        const run = try shape.shapeUtf8(aa, hb, c.label);
        var lw: f32 = 0;
        for (run.glyphs) |g| lw += g.x_advance * lc.fonts.scale(body.font_id);
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
            body.font_id,
            origin[0] + (content_w - lw) * 0.5,
            y + label_m.ascender,
            LABEL_COLOR,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
        y += label_m.line_height + LABEL_GAP;
    }

    const bars_top = y;
    const f_neutral = c.bal.fractionOf(c.bal.neutral);
    const values: [4]f32 = .{ c.bal.cur[0], c.bal.cur[1], c.bal.cur[2], c.bal.master };

    for (values, trackball.CHANNEL_COLORS, 0..) |v, chan_col, i| {
        const cx = origin[0] + cell_w * (@as(f32, @floatFromInt(i)) + 0.5);

        // Track, as a slot cut into the panel: the fill, then the lip's
        // shadow down the top of it and a sliver of bounce at the
        // bottom. `ends = false` — a vertical slot has no left and right
        // lip to occlude anything.
        //
        // The fill is a TRIANGLE rect rather than the rounded quad it
        // used to be, because the whole triangle layer draws beneath the
        // whole quad layer: as a quad it covered its own shadow. The
        // rounded ends were 2.5px on a 5px slot and are not missed; the
        // depth is.
        try relief.rect(out, lc, cx - TRACK_W * 0.5, bars_top, TRACK_W, c.bar_h, TRACK_COLOR);
        try relief.groove(out, lc, cx - TRACK_W * 0.5, bars_top, TRACK_W, c.bar_h, false);

        // Fill, from neutral to the value. Drawn as a span rather than
        // from the bottom so a signed range reads correctly: a lift of
        // -0.1 is a bar hanging BELOW the tick, not a short bar.
        const f_val = c.bal.fractionOf(v);
        const lo = @min(f_val, f_neutral);
        const hi = @max(f_val, f_neutral);
        const fill_h = (hi - lo) * c.bar_h;
        if (fill_h > 0.5) {
            try out.appendQuad(lc, .{
                .dst_pos = .{ cx - BAR_W * 0.5, bars_top + (1.0 - hi) * c.bar_h },
                .dst_size = .{ BAR_W, fill_h },
                .color = chan_col,
                .radius = BAR_W * 0.5,
            });
        }

        // Neutral tick.
        try out.appendQuad(lc, .{
            .dst_pos = .{ cx - BAR_W, bars_top + (1.0 - f_neutral) * c.bar_h - 0.5 },
            .dst_size = .{ BAR_W * 2, 1.0 },
            .color = NEUTRAL_TICK_COLOR,
            .radius = 0,
        });

        // Thumb.
        try out.appendQuad(lc, .{
            .dst_pos = .{ cx - BAR_W * 0.7, bars_top + (1.0 - f_val) * c.bar_h - THUMB_H * 0.5 },
            .dst_size = .{ BAR_W * 1.4, THUMB_H },
            .color = THUMB_COLOR,
            .radius = THUMB_H * 0.5,
        });
    }

    y += c.bar_h + READOUT_GAP;

    const readout_baseline = y + num_metrics.ascender;
    for (values, trackball.CHANNEL_COLORS, 0..) |v, col, i| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.2}", .{v}) catch continue;
        const hb = lc.fonts.hbFont(num_font);
        const run = try shape.shapeUtf8(aa, hb, s);
        var tw: f32 = 0;
        for (run.glyphs) |g| tw += g.x_advance * num_scale;
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
            num_font,
            origin[0] + cell_w * @as(f32, @floatFromInt(i)) + (cell_w - tw) * 0.5,
            readout_baseline,
            col,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
    }
    y += num_metrics.line_height;

    c.cell_w = cell_w;
    c.bars_top = bars_top - origin[1];
    c.content_w = content_w;

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = content_w,
        .h = y - origin[1],
        .baseline = readout_baseline,
    };
}

// ── Input ───────────────────────────────────────────────────────────

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_raw: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const state: *state_mod.State = @ptrCast(@alignCast(state_raw));

    switch (event) {
        .mouse_down => |m| {
            if (m.button != 0) return;
            c.grabbed = columnAt(c, m.local);
            if (c.grabbed != null) try applyDrag(c, state, m.local);
        },
        .mouse_move => |m| {
            if (m.button_down and c.grabbed != null) try applyDrag(c, state, m.local);
        },
        .mouse_up => |m| {
            if (m.button == 0) c.grabbed = null;
        },
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

/// Which bar a press at `local` grabbed. Latched, so a drag that leaves
/// the column keeps driving the bar it started on — the usual behaviour,
/// and here it is load-bearing: the columns are 40px apart and a drag
/// that swapped bars mid-gesture would scramble a grade.
pub fn columnAt(c: *const Component, local: [2]f32) ?usize {
    if (local[1] < c.bars_top - 6 or local[1] > c.bars_top + c.bar_h + 6) return null;
    if (local[0] < 0 or local[0] >= c.content_w) return null;
    if (!(c.cell_w > 0)) return null;
    const i: usize = @intFromFloat(@floor(local[0] / c.cell_w));
    return @min(i, MASTER);
}

fn applyDrag(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    const col = c.grabbed orelse return;
    if (!(c.bar_h > 0)) return;

    const f = color.clamp(1.0 - (local[1] - c.bars_top) / c.bar_h, 0, 1);
    const v = c.bal.min + f * (c.bal.max - c.bal.min);

    if (col == MASTER) {
        // Hold the balance, move the level — the dial's job, in bar
        // form. `forward` re-spreads the three channels around the new
        // master using the push that is already set.
        c.bal.master = v;
        c.bal.forward();
    } else {
        c.bal.setChannel(col, v);
    }
    c.version +%= 1;
    try c.writeChannels(state);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

var attr_pool: [8][12]components.Attr = undefined;
var attr_next: usize = 0;

fn specOf(attrs: []const components.Attr) components.Spec {
    const i = attr_next % attr_pool.len;
    attr_next += 1;
    for (attrs, 0..) |a, n| attr_pool[i][n] = a;
    return .{ .name = "color_bars", .id = null, .attrs = attr_pool[i][0..attrs.len], .body = "" };
}

/// A gain-shaped bar stack: 0..2 around a neutral of 1, four 40px
/// columns, bars from y=0 to y=100.
fn gainBars() !component_mod.Instance {
    const spec = specOf(&.{
        .{ .key = "r", .value = "gain_r" },
        .{ .key = "g", .value = "gain_g" },
        .{ .key = "b", .value = "gain_b" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "2" },
        .{ .key = "neutral", .value = "1" },
    });
    const inst = try create(&_test_spark, testing.allocator, &spec);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.cell_w = 40;
    c.bars_top = 0;
    c.bar_h = 100;
    c.content_w = 160;
    return inst;
}

test "color_bars: starts neutral on every channel" {
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    for (c.bal.cur) |v| try testing.expectApproxEqAbs(@as(f32, 1), v, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), c.bal.master, 1e-6);
}

test "color_bars: dragging one bar writes one channel" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Column 0 (red), three-quarters up the 100px track = 1.5.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 25 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(@as(?usize, 0), c.grabbed);
    try testing.expectApproxEqAbs(@as(f32, 1.5), c.bal.cur[0], 1e-4);
    try testing.expectEqualStrings("1.5000", state.get("gain_r").?);
    // The other two were not touched, so they were not authored.
    try testing.expect(state.get("gain_g") == null);
    try testing.expect(state.get("gain_b") == null);
}

test "color_bars: the master bar moves all three and keeps the spread" {
    // The property that makes this the same control as the trackball's
    // dial: level and balance are separable.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Push red up first, so there IS a spread to preserve.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 25 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 20, 25 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    const spread_before = c.bal.cur[0] - c.bal.cur[1];
    try testing.expect(spread_before > 0.1); // Rule 1

    // Now grab the master column (index 3 → x in 120..160) and pull it
    // down to 0.5 of the range.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 140, 75 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(@as(?usize, MASTER), c.grabbed);

    try testing.expectApproxEqAbs(@as(f32, 0.5), c.bal.master, 1e-4);
    const spread_after = c.bal.cur[0] - c.bal.cur[1];
    try testing.expectApproxEqAbs(spread_before, spread_after, 1e-3);
    // And all three really did move.
    try testing.expect(state.get("gain_g") != null);
    try testing.expect(state.get("gain_b") != null);
}

test "color_bars: the column latches, so a sideways drag stays on its bar" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 50 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    // Slide right across three columns while dragging up.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 150, 20 }, .button = 0, .button_down = true } }, @ptrCast(&state));

    try testing.expectEqual(@as(?usize, 0), c.grabbed);
    try testing.expectApproxEqAbs(@as(f32, 1.6), c.bal.cur[0], 1e-4);
    // Green and blue were never the target, so they are still neutral.
    try testing.expectApproxEqAbs(@as(f32, 1), c.bal.cur[1], 1e-6);
}

test "color_bars: a press outside the bars grabs nothing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Below the readout gap.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 140 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(@as(?usize, null), c.grabbed);
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 20, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expect(state.get("gain_r") == null);
}

test "color_bars: columnAt clamps rather than running off the end" {
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqual(@as(?usize, 0), columnAt(c, .{ 0, 50 }));
    try testing.expectEqual(@as(?usize, 1), columnAt(c, .{ 41, 50 }));
    try testing.expectEqual(@as(?usize, MASTER), columnAt(c, .{ 159.5, 50 }));
    // Past the right edge is a miss, not column 4.
    try testing.expectEqual(@as(?usize, null), columnAt(c, .{ 161, 50 }));
    try testing.expectEqual(@as(?usize, null), columnAt(c, .{ -1, 50 }));
}

test "color_bars: agrees with a trackball on the same numbers" {
    // The claim the two views exist to make. Drive the bars, take the
    // three channel values they wrote, feed them to a trackball as its
    // `value_*` bindings — which is exactly what the plane mirror does
    // between two panels — and the two must describe the same grade.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const bars = try gainBars();
    defer deinit_(bars.ctx, testing.allocator);
    const bc: *Component = @ptrCast(@alignCast(bars.ctx));

    try onInput(bars.ctx, .{ .mouse_down = .{ .local = .{ 20, 30 }, .button = 0, .button_down = true } }, @ptrCast(&state));

    var b: color.Balance = .{ .min = 0, .max = 2, .neutral = 1 };
    b.setChannels(bc.bal.cur);

    try testing.expectApproxEqAbs(bc.bal.master, b.master, 1e-5);
    try testing.expectApproxEqAbs(bc.bal.push, b.push, 1e-4);
    try testing.expectApproxEqAbs(bc.bal.hue, b.hue, 0.05);
    // Rule 1 — a neutral grade would pass this vacuously.
    try testing.expect(b.push > 0.1);
}

test "color_bars: an external write moves the bars" {
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const next = specOf(&.{
        .{ .key = "value_r", .value = "1.4" },
        .{ .key = "value_g", .value = "0.9" },
        .{ .key = "value_b", .value = "0.7" },
    });
    try update(inst.ctx, &next);

    try testing.expectApproxEqAbs(@as(f32, 1.4), c.bal.cur[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.bal.master, 1e-5);
    try testing.expect(c.bal.push > 0.1);
}

test "color_bars: a stale echo mid-drag does not twitch the other columns" {
    // Dragging R re-derives the master and the balance through
    // `inverse`. A stale echo arriving mid-gesture would recompute all
    // three from last frame's numbers, so the MST column and the arc
    // jitter while one bar is held steady.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 25 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 1.5), c.bal.cur[0], 1e-4);
    const master_live = c.bal.master;

    const stale = specOf(&.{
        .{ .key = "value_r", .value = "1.0000" },
        .{ .key = "value_g", .value = "1.0000" },
        .{ .key = "value_b", .value = "1.0000" },
    });
    try update(inst.ctx, &stale);
    try testing.expectApproxEqAbs(@as(f32, 1.5), c.bal.cur[0], 1e-4);
    try testing.expectApproxEqAbs(master_live, c.bal.master, 1e-5);

    // Rule 1: after the release the plane is the truth again.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 20, 25 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    const external = specOf(&.{
        .{ .key = "value_r", .value = "1.0000" },
        .{ .key = "value_g", .value = "1.0000" },
        .{ .key = "value_b", .value = "1.0000" },
    });
    try update(inst.ctx, &external);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.bal.cur[0], 1e-5);
}

test "color_bars: a zero-height bar does not divide by nothing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try gainBars();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    c.bar_h = 0;
    c.grabbed = 0;
    try applyDrag(c, &state, .{ 20, 0 });
    for (c.bal.cur) |v| try testing.expect(std.math.isFinite(v));
}
