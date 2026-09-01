//! `:::color_wheel` — a hue/saturation disc and a value bar, writing three
//! channels as an ABSOLUTE colour.
//!
//!     :::color_wheel {label="Sun" r=sun_r g=sun_g b=sun_b
//!                     value_r=${state.sun_r}
//!                     value_g=${state.sun_g}
//!                     value_b=${state.sun_b}
//!                     size=110}
//!     :::
//!
//! Same attribute names as `:::trackball` and `:::color_bars`, because
//! all three drive three bound paths and a document should not have to
//! learn a second spelling. `min` / `max` default to 0..1, which is what
//! a tint is.
//!
//! ## Why this exists when a trackball already does colour
//!
//! A trackball is a SIGNED push around a neutral, which is what a
//! grading primary is. A tint is not that. `render/light/sun_tint` runs
//! 0..1 with a default of white — and white is the TOP of that range, so
//! there is no headroom above neutral to push into and
//! `color.Balance.pushScale` collapses. A trackball bound to a tint
//! would be inert, which is why `hud/light.md` and `hud/sky.md` were
//! still spending three sliders on every colour they own.
//!
//! So the same three numbers, read as a colour: `color.Swatch`.
//!
//! ## The two gestures
//!
//! **Disc** — angle is hue, radius is saturation. Absolute, so the puck
//! goes where you press, and the centre is white rather than a reset:
//! on a picker, "no saturation" IS a colour you might want.
//!
//! **Value bar** — the strip below, absolute. Unlike the trackball's
//! dial, which is relative because a master is a fine trim, a value is
//! something you slam to nothing or to full and it wants the whole
//! travel under one gesture.
//!
//! The disc dims with the value, so the wheel shows the colours it will
//! actually produce rather than a bright ring above a dark result.

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
    try spark.registry.register("color_wheel", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Visual constants ────────────────────────────────────────────────

const DISC_SEGMENTS: usize = 96;
const DOT_SEGMENTS: usize = 24;
const DISC_RIM_SHADE: f32 = 0.22;
const DISC_SHADE_PX: f32 = 5.0;

const BAR_H: f32 = 12.0;
const BAR_GAP: f32 = 8.0;
const LABEL_GAP: f32 = 4.0;
const READOUT_GAP: f32 = 5.0;
const PUCK_R: f32 = 5.0;
/// The chip at the disc's centre — what the picker currently holds, at
/// full value so it stays legible when the wheel is turned down. It is
/// also, incidentally, the preview swatch that three sliders and a
/// `:::box {color=}` could never produce: attribute interpolation has no
/// string formatting, so no document can compose `#rrggbb`. A widget
/// that owns the colour sidesteps the whole problem.
const CHIP_R: f32 = 7.0;
const CHIP_RING: [4]f32 = .{ 1.0, 1.0, 1.0, 0.55 };
const DEFAULT_SIZE: f32 = 110.0;
const LABEL_COLOR: [4]f32 = .{ 0.92, 0.93, 0.97, 1.0 };
const READOUT_TEMPLATE = "-0.00";

const Zone = enum { none, disc, bar };

const Component = struct {
    allocator: std.mem.Allocator,
    paths: [3][]u8,
    label: []u8,
    sw: color.Swatch,
    size: f32,

    /// See `trackball.Component.last_written` — same gate, same reason.
    last_written: [3]f32 = .{ 0, 0, 0 },

    // Local geometry, recorded at layout; origin-independent.
    disc_centre: [2]f32 = .{ 0, 0 },
    disc_r: f32 = 1,
    bar_top: f32 = 0,
    content_w: f32 = 160,

    zone: Zone = .none,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var raw: [3]?[]const u8 = .{ null, null, null };
        var values: [3]?f32 = .{ null, null, null };
        var min: ?f32 = null;
        var max: ?f32 = null;

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
            } else if (std.mem.eql(u8, k, "size")) {
                if (parseF32(attr.value)) |v| {
                    if (v > 16) self.size = v;
                }
            } else if (std.mem.eql(u8, k, "label")) {
                const dup = try a.dupe(u8, attr.value);
                a.free(self.label);
                self.label = dup;
            }
        }

        // Paths and values are both held off during a gesture, and an
        // unchanged path is never reallocated. The long note on
        // `trackball.Component.ingest` says why: `state.set` notifies
        // subscribers synchronously, this component is one of them, and
        // a widget that writes THREE paths from one gesture would
        // otherwise re-derive itself from a two-thirds-stale triple —
        // and free the key the `set` on the stack is still holding.
        const gesture = self.zone != .none;
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

        if (min) |v| self.sw.min = v;
        if (max) |v| self.sw.max = v;

        if (!gesture and (values[0] != null or values[1] != null or values[2] != null)) {
            var next = self.sw.cur;
            for (values, 0..) |maybe, i| {
                if (maybe) |v| next[i] = v;
            }
            self.sw.setChannels(next);
            self.last_written = self.sw.cur;
        }

        self.version +%= 1;
    }

    fn writeChannels(self: *Component, state: *state_mod.State) !void {
        for (self.paths, self.sw.cur, 0..) |path, v, i| {
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
        .sw = .{},
        .size = DEFAULT_SIZE,
    };
    for (&c.paths) |*p| p.* = try allocator.dupe(u8, "");
    errdefer for (c.paths) |p| allocator.free(p);
    c.label = try allocator.dupe(u8, "");
    errdefer allocator.free(c.label);
    try c.ingest(spec);
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

fn hueRim(deg: f32) [3]f32 {
    return color.hsv2rgb(deg, 1, 1);
}

// ── Paint ───────────────────────────────────────────────────────────

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    _ = constraints; // intrinsically sized, like its two siblings

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
    const content_w = @max(c.size, cell_w * 4);

    var y = origin[1];
    if (c.label.len > 0) {
        const m = lc.fonts.metrics(body.font_id);
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
            y + m.ascender,
            LABEL_COLOR,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
        y += m.line_height + LABEL_GAP;
    }

    // ── Disc ──
    const centre: [2]f32 = .{ origin[0] + content_w * 0.5, y + c.size * 0.5 };
    const disc_r = @max(6.0, c.size * 0.5);
    const val = color.clamp(c.sw.val, 0, 1);

    try relief.hueDisc(out, lc, .{
        .centre = centre,
        .r = disc_r,
        // The middle of a hue wheel is white — saturation zero — and it
        // dims with the value like everything else on the disc.
        .centre_color = .{ val, val, val, 1.0 },
        .segments = DISC_SEGMENTS,
        .hueAt = hueRim,
        .rim_shade = DISC_RIM_SHADE,
        .shade_px = DISC_SHADE_PX,
        .brightness = val,
    });

    // The chip: what the picker holds, at full value so it stays
    // readable when the wheel is dark.
    try relief.disc(out, lc, centre, CHIP_R + 1.5, CHIP_RING, DOT_SEGMENTS);
    try relief.disc(out, lc, centre, CHIP_R, c.sw.chip(), DOT_SEGMENTS);

    // The puck: hue around, saturation out.
    const puck = relief.onCircle(centre, color.clamp(c.sw.sat, 0, 1) * disc_r, c.sw.hue);
    try relief.disc(out, lc, puck, PUCK_R + 1.5, .{ 1, 1, 1, 0.92 }, DOT_SEGMENTS);
    try relief.disc(out, lc, puck, PUCK_R, c.sw.chip(), DOT_SEGMENTS);

    y += c.size + BAR_GAP;

    // ── Value bar ──
    //
    // Black to the picked hue at full saturation, so the strip is a
    // picture of the axis it drives rather than a grey slot.
    const bar_top = y;
    const full = c.sw.chip();
    try relief.shadeH(out, lc, origin[0], bar_top, content_w, BAR_H, .{ 0, 0, 0, 1 }, full);
    try relief.groove(out, lc, origin[0], bar_top, content_w, BAR_H, false);
    const tx = origin[0] + val * content_w;
    try relief.disc(out, lc, .{ tx, bar_top + BAR_H * 0.5 }, BAR_H * 0.42, .{ 0.97, 0.97, 1.0, 1.0 }, DOT_SEGMENTS);

    y += BAR_H + READOUT_GAP;

    // ── Readout ──
    const baseline = y + num_metrics.ascender;
    const cells: [4]f32 = .{ c.sw.cur[0], c.sw.cur[1], c.sw.cur[2], val };
    for (cells, trackball.CHANNEL_COLORS, 0..) |v, col, i| {
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
            baseline,
            col,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
    }
    y += num_metrics.line_height;

    c.disc_centre = .{ centre[0] - origin[0], centre[1] - origin[1] };
    c.disc_r = disc_r;
    c.bar_top = bar_top - origin[1];
    c.content_w = content_w;

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = content_w,
        .h = y - origin[1],
        .baseline = baseline,
    };
}

// ── Input ───────────────────────────────────────────────────────────

fn onInput(ctx: *anyopaque, event: element.InputEvent, state_raw: *anyopaque) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const state: *state_mod.State = @ptrCast(@alignCast(state_raw));

    switch (event) {
        .mouse_down => |m| {
            if (m.button != 0) return;
            c.zone = zoneAt(c, m.local);
            switch (c.zone) {
                .disc => try pressDisc(c, state, m.local),
                .bar => try pressBar(c, state, m.local),
                .none => {},
            }
        },
        .mouse_move => |m| {
            if (!m.button_down) return;
            switch (c.zone) {
                .disc => try pressDisc(c, state, m.local),
                .bar => try pressBar(c, state, m.local),
                .none => {},
            }
        },
        .mouse_up => |m| {
            if (m.button == 0) c.zone = .none;
        },
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

pub fn zoneAt(c: *const Component, local: [2]f32) Zone {
    if (local[1] >= c.bar_top and local[1] <= c.bar_top + BAR_H) return .bar;
    const dx = local[0] - c.disc_centre[0];
    const dy = local[1] - c.disc_centre[1];
    const slop = c.disc_r * 1.12;
    if (dx * dx + dy * dy <= slop * slop) return .disc;
    return .none;
}

fn pressDisc(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    const dx = local[0] - c.disc_centre[0];
    const dy = local[1] - c.disc_centre[1];
    const dist = @sqrt(dx * dx + dy * dy);
    c.sw.sat = color.clamp(dist / c.disc_r, 0, 1);
    // A hue read at the exact centre is noise, and spinning it there
    // would make the puck flick as it crossed the middle. Same rule as
    // `Swatch.inverse` keeping the hue through black.
    if (dist > 0.5) {
        c.sw.hue = @mod(std.math.atan2(dx, -dy) * 180.0 / std.math.pi + 360.0, 360.0);
    }
    c.sw.forward();
    c.version +%= 1;
    try c.writeChannels(state);
}

fn pressBar(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    if (!(c.content_w > 0)) return;
    c.sw.val = color.clamp(local[0] / c.content_w, 0, 1);
    c.sw.forward();
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
    return .{ .name = "color_wheel", .id = null, .attrs = attr_pool[i][0..attrs.len], .body = "" };
}

/// A tint picker with a geometry a test can aim at: centre (60, 60),
/// radius 50, bar from y=130 to y=142, 120 wide.
fn tintWheel() !component_mod.Instance {
    const spec = specOf(&.{
        .{ .key = "r", .value = "sun_r" },
        .{ .key = "g", .value = "sun_g" },
        .{ .key = "b", .value = "sun_b" },
        .{ .key = "value_r", .value = "1" },
        .{ .key = "value_g", .value = "1" },
        .{ .key = "value_b", .value = "1" },
    });
    const inst = try create(&_test_spark, testing.allocator, &spec);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.disc_centre = .{ 60, 60 };
    c.disc_r = 50;
    c.bar_top = 130;
    c.content_w = 120;
    return inst;
}

test "color_wheel: a white tint opens at the centre, full value" {
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectApproxEqAbs(@as(f32, 0), c.sw.sat, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), c.sw.val, 1e-5);
}

test "color_wheel: a press on the rim writes a saturated colour" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Straight up is hue 0 — red — at full saturation.
    try pressDisc(c, &state, .{ 60, 10 });
    try testing.expectApproxEqAbs(@as(f32, 0), c.sw.hue, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), c.sw.sat, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), c.sw.cur[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), c.sw.cur[1], 1e-5);

    // Green and blue moved and were written; RED DID NOT. White is
    // (1,1,1) and red is (1,0,0), so the red channel is genuinely
    // unchanged and the write gate correctly declines to re-author it —
    // the same rule `::grip` follows for an axis that did not move.
    try testing.expectEqualStrings("0.0000", state.get("sun_g").?);
    try testing.expectEqualStrings("0.0000", state.get("sun_b").?);
    try testing.expect(state.get("sun_r") == null);

    // And a swing that DOES move red writes it, so the silence above is
    // about the gate rather than about a path that was never bound.
    try pressDisc(c, &state, .{ 60, 110 }); // hue 180, cyan
    try testing.expectEqualStrings("0.0000", state.get("sun_r").?);
}

test "color_wheel: unlike a trackball, the centre is white and not a reset" {
    // On a balance control the middle means "no push", so clicking it
    // homes everything. On a PICKER it is a colour you might want, and
    // snapping the value home with it would throw away a setting the
    // user made with the other gesture.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try pressBar(c, &state, .{ 36, 135 }); // value to 0.30
    try testing.expectApproxEqAbs(@as(f32, 0.30), c.sw.val, 1e-3);

    try pressDisc(c, &state, .{ 61, 60 }); // dead centre
    try testing.expectApproxEqAbs(@as(f32, 0), c.sw.sat, 0.05);
    // The value the bar set is still there.
    try testing.expectApproxEqAbs(@as(f32, 0.30), c.sw.val, 1e-3);
}

test "color_wheel: the value bar is absolute, not relative" {
    // The trackball's dial is relative because a master is a fine trim.
    // A value is something you slam to nothing or to full, and it wants
    // the whole travel under one gesture.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 0, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 0), c.sw.val, 1e-5);
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 120, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 1), c.sw.val, 1e-5);
}

test "color_wheel: the hue survives being dragged to black and back" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // 40px out on a 50px radius — saturation 0.8, not full.
    try pressDisc(c, &state, .{ 100, 60 });
    try testing.expectApproxEqAbs(@as(f32, 90), c.sw.hue, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.8), c.sw.sat, 1e-3);

    try pressBar(c, &state, .{ 0, 135 }); // to black
    for (c.sw.cur) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-5);
    try pressBar(c, &state, .{ 120, 135 }); // and back up
    try testing.expectApproxEqAbs(@as(f32, 90), c.sw.hue, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.8), c.sw.sat, 1e-3);
}

test "color_wheel: the zone latches so a drag off the disc keeps steering it" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 60, 20 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(Zone.disc, c.zone);
    const val_before = c.sw.val;
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 90, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(Zone.disc, c.zone);
    try testing.expectApproxEqAbs(val_before, c.sw.val, 1e-6);
    // Rule 1: the move landed on the disc, so the hue really did change.
    try testing.expect(c.sw.hue > 90 and c.sw.hue < 180);
}

test "color_wheel: a stale echo mid-gesture does not move the puck" {
    // Three paths written one at a time, each notifying us before the
    // next goes out — see `trackball.zig`'s long note. Here the damage
    // would be a hue re-derived from `(new_r, old_g, old_b)`.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 100, 60 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 90), c.sw.hue, 0.5);

    const stale = specOf(&.{
        .{ .key = "value_r", .value = "1.0000" },
        .{ .key = "value_g", .value = "1.0000" },
        .{ .key = "value_b", .value = "1.0000" },
    });
    try update(inst.ctx, &stale);
    try testing.expectApproxEqAbs(@as(f32, 90), c.sw.hue, 0.5);

    // Rule 1: once the gesture ends the plane is the truth again.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 100, 60 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try update(inst.ctx, &stale);
    try testing.expectApproxEqAbs(@as(f32, 0), c.sw.sat, 1e-3); // white
}

test "color_wheel: an unchanged path is not reallocated" {
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    const before = c.paths[0].ptr;
    const same = specOf(&.{.{ .key = "r", .value = "sun_r" }});
    try update(inst.ctx, &same);
    try testing.expectEqual(before, c.paths[0].ptr);
}

test "color_wheel: zoneAt separates the disc from the bar" {
    const inst = try tintWheel();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(Zone.disc, zoneAt(c, .{ 60, 60 }));
    try testing.expectEqual(Zone.disc, zoneAt(c, .{ 60, 12 }));
    try testing.expectEqual(Zone.none, zoneAt(c, .{ 60, -20 }));
    try testing.expectEqual(Zone.bar, zoneAt(c, .{ 60, 135 }));
    try testing.expectEqual(Zone.none, zoneAt(c, .{ 60, 160 }));
}
