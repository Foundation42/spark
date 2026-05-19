//! `::badge` — the first inline-flow component (stage 15E text
//! intrusion). A pill-shaped tag that flows alongside text inside a
//! paragraph or heading, sharing the surrounding baseline.
//!
//! Wired via the same factory + registry machinery the block-level
//! providers use; surfaces in the element tree as
//! `Element.inline_object` (not `.custom`), so the inline-flow walker
//! consults `vtable.measure_inline` before wrap and dispatches
//! `vtable.layout_and_render` once the line's baseline is resolved.
//!
//! Attribute grammar:
//!
//!     ::badge {label="13ms" color=red}
//!
//! - `label` (required) — text rendered inside the pill.
//! - `color` (optional) — background. Accepts named colors
//!   (`red`/`green`/`blue`/`yellow`/`purple`/`orange`/`gray`) or hex
//!   `#RRGGBB`. Default: gray.
//! - `text_color` (optional) — label color. Default: near-white.
//!
//! Markdown surface for inline placement is deferred (Stage 15E.2);
//! for the MVP demo the host hand-builds an `inline_object` Element
//! pointing at an instance produced by this factory.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");

pub const Error = error{
    BadgeMissingLabel,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("badge", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Component state ─────────────────────────────────────────────────

const Component = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    bg_color: [4]f32,
    text_color: [4]f32,
    /// Bumped on every spec ingest so the retained layout cache picks
    /// up changes on the next walk.
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var label_raw: ?[]const u8 = null;
        var bg = self.bg_color;
        var fg = self.text_color;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (parseColor(attr.value)) |c| bg = c;
            } else if (std.mem.eql(u8, attr.key, "text_color")) {
                if (parseColor(attr.value)) |c| fg = c;
            }
        }

        const label = label_raw orelse return Error.BadgeMissingLabel;
        const new_label = try a.dupe(u8, label);
        a.free(self.label);
        self.label = new_label;
        self.bg_color = bg;
        self.text_color = fg;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, ""),
        .bg_color = NAMED_COLORS[6], // gray default
        .text_color = .{ 0.98, 0.98, 1.0, 1.0 },
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
    allocator.free(c.label);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .measure_inline = measureInline,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Visual constants ────────────────────────────────────────────────

/// Horizontal padding inside the pill, as a fraction of the body font
/// display_px. Picked by feel — wide enough that short labels (3-4
/// chars) don't look cramped, narrow enough that long labels stay
/// compact in running prose.
const PAD_X_EM: f32 = 0.55;

/// Vertical padding above + below the label inside the pill, in em.
/// Small — the pill height is dominated by the font's line_height,
/// and over-padding makes the line box grow in surrounding text.
const PAD_Y_EM: f32 = 0.10;

// ── Layout-time geometry helpers ────────────────────────────────────

/// Use the body style as the label font. Code_inline reads as too
/// "technical" in a sentence; body keeps the badge feeling like part
/// of the prose while the colored background does the visual work.
fn labelStyle(theme: *const element.Theme) element.Style {
    return theme.body;
}

/// Computed pill metrics — shared between measureInline (wrap-pass
/// intent) and layoutAndRender (paint pass). Both passes must agree
/// on width and height; isolating the math here keeps them in sync.
const Geometry = struct {
    text_w: f32,
    pad_x: f32,
    pad_y: f32,
    ascender: f32, // above baseline (positive)
    descender: f32, // below baseline (positive)
    width: f32,
    height: f32,
};

fn computeGeometry(
    label: []const u8,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun } {
    const style = labelStyle(lc.theme);
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, label);

    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));
    const pad_x = em * PAD_X_EM;
    const pad_y = em * PAD_Y_EM;

    const m = lc.fonts.metrics(style.font_id);
    // `m.descender` is negative (below baseline). Convert to a
    // positive "extent below" for the IntrinsicMetrics contract.
    const desc_abs = -m.descender;

    const asc = m.ascender + pad_y;
    const desc = desc_abs + pad_y;
    return .{
        .geom = .{
            .text_w = text_w,
            .pad_x = pad_x,
            .pad_y = pad_y,
            .ascender = asc,
            .descender = desc,
            .width = text_w + 2 * pad_x,
            .height = asc + desc,
        },
        .run = run,
    };
}

// ── Inline measure (wrap-pass) ──────────────────────────────────────

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = em_px;
    const c: *const Component = @ptrCast(@alignCast(ctx));

    // Per-frame arena — the ShapedRun produced here is only needed
    // to read advance widths; we throw it away at the end. Paint
    // pass re-shapes against its own arena.
    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const g = (try computeGeometry(c.label, lc, aa)).geom;
    return .{
        .width = g.width,
        .ascender = g.ascender,
        .descender = g.descender,
    };
}

// ── Inline paint ────────────────────────────────────────────────────

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    _ = constraints;
    const c: *const Component = @ptrCast(@alignCast(ctx));

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const result = try computeGeometry(c.label, lc, aa);
    const g = result.geom;
    const run = result.run;

    // Pill body. Radius = half height for a full-pill end-cap; the
    // existing rounded-quad pipeline supports this for free.
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ g.width, g.height },
        .color = c.bg_color,
        .radius = g.height * 0.5,
    });

    // Label. Baseline sits `g.ascender` below the pill's top edge,
    // matching the IntrinsicMetrics contract (ascender is the
    // distance from the box's top to the baseline).
    const style = labelStyle(lc.theme);
    const baseline_y = origin[1] + g.ascender;
    const text_x = origin[0] + g.pad_x;
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
        text_x,
        baseline_y,
        c.text_color,
        style.hot_color,
        0, // no attention pulse on badges
        lc.zoom,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = g.width,
        .h = g.height,
        .baseline = baseline_y,
    };
}

// ── Color parsing ───────────────────────────────────────────────────

/// Named badge colors — picked to read on a dark-ish editor
/// background. Each is a moderately desaturated mid-tone so the
/// label stays legible in white without needing a contrast check.
const NAMED_COLORS = [_][4]f32{
    .{ 0.78, 0.30, 0.32, 1.0 }, // red    [0]
    .{ 0.36, 0.62, 0.38, 1.0 }, // green  [1]
    .{ 0.32, 0.50, 0.78, 1.0 }, // blue   [2]
    .{ 0.78, 0.62, 0.24, 1.0 }, // yellow [3]
    .{ 0.58, 0.40, 0.72, 1.0 }, // purple [4]
    .{ 0.78, 0.50, 0.26, 1.0 }, // orange [5]
    .{ 0.42, 0.42, 0.46, 1.0 }, // gray   [6]
};

fn parseColor(s: []const u8) ?[4]f32 {
    if (std.mem.eql(u8, s, "red")) return NAMED_COLORS[0];
    if (std.mem.eql(u8, s, "green")) return NAMED_COLORS[1];
    if (std.mem.eql(u8, s, "blue")) return NAMED_COLORS[2];
    if (std.mem.eql(u8, s, "yellow")) return NAMED_COLORS[3];
    if (std.mem.eql(u8, s, "purple")) return NAMED_COLORS[4];
    if (std.mem.eql(u8, s, "orange")) return NAMED_COLORS[5];
    if (std.mem.eql(u8, s, "gray") or std.mem.eql(u8, s, "grey")) return NAMED_COLORS[6];

    // Hex `#RRGGBB`.
    if (s.len == 7 and s[0] == '#') {
        const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
        return .{
            @as(f32, @floatFromInt(r)) / 255.0,
            @as(f32, @floatFromInt(g)) / 255.0,
            @as(f32, @floatFromInt(b)) / 255.0,
            1.0,
        };
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "badge: parseColor names + hex" {
    try testing.expectEqual(@as(?[4]f32, NAMED_COLORS[0]), parseColor("red"));
    try testing.expectEqual(@as(?[4]f32, NAMED_COLORS[6]), parseColor("gray"));
    try testing.expectEqual(@as(?[4]f32, NAMED_COLORS[6]), parseColor("grey"));
    try testing.expectEqual(@as(?[4]f32, .{ 1.0, 0.0, 0.0, 1.0 }), parseColor("#ff0000"));
    try testing.expectEqual(@as(?[4]f32, null), parseColor("not-a-color"));
    try testing.expectEqual(@as(?[4]f32, null), parseColor("#zzz"));
}

test "badge: ingest stores label + parses color" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "13ms" },
        .{ .key = "color", .value = "red" },
    };
    const spec: components.Spec = .{ .name = "badge", .attrs = &attrs };

    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("13ms", c.label);
    try testing.expectEqual(NAMED_COLORS[0], c.bg_color);
}

test "badge: missing label rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "blue" },
    };
    const spec: components.Spec = .{ .name = "badge", .attrs = &attrs };
    try testing.expectError(Error.BadgeMissingLabel, create(&_test_spark, testing.allocator, &spec));
}

test "badge: vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
