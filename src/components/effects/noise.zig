//! `:::noise` — hash-based value noise summed over octaves.
//! Effects-spec Phase A.5 third canary. Param shape: two integers
//! + one float (`seed`, `octaves`, `scale`) — exercises the
//! resolver's `u32` + `f32` arms simultaneously, a different mix
//! from `:::gradient` (vec4×2 + enum) and `:::pattern` (enum + int).
//!
//! Attribute grammar:
//!
//!     :::noise {seed=0 scale=8.0 octaves=4 width=100% height=120}
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
    NoiseShaderNotRegistered,
};

const NoiseUniforms = extern struct {
    seed: u32,                 // offset 0,  size 4
    octaves: u32,              // offset 4,  size 4
    scale: f32,                // offset 8,  size 4
    _pad: u32 = 0,             // offset 12, size 4 — pad to vec4 boundary
    // Total: 16 bytes.
};

const SHADER_NAME = "noise.frag";
const SHADER_ID: component_mod.ShaderId = pass.shaderIdFromName(SHADER_NAME);

const Component = struct {
    uniforms: NoiseUniforms,
    width: box_helpers.Length,
    height: box_helpers.Length,

    fn fromSpec(spec: *const components.Spec) Component {
        const seed = params.resolve(u32, spec, "seed", 0);
        const octaves = params.resolve(u32, spec, "octaves", 4);
        const scale = params.resolve(f32, spec, "scale", 8.0);
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
                .seed = seed,
                .octaves = octaves,
                .scale = scale,
            },
            .width = width,
            .height = height,
        };
    }
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("noise", factory);
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
    _ = spark.shader_resolver.resolve(SHADER_ID) catch return Error.NoiseShaderNotRegistered;
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

test "NoiseUniforms: std140 layout offsets" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(NoiseUniforms, "seed"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(NoiseUniforms, "octaves"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(NoiseUniforms, "scale"));
    try testing.expectEqual(@as(usize, 16), @sizeOf(NoiseUniforms));
}

test "fromSpec: parses int + int + float" {
    const attrs = [_]components.Attr{
        .{ .key = "seed", .value = "7" },
        .{ .key = "octaves", .value = "6" },
        .{ .key = "scale", .value = "16.0" },
    };
    const spec: components.Spec = .{ .name = "noise", .attrs = &attrs };
    const c = Component.fromSpec(&spec);
    try testing.expectEqual(@as(u32, 7), c.uniforms.seed);
    try testing.expectEqual(@as(u32, 6), c.uniforms.octaves);
    try testing.expectApproxEqAbs(@as(f32, 16.0), c.uniforms.scale, 0.001);
}

test "fromSpec: default octaves=4 scale=8.0" {
    const spec: components.Spec = .{ .name = "noise" };
    const c = Component.fromSpec(&spec);
    try testing.expectEqual(@as(u32, 4), c.uniforms.octaves);
    try testing.expectApproxEqAbs(@as(f32, 8.0), c.uniforms.scale, 0.001);
}

// See gradient.zig for the test-pattern footgun comment on
// constructing the ShaderResolver in place on `test_spark.shader_resolver`
// rather than via a separate local.

test "create: fail-fast when shader not registered" {
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    test_spark.shader_resolver = pass.ShaderResolver.init(testing.allocator);
    defer test_spark.shader_resolver.deinit();
    const spec: components.Spec = .{ .name = "noise" };
    try testing.expectError(
        Error.NoiseShaderNotRegistered,
        create(&test_spark, testing.allocator, &spec),
    );
}
