//! `:::gradient` — linear color interpolation between two vec4 colors.
//! Effects-spec Phase A.5 first canary pattern factory. Demonstrates
//! the full `Factory.pass_shape = .pattern` shape end-to-end:
//! resolver-validated shader, std140 uniform struct, factory-side
//! shader_id computation at comptime, fail-fast on missing shader.
//!
//! Attribute grammar:
//!
//!     :::gradient {from=#1a1a2e to=#16213e direction=vertical width=100% height=120}
//!
//! Direction is `vertical` (default — t = y), `horizontal` (t = x),
//! or `diagonal` (t = (x+y)/2). Colors accept hex / named / CSV vec4
//! via the shared `params.resolve([4]f32, ...)` rung order.
//!
//! **A.5 runtime semantics.** The factory creates an Instance and
//! claims layout space; the layout call emits NOTHING into DrawList.
//! The pass-graph compiler doesn't dispatch yet (`Graph.dispatchPass(.pattern)`
//! still panics with the A.6 phase tag), so a `:::gradient` in a doc
//! today lays out as an invisible block. A.6 lights up the dispatch
//! and the gradient becomes visible at the claimed region.

const std = @import("std");
const element = @import("../../element.zig");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const spark_mod = @import("../../spark.zig");
const params = @import("../../params.zig");
const box_helpers = @import("../box.zig");
const pass = @import("../../pass/root.zig");

pub const Error = error{
    GradientShaderNotRegistered,
};

/// Direction enum — wire format matches field names directly so
/// `params.resolve(Direction, ...)` works with `direction=vertical`
/// authoring syntax. `@intFromEnum` packs into the uniform struct.
const Direction = enum(u32) {
    vertical = 0,
    horizontal = 1,
    diagonal = 2,
};

/// std140-compatible uniform block for the gradient fragment shader.
///
/// **Pinned policy (Decision #10, A.5).** Every effect uniform
/// struct is `extern struct` with explicit padding to satisfy
/// std140. The rules every subsequent factory mirrors:
///
///   * `vec4` (Zig `[N]f32` for N=2..4) occupies 16 bytes and
///     aligns to 16. Use `[4]f32` for vec4.
///   * `vec2` aligns to 8; `[2]f32` is fine without explicit pad
///     unless followed by another vec2 that needs alignment.
///   * Scalars (`f32` / `u32` / `i32`) occupy 4 bytes. The *next*
///     `vec4` after a scalar starts at the next 16-byte boundary,
///     so trailing scalars need explicit `_pad: [N]u32` to the
///     boundary. Crucially this applies at the *end* of the struct
///     too — Vulkan's uniform buffer descriptor reads the full
///     16-byte stride, so a struct that ends on a scalar reads
///     uninitialised memory unless padded.
///   * Arrays-of-scalars stride to vec4 in std140 (every element
///     occupies 16 bytes regardless of declared type). Avoid them;
///     use `[N][4]f32` if indexed storage is genuinely needed.
///
/// Mirror this layout on the GLSL side (`layout(set=0, binding=0,
/// std140) uniform Params { … }`). The field names should match
/// 1:1 between this struct and the GLSL block so a future
/// glsl-vs-zig field-name validator can cross-check both sides.
const GradientUniforms = extern struct {
    from: [4]f32,                  // offset 0,  size 16
    to: [4]f32,                    // offset 16, size 16
    direction: u32,                // offset 32, size 4
    _pad: [3]u32 = .{ 0, 0, 0 },   // offset 36, size 12 — pad to vec4 boundary
    // Total size: 48 bytes. std140 conforming.
};

const SHADER_NAME = "gradient.frag";
const SHADER_ID: component_mod.ShaderId = pass.shaderIdFromName(SHADER_NAME);

const Component = struct {
    uniforms: GradientUniforms,
    width: box_helpers.Length,
    height: box_helpers.Length,

    fn fromSpec(spec: *const components.Spec) Component {
        const from = params.resolve([4]f32, spec, "from", .{ 0, 0, 0, 1 });
        const to = params.resolve([4]f32, spec, "to", .{ 1, 1, 1, 1 });
        const direction = params.resolve(Direction, spec, "direction", .vertical);
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
                .from = from,
                .to = to,
                .direction = @intFromEnum(direction),
            },
            .width = width,
            .height = height,
        };
    }
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("gradient", factory);
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
    // **Fail-fast barrier (A.5 watch-point #5).** Validate the
    // shader is registered before allocating the instance. A typo
    // in the SHADER_NAME above, a missing entry in
    // `registerEmbeddedPassShaders`, or a skipped build step shows
    // up here as "this doc fails to load" rather than "this doc
    // loads but crashes / renders wrong mid-frame." Same philosophy
    // as the glslc-not-found message in build.zig.
    _ = spark.shader_resolver.resolve(SHADER_ID) catch return Error.GradientShaderNotRegistered;
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
    .snapshot_uniforms = snapshotUniforms,
};

/// Effects-spec Phase A.6.a hook. Copies the std140-padded
/// `GradientUniforms` bytes into the walker-supplied scratch
/// buffer. The pass-graph emission code in `element_layout.zig`
/// hands this function a slice of `PassDispatch.uniform_bytes`
/// (capped at `MAX_PASS_UNIFORM_BYTES = 256`); 48 bytes for
/// gradient.
fn snapshotUniforms(ctx: *anyopaque, out: []u8) usize {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    const bytes = std.mem.asBytes(&c.uniforms);
    @memcpy(out[0..bytes.len], bytes);
    return bytes.len;
}

/// A.5 layout: claim the requested width/height; emit no DrawList
/// work. A.6 will read this element's box from the document tree
/// and dispatch the gradient shader scissored to that region —
/// until then the doc lays out the space but renders nothing
/// visible. First non-empty fingerprint in `integration_render.zig`
/// is still A.6's job.
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

test "GradientUniforms: std140 layout offsets" {
    // Pin the load-bearing struct offsets so a future "innocent"
    // reorder fails here loudly, not silently on the GPU where
    // mis-aligned uniforms read garbage data. These numbers ARE
    // the GLSL `layout(std140)` contract.
    try testing.expectEqual(@as(usize, 0), @offsetOf(GradientUniforms, "from"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(GradientUniforms, "to"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(GradientUniforms, "direction"));
    try testing.expectEqual(@as(usize, 48), @sizeOf(GradientUniforms));
}

test "fromSpec: parses all uniform fields" {
    const attrs = [_]components.Attr{
        .{ .key = "from", .value = "#ff0000" },
        .{ .key = "to", .value = "#0000ff" },
        .{ .key = "direction", .value = "horizontal" },
    };
    const spec: components.Spec = .{ .name = "gradient", .attrs = &attrs };
    const c = Component.fromSpec(&spec);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.uniforms.from[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.uniforms.to[2], 0.001);
    try testing.expectEqual(@as(u32, @intFromEnum(Direction.horizontal)), c.uniforms.direction);
}

test "fromSpec: defaults when attrs omitted" {
    const spec: components.Spec = .{ .name = "gradient" };
    const c = Component.fromSpec(&spec);
    // Direction defaults vertical (0).
    try testing.expectEqual(@as(u32, 0), c.uniforms.direction);
    // Width defaults to 100% (.percent = 1.0).
    try testing.expect(c.width == .percent);
}

// **Test-pattern footgun.** `ShaderResolver` is a by-value struct
// with an internal `AutoHashMap` (which heap-allocates on `put`).
// Do NOT construct via `var resolver = ...; test_spark.shader_resolver
// = resolver;` and then call `register()` on `test_spark.shader_resolver`
// — the assignment copies the empty HashMap; a subsequent grow
// reassigns the COPY's bucket pointer; the original's `defer deinit`
// frees the wrong allocation and the new one leaks. Always construct
// in place on `test_spark.shader_resolver` and defer-deinit there.

test "create: fail-fast when shader not registered" {
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    test_spark.shader_resolver = pass.ShaderResolver.init(testing.allocator);
    defer test_spark.shader_resolver.deinit();

    const spec: components.Spec = .{ .name = "gradient" };
    try testing.expectError(
        Error.GradientShaderNotRegistered,
        create(&test_spark, testing.allocator, &spec),
    );
}

test "create: succeeds when shader registered" {
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    test_spark.shader_resolver = pass.ShaderResolver.init(testing.allocator);
    defer test_spark.shader_resolver.deinit();

    // SPIR-V magic prefix — proves we're not registering literal "spv"
    // text and resolving against it. Same magic-byte sanity as A.4's
    // smoke test in shader_resolver.zig.
    const fake_spv = [_]u8{ 0x03, 0x02, 0x23, 0x07 };
    try test_spark.shader_resolver.register(SHADER_NAME, &fake_spv);

    const spec: components.Spec = .{ .name = "gradient" };
    const inst = try create(&test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
}

test "factory: pass_shape is .pattern with correct shader_id" {
    // Lock-in test: factory.pass_shape must remain .pattern and the
    // shader_id must match what registerEmbeddedPassShaders seeds.
    // If either drifts, the A.5 contract is broken.
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .pattern),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .pattern => |p| try testing.expectEqual(SHADER_ID, p.shader_id),
        else => unreachable,
    }
}
