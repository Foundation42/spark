//! `::progress` — inline progress bar (stage 15E.4).
//!
//! A pill-shaped horizontal bar that flows inline with text and
//! shows a `value` in `[0, 1]` as a filled portion of its track.
//! Reactive: bind `value=${state.x}` and the registry will re-ingest
//! the spec on state mutations, so a slider / button / timer driving
//! `state.x` reshapes the bar in real time.
//!
//! Attribute grammar:
//!
//!     ::progress {value=0.7}
//!     ::progress {value=${state.x} color=green bg_color=#222 width=120 height=6}
//!
//! - `value` (required) — ratio numerator. Pair with `max` to scale
//!   ranges other than [0, 1].
//! - `max` (optional) — denominator. Ratio is `value / max`,
//!   clamped to [0, 1]. Default 1.
//! - `color` (optional) — filled portion. Default accent blue.
//! - `bg_color` (optional) — empty track. Default dim grey.
//! - `width` (optional) — pixel literal. Default 80.
//! - `height` (optional) — pixel literal. Default 8.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    ProgressMissingValue,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("progress", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Resolved ratio in [0, 1] — value/max clamped.
    ratio: f32,
    color: [4]f32,
    bg_color: [4]f32,
    width: f32,
    height: f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        var value_raw: ?[]const u8 = null;
        var max_raw: []const u8 = "1";
        var color = self.color;
        var bg = self.bg_color;
        var width = self.width;
        var height = self.height;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "value")) {
                value_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "max")) {
                max_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| color = c;
            } else if (std.mem.eql(u8, attr.key, "bg_color")) {
                if (box_helpers.parseColor(attr.value)) |c| bg = c;
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| width = switch (l) {
                    .pixels => |p| p,
                    else => width,
                };
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| height = switch (l) {
                    .pixels => |p| p,
                    else => height,
                };
            }
        }

        const raw = value_raw orelse return Error.ProgressMissingValue;
        // Unresolved `${state.x}` tokens survive substitution as the
        // literal text; parseFloat fails → treat as 0 rather than
        // erroring the parse. Authors see a stuck-at-zero bar, which
        // is a clearer "your state binding didn't resolve" signal
        // than a missing component placeholder.
        const v = std.fmt.parseFloat(f32, raw) catch 0;
        const m = std.fmt.parseFloat(f32, max_raw) catch 1;
        const safe_m = if (m == 0) 1 else m;
        self.ratio = std.math.clamp(v / safe_m, 0.0, 1.0);
        self.color = color;
        self.bg_color = bg;
        self.width = width;
        self.height = height;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .ratio = 0,
        .color = DEFAULT_FILL,
        .bg_color = DEFAULT_BG,
        .width = 80,
        .height = 8,
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

const DEFAULT_FILL: [4]f32 = .{ 0.40, 0.68, 0.95, 1.0 };
const DEFAULT_BG: [4]f32 = .{ 0.20, 0.22, 0.26, 1.0 };

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = lc;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    // Centre the bar on the text x-height (~0.5 em above baseline)
    // so it reads as flowing through the middle of the line rather
    // than hanging off the baseline like an underline. The ascender
    // / descender split below puts the bar's vertical centre exactly
    // at the x-height centre line.
    const x_centre = em_px * 0.32; // ≈ middle of lowercase letters
    const half_h = c.height * 0.5;
    return .{
        .width = c.width,
        .ascender = x_centre + half_h,
        .descender = -(x_centre - half_h),
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

    // Track (full width). Pill ends from radius = h/2.
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ c.width, c.height },
        .color = c.bg_color,
        .radius = c.height * 0.5,
    });

    // Fill (left portion). Hide when ratio is zero so we don't draw
    // a stray 0-width quad.
    const fill_w = c.width * c.ratio;
    if (fill_w > 0.5) {
        try out.appendQuad(lc, .{
            .dst_pos = .{ origin[0], origin[1] },
            .dst_size = .{ fill_w, c.height },
            .color = c.color,
            .radius = c.height * 0.5,
        });
    }

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = c.width,
        .h = c.height,
        .baseline = origin[1] + c.height,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "Component: clamps ratio to [0,1]" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "1.7" },
    };
    const spec: components.Spec = .{ .name = "progress", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(f32, 1.0), c.ratio);
}

test "Component: value/max scales the ratio" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "30" },
        .{ .key = "max", .value = "40" },
    };
    const spec: components.Spec = .{ .name = "progress", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectApproxEqAbs(@as(f32, 0.75), c.ratio, 1e-6);
}

test "Component: unresolved template falls to zero" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "${state.missing}" },
    };
    const spec: components.Spec = .{ .name = "progress", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(f32, 0.0), c.ratio);
}

test "Component: missing value rejected" {
    const spec: components.Spec = .{ .name = "progress" };
    try testing.expectError(Error.ProgressMissingValue, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
