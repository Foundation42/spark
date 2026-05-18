//! `::tag` — hashtag-style inline chip (stage 15E.5).
//!
//! Reads as a semantic label: lightweight outline + `#`-prefixed
//! text. Distinct from `::badge` (filled pill, emphasis weight) —
//! tag's outline-only treatment lets several tags cluster in a
//! paragraph without dominating it. Suited for category labels
//! ("wip", "deprecated"), search facets, version markers.
//!
//! Attribute grammar:
//!
//!     ::tag {label="deprecated"}
//!     ::tag {label="wip" color=orange}
//!
//! - `label` (required) — text rendered after the `#` prefix.
//! - `color` (optional) — outline + label tint. Default neutral.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    TagMissingLabel,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("tag", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Stored with the `#` already prepended so render reads
    /// directly off the field.
    text: []u8,
    color: [4]f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var label_raw: ?[]const u8 = null;
        var color = self.color;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| color = c;
            }
        }

        const lbl = label_raw orelse return Error.TagMissingLabel;
        const composed = try std.fmt.allocPrint(a, "#{s}", .{lbl});
        a.free(self.text);
        self.text = composed;
        self.color = color;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        // Empty placeholder — ingest builds the real `#label`.
        // `dupe(u8, "")` returns &.{} (no allocation), so an
        // ingest failure between here and the return doesn't leak.
        .text = try allocator.dupe(u8, ""),
        .color = DEFAULT_COLOR,
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

const DEFAULT_COLOR: [4]f32 = .{ 0.55, 0.62, 0.72, 1.0 };
const BORDER_PX: f32 = 1.0;
const PAD_X_EM: f32 = 0.40;
const PAD_Y_EM: f32 = 0.06;

const Geometry = struct {
    text_w: f32,
    pad_x: f32,
    pad_y: f32,
    ascender: f32,
    descender: f32,
    width: f32,
    height: f32,
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
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));
    const pad_x = em * PAD_X_EM;
    const pad_y = em * PAD_Y_EM;

    const m = lc.fonts.metrics(style.font_id);
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

    // Hollow outline: draw the accent rect, then knock out the
    // interior with the document background so only the border
    // shows. Same trick :::button uses. The theme doesn't expose
    // its body background colour directly, so use a near-black
    // fill that matches the demo's dark surface.
    const radius: f32 = 3;
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ g.width, g.height },
        .color = c.color,
        .radius = radius,
    });
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + BORDER_PX, origin[1] + BORDER_PX },
        .dst_size = .{ g.width - 2 * BORDER_PX, g.height - 2 * BORDER_PX },
        .color = .{ 0.08, 0.10, 0.13, 1.0 },
        .radius = @max(0, radius - BORDER_PX),
    });

    // Label — accent-coloured to echo the outline.
    const style = lc.theme.body;
    const baseline_y = origin[1] + g.ascender;
    const text_x = origin[0] + g.pad_x;
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
        c.color,
        style.hot_color,
        0,
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

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "Component: stores text with # prefix" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "wip" },
    };
    const spec: components.Spec = .{ .name = "tag", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("#wip", c.text);
}

test "Component: color attr overrides default" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "color", .value = "orange" },
    };
    const spec: components.Spec = .{ .name = "tag", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(c.color[0] != DEFAULT_COLOR[0]);
}

test "Component: missing label rejected" {
    const spec: components.Spec = .{ .name = "tag" };
    try testing.expectError(Error.TagMissingLabel, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
