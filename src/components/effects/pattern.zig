//! `:::pattern` — geometric pattern fill (checker / stripes / grid /
//! dots). Effects-spec Phase A.5 second canary. Param shape is
//! deliberately distinct from `:::gradient` — enum + integer rather
//! than vec4×2 + enum — so the typed-marshalling test surface
//! exercises a different combination of resolver arms.
//!
//! Attribute grammar:
//!
//!     :::pattern {type=checker seed=0 width=100% height=120}
//!
//! See `gradient.zig` for the load-bearing std140 padding policy
//! comment that every effect uniform struct mirrors.

const std = @import("std");
const element = @import("../../element.zig");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const spark_mod = @import("../../spark.zig");
const params = @import("../../params.zig");
const box_helpers = @import("../box.zig");
const pass = @import("../../pass/root.zig");

pub const Error = error{
    PatternShaderNotRegistered,
};

/// Pattern type — wire format matches field names directly.
const PatternType = enum(u32) {
    checker = 0,
    stripes = 1,
    grid = 2,
    dots = 3,
};

/// std140 uniform block. Two trailing u32s already round to 8 bytes
/// but std140 still requires the *struct* to round up to vec4 stride
/// when the buffer is bound as a uniform — explicit pad makes that
/// invariant visible at the type level.
const PatternUniforms = extern struct {
    pattern_type: u32,           // offset 0,  size 4
    seed: u32,                   // offset 4,  size 4
    _pad: [2]u32 = .{ 0, 0 },    // offset 8,  size 8 — pad to vec4 boundary
    // Total: 16 bytes.
};

const SHADER_NAME = "pattern.frag";
const SHADER_ID: component_mod.ShaderId = pass.shaderIdFromName(SHADER_NAME);

const Component = struct {
    uniforms: PatternUniforms,
    width: box_helpers.Length,
    height: box_helpers.Length,

    fn fromSpec(spec: *const components.Spec) Component {
        const pattern_type = params.resolve(PatternType, spec, "type", .checker);
        const seed = params.resolve(u32, spec, "seed", 0);
        const width = if (params.find(spec, "width")) |s|
            box_helpers.parseLength(s) orelse box_helpers.Length{ .percent = 1.0 }
        else
            box_helpers.Length{ .percent = 1.0 };
        const height = if (params.find(spec, "height")) |s|
            box_helpers.parseLength(s) orelse box_helpers.Length{ .pixels = 120 }
        else
            box_helpers.Length{ .pixels = 120 };
        return .{
            .uniforms = .{
                .pattern_type = @intFromEnum(pattern_type),
                .seed = seed,
            },
            .width = width,
            .height = height,
        };
    }
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("pattern", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .pass_shape = .{ .pattern = .{ .shader_id = SHADER_ID } },
};

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    _ = spark.shader_resolver.resolve(SHADER_ID) catch return Error.PatternShaderNotRegistered;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = Component.fromSpec(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.* = Component.fromSpec(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
};

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    _ = lc;
    _ = out;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    const w = c.width.resolve(constraints.max_w, constraints.max_w);
    const h = c.height.resolve(constraints.max_h, 120);
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "PatternUniforms: std140 layout offsets" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(PatternUniforms, "pattern_type"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(PatternUniforms, "seed"));
    try testing.expectEqual(@as(usize, 16), @sizeOf(PatternUniforms));
}

test "fromSpec: parses enum + integer" {
    const attrs = [_]components.Attr{
        .{ .key = "type", .value = "grid" },
        .{ .key = "seed", .value = "42" },
    };
    const spec: components.Spec = .{ .name = "pattern", .attrs = &attrs };
    const c = Component.fromSpec(&spec);
    try testing.expectEqual(@as(u32, @intFromEnum(PatternType.grid)), c.uniforms.pattern_type);
    try testing.expectEqual(@as(u32, 42), c.uniforms.seed);
}

test "fromSpec: defaults to checker + seed 0" {
    const spec: components.Spec = .{ .name = "pattern" };
    const c = Component.fromSpec(&spec);
    try testing.expectEqual(@as(u32, 0), c.uniforms.pattern_type);
    try testing.expectEqual(@as(u32, 0), c.uniforms.seed);
}

// See gradient.zig for the test-pattern footgun comment on
// constructing the ShaderResolver in place on `test_spark.shader_resolver`
// rather than via a separate local.

test "create: fail-fast when shader not registered" {
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    test_spark.shader_resolver = pass.ShaderResolver.init(testing.allocator);
    defer test_spark.shader_resolver.deinit();
    const spec: components.Spec = .{ .name = "pattern" };
    try testing.expectError(
        Error.PatternShaderNotRegistered,
        create(&test_spark, testing.allocator, &spec),
    );
}
