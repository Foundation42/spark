//! `:::frosted_glass` — wraps child content with a blurred + tinted
//! overlay. Effects-spec Phase B.6 — second user-facing single_source
//! factory. First consumer to ratify the post-B.6.a cache substrate
//! cleanly (no `disable_cache` workaround needed); shares the same
//! pipeline shape drop_shadow uses (combined-image-sampler descriptor
//! layout + push-constant uniforms).
//!
//! Attribute grammar:
//!
//!     :::frosted_glass {blur=12 tint=#ffffff10}
//!       :::box {color=teal width=160 height=80 radius=8}
//!         Tools panel
//!       :::
//!     :::
//!
//! Defaults: blur=12px, tint=#ffffff10 (~6% white overlay — the
//! modern-OS frosted-panel look).
//!
//! **No layout inflation.** Unlike drop_shadow, the effect renders
//! within the child's natural bounds — no halo extends beyond the
//! panel. `Factory.pass_shape.single_source.layout_inflation` is
//! left null; the walker reads box.{w, h} (the child's natural box)
//! as target_size.

const std = @import("std");
const element = @import("../../element.zig");
const element_layout = @import("../../element_layout.zig");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const spark_mod = @import("../../spark.zig");
const params = @import("../../params.zig");
const pass = @import("../../pass/root.zig");
const markdown = @import("../../markdown.zig");

pub const Error = error{
    FrostedGlassShaderNotRegistered,
};

/// std140-compatible uniform block. Mirrors `Params` in
/// `shaders/frosted_glass.frag` exactly. See A.5 Decision #10 for
/// the std140 padding rules.
///
/// Layout:
///   blur_radius : f32   — 0..4   (tap separation in pixels)
///   _pad        : f32x3 — 4..16  (align next vec4 to 16-byte boundary)
///   tint_color  : vec4  — 16..32 (premultiplied-alpha RGBA overlay)
const FrostedGlassUniforms = extern struct {
    blur_radius: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
    tint_color: [4]f32,
    // Total size: 32 bytes. std140 conforming.
};

const SHADER_NAME = "frosted_glass.frag";
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

    /// std140-padded uniform bytes for the GPU compose dispatch.
    /// Snapshotted into PassDispatch.filter_uniforms via the
    /// vtable's `snapshot_uniforms` hook.
    uniforms: FrostedGlassUniforms,

    version: u64 = 0,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("frosted_glass", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .pass_shape = .{ .single_source = .{
        .shader_id = SHADER_ID,
        // No layout_inflation — frosted_glass renders within child
        // bounds (no halo). Decision #8 still applies vacuously: an
        // author who wants extra room for a different effect wraps
        // with `:::box` to grow the bounds explicitly.
    } },
};

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    // Fail-fast barrier (A.5/B.5 pattern): the shader must be
    // registered before instance creation. Mismatched names or a
    // skipped build step shows up here, not mid-frame.
    _ = spark.shader_resolver.resolve(SHADER_ID) catch return Error.FrostedGlassShaderNotRegistered;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const id_raw = spec.id orelse "frosted_glass";

    c.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .spark = spark,
        .uniforms = .{ .blur_radius = 0, .tint_color = .{ 0, 0, 0, 0 } },
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
    applyAttrs(c, spec);
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
    const blur = params.resolve(f32, spec, "blur", 12.0);
    // Default tint: #ffffff10 = white at 6.25% alpha. The
    // modern-OS panel look sits in the 5–15% range.
    const tint = params.resolve([4]f32, spec, "tint", .{ 1, 1, 1, 0.0625 });
    c.uniforms = .{
        .blur_radius = blur,
        .tint_color = tint,
    };
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .snapshot_uniforms = snapshotUniforms,
    // Cacheable. Phase B.6.a's cache replay-with-offset substrate
    // restored cache eligibility for single_source factories; no
    // workaround flag carried here. See `layout_cache.zig`
    // blitEntry / snapshotEntry and `element.zig`
    // appendGlyphsReplayingTargets.
};

/// Copy the std140-padded `FrostedGlassUniforms` bytes into the
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

/// Layout the child at origin (no inflation); return its natural
/// box. The walker reads box.{w, h} as the single_source dispatch's
/// target_size.
fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    // No inflation: walk child at origin, return child's box
    // directly. Drawlist primitives the child emits will tag
    // against the walker's current_target_dispatch_index (our own
    // dispatch index, pushed by the walker's .custom arm), so
    // they route into our offscreen target.
    return try element_layout.layoutAndRenderCached(
        c.root,
        origin,
        constraints,
        lc,
        out,
    );
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "FrostedGlassUniforms: std140 layout offsets" {
    // Lock-in test. These offsets ARE the GLSL push_constant block's
    // contract; an "innocent" field reorder that compiles cleanly
    // would push misaligned uniforms to the GPU and render garbage.
    try testing.expectEqual(@as(usize, 0), @offsetOf(FrostedGlassUniforms, "blur_radius"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(FrostedGlassUniforms, "tint_color"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(FrostedGlassUniforms));
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

test "factory: layout_inflation is null (no halo, no edge reservation)" {
    // Frosted glass renders within child bounds — author opts into
    // extra room by wrapping in :::box, not by an inflation knob.
    switch (factory.pass_shape) {
        .single_source => |ss| try testing.expect(ss.layout_inflation == null),
        else => unreachable,
    }
}
