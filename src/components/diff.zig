//! `::diff` — inline add/remove change summary (session 17). Reads as
//! "this changeset added N lines and removed M". Pairs naturally with
//! `::commit`: every commit / PR has a diff stat.
//!
//! Attribute grammar:
//!
//!     ::diff {add=437 remove=17}
//!     ::diff {add=12}
//!     ::diff {remove=8}
//!
//! - `add` (optional, default 0) — non-negative line-add count.
//! - `remove` (optional, default 0) — non-negative line-remove count.
//!
//! Both default to zero so the author can omit whichever half doesn't
//! apply. With both zero the chip renders as a muted `+0 −0` — useful
//! for "this is a no-op commit" prose.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("diff", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Composed render text: `"+N \u{2212}M"`.
    text: []u8,
    /// Byte offset where the negative half begins. Lets the render
    /// path colour the two halves distinctly with a single shape.
    minus_byte_offset: usize,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var add: u32 = 0;
        var remove: u32 = 0;

        for (spec.attrs) |attr| {
            const v = std.mem.trim(u8, attr.value, " \t");
            if (std.mem.eql(u8, attr.key, "add")) {
                add = std.fmt.parseInt(u32, v, 10) catch 0;
            } else if (std.mem.eql(u8, attr.key, "remove")) {
                remove = std.fmt.parseInt(u32, v, 10) catch 0;
            }
        }

        // Compose `"+N \u{2212}M"`. The middle space splits the two
        // halves; `minus_byte_offset` records where the minus sign
        // begins so the render pass can swap colour at the right
        // glyph cluster.
        const plus_str = try std.fmt.allocPrint(a, "+{d} ", .{add});
        defer a.free(plus_str);
        const minus_str = try std.fmt.allocPrint(a, "\u{2212}{d}", .{remove});
        defer a.free(minus_str);

        const composed = try a.alloc(u8, plus_str.len + minus_str.len);
        errdefer a.free(composed);
        @memcpy(composed[0..plus_str.len], plus_str);
        @memcpy(composed[plus_str.len..], minus_str);

        a.free(self.text);
        self.text = composed;
        self.minus_byte_offset = plus_str.len;
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
        .minus_byte_offset = 0,
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

const COLOR_ADD: [4]f32 = .{ 0.40, 0.82, 0.50, 1.0 };
const COLOR_REMOVE: [4]f32 = .{ 0.90, 0.42, 0.42, 1.0 };

fn labelStyle(theme: *const element.Theme) element.Style {
    return theme.applyCodeInline(theme.body);
}

const Geometry = struct {
    width: f32,
    ascender: f32,
    descender: f32,
    /// Width of the "+N " prefix slice (for x-offset of the minus
    /// half when we issue the second appendShapedRun call).
    plus_w: f32,
};

fn computeGeometry(
    text: []const u8,
    minus_byte_offset: usize,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun } {
    const style = labelStyle(lc.theme);
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, text);

    const fscale = lc.fonts.scale(style.font_id);
    var w: f32 = 0;
    var plus_w: f32 = 0;
    for (run.glyphs) |g| {
        const adv = g.x_advance * fscale;
        w += adv;
        if (g.cluster < minus_byte_offset) plus_w += adv;
    }

    const m = lc.fonts.metrics(style.font_id);
    return .{
        .geom = .{
            .width = w,
            .ascender = m.ascender,
            .descender = -m.descender,
            .plus_w = plus_w,
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
    const g = (try computeGeometry(c.text, c.minus_byte_offset, lc, arena.allocator())).geom;
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

    const result = try computeGeometry(c.text, c.minus_byte_offset, lc, arena.allocator());
    const g = result.geom;
    const run = result.run;

    // Split the run at the cluster boundary so the green / red halves
    // emit as separate `appendShapedRun` calls. Same trick `::rating`
    // uses; identical reasoning — one shape pass, two colours.
    var split_idx: usize = 0;
    for (run.glyphs, 0..) |gly, i| {
        if (gly.cluster >= c.minus_byte_offset) {
            split_idx = i;
            break;
        }
        split_idx = i + 1;
    }

    const style = labelStyle(lc.theme);
    const baseline_y = origin[1] + g.ascender;

    if (split_idx > 0) {
        const plus_run = shape.ShapedRun{
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
            plus_run,
            style.font_id,
            origin[0],
            baseline_y,
            COLOR_ADD,
            style.hot_color,
            0,
            lc.zoom,
        );
    }
    if (split_idx < run.glyphs.len) {
        const minus_run = shape.ShapedRun{
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
            minus_run,
            style.font_id,
            origin[0] + g.plus_w,
            baseline_y,
            COLOR_REMOVE,
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

test "Component: composes +N -M with U+2212 minus" {
    const attrs = [_]components.Attr{
        .{ .key = "add", .value = "437" },
        .{ .key = "remove", .value = "17" },
    };
    const spec: components.Spec = .{ .name = "diff", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("+437 \u{2212}17", c.text);
}

test "Component: zero defaults" {
    const spec: components.Spec = .{ .name = "diff" };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("+0 \u{2212}0", c.text);
}

test "Component: minus offset points at the minus sign" {
    const attrs = [_]components.Attr{
        .{ .key = "add", .value = "12" },
        .{ .key = "remove", .value = "3" },
    };
    const spec: components.Spec = .{ .name = "diff", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    // "+12 " is 4 bytes; the minus sign begins at offset 4.
    try testing.expectEqual(@as(usize, 4), c.minus_byte_offset);
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
