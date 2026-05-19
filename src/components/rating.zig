//! `::rating` — inline star rating (session 17). Renders `value`
//! filled stars out of `max`, with the remainder as empty outlines.
//! Half-stars are supported via a half-star glyph between the filled
//! and empty runs.
//!
//! Attribute grammar:
//!
//!     ::rating {value=4.5 max=5}
//!     ::rating {value=3}
//!     ::rating {value=2.5 max=5 color=orange}
//!
//! - `value` (required) — float between 0 and `max`. Rounded to the
//!   nearest half.
//! - `max` (optional, default 5) — total number of star slots.
//! - `color` (optional) — tint for the filled stars. Empty stars use
//!   a muted neutral regardless.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    RatingMissingValue,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("rating", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Buffer of composed render text — repeated ★ / ½ / ☆ glyphs.
    text: []u8,
    /// Index (in bytes) where the filled-star run ends and the
    /// empty/half run begins. Lets `layoutAndRender` colour the
    /// two halves distinctly without a second shape pass.
    filled_byte_len: usize,
    color_filled: [4]f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var value_raw: ?[]const u8 = null;
        var max_raw: []const u8 = "5";
        var color_filled = COLOR_FILLED;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "value")) {
                value_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "max")) {
                max_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| color_filled = c;
            }
        }

        const v_str = value_raw orelse return Error.RatingMissingValue;
        const value = std.fmt.parseFloat(f32, std.mem.trim(u8, v_str, " \t")) catch 0;
        const max = std.fmt.parseInt(u32, std.mem.trim(u8, max_raw, " \t"), 10) catch 5;

        // Round value to nearest half.
        const halved = std.math.clamp(@round(value * 2) / 2, 0, @as(f32, @floatFromInt(max)));
        const full: u32 = @intFromFloat(@floor(halved));
        const has_half = (halved - @as(f32, @floatFromInt(full))) >= 0.5;
        const empty: u32 = if (max > full + (if (has_half) @as(u32, 1) else 0))
            max - full - (if (has_half) @as(u32, 1) else 0)
        else
            0;

        // Compose the string. Each star glyph is 3 UTF-8 bytes (BMP
        // characters in the 0x2605 range), so allocate exactly.
        const filled_bytes = full * STAR_FILLED.len;
        const half_bytes: usize = if (has_half) STAR_HALF.len else 0;
        const empty_bytes = empty * STAR_EMPTY.len;
        const total = filled_bytes + half_bytes + empty_bytes;

        const buf = try a.alloc(u8, total);
        errdefer a.free(buf);

        var off: usize = 0;
        var i: u32 = 0;
        while (i < full) : (i += 1) {
            @memcpy(buf[off .. off + STAR_FILLED.len], STAR_FILLED);
            off += STAR_FILLED.len;
        }
        const filled_end = off;
        if (has_half) {
            @memcpy(buf[off .. off + STAR_HALF.len], STAR_HALF);
            off += STAR_HALF.len;
        }
        i = 0;
        while (i < empty) : (i += 1) {
            @memcpy(buf[off .. off + STAR_EMPTY.len], STAR_EMPTY);
            off += STAR_EMPTY.len;
        }

        a.free(self.text);
        self.text = buf;
        self.filled_byte_len = filled_end;
        self.color_filled = color_filled;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .text = try allocator.dupe(u8, ""),
        .filled_byte_len = 0,
        .color_filled = COLOR_FILLED,
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

const STAR_FILLED: []const u8 = "\u{2605}"; // ★
const STAR_EMPTY: []const u8 = "\u{2606}"; // ☆
/// "Vulgar fraction one half" — the closest single codepoint
/// available everywhere. Visually reads as "half star" in context.
const STAR_HALF: []const u8 = "\u{00BD}"; // ½

const COLOR_FILLED: [4]f32 = .{ 0.96, 0.78, 0.30, 1.0 }; // gold
const COLOR_EMPTY: [4]f32 = .{ 0.42, 0.45, 0.50, 1.0 }; // dim slate

const Geometry = struct {
    width: f32,
    ascender: f32,
    descender: f32,
    filled_width: f32,
};

fn computeGeometry(
    text: []const u8,
    filled_byte_len: usize,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun } {
    const style = lc.theme.body;
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, text);

    const fscale = lc.fonts.scale(style.font_id);
    var w: f32 = 0;
    var filled_w: f32 = 0;
    for (run.glyphs) |g| {
        const adv = g.x_advance * fscale;
        w += adv;
        if (g.cluster < filled_byte_len) filled_w += adv;
    }

    const m = lc.fonts.metrics(style.font_id);
    return .{
        .geom = .{
            .width = w,
            .ascender = m.ascender,
            .descender = -m.descender,
            .filled_width = filled_w,
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
    const g = (try computeGeometry(c.text, c.filled_byte_len, lc, arena.allocator())).geom;
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

    const result = try computeGeometry(c.text, c.filled_byte_len, lc, arena.allocator());
    const g = result.geom;
    const run = result.run;

    const style = lc.theme.body;
    const baseline_y = origin[1] + g.ascender;

    // The shape pass produced one ShapedRun for the whole string;
    // colour-split it into a filled run and an empty run by finding
    // the glyph index where the source cluster crosses the half/empty
    // boundary. The half glyph itself (½) sits in the empty run so it
    // tints with the muted colour, reading as "this half isn't full".
    var split_idx: usize = 0;
    for (run.glyphs, 0..) |gly, i| {
        if (gly.cluster >= c.filled_byte_len) {
            split_idx = i;
            break;
        }
        split_idx = i + 1;
    }

    if (split_idx > 0) {
        const filled_run = shape.ShapedRun{
            .glyphs = run.glyphs[0..split_idx],
            .allocator = run.allocator,
        };
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
        &out.glyph_targets,
        lc.current_target_dispatch_index,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            filled_run,
            style.font_id,
            origin[0],
            baseline_y,
            c.color_filled,
            style.hot_color,
            0,
            lc.zoom,
        );
    }
    if (split_idx < run.glyphs.len) {
        const empty_run = shape.ShapedRun{
            .glyphs = run.glyphs[split_idx..],
            .allocator = run.allocator,
        };
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
        &out.glyph_targets,
        lc.current_target_dispatch_index,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            empty_run,
            style.font_id,
            origin[0] + g.filled_width,
            baseline_y,
            COLOR_EMPTY,
            style.hot_color,
            0,
            lc.zoom,
        );
    }

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

test "Component: integer rating composes full + empty stars" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "3" },
        .{ .key = "max", .value = "5" },
    };
    const spec: components.Spec = .{ .name = "rating", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    // 3 filled + 2 empty, no half.
    try testing.expectEqualStrings("\u{2605}\u{2605}\u{2605}\u{2606}\u{2606}", c.text);
    try testing.expectEqual(@as(usize, 3 * STAR_FILLED.len), c.filled_byte_len);
}

test "Component: half rating inserts the half glyph" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "2.5" },
        .{ .key = "max", .value = "5" },
    };
    const spec: components.Spec = .{ .name = "rating", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    // 2 filled + ½ + 2 empty.
    try testing.expectEqualStrings("\u{2605}\u{2605}\u{00BD}\u{2606}\u{2606}", c.text);
}

test "Component: full rating omits empties" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "5" },
        .{ .key = "max", .value = "5" },
    };
    const spec: components.Spec = .{ .name = "rating", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}", c.text);
}

test "Component: out-of-range value clamps" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "9" },
        .{ .key = "max", .value = "5" },
    };
    const spec: components.Spec = .{ .name = "rating", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    // Clamped to 5 → all filled.
    try testing.expectEqualStrings("\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}", c.text);
}

test "Component: missing value rejected" {
    const spec: components.Spec = .{ .name = "rating" };
    try testing.expectError(Error.RatingMissingValue, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
