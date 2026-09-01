//! `:::meter` — a labelled bar with its number, in FIXED columns.
//!
//! Attribute grammar:
//!
//!     :::meter {label="traversal" value=${state.p_trav} max=${state.gpu_ms}
//!               color=#e8873a unit=ms percent=1}
//!     :::
//!
//! - `label`   (required) — the row's name, left column.
//! - `value`   (required) — the number. Non-numeric reads as 0.
//! - `min`     (optional) — the bar's low end. Default 0. A range that
//!   spans zero (`min=-3 max=3`) fills from the CENTRE and draws a tick
//!   there — what a signed reading needs, like a fly-cam's thrust stick.
//! - `max`     (optional) — the bar's full scale. Default 1.
//! - `color`   (optional) — swatch and bar fill.
//! - `unit`    (optional) — printed after the value (`ms`, `%`, `fps`).
//! - `decimals`(optional) — fixed decimal places. Default 2.
//! - `percent` (optional) — add a `value/max` percentage column.
//! - `spark`   (optional) — add a sparkline of this value's own recent
//!   history, auto-scaled to what is in the window.
//! - `bar`     (optional) — draw the proportional bar. Default on; turn
//!   it off for a row whose reading is the trace and the number.
//! - `label_w` / `value_w` / `width` (optional) — column geometry.
//!
//! ## The bug this is the cure for
//!
//! A readout in flowing prose re-wraps. `hud/perf.md` shipped as
//! `**${state.fps} fps** · ${state.frame_ms} ms` and Chris, 2026-09-01:
//! "the panel is laying out constantly because depending on the numbers it
//! tends to wrap."
//!
//! It is not a wrapping bug — it is the honest consequence of putting a
//! value whose WIDTH changes into a line whose layout depends on width.
//! `60.02` and `9.5` are different numbers of glyphs, the run rewraps, the
//! paragraph's height changes, and every block below it moves. At ten
//! updates a second that is a panel that never stops relaying out.
//!
//! So a meter does the two things prose cannot:
//!
//!   * **Fixed columns.** The label, the bar, the value and the percentage
//!     each occupy a declared width. Nothing a number does can move
//!     anything else, because nothing downstream is measured from it.
//!   * **Fixed decimals.** The value is parsed and re-formatted at
//!     `decimals` places, so it does not change width as it crosses a power
//!     of ten — and it is right-aligned in its column, so it does not shift
//!     when it does.
//!
//! Both halves are needed. Fixed columns with a ragged number still jitters
//! the digits; fixed decimals in flowing prose still rewraps the line.
//!
//! ## Why this and not `::progress`
//!
//! `::progress` is a bar and nothing else — an inline object with no label,
//! no number, no scale. It is right for "a bar inside a sentence" and this
//! is right for "a row in a table of measurements". The perf panel wants
//! eighteen of the latter, and writing each as a hand-aligned trio of
//! inline objects is how a document ends up with a layout nobody can edit.
//!
//! ## Drawn in the TRIANGLE layer, except the swatch
//!
//! The track, its recess shading and the fill are triangles so they order
//! correctly among themselves — the renderer draws the whole triangle layer
//! beneath the whole quad layer, not in emission order, so a quad fill under
//! a triangle shadow comes out with the shadow behind the thing it falls on.
//! The swatch is a rounded quad because it overlaps nothing and would rather
//! have `quad.frag`'s corners.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
const relief = @import("relief.zig");

pub const Error = error{
    MeterMissingLabel,
    MeterNotInstalled,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("meter", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

/// A number from an attribute. Non-numeric reads as zero rather than
/// refusing: these values arrive from `${state.x}`, and a path that has not
/// been published yet is an empty string. A meter that failed to mount
/// because the engine had not measured a frame yet would be a worse
/// answer than a bar at zero.
pub fn numberOf(s: []const u8) f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t\r\n")) catch 0;
}

/// Where `value` sits across the bar, as 0..1. An empty or inverted range
/// gives zero rather than an infinity or a NaN — `max=${state.gpu_ms}` is
/// exactly an empty range on the first frame.
pub fn fractionIn(value: f32, min: f32, max: f32) f32 {
    if (!(max > min) or !std.math.isFinite(value)) return 0;
    const f = (value - min) / (max - min);
    if (!std.math.isFinite(f)) return 0;
    return std.math.clamp(f, 0, 1);
}

/// Where the fill STARTS FROM, as 0..1.
///
/// The position of zero, clamped into the range. A `min=0` bar fills from
/// its left edge, which is every measurement; a `min=-3 max=3` bar fills
/// from its CENTRE, which is what a signed reading needs — a fly-cam's
/// thrust stick pushed backwards is not "a bit of forward", it is the
/// other direction, and a bar growing rightwards from the left edge says
/// the wrong thing about it.
///
/// Falling out of "where is zero" rather than being a mode flag means a
/// range that does not contain zero (`min=5 max=10`) still fills from its
/// own left edge, with nothing to decide.
pub fn originFraction(min: f32, max: f32) f32 {
    if (!(max > min)) return 0;
    return fractionIn(std.math.clamp(@as(f32, 0), min, max), min, max);
}

/// Where each column starts, given the row's total width.
///
/// Split out so the arithmetic has somewhere to be checked: the drawing
/// needs a font stack and two atlases to reach, and a column layout nobody
/// can gate is a column layout that drifts.
pub const Columns = struct {
    swatch_x: f32,
    label_x: f32,
    bar_x: f32,
    bar_w: f32,
    /// RIGHT edge of the value column — the text is right-aligned to it.
    value_right: f32,
    /// Right edge of the percentage column, when there is one.
    pct_right: f32,
    spark_x: f32,
    spark_w: f32,
};

/// The columns, left to right: swatch, label, bar, sparkline, value,
/// percentage. Each is either its declared width or absent — the BAR is
/// the only elastic one, because it is the only one whose meaning is a
/// proportion of the space it is given.
pub fn columnsFor(
    x: f32,
    total_w: f32,
    label_w: f32,
    value_w: f32,
    percent: bool,
    bar: bool,
    spark: bool,
) Columns {
    const pct_w: f32 = if (percent) PCT_W else 0;
    const spark_w: f32 = if (spark) SPARK_W else 0;
    const spark_gap: f32 = if (spark) BAR_GAP else 0;
    const bar_x = x + SWATCH + SWATCH_GAP + label_w;
    const right_of_bar = (x + total_w) - pct_w - value_w - BAR_GAP - spark_w - spark_gap;
    // The bar takes what is left. It may end up at zero on a very narrow
    // panel, and zero is drawn as nothing rather than as a negative width
    // that would fold the geometry inside out.
    const bar_w: f32 = if (bar) @max(0, right_of_bar - bar_x) else 0;
    return .{
        .swatch_x = x,
        .label_x = x + SWATCH + SWATCH_GAP,
        .bar_x = bar_x,
        .bar_w = bar_w,
        // The sparkline sits between the bar and the value, right-anchored
        // — so a row with no bar keeps its trace in the same column as a
        // row that has one, and a table of mixed rows still lines up.
        .spark_x = right_of_bar + spark_gap,
        .spark_w = spark_w,
        .value_right = x + total_w - pct_w,
        .pct_right = x + total_w,
    };
}

const Component = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    unit: []u8,
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    decimals: u8 = 2,
    percent: bool = false,
    color: [4]f32 = BAR,
    width: ?box_helpers.Length = null,
    label_w: f32 = LABEL_W,
    value_w: f32 = VALUE_W,
    /// Whether to draw the proportional bar. Off for a row whose reading
    /// is the trace and the number — the console's pass rows are that.
    bar: bool = true,
    /// Whether to draw the sparkline column.
    spark: bool = false,
    /// The trace's own history. Small and fixed: a per-row sparkline is
    /// forty pixels wide, so more samples than that is more resolution
    /// than the column can show, and a heap allocation per row of a
    /// twenty-row panel is a cost with nothing to buy.
    hist: [SPARK_N]f32 = @splat(0),
    hist_n: usize = 0,
    hist_at: usize = 0,
    /// The last value appended, so a re-ingest that did not move it does
    /// not append a duplicate. Same guard, and same reason, as
    /// `:::chart`'s: `update` fires on ANY bound attribute re-resolving,
    /// and on `hud/perf.md` that is seventeen other paths.
    last_value: ?f32 = null,
    version: u64 = 0,

    fn push(self: *Component, v: f32) void {
        if (self.last_value) |prev| {
            if (prev == v) return;
        }
        self.last_value = v;
        self.hist[self.hist_at] = v;
        self.hist_at = (self.hist_at + 1) % SPARK_N;
        if (self.hist_n < SPARK_N) self.hist_n += 1;
    }

    /// Logical index 0..hist_n-1, oldest first.
    fn histAt(self: *const Component, i: usize) f32 {
        if (self.hist_n < SPARK_N) return self.hist[i];
        return self.hist[(self.hist_at + i) % SPARK_N];
    }

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var label_raw: ?[]const u8 = null;
        var unit_raw: []const u8 = "";

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "unit")) {
                unit_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "value")) {
                self.value = numberOf(attr.value);
                self.push(self.value);
            } else if (std.mem.eql(u8, attr.key, "min")) {
                self.min = numberOf(attr.value);
            } else if (std.mem.eql(u8, attr.key, "max")) {
                self.max = numberOf(attr.value);
            } else if (std.mem.eql(u8, attr.key, "decimals")) {
                self.decimals = @intFromFloat(std.math.clamp(numberOf(attr.value), 0, 6));
            } else if (std.mem.eql(u8, attr.key, "spark")) {
                self.spark = @import("button.zig").isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "bar")) {
                self.bar = @import("button.zig").isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "percent")) {
                self.percent = @import("button.zig").isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.color = v;
            } else if (std.mem.eql(u8, attr.key, "label_w")) {
                self.label_w = numberOf(attr.value);
            } else if (std.mem.eql(u8, attr.key, "value_w")) {
                self.value_w = numberOf(attr.value);
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            }
        }

        const label = label_raw orelse return Error.MeterMissingLabel;
        try component_mod.adoptString(a, &self.label, label);
        try component_mod.adoptString(a, &self.unit, unit_raw);
        self.version +%= 1;
    }
};

fn create(_: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, ""),
        .unit = try allocator.dupe(u8, ""),
    };
    errdefer {
        allocator.free(c.label);
        allocator.free(c.unit);
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
    allocator.free(c.unit);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Geometry ────────────────────────────────────────────────────────

/// The colour chip that ties a row to its segment in a stacked bar above.
const SWATCH: f32 = 7;
const SWATCH_GAP: f32 = 7;
/// Between the bar and the value column.
const BAR_GAP: f32 = 8;
const LABEL_W: f32 = 88;
/// Wide enough for `-000.00 ms` in the mono face, which is the widest thing
/// a frame timing puts here.
const VALUE_W: f32 = 62;
const PCT_W: f32 = 38;
const ROW_H: f32 = 18;
const BAR_H: f32 = 7;

/// The track is a NEUTRAL darkening, the idiom every recessed thing in this
/// vocabulary uses, so a meter takes the tint of whatever panel it is on.
const TRACK: [4]f32 = .{ 0, 0, 0, 0.42 };
const BAR: [4]f32 = .{ 0.35, 0.62, 0.95, 1.0 };
const LABEL: [4]f32 = .{ 0.80, 0.81, 0.84, 1.0 };
const VALUE: [4]f32 = .{ 0.90, 0.91, 0.93, 1.0 };
/// The percentage is context, not the reading — quieter than the value it
/// is a restatement of.
const PCT: [4]f32 = .{ 0.56, 0.55, 0.54, 1.0 };
/// The tick at zero on a signed bar. Light, because it is a reference and
/// not a reading.
const ZERO_MARK: [4]f32 = .{ 1.0, 1.0, 1.0, 0.28 };
/// The per-row trace. One colour for every row on purpose: the SWATCH
/// says which series this is, and a trace in the series colour would make
/// twenty rows of confetti out of a table meant to be scanned.
const SPARK: [4]f32 = .{ 0.62, 0.66, 0.74, 0.85 };
/// Samples in a row's history. Forty pixels of column cannot show more
/// resolution than this, and a heap allocation per row of a twenty-row
/// panel would be a cost with nothing to buy.
const SPARK_N: usize = 40;
const SPARK_W: f32 = 46;
const SPARK_H: f32 = 12;

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = lc.theme.body;
    const mono = lc.theme.applyCodeInline(lc.theme.body);
    const m = lc.fonts.metrics(body.font_id);

    const fallback: f32 = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320;
    const total_w: f32 = if (c.width) |w| w.resolve(constraints.max_w, fallback) else fallback;
    const x = @round(origin[0]);
    const y = @round(origin[1]);
    const cols = columnsFor(x, total_w, c.label_w, c.value_w, c.percent, c.bar, c.spark);

    const frac = fractionIn(c.value, c.min, c.max);
    const from = originFraction(c.min, c.max);
    const bar_y = @round(y + (ROW_H - BAR_H) * 0.5);

    // ── The bar, all triangles so it orders among itself ──────────────
    if (c.bar and cols.bar_w > 0) {
        try relief.rect(out, lc, cols.bar_x, bar_y, cols.bar_w, BAR_H, TRACK);
        // The fill runs BETWEEN the origin and the value, which is the same
        // arithmetic for both directions — a signed bar needs no second
        // code path, only a `min` that puts zero somewhere other than the
        // left edge.
        const a = @round(cols.bar_x + cols.bar_w * @min(from, frac));
        const b = @round(cols.bar_x + cols.bar_w * @max(from, frac));
        if (b > a) {
            try relief.rect(out, lc, a, bar_y, b - a, BAR_H, c.color);
        }
        // The zero mark, for a bar whose zero is not its left edge. Without
        // it a stick at rest and a stick held hard left look the same at a
        // glance: both are "no fill near the middle".
        if (from > 0.01 and from < 0.99) {
            try relief.rect(out, lc, @round(cols.bar_x + cols.bar_w * from), bar_y - 1, 1, BAR_H + 2, ZERO_MARK);
        }
        // The recess shading goes over BOTH, so the fill reads as sitting
        // in the slot rather than on top of it.
        try relief.groove(out, lc, cols.bar_x, bar_y, cols.bar_w, BAR_H, false);
    }

    // ── The trace ────────────────────────────────────────────────────
    // Newest at the RIGHT and a partly-filled history empty on the LEFT,
    // the same anchoring `chart.slotOf` uses and for the same reason: the
    // right-hand edge is NOW, from the first sample to forever.
    if (c.spark and cols.spark_w > 0 and c.hist_n > 0) {
        const sh = SPARK_H;
        const sy = @round(y + (ROW_H - sh) * 0.5);
        const slot = cols.spark_w / @as(f32, @floatFromInt(SPARK_N));
        // Auto-scaled to what is IN the window, not to `max`. A pass
        // holding 3% of the frame would otherwise be a flat line along the
        // bottom for ever — and the shape of its own variation is the only
        // thing a forty-pixel trace can usefully show.
        var lo: f32 = c.histAt(0);
        var hi: f32 = lo;
        for (0..c.hist_n) |i| {
            const v = c.histAt(i);
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        const span: f32 = if (hi - lo > 1e-6) hi - lo else 1;
        for (0..c.hist_n) |i| {
            const norm = (c.histAt(i) - lo) / span;
            const col_h = @max(1, norm * sh);
            const sx = cols.spark_x + @as(f32, @floatFromInt(SPARK_N - c.hist_n + i)) * slot;
            try relief.rect(out, lc, @round(sx), sy + sh - col_h, @max(1, slot), col_h, SPARK);
        }
    }

    // The swatch is a quad — it overlaps nothing, so it may as well have
    // the rounded-corner pipeline's edges.
    try out.appendQuad(lc, .{
        .dst_pos = .{ cols.swatch_x, @round(y + (ROW_H - SWATCH) * 0.5) },
        .dst_size = .{ SWATCH, SWATCH },
        .color = c.color,
        .radius = 1.5,
    });

    const baseline = y + (ROW_H - m.line_height) * 0.5 + m.ascender;

    try drawRun(lc, out, aa, body, c.label, cols.label_x, baseline, LABEL);

    // The value, re-formatted at fixed decimals and right-aligned. Both
    // halves are the cure for the reflow — see the header.
    var vbuf: [48]u8 = undefined;
    const vtext = formatValue(&vbuf, c.value, c.decimals, c.unit);
    try drawRunRight(lc, out, aa, mono, vtext, cols.value_right, baseline, VALUE);

    if (c.percent) {
        var pbuf: [16]u8 = undefined;
        // A position across the declared range, which for the ordinary
        // `min=0` bar is the ratio to max everyone expects.
        const ptext = std.fmt.bufPrint(&pbuf, "{d:.0}%", .{frac * 100}) catch "";
        try drawRunRight(lc, out, aa, mono, ptext, cols.pct_right, baseline, PCT);
    }

    return .{ .x = origin[0], .y = origin[1], .w = total_w, .h = ROW_H, .baseline = baseline };
}

/// `value` at `decimals` places, with `unit` appended after a space.
pub fn formatValue(buf: []u8, value: f32, decimals: u8, unit: []const u8) []const u8 {
    const n = switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d:.0}", .{value}),
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{value}),
        3 => std.fmt.bufPrint(buf, "{d:.3}", .{value}),
        else => std.fmt.bufPrint(buf, "{d:.2}", .{value}),
    } catch return "";
    if (unit.len == 0) return n;
    const rest = buf[n.len..];
    const u = std.fmt.bufPrint(rest, " {s}", .{unit}) catch return n;
    return buf[0 .. n.len + u.len];
}

fn drawRun(
    lc: *element.LayoutCtx,
    out: *element.DrawList,
    aa: std.mem.Allocator,
    style: element.Style,
    text: []const u8,
    x: f32,
    baseline: f32,
    color: [4]f32,
) !void {
    if (text.len == 0) return;
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(aa, hb, text);
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
        x,
        baseline,
        color,
        style.hot_color,
        style.attention,
        lc.zoom,
    );
}

/// Right-aligned to `right`. Shaping twice would be the obvious way and is
/// wasteful; the run is measured from the advances it already carries.
fn drawRunRight(
    lc: *element.LayoutCtx,
    out: *element.DrawList,
    aa: std.mem.Allocator,
    style: element.Style,
    text: []const u8,
    right: f32,
    baseline: f32,
    color: [4]f32,
) !void {
    if (text.len == 0) return;
    const hb = lc.fonts.hbFont(style.font_id);
    const fscale = lc.fonts.scale(style.font_id);
    const run = try shape.shapeUtf8(aa, hb, text);
    var w: f32 = 0;
    for (run.glyphs) |g| w += g.x_advance * fscale;
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
        @round(right - w),
        baseline,
        color,
        style.hot_color,
        style.attention,
        lc.zoom,
    );
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "meter: a number that has not been published yet reads as zero" {
    // These values arrive from `${state.x}`, and a plane path nothing has
    // written yet interpolates to the empty string. Refusing to mount
    // because the engine has not measured a frame would be a worse answer
    // than a bar at zero.
    try testing.expectEqual(@as(f32, 0), numberOf(""));
    try testing.expectEqual(@as(f32, 0), numberOf("  "));
    try testing.expectEqual(@as(f32, 0), numberOf("albedo"));
    try testing.expectEqual(@as(f32, 16.66), numberOf("16.66"));
    try testing.expectEqual(@as(f32, 4), numberOf(" 4 "));
}

test "meter: an empty range is a zero bar, not an infinity" {
    // `max=${state.gpu_ms}` is exactly an empty range on the first frame,
    // and a fraction of inf or NaN is a bar of garbage width.
    try testing.expectEqual(@as(f32, 0), fractionIn(5, 0, 0));
    try testing.expectEqual(@as(f32, 0), fractionIn(5, 0, -1));
    try testing.expectEqual(@as(f32, 0.5), fractionIn(5, 0, 10));
    // Clamped both ways: a pass that momentarily exceeds the frame total
    // must not draw past the end of its track.
    try testing.expectEqual(@as(f32, 1), fractionIn(20, 0, 10));
    try testing.expectEqual(@as(f32, 0), fractionIn(-5, 0, 10));
}

test "meter: a signed range fills from its centre" {
    // A fly-cam's thrust stick pushed backwards is not "a bit of forward",
    // it is the other direction — and a bar growing rightwards from the
    // left edge says the wrong thing about it.
    try testing.expectEqual(@as(f32, 0.5), originFraction(-3, 3));
    try testing.expectEqual(@as(f32, 0.5), fractionIn(0, -3, 3));
    try testing.expectEqual(@as(f32, 1), fractionIn(3, -3, 3));
    try testing.expectEqual(@as(f32, 0), fractionIn(-3, -3, 3));
    // Off-centre zero, which is what an asymmetric stick would give.
    try testing.expectEqual(@as(f32, 0.25), originFraction(-1, 3));
}

test "meter: a range that misses zero fills from its own edge" {
    // Falls out of "where is zero, clamped into the range" rather than
    // needing a mode flag — so there is nothing to decide and nothing to
    // get wrong when a bar's range happens not to contain zero.
    try testing.expectEqual(@as(f32, 0), originFraction(5, 10));
    try testing.expectEqual(@as(f32, 0), originFraction(0, 10));
    // …including a range wholly BELOW zero, where the origin is the right
    // edge and the fill therefore grows leftwards.
    try testing.expectEqual(@as(f32, 1), originFraction(-10, -5));
}

test "meter: fixed decimals, so a number does not change width" {
    // Half the cure for the reflow. `60.02` and `9.5` are different
    // numbers of glyphs; at ten updates a second that is a row whose
    // digits shuffle even inside a fixed column.
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("16.66", formatValue(&buf, 16.66, 2, ""));
    try testing.expectEqualStrings("9.50", formatValue(&buf, 9.5, 2, ""));
    try testing.expectEqualStrings("0.00", formatValue(&buf, 0, 2, ""));
    try testing.expectEqualStrings("16.7 ms", formatValue(&buf, 16.66, 1, "ms"));
    try testing.expectEqualStrings("60 fps", formatValue(&buf, 60.02, 0, "fps"));
}

test "meter: the columns tile the row and never overlap" {
    // The other half of the cure. Nothing downstream is measured from the
    // value's width, so nothing a number does can move anything else.
    const c = columnsFor(0, 300, 88, 62, true, true, false);
    try testing.expectEqual(@as(f32, 0), c.swatch_x);
    try testing.expect(c.label_x > c.swatch_x);
    try testing.expect(c.bar_x >= c.label_x + 88);
    try testing.expect(c.bar_x + c.bar_w + BAR_GAP <= c.value_right);
    try testing.expectEqual(@as(f32, 300 - PCT_W), c.value_right);
    try testing.expectEqual(@as(f32, 300), c.pct_right);
}

test "meter: dropping the percentage column gives the width to the bar" {
    const with = columnsFor(0, 300, 88, 62, true, true, false);
    const without = columnsFor(0, 300, 88, 62, false, true, false);
    try testing.expectEqual(with.bar_w + PCT_W, without.bar_w);
    try testing.expectEqual(@as(f32, 300), without.value_right);
}

test "meter: a row too narrow for its columns gives a zero bar, not a fold" {
    // A negative width would wind the geometry inside out. Zero draws
    // nothing, which is the honest picture of "there is no room here".
    const c = columnsFor(0, 40, 88, 62, true, true, false);
    try testing.expectEqual(@as(f32, 0), c.bar_w);
}

test "meter: the row's origin carries into every column" {
    const a = columnsFor(0, 300, 88, 62, false, true, false);
    const b = columnsFor(50, 300, 88, 62, false, true, false);
    try testing.expectEqual(a.swatch_x + 50, b.swatch_x);
    try testing.expectEqual(a.label_x + 50, b.label_x);
    try testing.expectEqual(a.bar_x + 50, b.bar_x);
    try testing.expectEqual(a.value_right + 50, b.value_right);
    try testing.expectEqual(a.bar_w, b.bar_w);
}

test "meter: the sparkline sits between the bar and the value" {
    const c = columnsFor(0, 400, 88, 62, true, true, true);
    // Bar, then trace, then the value's column, then the percentage.
    try testing.expect(c.spark_x >= c.bar_x + c.bar_w);
    try testing.expect(c.spark_x + c.spark_w <= c.value_right - 62);
    try testing.expectEqual(SPARK_W, c.spark_w);
}

test "meter: a row with no bar keeps its trace in the same column" {
    // So a table of mixed rows still lines up — the console's pass rows
    // are trace-and-number, and its CPU rows are bar-and-trace, and they
    // sit one above the other.
    const with_bar = columnsFor(0, 400, 88, 62, true, true, true);
    const without = columnsFor(0, 400, 88, 62, true, false, true);
    try testing.expectEqual(with_bar.spark_x, without.spark_x);
    try testing.expectEqual(@as(f32, 0), without.bar_w);
}

test "meter: asking for no sparkline gives the width back to the bar" {
    const with_spark = columnsFor(0, 400, 88, 62, false, true, true);
    const without = columnsFor(0, 400, 88, 62, false, true, false);
    try testing.expect(without.bar_w > with_spark.bar_w);
    try testing.expectEqual(@as(f32, 0), without.spark_w);
}
