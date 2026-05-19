//! `:::drop_shadow` — wraps child content with a blurred, offset,
//! tinted shadow. Effects-spec Phase B.5 — first user-facing
//! single_source factory. End-to-end exercise of the B.4.b substrate
//! (target_pool → SingleSourcePipelineCache → descriptor pool →
//! three-phase dispatch processor).
//!
//! Attribute grammar:
//!
//!     :::drop_shadow {offset_x=4 offset_y=4 blur=8 color=#000a}
//!       :::box {color=teal width=200 height=80 radius=8}
//!       :::
//!     :::
//!
//! Defaults: offset (4,4), blur 8px, color #00000080 (50% opaque
//! black). The child renders normally; the shadow appears under
//! it shifted by `(offset_x, offset_y)` with a 9-tap box blur of
//! radius `blur` pixels.
//!
//! **Inflation = target_size invariant (B.5 watch-point).** The
//! factory computes inflation Edges from (blur, offset_x, offset_y)
//! at create() time and stores them on the Component. Layout reads
//! the Edges to inflate the child's reserved region; the walker
//! reads `box.{w, h}` (the returned inflated box) for the
//! single_source dispatch's target_size. Same value flowing through
//! two channels; can't drift.
//!
//! Inflation math:
//!     left   = blur - min(0, offset_x)   // blur + extra room for negative offsets
//!     right  = blur + max(0, offset_x)   // blur + extra room for positive offsets
//!     top    = blur - min(0, offset_y)
//!     bottom = blur + max(0, offset_y)
//!
//! Example: blur=8, offset_x=4, offset_y=4 →
//!     left=8, right=12, top=8, bottom=12
//! The child sits at (origin + (8, 8)) inside the inflated region.
//! The shadow extends 12px to the right and 12px below.

const std = @import("std");
const element = @import("../../element.zig");
const element_layout = @import("../../element_layout.zig");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const spark_mod = @import("../../spark.zig");
const params = @import("../../params.zig");
const box_helpers = @import("../box.zig");
const pass = @import("../../pass/root.zig");
const markdown = @import("../../markdown.zig");

pub const Error = error{
    DropShadowShaderNotRegistered,
};

/// std140-compatible uniform block. Mirrors `Params` in
/// `shaders/drop_shadow.frag` exactly. See A.5 Decision #10 for
/// the std140 padding rules.
///
/// Layout:
///   offset       : vec2 — 0..8   (pixel offset of shadow from child)
///   blur_radius  : f32  — 8..12  (tap separation in pixels)
///   _pad         : f32  — 12..16 (align next vec4 to 16-byte boundary)
///   shadow_color : vec4 — 16..32 (premultiplied-alpha RGBA tint)
const DropShadowUniforms = extern struct {
    offset: [2]f32,
    blur_radius: f32,
    _pad: f32 = 0,
    shadow_color: [4]f32,
    // Total size: 32 bytes. std140 conforming.
};

const SHADER_NAME = "drop_shadow.frag";
const SHADER_ID: component_mod.ShaderId = pass.shaderIdFromName(SHADER_NAME);

const Component = struct {
    /// Owns the parsed child tree.
    arena: std.heap.ArenaAllocator,
    /// Parsed children — typically a `container.stack_v`.
    root: element.Element,
    /// Scope prefix for child registry keys.
    scope: []u8,
    /// Captured at create() so deinit_ can reach the registry.
    spark: ?*spark_mod.Spark = null,

    /// Resolved at create(). Layout reads to inflate child region;
    /// walker reads box.{w,h} (the inflated box) for target_size.
    /// Single source of truth — both channels see the same Edges.
    inflation: component_mod.Edges,

    /// std140-padded uniform bytes for the GPU compose dispatch.
    /// Snapshotted into PassDispatch.filter_uniforms via the
    /// vtable's `snapshot_uniforms` hook.
    uniforms: DropShadowUniforms,

    version: u64 = 0,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("drop_shadow", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .pass_shape = .{ .single_source = .{
        .shader_id = SHADER_ID,
        .layout_inflation = .{ .from_params = computeInflationFromSpec },
    } },
};

/// Inflation derivation from raw spec attrs. Wired into
/// `Factory.pass_shape.single_source.layout_inflation` as the
/// `.from_params` callback. Also called directly from `create` /
/// `applyAttrs` so the inflation Edges + the layout coords + the
/// shader uniforms all originate from the same parse of the same
/// spec — no divergence between "what the factory declares" and
/// "what the instance applies."
fn computeInflationFromSpec(spec: *const components.Spec) component_mod.Edges {
    const offset_x = params.resolve(f32, spec, "offset_x", 4.0);
    const offset_y = params.resolve(f32, spec, "offset_y", 4.0);
    const blur = params.resolve(f32, spec, "blur", 8.0);
    return computeInflation(offset_x, offset_y, blur);
}

/// The load-bearing inflation math. Separate from
/// `computeInflationFromSpec` so unit tests can exercise the math
/// directly without constructing a Spec.
fn computeInflation(offset_x: f32, offset_y: f32, blur: f32) component_mod.Edges {
    return .{
        .left = blur - @min(@as(f32, 0), offset_x),
        .right = blur + @max(@as(f32, 0), offset_x),
        .top = blur - @min(@as(f32, 0), offset_y),
        .bottom = blur + @max(@as(f32, 0), offset_y),
    };
}

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    // Fail-fast barrier (A.5/B.5 pattern): the shader must be
    // registered before instance creation. Mismatched names or a
    // skipped build step shows up here, not mid-frame.
    _ = spark.shader_resolver.resolve(SHADER_ID) catch return Error.DropShadowShaderNotRegistered;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const id_raw = spec.id orelse "drop_shadow";

    c.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .spark = spark,
        .inflation = .{},
        .uniforms = .{ .offset = .{ 0, 0 }, .blur_radius = 0, .shadow_color = .{ 0, 0, 0, 0 } },
        .version = 0,
    };
    errdefer c.arena.deinit();

    c.scope = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(c.scope);

    applyAttrs(c, spec);

    c.root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        spec.body,
        spark.theme,
        spark.registry,
        spark.host_state,
        c.scope,
    );

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const prev_version = c.version;
    // Decision #8: inflation resolves ONCE at create. We update
    // shader uniforms (animating blur within the reserved edge is
    // fine) but NOT inflation — an author who wants more room must
    // recreate the component via a #id change.
    const offset_x = params.resolve(f32, spec, "offset_x", 4.0);
    const offset_y = params.resolve(f32, spec, "offset_y", 4.0);
    const blur = params.resolve(f32, spec, "blur", 8.0);
    const color = params.resolve([4]f32, spec, "color", .{ 0, 0, 0, 0.5 });
    c.uniforms = .{
        .offset = .{ offset_x, offset_y },
        .blur_radius = blur,
        .shadow_color = color,
    };
    c.version = prev_version +% 1;
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (c.spark) |sp| sp.registry.deinitScope(c.scope);
    c.arena.deinit();
    allocator.free(c.scope);
    allocator.destroy(c);
}

fn applyAttrs(c: *Component, spec: *const components.Spec) void {
    const offset_x = params.resolve(f32, spec, "offset_x", 4.0);
    const offset_y = params.resolve(f32, spec, "offset_y", 4.0);
    const blur = params.resolve(f32, spec, "blur", 8.0);
    const color = params.resolve([4]f32, spec, "color", .{ 0, 0, 0, 0.5 });
    c.inflation = computeInflation(offset_x, offset_y, blur);
    c.uniforms = .{
        .offset = .{ offset_x, offset_y },
        .blur_radius = blur,
        .shadow_color = color,
    };
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .snapshot_uniforms = snapshotUniforms,
};

/// Copy the std140-padded `DropShadowUniforms` bytes into the
/// walker-supplied scratch buffer. Walker hands us a slice of
/// PassDispatch.filter_uniforms (capped at MAX_PASS_UNIFORM_BYTES).
/// Zero-pads the unused tail per the gradient.zig pattern —
/// deterministic, zero validation noise.
fn snapshotUniforms(ctx: *anyopaque, out: []u8) usize {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    const bytes = std.mem.asBytes(&c.uniforms);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    return bytes.len;
}

/// Layout the child inside the inflated region; return the
/// inflated box. The walker reads box.{w,h} as the single_source
/// dispatch's target_size, so the inflated box IS the GPU target
/// size — invariant preserved.
fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const inf = c.inflation;

    // Inflated constraints: child gets less horizontal slack since
    // we're reserving inflation.left + inflation.right pixels for
    // the shadow halo.
    var child_constraints = constraints;
    if (std.math.isFinite(child_constraints.max_w)) {
        child_constraints.max_w = @max(0, child_constraints.max_w - inf.left - inf.right);
    }
    if (std.math.isFinite(child_constraints.max_h)) {
        child_constraints.max_h = @max(0, child_constraints.max_h - inf.top - inf.bottom);
    }

    // Walk the child subtree at the inflated-origin position.
    // Drawlist primitives the child emits will tag against the
    // walker's current_target_dispatch_index (which is our own
    // dispatch index, pushed by the walker's .custom arm), so they
    // route into our offscreen target.
    const child_box = try element_layout.layoutAndRenderCached(
        c.root,
        .{ origin[0] + inf.left, origin[1] + inf.top },
        child_constraints,
        lc,
        out,
    );

    // Return the inflated box. Walker reads box.{w,h} for
    // target_size in the single_source PassDispatch emission.
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = child_box.w + inf.left + inf.right,
        .h = child_box.h + inf.top + inf.bottom,
        .baseline = 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "DropShadowUniforms: std140 layout offsets" {
    // Lock-in test. These offsets ARE the GLSL push_constant block's
    // contract; an "innocent" field reorder that compiles cleanly
    // would push misaligned uniforms to the GPU and render garbage.
    try testing.expectEqual(@as(usize, 0), @offsetOf(DropShadowUniforms, "offset"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(DropShadowUniforms, "blur_radius"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(DropShadowUniforms, "shadow_color"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(DropShadowUniforms));
}

test "computeInflation: positive offset extends right + bottom" {
    const e = computeInflation(4, 4, 8);
    try testing.expectEqual(@as(f32, 8), e.left);
    try testing.expectEqual(@as(f32, 12), e.right);
    try testing.expectEqual(@as(f32, 8), e.top);
    try testing.expectEqual(@as(f32, 12), e.bottom);
}

test "computeInflation: negative offset extends left + top" {
    const e = computeInflation(-4, -4, 8);
    try testing.expectEqual(@as(f32, 12), e.left);
    try testing.expectEqual(@as(f32, 8), e.right);
    try testing.expectEqual(@as(f32, 12), e.top);
    try testing.expectEqual(@as(f32, 8), e.bottom);
}

test "computeInflation: zero offset is symmetric (blur on all sides)" {
    const e = computeInflation(0, 0, 6);
    try testing.expectEqual(@as(f32, 6), e.left);
    try testing.expectEqual(@as(f32, 6), e.right);
    try testing.expectEqual(@as(f32, 6), e.top);
    try testing.expectEqual(@as(f32, 6), e.bottom);
}

test "factory: pass_shape is .single_source with correct shader_id" {
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .single_source),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .single_source => |ss| try testing.expectEqual(SHADER_ID, ss.shader_id),
        else => unreachable,
    }
}

test "factory: layout_inflation is from_params (resolves at create)" {
    // Decision #8 invariant — inflation is .from_params not .fixed
    // because drop_shadow's inflation depends on parsed (blur,
    // offset_x, offset_y) attrs, not a hardcoded value.
    switch (factory.pass_shape) {
        .single_source => |ss| {
            const li = ss.layout_inflation orelse return error.MissingInflationSpec;
            try testing.expectEqual(
                @as(std.meta.Tag(component_mod.LayoutInflationSpec), .from_params),
                std.meta.activeTag(li),
            );
        },
        else => unreachable,
    }
}
