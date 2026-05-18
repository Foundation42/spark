//! `::dot` — tiny coloured circle, baseline-aligned (session 17).
//! Thinner cousin of `::status`: smaller diameter, label-less by
//! design, optimised for sprinkling into prose ("build • passing on
//! main, • flaky on PR #42, • blocked on staging"). For a richer
//! status-line indicator with a label and bigger dot, reach for
//! `::status` instead.
//!
//! Attribute grammar:
//!
//!     ::dot {color=green}
//!     ::dot {color="#a070ff"}

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    DotMissingColor,
};

pub fn install(registry: *component_mod.Registry) !void {
    try registry.register("dot", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    color: [4]f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        var color_resolved: ?[4]f32 = null;
        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "color")) {
                color_resolved = box_helpers.parseColor(attr.value);
            }
        }
        self.color = color_resolved orelse return Error.DotMissingColor;
        self.version +%= 1;
    }
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{ .color = .{ 0.5, 0.5, 0.5, 1.0 } };
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
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

/// Smaller than `::status`'s 0.55em — `::dot` is a sentence-level
/// ornament, not a status-row indicator.
const DOT_DIAMETER_EM: f32 = 0.40;
/// A breath of side padding so consecutive dots and surrounding text
/// don't collide visually. Single-em-space gaps in the inline-flow
/// walker handle inter-word spacing, but a glyph-tight dot reads
/// better with a small intrinsic cushion.
const SIDE_PAD_EM: f32 = 0.10;

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = ctx;
    _ = em_px;
    const em: f32 = @floatFromInt(lc.fonts.displayPx(lc.theme.body.font_id));
    const dot_d = em * DOT_DIAMETER_EM;
    const pad = em * SIDE_PAD_EM;
    // Vertically: dot sits centred on the x-height (em * 0.32 above
    // baseline). Half-dot above and below that centre defines the
    // ascender / descender the wrap loop allots for it.
    const x_centre = em * 0.32;
    const half = dot_d * 0.5;
    return .{
        .width = dot_d + 2 * pad,
        .ascender = x_centre + half,
        .descender = -(x_centre - half),
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

    const style = lc.theme.body;
    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));
    const dot_d = em * DOT_DIAMETER_EM;
    const pad = em * SIDE_PAD_EM;

    const x_centre_offset = em * 0.32;
    const half = dot_d * 0.5;
    const baseline_y = origin[1] + (x_centre_offset + half);
    const x_centre_y = baseline_y - x_centre_offset;
    const dot_y = x_centre_y - half;

    try out.quads.append(.{
        .dst_pos = .{ origin[0] + pad, dot_y },
        .dst_size = .{ dot_d, dot_d },
        .color = c.color,
        .radius = dot_d * 0.5,
    });

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = dot_d + 2 * pad,
        .h = dot_d,
        .baseline = baseline_y,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Component: color is parsed" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "green" },
    };
    const spec: components.Spec = .{ .name = "dot", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    // Green is decidedly not gray.
    try testing.expect(c.color[1] > c.color[0]);
}

test "Component: missing color rejected" {
    const spec: components.Spec = .{ .name = "dot" };
    try testing.expectError(Error.DotMissingColor, create(testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
