//! `:::drop_shadow` — a Photoshop-shaped drop shadow: a real Gaussian
//! blur of the child's silhouette, offset, tinted, spread, and laid under
//! the child. Effects-spec Phase C.2, and the first CHAIN consumer.
//!
//! ## What changed, and why it had to
//!
//! Phase B.5 shipped this as a single_source filter with a 9-tap box blur:
//! three taps per axis separated by the whole blur radius. That is not a
//! blur. A capture of matryoshka's Lab at `blur=8` showed the heading three
//! times across and three times down — nine legible ghosts, at exactly the
//! spacing the algorithm specifies. Chris, at the bench: *"our current drop
//! shadows are a bit sketchy."*
//!
//! A Gaussian of radius R is O(R²) samples done directly and O(R) done as
//! two 1D passes, because a 2D Gaussian is the outer product of two 1D
//! ones. Two passes means two images, and two images means a chain — which
//! is what C.1/C.1.5 built the ping-pong pool for and left waiting for its
//! first consumer.
//!
//! ## The chain, in three steps and three pool targets
//!
//! `pool[0]` arrives holding the rendered child (C.1.5 renders the subtree
//! into it before `steps[]` run). Then:
//!
//! ```text
//!   step 0   pool[0] --  horizontal gaussian of ALPHA, shifted by offset
//!                    --> pool[1]      (greyscale, clear)
//!   step 1   pool[1] --  vertical gaussian of RED, spread, tinted
//!                    --> pool[2]      (the shadow, premultiplied, clear)
//!   step 2   pool[0] --  straight copy, KEEPING what is already there
//!                    --> pool[2]      (the child, over its own shadow)
//!   phase 2  pool[2] --> MAIN at compose_region
//! ```
//!
//! The third step is the whole reason `ChainLoad` exists. A drop shadow is
//! a composite, not a filter: the last thing that happens is the child
//! being laid back on top of the shadow it cast, which needs the
//! destination's existing contents and the pipeline's ordinary
//! premultiplied-over blend. Doing it as source=child / dest=shadow is what
//! lets it use that blend unchanged — the alternative, drawing the shadow
//! under the child, would have needed a destination-over blend variant and
//! a second pipeline per shader.
//!
//! The offset is applied ONCE, on the horizontal pass. Applying it on both
//! would move the shadow diagonally by twice what the author asked for, and
//! the failure would look like a working shadow in the wrong place.
//!
//! ## Attribute grammar
//!
//!     :::drop_shadow {offset_x=4 offset_y=4 blur=8 spread=0 color=#000a}
//!       :::box {color=teal width=200 height=80 radius=8}
//!       :::
//!     :::
//!
//! `blur` is the shadow's visible REACH in pixels, not a tap spacing —
//! sigma is `blur / 3`, so three sigma (99.7% of the kernel) lands exactly
//! on the inflation halo the layout already reserves. That keeps the B.5
//! inflation maths, and its tests, untouched and still correct: a shadow
//! cannot spill outside the region reserved for it.
//!
//! `spread` (0..0.95, default 0) is Photoshop's Spread, read cheaply: the
//! blurred alpha is divided by `1 - spread` and clipped, which lifts the
//! falloff and fattens the core. At 0 it is the identity.
//!
//! `color` is authored straight (`#000a` is black at 62.5%) and
//! premultiplied here, because the shader multiplies the tint by a scalar
//! coverage and the pipeline blends premultiplied. B.5 passed it through
//! straight, which was invisible for a black shadow — `rgb * a == rgb`
//! when rgb is 0 — and would have made any coloured shadow too bright.
//!
//! ## Inflation
//!
//! Unchanged from B.5, and still the layout invariant: the returned box IS
//! the GPU target size, so the walker's `target_size` and the layout's
//! reserved region cannot drift.
//!
//!     left   = blur - min(0, offset_x)
//!     right  = blur + max(0, offset_x)
//!     top    = blur - min(0, offset_y)
//!     bottom = blur + max(0, offset_y)

const std = @import("std");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const element = @import("../../element.zig");
const element_layout = @import("../../element_layout.zig");
const markdown = @import("../../markdown.zig");
const params = @import("../../params.zig");
const spark_mod = @import("../../spark.zig");
const shader_resolver = @import("../../pass/shader_resolver.zig");

pub const Error = error{
    DropShadowShaderNotRegistered,
};

const BLUR_SHADER: component_mod.ShaderId = shader_resolver.shaderIdFromName("gaussian_alpha.frag");
const COMPOSITE_SHADER: component_mod.ShaderId = shader_resolver.shaderIdFromName("copy.frag");

/// Three sigma is the kernel's practical width, so a `blur` of N pixels is
/// a sigma of N/3 and the shadow dies exactly at the halo the layout
/// reserved. Naming the constant keeps the shader, the inflation maths and
/// this comment from drifting apart.
const SIGMA_PER_BLUR: f32 = 1.0 / 3.0;

/// std140-compatible uniform block for `shaders/gaussian_alpha.frag`.
///
///   direction : vec2  —  0..8    axis of this pass, in texels
///   offset    : vec2  —  8..16   shadow displacement, pixels
///   channel   : vec4  — 16..32   dot mask selecting the channel to blur
///   tint      : vec4  — 32..48   premultiplied output colour
///   sigma     : f32   — 48..52
///   spread    : f32   — 52..56
const GaussianUniforms = extern struct {
    direction: [2]f32,
    offset: [2]f32,
    channel: [4]f32,
    tint: [4]f32,
    sigma: f32,
    spread: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

/// `copy.frag`'s push-constant block: one float, and we want it at 1.0.
const CopyUniforms = extern struct {
    alpha: f32 = 1.0,
};

/// Read straight off the spec, before anything is premultiplied or
/// converted to sigma. Kept as a struct so `create` and `update` cannot
/// disagree about defaults.
const Attrs = struct {
    offset: [2]f32,
    blur: f32,
    spread: f32,
    /// Straight (non-premultiplied) RGBA, as authored.
    color: [4]f32,

    fn read(spec: *const components.Spec) Attrs {
        return .{
            .offset = .{
                params.resolve(f32, spec, "offset_x", 4.0),
                params.resolve(f32, spec, "offset_y", 4.0),
            },
            .blur = @max(0, params.resolve(f32, spec, "blur", 8.0)),
            .spread = std.math.clamp(params.resolve(f32, spec, "spread", 0.0), 0.0, 0.95),
            .color = params.resolve([4]f32, spec, "color", .{ 0, 0, 0, 0.5 }),
        };
    }
};

/// The load-bearing inflation math. Separate from the spec-driven wrapper
/// so unit tests can exercise it directly without constructing a Spec.
fn computeInflation(offset_x: f32, offset_y: f32, blur: f32) component_mod.Edges {
    return .{
        .left = blur - @min(@as(f32, 0), offset_x),
        .right = blur + @max(@as(f32, 0), offset_x),
        .top = blur - @min(@as(f32, 0), offset_y),
        .bottom = blur + @max(@as(f32, 0), offset_y),
    };
}

fn computeInflationFromSpec(spec: *const components.Spec) component_mod.Edges {
    const a = Attrs.read(spec);
    return computeInflation(a.offset[0], a.offset[1], a.blur);
}

/// Straight RGBA → premultiplied. The shader scales this by a scalar
/// coverage and the pipeline blends premultiplied; handing it straight
/// colour makes a coloured shadow glow.
fn premultiply(c: [4]f32) [4]f32 {
    const a = std.math.clamp(c[3], 0, 1);
    return .{ c[0] * a, c[1] * a, c[2] * a, a };
}

/// Zero the whole slot before copying. The uniform block is hashed whole by
/// the frame fingerprint, so uninitialised tail bytes would make an
/// otherwise-identical frame hash differently run to run.
fn writeUniforms(out: *[element.MAX_PASS_UNIFORM_BYTES]u8, bytes: []const u8) void {
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
}

/// The three steps, written into the instance's own scratch.
///
/// Called from `snapshot_chain_steps` on every walk.
fn buildSteps(steps: *[3]element.ChainPassStep, a: Attrs) void {
    const sigma = @max(a.blur * SIGMA_PER_BLUR, 0.0);

    // Step 0 — horizontal, over the child's alpha, shifted by the offset.
    // Output is greyscale coverage in every channel so the second pass can
    // read RED: a 10-bit HDR swapchain gives alpha two bits, and a shadow
    // stored there comes back as four steps of banding.
    const h = GaussianUniforms{
        .direction = .{ 1, 0 },
        .offset = a.offset,
        .channel = .{ 0, 0, 0, 1 },
        .tint = .{ 1, 1, 1, 1 },
        .sigma = sigma,
        .spread = 0,
    };
    steps[0] = .{
        .composite_shader_id = BLUR_SHADER,
        .source_pool_local = 0,
        .dest_pool_local = 1,
        .load = .clear,
        .uniform_len = @sizeOf(GaussianUniforms),
    };
    writeUniforms(&steps[0].uniform_bytes, std.mem.asBytes(&h));

    // Step 1 — vertical, over that greyscale, spread and tinted. No offset:
    // it was spent on the horizontal pass, and spending it twice would move
    // the shadow diagonally by double what the author wrote.
    const v = GaussianUniforms{
        .direction = .{ 0, 1 },
        .offset = .{ 0, 0 },
        .channel = .{ 1, 0, 0, 0 },
        .tint = premultiply(a.color),
        .sigma = sigma,
        .spread = a.spread,
    };
    steps[1] = .{
        .composite_shader_id = BLUR_SHADER,
        .source_pool_local = 1,
        .dest_pool_local = 2,
        .load = .clear,
        .uniform_len = @sizeOf(GaussianUniforms),
    };
    writeUniforms(&steps[1].uniform_bytes, std.mem.asBytes(&v));

    // Step 2 — the child, back over its own shadow. `.keep` is what makes
    // this a composite rather than a filter.
    const copy = CopyUniforms{};
    steps[2] = .{
        .composite_shader_id = COMPOSITE_SHADER,
        .source_pool_local = 0,
        .dest_pool_local = 2,
        .load = .keep,
        .uniform_len = @sizeOf(CopyUniforms),
    };
    writeUniforms(&steps[2].uniform_bytes, std.mem.asBytes(&copy));
}

const Component = struct {
    arena: std.heap.ArenaAllocator,
    root: element.Element,
    scope: []u8,
    spark: ?*spark_mod.Spark = null,
    inflation: component_mod.Edges,
    attrs: Attrs,
    version: u64 = 0,
    body: component_mod.Body = .{},
    /// Per-instance scratch the chain hook returns a slice into. Owned by
    /// the instance (registry allocator), rewritten on each walk, read by
    /// the walker before the next one — the single-writer-per-frame
    /// invariant `snapshot_chain_steps` documents.
    steps: [3]element.ChainPassStep = undefined,
    /// The pool format, resolved at create-time. The component decides the
    /// format; the walker consumes what it is handed.
    target_format: u32 = 0,
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .pass_shape = .{ .chain = .{
        .max_steps = 3,
        .final_composite_shader_id = COMPOSITE_SHADER,
        // LDR throughout: the shadow is a coverage mask tinted by an
        // authored colour, and both live happily in the swapchain format.
        // The v1 target pool keys on `(w, h, spark.color_format)` anyway,
        // so asking for RGBA16F here would be a promise nothing keeps.
        .hdr_target = false,
        .layout_inflation = component_mod.LayoutInflationSpec{ .from_params = computeInflationFromSpec },
    } },
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("drop_shadow", factory);
}

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    // Fail fast, at create, while there is a document position to blame —
    // a missing shader discovered inside a command-buffer walk is a
    // silently-skipped effect.
    _ = spark.shader_resolver.resolve(BLUR_SHADER) catch return Error.DropShadowShaderNotRegistered;
    _ = spark.shader_resolver.resolve(COMPOSITE_SHADER) catch return Error.DropShadowShaderNotRegistered;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const id_raw = spec.id orelse "drop_shadow";
    const attrs = Attrs.read(spec);

    c.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .spark = spark,
        .inflation = computeInflation(attrs.offset[0], attrs.offset[1], attrs.blur),
        .attrs = attrs,
        .version = 0,
        .body = .{},
        .steps = undefined,
        .target_format = @intCast(spark.color_format),
    };
    errdefer c.arena.deinit();

    c.scope = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(c.scope);

    _ = c.body.adopt(spec.body);
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
    // Decision #8: inflation resolves ONCE at create. update() touches only
    // the attributes that fit inside the reserved edge — animating a
    // shadow's colour or spread is free; growing its blur needs a recreate
    // via an #id change, because the halo is already in the layout.
    c.attrs = Attrs.read(spec);
    c.version = prev_version +% 1;

    // The body is authored text too, and a hot-reloaded document hands the
    // same `#id` a new one. See `component.Body`.
    if (c.body.adopt(spec.body)) {
        if (c.spark) |sp| {
            // The block-layout cache is keyed by element ADDRESS, and an
            // arena reset hands the new tree the old one's addresses.
            sp.layout_cache.clear();
            c.root = element.Element{ .paragraph = &[_]element.Element{} };
            _ = c.arena.reset(.retain_capacity);
            c.root = try markdown.parseWithStateAndScope(
                c.arena.allocator(),
                spec.body,
                sp.theme,
                sp.registry,
                sp.host_state,
                c.scope,
            );
        }
    }
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (c.spark) |sp| sp.registry.deinitScope(c.scope);
    c.arena.deinit();
    allocator.free(c.scope);
    allocator.destroy(c);
}

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

/// The mandatory per-element uniform hook. For a chain it is the FINAL
/// composite's push constants — the one draw this element contributes to
/// MAIN — which is why it is `copy.frag`'s single alpha and not a blur's.
/// The per-step uniforms travel on the steps themselves.
fn snapshotUniforms(ctx: *anyopaque, out: []u8) usize {
    _ = ctx;
    const copy = CopyUniforms{};
    const bytes = std.mem.asBytes(&copy);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    return bytes.len;
}

fn snapshotChainSteps(ctx: *anyopaque, target_size: [2]u32) element.ChainHookResult {
    _ = target_size; // the pool is sized from the element's box by the walker
    const c: *Component = @ptrCast(@alignCast(ctx));
    buildSteps(&c.steps, c.attrs);
    return .{
        .steps = c.steps[0..],
        .target_format = c.target_format,
        .target_pool_count = 3,
        .final_pool_local = 2,
    };
}

/// Walk the child subtree at the inflated origin with inflated constraints,
/// return the inflated box. The walker reads `box.{w,h}` as the chain
/// dispatch's `target_size`, so the returned box IS the GPU target size.
fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const inf = c.inflation;

    var child_constraints = constraints;
    if (std.math.isFinite(child_constraints.max_w)) {
        child_constraints.max_w = @max(0, child_constraints.max_w - inf.left - inf.right);
    }
    if (std.math.isFinite(child_constraints.max_h)) {
        child_constraints.max_h = @max(0, child_constraints.max_h - inf.top - inf.bottom);
    }

    const child_box = try element_layout.layoutAndRenderCached(
        c.root,
        .{ origin[0] + inf.left, origin[1] + inf.top },
        child_constraints,
        lc,
        out,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = child_box.w + inf.left + inf.right,
        .h = child_box.h + inf.top + inf.bottom,
        .baseline = 0,
    };
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .snapshot_uniforms = snapshotUniforms,
    .snapshot_chain_steps = snapshotChainSteps,
    .content_version = contentVersion,
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// `uniform_bytes` is a byte array with no alignment guarantee, so it is
/// COPIED out rather than pointer-cast — an `@alignCast` here panics, which
/// is a test failing for a reason that has nothing to do with the effect.
fn readGaussian(step: element.ChainPassStep) GaussianUniforms {
    var out: GaussianUniforms = undefined;
    @memcpy(std.mem.asBytes(&out), step.uniform_bytes[0..@sizeOf(GaussianUniforms)]);
    return out;
}

test "GaussianUniforms: std140 layout offsets" {
    // Lock-in test. These offsets ARE the GLSL push_constant block's
    // contract; an "innocent" field reorder that compiles cleanly would
    // push misaligned uniforms to the GPU and render garbage. See
    // [[feedback-std140-offset-lockin]] — the explicit per-effect test is
    // the load-bearing part, and a generator cannot supply it.
    try testing.expectEqual(@as(usize, 0), @offsetOf(GaussianUniforms, "direction"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(GaussianUniforms, "offset"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(GaussianUniforms, "channel"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(GaussianUniforms, "tint"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(GaussianUniforms, "sigma"));
    try testing.expectEqual(@as(usize, 52), @offsetOf(GaussianUniforms, "spread"));
    try testing.expectEqual(@as(usize, 64), @sizeOf(GaussianUniforms));
    try testing.expect(@sizeOf(GaussianUniforms) <= element.MAX_PASS_UNIFORM_BYTES);
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

test "factory: pass_shape is .chain, three steps, composite shader named" {
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .chain),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .chain => |ch| {
            try testing.expectEqual(@as(u16, 3), ch.max_steps);
            try testing.expect(ch.max_steps <= element.MAX_CHAIN_STEPS);
            try testing.expectEqualSlices(u8, &COMPOSITE_SHADER, &ch.final_composite_shader_id);
            const li = ch.layout_inflation orelse return error.MissingInflationSpec;
            try testing.expectEqual(
                @as(std.meta.Tag(component_mod.LayoutInflationSpec), .from_params),
                std.meta.activeTag(li),
            );
        },
        else => unreachable,
    }
}

test "steps: two blurs that clear, then one composite that keeps" {
    // The shape of the whole effect, asserted where it is cheap. Each
    // clause below is a thing that would render a plausible-looking wrong
    // picture if it flipped, and none of them would fail to compile.
    var steps: [3]element.ChainPassStep = undefined;
    buildSteps(&steps, .{
        .offset = .{ 4, 6 },
        .blur = 9,
        .spread = 0.25,
        .color = .{ 1, 0, 0, 0.5 },
    });

    // Ping-pong: 0→1, 1→2, and finally 0 over 2.
    try testing.expectEqual(@as(u16, 0), steps[0].source_pool_local);
    try testing.expectEqual(@as(u16, 1), steps[0].dest_pool_local);
    try testing.expectEqual(@as(u16, 1), steps[1].source_pool_local);
    try testing.expectEqual(@as(u16, 2), steps[1].dest_pool_local);
    try testing.expectEqual(@as(u16, 0), steps[2].source_pool_local);
    try testing.expectEqual(@as(u16, 2), steps[2].dest_pool_local);

    // The two filters own their targets; the composite does not. A
    // composite that cleared would erase the shadow it is being laid over,
    // and the picture would be the child with no shadow at all — which
    // reads as "the effect is off", not as "one enum is wrong".
    try testing.expectEqual(element.ChainLoad.clear, steps[0].load);
    try testing.expectEqual(element.ChainLoad.clear, steps[1].load);
    try testing.expectEqual(element.ChainLoad.keep, steps[2].load);

    const h = readGaussian(steps[0]);
    const v = readGaussian(steps[1]);

    // Separable, and on different axes — the same axis twice is a blur
    // that smears in one direction and looks like motion, not a shadow.
    try testing.expectEqual(@as(f32, 1), h.direction[0]);
    try testing.expectEqual(@as(f32, 0), h.direction[1]);
    try testing.expectEqual(@as(f32, 0), v.direction[0]);
    try testing.expectEqual(@as(f32, 1), v.direction[1]);

    // The offset is spent exactly once.
    try testing.expectEqual(@as(f32, 4), h.offset[0]);
    try testing.expectEqual(@as(f32, 6), h.offset[1]);
    try testing.expectEqual(@as(f32, 0), v.offset[0]);
    try testing.expectEqual(@as(f32, 0), v.offset[1]);

    // Pass one reads alpha, pass two reads red. Reading alpha twice costs
    // nothing on an 8-bit swapchain and destroys the shadow on a 10-bit
    // one, where alpha is two bits — a bug that reproduces on one machine
    // and not the next.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1 }, &h.channel);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 0 }, &v.channel);

    // Spread is applied once, after the blur, on the tinted pass.
    try testing.expectEqual(@as(f32, 0), h.spread);
    try testing.expectEqual(@as(f32, 0.25), v.spread);

    // Sigma is blur/3, so three sigma lands on the inflation halo.
    try testing.expectApproxEqAbs(@as(f32, 3), v.sigma, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 9), v.sigma * 3, 1e-5);

    // The tint reaches the GPU premultiplied. Straight red at 50% would
    // arrive as (1, 0, 0, 0.5) and blend twice as bright as authored.
    try testing.expectApproxEqAbs(@as(f32, 0.5), v.tint[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), v.tint[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), v.tint[3], 1e-6);
}

test "steps: a black shadow is the case premultiplication hides in" {
    // Rule 1 for the assertion above. `premultiply` on the DEFAULT colour
    // changes nothing at all — black times anything is black — so a gate
    // that only ever used the default would pass against no
    // premultiplication whatsoever.
    const black = premultiply(.{ 0, 0, 0, 0.5 });
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0.5 }, &black);
    const white = premultiply(.{ 1, 1, 1, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), white[0], 1e-6);
}

test "steps: the tail of every uniform slot is zeroed" {
    // The frame fingerprint hashes the whole `uniform_bytes` array, so a
    // slot left `undefined` past the struct makes two identical frames hash
    // differently — a determinism failure that reads as a rendering bug.
    var steps: [3]element.ChainPassStep = undefined;
    buildSteps(&steps, .{ .offset = .{ 1, 2 }, .blur = 4, .spread = 0, .color = .{ 0, 0, 0, 1 } });
    for (steps) |s| {
        for (s.uniform_bytes[s.uniform_len..]) |b| try testing.expectEqual(@as(u8, 0), b);
    }
}

test "steps: blur is clamped at zero, and a zero blur still emits a chain" {
    // `blur=-4` is a typo, not a request to invert the kernel. Sigma goes
    // to zero, the shader clamps it, and the shadow collapses to a hard
    // offset copy — which is a picture, rather than a hang or a NaN.
    var steps: [3]element.ChainPassStep = undefined;
    buildSteps(&steps, .{ .offset = .{ 0, 0 }, .blur = 0, .spread = 0, .color = .{ 0, 0, 0, 1 } });
    const h = readGaussian(steps[0]);
    try testing.expectEqual(@as(f32, 0), h.sigma);
    try testing.expectEqual(@as(u32, @sizeOf(GaussianUniforms)), steps[0].uniform_len);
}
