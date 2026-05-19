//! `::status` — coloured-dot status indicator (stage 15E.5).
//!
//! A small filled circle, optionally followed by a label. Reads
//! like the indicators on a dashboard or admin UI: "Database
//! ::status{color=green label=\"online\"}". The dot alone (no
//! label) is also valid for compact rows where the surrounding
//! prose already says what the status is for.
//!
//! Attribute grammar:
//!
//!     ::status {color=green}
//!     ::status {color=red label="offline"}
//!     ::status {color="#a070ff" label="syncing"}

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    StatusMissingColor,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("status", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    color: [4]f32,
    /// Empty string means "no label, dot only".
    label: []u8,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var color_resolved: ?[4]f32 = null;
        var label_raw: []const u8 = "";

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "color")) {
                color_resolved = box_helpers.parseColor(attr.value);
            } else if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            }
        }

        const col = color_resolved orelse return Error.StatusMissingColor;
        const new_label = try a.dupe(u8, label_raw);
        a.free(self.label);
        self.label = new_label;
        self.color = col;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .color = .{ 0.5, 0.5, 0.5, 1.0 },
        .label = try allocator.dupe(u8, ""),
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

// ── Visual constants ───────────────────────────────────────────────

const DOT_DIAMETER_EM: f32 = 0.55;
const DOT_LABEL_GAP_EM: f32 = 0.30;

// ── Geometry helpers (shared between measure and render) ──────────

const Geometry = struct {
    dot_d: f32,
    gap: f32,
    text_w: f32,
    label_ascender: f32,
    label_descender: f32,
    width: f32,
};

fn computeGeometry(
    label: []const u8,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: ?shape.ShapedRun } {
    const style = lc.theme.body;
    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));
    const dot_d = em * DOT_DIAMETER_EM;

    if (label.len == 0) {
        return .{
            .geom = .{
                .dot_d = dot_d,
                .gap = 0,
                .text_w = 0,
                .label_ascender = 0,
                .label_descender = 0,
                .width = dot_d,
            },
            .run = null,
        };
    }

    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, label);
    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const gap = em * DOT_LABEL_GAP_EM;
    const m = lc.fonts.metrics(style.font_id);

    return .{
        .geom = .{
            .dot_d = dot_d,
            .gap = gap,
            .text_w = text_w,
            .label_ascender = m.ascender,
            .label_descender = -m.descender,
            .width = dot_d + gap + text_w,
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
    const g = (try computeGeometry(c.label, lc, arena.allocator())).geom;
    // With a label: lean on the label's text metrics so the whole
    // glyph aligns with surrounding prose. Without one: centre the
    // dot on the x-height (em * 0.32 above baseline, ± half-dot).
    if (c.label.len == 0) {
        const em_local: f32 = @floatFromInt(lc.fonts.displayPx(lc.theme.body.font_id));
        const x_centre = em_local * 0.32;
        const half = g.dot_d * 0.5;
        return .{
            .width = g.width,
            .ascender = x_centre + half,
            .descender = -(x_centre - half),
        };
    }
    return .{
        .width = g.width,
        .ascender = g.label_ascender,
        .descender = g.label_descender,
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

    const result = try computeGeometry(c.label, lc, arena.allocator());
    const g = result.geom;
    const style = lc.theme.body;
    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));

    // Vertical placement: dot's vertical centre coincides with the
    // x-height centre of the surrounding text. With a label the
    // ascender/descender are derived from the label; without, from
    // the dot's height alone.
    const baseline_y = origin[1] + (if (c.label.len == 0)
        em * 0.32 + g.dot_d * 0.5
    else
        g.label_ascender);
    const x_centre_y = baseline_y - em * 0.32;
    const dot_y = x_centre_y - g.dot_d * 0.5;

    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], dot_y },
        .dst_size = .{ g.dot_d, g.dot_d },
        .color = c.color,
        .radius = g.dot_d * 0.5,
    });

    if (result.run) |run| {
        const label_x = origin[0] + g.dot_d + g.gap;
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
            label_x,
            baseline_y,
            style.color,
            style.hot_color,
            style.attention,
            lc.zoom,
        );
    }

    const total_h = if (c.label.len == 0)
        g.dot_d
    else
        g.label_ascender + g.label_descender;

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = g.width,
        .h = total_h,
        .baseline = baseline_y,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "Component: dot only (no label)" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "green" },
    };
    const spec: components.Spec = .{ .name = "status", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("", c.label);
}

test "Component: dot + label" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "red" },
        .{ .key = "label", .value = "offline" },
    };
    const spec: components.Spec = .{ .name = "status", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("offline", c.label);
}

test "Component: missing color rejected" {
    const spec: components.Spec = .{ .name = "status" };
    try testing.expectError(Error.StatusMissingColor, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
