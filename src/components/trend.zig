//! `::trend` — inline delta indicator with direction arrow + colour
//! (session 17). Reads as "this metric moved by this much in this
//! direction": revenue up 12.4%, latency down 23ms. The arrow is the
//! point; the colour reinforces. Sign is auto-derived from the value
//! so authors write `value=+12.4%` / `value=-2.1%` / `value=0` and the
//! component picks ▲ green, ▼ red, ─ neutral respectively.
//!
//! Attribute grammar:
//!
//!     ::trend {value="+12.4%"}
//!     ::trend {value="-2.1%"}
//!     ::trend {value="0%"}
//!     ::trend {value="+47ms" up_color=red down_color=green}
//!
//! - `value` (required) — the delta as it should display, with a
//!   leading sign (`+` / `-`) when directional. Numerically zero (or
//!   sign-less) values render as neutral.
//! - `up_color` / `down_color` (optional) — override the default
//!   green-up / red-down convention. Useful when "up = bad" (latency,
//!   error count): swap the polarities.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    TrendMissingValue,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("trend", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Direction = enum { up, down, flat };

const Component = struct {
    allocator: std.mem.Allocator,
    /// Composed render text: `"▲ 12.4%"` / `"▼ 2.1%"` / `"─ 0%"`.
    text: []u8,
    color: [4]f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var value_raw: ?[]const u8 = null;
        var up_color: [4]f32 = COLOR_UP;
        var down_color: [4]f32 = COLOR_DOWN;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "value")) {
                value_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "up_color")) {
                if (box_helpers.parseColor(attr.value)) |c| up_color = c;
            } else if (std.mem.eql(u8, attr.key, "down_color")) {
                if (box_helpers.parseColor(attr.value)) |c| down_color = c;
            }
        }

        const v = value_raw orelse return Error.TrendMissingValue;
        const trimmed = std.mem.trim(u8, v, " \t");
        const dir = classify(trimmed);
        const body = stripLeadingPlus(trimmed);
        const arrow: []const u8 = switch (dir) {
            .up => "\u{25B2}", // ▲
            .down => "\u{25BC}", // ▼
            .flat => "\u{2014}", // —
        };

        const composed = try std.fmt.allocPrint(a, "{s} {s}", .{ arrow, body });
        a.free(self.text);
        self.text = composed;
        self.color = switch (dir) {
            .up => up_color,
            .down => down_color,
            .flat => COLOR_FLAT,
        };
        self.version +%= 1;
    }
};

/// Determine direction from the value string. A leading `+` is up;
/// a leading `-` followed by a non-zero digit is down; anything that
/// parses as numerically zero (or carries no explicit sign and starts
/// with zero) is flat.
fn classify(v: []const u8) Direction {
    if (v.len == 0) return .flat;
    if (v[0] == '+') return .up;
    if (v[0] == '-') {
        // "-0" / "-0%" / "-0.0" → flat; "-2.1%" → down.
        for (v[1..]) |ch| {
            if (ch >= '1' and ch <= '9') return .down;
        }
        return .flat;
    }
    // No sign — flat unless we can find a non-zero digit (e.g.
    // bare "12.4%" still reads as a delta direction, treat as up).
    for (v) |ch| {
        if (ch >= '1' and ch <= '9') return .up;
    }
    return .flat;
}

fn stripLeadingPlus(v: []const u8) []const u8 {
    if (v.len > 0 and v[0] == '+') return v[1..];
    return v;
}

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .text = try allocator.dupe(u8, ""),
        .color = COLOR_FLAT,
    };
    errdefer allocator.free(c.text);
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.text);
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

// ── Visual constants ───────────────────────────────────────────────

const COLOR_UP: [4]f32 = .{ 0.40, 0.82, 0.50, 1.0 };
const COLOR_DOWN: [4]f32 = .{ 0.90, 0.42, 0.42, 1.0 };
const COLOR_FLAT: [4]f32 = .{ 0.60, 0.62, 0.66, 1.0 };

const Geometry = struct {
    width: f32,
    ascender: f32,
    descender: f32,
};

fn computeGeometry(
    text: []const u8,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun } {
    const style = lc.theme.body;
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, text);

    const fscale = lc.fonts.scale(style.font_id);
    var w: f32 = 0;
    for (run.glyphs) |g| w += g.x_advance * fscale;

    const m = lc.fonts.metrics(style.font_id);
    return .{
        .geom = .{
            .width = w,
            .ascender = m.ascender,
            .descender = -m.descender,
        },
        .run = run,
    };
}

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = em_px;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const g = (try computeGeometry(c.text, lc, arena.allocator())).geom;
    return .{
        .width = g.width,
        .ascender = g.ascender,
        .descender = g.descender,
    };
}

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

    const result = try computeGeometry(c.text, lc, arena.allocator());
    const g = result.geom;
    const run = result.run;

    const style = lc.theme.body;
    const baseline_y = origin[1] + g.ascender;
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
        origin[0],
        baseline_y,
        c.color,
        style.hot_color,
        0,
        lc.zoom,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = g.width,
        .h = g.ascender + g.descender,
        .baseline = baseline_y,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "classify: leading + is up" {
    try testing.expectEqual(Direction.up, classify("+12.4%"));
    try testing.expectEqual(Direction.up, classify("+0.1"));
}

test "classify: leading - with non-zero digit is down" {
    try testing.expectEqual(Direction.down, classify("-2.1%"));
    try testing.expectEqual(Direction.down, classify("-0.5"));
}

test "classify: zero variants are flat" {
    try testing.expectEqual(Direction.flat, classify("0"));
    try testing.expectEqual(Direction.flat, classify("0%"));
    try testing.expectEqual(Direction.flat, classify("-0"));
    try testing.expectEqual(Direction.flat, classify("-0.0%"));
    try testing.expectEqual(Direction.flat, classify(""));
}

test "classify: sign-less non-zero is up" {
    try testing.expectEqual(Direction.up, classify("12.4%"));
}

test "Component: up trend gets green + up arrow" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "+12.4%" },
    };
    const spec: components.Spec = .{ .name = "trend", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(std.mem.startsWith(u8, c.text, "\u{25B2}"));
    try testing.expectEqual(COLOR_UP, c.color);
    try testing.expect(std.mem.indexOf(u8, c.text, "12.4%") != null);
    // Leading '+' is stripped (arrow conveys direction).
    try testing.expect(std.mem.indexOf(u8, c.text, "+") == null);
}

test "Component: down trend keeps minus sign and gets red" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "-2.1%" },
    };
    const spec: components.Spec = .{ .name = "trend", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(std.mem.startsWith(u8, c.text, "\u{25BC}"));
    try testing.expectEqual(COLOR_DOWN, c.color);
    try testing.expect(std.mem.indexOf(u8, c.text, "-2.1%") != null);
}

test "Component: missing value rejected" {
    const spec: components.Spec = .{ .name = "trend" };
    try testing.expectError(Error.TrendMissingValue, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
