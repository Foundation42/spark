//! `:::frosted_glass` — the child's content, softened by a real Gaussian
//! blur, behind a tinted wash. The modern-OS panel look.
//!
//! ## What changed, and why it had to
//!
//! Phase B.6 shipped this as a single_source filter with a 9-tap box blur:
//! three taps per axis, separated by the whole blur radius. Its own header
//! said "matches drop_shadow's tap shape" — which is exactly the tap shape
//! that turned out to produce nine legible ghosts rather than a blur, found
//! in a capture of matryoshka's Lab and fixed in `:::drop_shadow` at C.2.
//! The shape was wrong in both places; only one of them had been looked at.
//!
//! It read as less obviously broken here because the thing being ghosted is
//! usually a flat panel, where three copies of a flat colour is that colour.
//! Put text or a pattern behind it at `blur=28` — which `src/effect.md`
//! does — and the same triple image comes back.
//!
//! A Gaussian of radius R is O(R²) samples done directly and O(R) done as
//! two 1D passes, so it is two images, so it is a chain. The kernel is
//! shared with the drop shadow's ([[gaussian]], `shaders/gaussian.glsl`);
//! what differs is the ending, and that is the whole reason there are two
//! blur shaders rather than one with a mode flag.
//!
//! ## The chain, in two steps and two pool targets
//!
//! `pool[0]` arrives holding the rendered child (C.1.5 renders the subtree
//! into it before `steps[]` run). Then:
//!
//! ```text
//!   step 0   pool[0] --  horizontal gaussian, all four channels
//!                    --> pool[1]      (clear, no tint)
//!   step 1   pool[1] --  vertical gaussian, then the wash laid over
//!                    --> pool[0]      (clear — the child is spent)
//!   phase 2  pool[0] --> MAIN at compose_region
//! ```
//!
//! **This is the first chain that actually ping-pongs.** `:::drop_shadow`
//! needs the untouched child for its last step, so it runs 0→1→2 and every
//! destination is fresh. Here the child has no further use once the
//! horizontal pass has read it, so the vertical pass writes back over it and
//! the effect costs two full-panel RGBA16F targets instead of three. That
//! only became safe when `recordChainStep`'s clear-path barrier started
//! waiting on the fragment stage — see the note there; it named
//! TOP_OF_PIPE, which waits for nothing, and a write-after-read against a
//! target the previous step was still sampling is precisely the hazard.
//!
//! **The tint rides on the vertical pass**, not on a third step. Premultiplied
//! "over" with an all-zero source is the identity, so the horizontal pass
//! carries a zero tint and the same shader serves both.
//!
//! ## Attribute grammar
//!
//!     :::frosted_glass {blur=12 tint=#ffffff10}
//!       :::box {color=teal width=160 height=80 radius=8}
//!         Tools panel
//!       :::
//!     :::
//!
//! `blur` is the softness's REACH in pixels; sigma is `blur / 3` via
//! [[gaussian]]`.sigmaFor`, the same conversion the drop shadow uses, so the
//! word means one thing across effects. Default 12.
//!
//! `tint` defaults to `#ffffff10` — white at 6.25%. The modern-OS panel look
//! sits in the 5–15% range. It is authored STRAIGHT and premultiplied here,
//! because the chain blends premultiplied end to end.
//!
//! ## No inflation, and why that is not the shadow's answer
//!
//! A drop shadow inflates its layout box because the shadow falls OUTSIDE
//! the child and needs somewhere to land. A blur does not grow the panel —
//! it stays exactly where the author put it. The effect sampler is
//! CLAMP_TO_EDGE, so taps that reach past the target's edge repeat the edge
//! texel rather than pulling in the cleared border, and the panel's own
//! edges stay solid instead of fading out. An author who wants a soft edge
//! asks for one by wrapping in `:::box`.
//!
//! ## `{backdrop}` — blurring what is BEHIND the panel
//!
//! By default the blur is of the CHILD's content: wrap a pattern, get a
//! blurred pattern. `{backdrop}` inverts that. pool[0] stops being a render
//! of the children and becomes a COPY of the region of the host's attachment
//! the panel covers, so the effect blurs the scene behind it, and the
//! children are left on MAIN to be drawn over the result — sharp.
//!
//!     :::frosted_glass {backdrop blur=24 tint=#0b122870}
//!     ### Exposure
//!     :::slider {target=exposure min=0.1 max=4 value=${state.exposure}}
//!     :::
//!     :::
//!
//! The layering costs nothing: Phase 2 records every pass composite before
//! any MAIN drawlist primitive, which is the same reason `:::pattern` is a
//! background. See `element.ChainSource` for what a backdrop can and cannot
//! see, and `Spark.fillPoolZeroFromMain` for why the copy is legal only in
//! Phase 1.
//!
//! Resolve-once, like inflation: `blur` and `tint` animate freely through
//! `update`, but flipping `backdrop` needs a new instance (an `#id` change),
//! because the walker has already routed this frame's children by the time
//! anything could change its mind.
//!
//! `:::liquid_glass` still refracts only its own content — the same limit
//! this used to document, now true of one effect rather than two.

const std = @import("std");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const element = @import("../../element.zig");
const layout_cache = @import("../../layout_cache.zig");
const element_layout = @import("../../element_layout.zig");
const gaussian = @import("gaussian.zig");
const markdown = @import("../../markdown.zig");
const params = @import("../../params.zig");
const spark_mod = @import("../../spark.zig");
const shader_resolver = @import("../../pass/shader_resolver.zig");

pub const Error = error{
    FrostedGlassShaderNotRegistered,
};

const BLUR_SHADER = gaussian.RGBA_SHADER;
const COMPOSITE_SHADER: component_mod.ShaderId = shader_resolver.shaderIdFromName("copy.frag");

/// `copy.frag`'s push-constant block: one float, and we want it at 1.0.
const CopyUniforms = extern struct {
    alpha: f32 = 1.0,
};

/// Read straight off the spec, before anything is premultiplied or converted
/// to sigma. Kept as a struct so `create` and `update` cannot disagree about
/// defaults.
const Attrs = struct {
    blur: f32,
    /// Straight (non-premultiplied) RGBA, as authored.
    tint: [4]f32,
    /// `backdrop` — blur what is BEHIND the panel instead of what is inside
    /// it, and let the children draw on top, sharp. The macOS/iOS look.
    backdrop: bool,

    fn read(spec: *const components.Spec) Attrs {
        return .{
            .blur = @max(0, params.resolve(f32, spec, "blur", 12.0)),
            .tint = params.resolve([4]f32, spec, "tint", .{ 1, 1, 1, 0.0625 }),
            .backdrop = readFlag(spec, "backdrop"),
        };
    }
};

/// A bare `{backdrop}` means true, `{backdrop=false}` means false, and an
/// absent one means false.
///
/// `params.resolve` cannot express this: a valueless attribute trims to the
/// empty string, which it reports as "unparseable" and answers with the
/// caller's default — so `{backdrop}` read as OFF and the panel silently
/// blurred its own children instead. Presence is the signal for a flag, and
/// only a flag; every other attribute here stays `key=value`.
fn readFlag(spec: *const components.Spec, key: []const u8) bool {
    for (spec.attrs) |a| {
        if (!std.mem.eql(u8, a.key, key)) continue;
        const t = std.mem.trim(u8, a.value, " \t");
        if (t.len == 0) return true; // bare — presence is the value
        return params.resolve(bool, spec, key, false);
    }
    return false;
}

/// The two steps, written into the instance's own scratch.
///
/// Called from `snapshot_chain_steps` on every walk.
fn buildSteps(steps: *[2]element.ChainPassStep, a: Attrs) void {
    const sigma = gaussian.sigmaFor(a.blur);

    // Step 0 — horizontal. No tint: an all-zero premultiplied source is the
    // identity of "over", so the wash can wait for the second pass. Applying
    // it on both would lay it down twice and darken the panel by more than
    // the author asked for — a plausible-looking picture, wrong by a square.
    const h = gaussian.RgbaUniforms{
        .direction = .{ 1, 0 },
        .tint = .{ 0, 0, 0, 0 },
        .sigma = sigma,
    };
    steps[0] = .{
        .composite_shader_id = BLUR_SHADER,
        .source_pool_local = 0,
        .dest_pool_local = 1,
        .load = .clear,
        .uniform_len = @sizeOf(gaussian.RgbaUniforms),
    };
    gaussian.writeUniforms(&steps[0].uniform_bytes, std.mem.asBytes(&h));

    // Step 1 — vertical, back over pool[0], with the wash. The child in
    // pool[0] has been read by step 0 and is not needed again.
    const v = gaussian.RgbaUniforms{
        .direction = .{ 0, 1 },
        .tint = gaussian.premultiply(a.tint),
        .sigma = sigma,
    };
    steps[1] = .{
        .composite_shader_id = BLUR_SHADER,
        .source_pool_local = 1,
        .dest_pool_local = 0,
        .load = .clear,
        .uniform_len = @sizeOf(gaussian.RgbaUniforms),
    };
    gaussian.writeUniforms(&steps[1].uniform_bytes, std.mem.asBytes(&v));
}

const Component = struct {
    arena: std.heap.ArenaAllocator,
    root: element.Element,
    scope: []u8,
    spark: ?*spark_mod.Spark = null,
    attrs: Attrs,
    version: u64 = 0,
    body: component_mod.Body = .{},
    /// Per-instance scratch the chain hook returns a slice into. Owned by the
    /// instance (registry allocator), rewritten on each walk, read by the
    /// walker before the next one — the single-writer-per-frame invariant
    /// `snapshot_chain_steps` documents.
    steps: [2]element.ChainPassStep = undefined,
    /// The pool format, read at create-time from the Spark. One answer per
    /// Spark, because a chain and a single_source nested inside it render
    /// through pipelines built for one format and cannot disagree.
    target_format: u32 = 0,
    /// Resolve-once, like inflation. `update` may animate blur and tint
    /// freely; flipping `backdrop` needs a new instance (an `#id` change),
    /// because the walker has already routed this frame's children.
    source: element.ChainSource = .subtree,
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .pass_shape = .{ .chain = .{
        .max_steps = 2,
        .final_composite_shader_id = COMPOSITE_SHADER,
        // No inflation — a blur does not grow the panel. See the header.
        .layout_inflation = null,
    } },
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("frosted_glass", factory);
}

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    // Fail fast, at create, while there is a document position to blame — a
    // missing shader discovered inside a command-buffer walk is a silently
    // skipped effect.
    _ = spark.shader_resolver.resolve(BLUR_SHADER) catch return Error.FrostedGlassShaderNotRegistered;
    _ = spark.shader_resolver.resolve(COMPOSITE_SHADER) catch return Error.FrostedGlassShaderNotRegistered;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const id_raw = spec.id orelse "frosted_glass";

    c.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .spark = spark,
        .attrs = Attrs.read(spec),
        .version = 0,
        .body = .{},
        .steps = undefined,
        .target_format = @intCast(spark.offscreen_format),
        .source = if (Attrs.read(spec).backdrop) .backdrop else .subtree,
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
    // Fold in the children. Without this an interactive control inside the
    // effect is frozen at its create-time value: the effect's cached
    // drawlist is replayed because its own version never moved, so a slider
    // drives the plane and never draws its own new position. See
    // `layout_cache.aggregateRootVersion`.
    return c.version ^ layout_cache.aggregateRootVersion(c.root);
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
        .target_pool_count = 2,
        .final_pool_local = 0,
        .source = c.source,
    };
}

/// Answered BEFORE layout — see `ElementVTable.chain_source`. Resolved once
/// at create, in the spirit of Decision #8: the walker asks this to decide
/// where the children's drawlist primitives go, and Phase 1 asks the step
/// hook where pool[0] comes from. If the two could disagree within a frame,
/// the children would render into a target nothing composites.
fn chainSource(ctx: *anyopaque) element.ChainSource {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.source;
}

/// No inflation: the child's box IS the effect's box, and the walker reads
/// `box.{w,h}` as the chain dispatch's `target_size`.
fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    return element_layout.layoutAndRenderCached(c.root, origin, constraints, lc, out);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .snapshot_uniforms = snapshotUniforms,
    .snapshot_chain_steps = snapshotChainSteps,
    .chain_source = chainSource,
    .content_version = contentVersion,
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn readRgba(step: element.ChainPassStep) gaussian.RgbaUniforms {
    return gaussian.readUniforms(gaussian.RgbaUniforms, step);
}

test "factory: pass_shape is .chain, two steps, no inflation" {
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .chain),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .chain => |ch| {
            try testing.expectEqual(@as(u16, 2), ch.max_steps);
            try testing.expect(ch.max_steps <= element.MAX_CHAIN_STEPS);
            try testing.expectEqualSlices(u8, &COMPOSITE_SHADER, &ch.final_composite_shader_id);
            // A blur does not grow the panel. Inflating would move every
            // sibling in the document, which is a layout change wearing a
            // rendering change's clothes.
            try testing.expect(ch.layout_inflation == null);
        },
        else => unreachable,
    }
}

test "steps: two axes, and the second writes back over the child" {
    // The shape of the whole effect, asserted where it is cheap. Each clause
    // below would render a plausible-looking wrong picture if it flipped,
    // and none of them would fail to compile.
    var steps: [2]element.ChainPassStep = undefined;
    buildSteps(&steps, .{ .blur = 12, .tint = .{ 1, 0, 0, 0.5 }, .backdrop = false });

    // The ping-pong: 0→1, then 1→0. This is the property that separates
    // this chain from the drop shadow's, and it is what
    // `recordChainStep`'s clear-path barrier has to wait on the fragment
    // stage for. A step writing a target the previous step is still
    // sampling is a write-after-read hazard.
    try testing.expectEqual(@as(u16, 0), steps[0].source_pool_local);
    try testing.expectEqual(@as(u16, 1), steps[0].dest_pool_local);
    try testing.expectEqual(@as(u16, 1), steps[1].source_pool_local);
    try testing.expectEqual(@as(u16, 0), steps[1].dest_pool_local);

    // Both are filters that own their destination. A `.keep` here would
    // composite this frame's blur over the last one still resident in a
    // recycled pool target — a smear that only shows up on the second frame.
    try testing.expectEqual(element.ChainLoad.clear, steps[0].load);
    try testing.expectEqual(element.ChainLoad.clear, steps[1].load);

    const h = readRgba(steps[0]);
    const v = readRgba(steps[1]);

    // Separable, and on different axes — the same axis twice is a blur that
    // smears in one direction and reads as motion, not as glass.
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, &h.direction);
    try testing.expectEqualSlices(f32, &.{ 0, 1 }, &v.direction);

    // Same sigma on both passes: a separable Gaussian is only a Gaussian if
    // the two axes match, and blur=12 is a sigma of 4.
    try testing.expectApproxEqAbs(@as(f32, 4), h.sigma, 1e-5);
    try testing.expectApproxEqAbs(h.sigma, v.sigma, 1e-6);

    // The wash is laid down exactly ONCE, on the vertical pass. An all-zero
    // premultiplied tint is the identity of "over", so a horizontal pass
    // that also carried it would darken the panel by the square of what the
    // author wrote.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &h.tint);

    // And it reaches the GPU premultiplied. Straight red at 50% would arrive
    // as (1, 0, 0, 0.5) against a premultiplied blend and wash twice as hot.
    try testing.expectApproxEqAbs(@as(f32, 0.5), v.tint[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), v.tint[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), v.tint[3], 1e-6);
}

test "steps: the default wash is nearly invisible, which is why it is not the gate" {
    // Rule 1 for the premultiply assertion above. The DEFAULT tint is white
    // at 6.25%, where premultiplying changes 1.0 to 0.0625 — a real change,
    // but one that still looks like "a faint white wash" either way on
    // screen. The saturated case above is the one that fails loudly.
    var steps: [2]element.ChainPassStep = undefined;
    buildSteps(&steps, Attrs{ .blur = 12, .tint = .{ 1, 1, 1, 0.0625 }, .backdrop = false });
    const v = readRgba(steps[1]);
    try testing.expectApproxEqAbs(@as(f32, 0.0625), v.tint[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0625), v.tint[3], 1e-6);
}

test "steps: blur is clamped at zero, and a zero blur still emits a chain" {
    // `blur=-4` is a typo, not a request to invert the kernel. Sigma goes to
    // zero, the shader clamps it, and the panel comes through sharp — which
    // is a picture, rather than a hang or a NaN.
    var steps: [2]element.ChainPassStep = undefined;
    buildSteps(&steps, .{ .blur = -4, .tint = .{ 1, 1, 1, 0.0625 }, .backdrop = false });
    try testing.expectEqual(@as(f32, 0), readRgba(steps[0]).sigma);
    try testing.expectEqual(@as(u32, @sizeOf(gaussian.RgbaUniforms)), steps[0].uniform_len);
}

test "steps: uniform_len names exactly the bytes that were written" {
    // What this watches is the AGREEMENT between `uniform_len` and the block
    // actually copied in — see the same gate in `drop_shadow.zig`, and the
    // poisoned-slot gate in [[gaussian]] for `writeUniforms` itself.
    var steps: [2]element.ChainPassStep = undefined;
    buildSteps(&steps, .{ .blur = 8, .tint = .{ 0, 0, 0, 1 }, .backdrop = false });
    for (steps) |s| {
        for (s.uniform_bytes[s.uniform_len..]) |b| try testing.expectEqual(@as(u8, 0), b);
    }
}

test "backdrop: bare flag, explicit value, and absent" {
    // `{backdrop}` with no value is how an author naturally writes a flag,
    // and it is what this file's own docstring shows. `params.resolve`
    // answers `false` for it — an empty value is unparseable, so it returns
    // the default — which made the attribute silently do nothing.
    const bare = [_]components.Attr{.{ .key = "backdrop", .value = "" }};
    try testing.expect(readFlag(&components.Spec{ .name = "frosted_glass", .attrs = &bare }, "backdrop"));

    // Rule 1: an explicit false must still be false, or "presence means
    // true" would have swallowed it.
    const off = [_]components.Attr{.{ .key = "backdrop", .value = "false" }};
    try testing.expect(!readFlag(&components.Spec{ .name = "frosted_glass", .attrs = &off }, "backdrop"));

    const on = [_]components.Attr{.{ .key = "backdrop", .value = "true" }};
    try testing.expect(readFlag(&components.Spec{ .name = "frosted_glass", .attrs = &on }, "backdrop"));

    const none = [_]components.Attr{.{ .key = "blur", .value = "12" }};
    try testing.expect(!readFlag(&components.Spec{ .name = "frosted_glass", .attrs = &none }, "backdrop"));
}

test "backdrop: the chain reports where pool[0] comes from" {
    // Two hooks must agree, and they are asked at different times: the
    // walker calls `chain_source` BEFORE layout to decide where the
    // children's drawlist primitives go, and Phase 1 reads
    // `ChainHookResult.source` to decide how to fill pool[0]. If they could
    // disagree, the children would render into a target nothing composites
    // — an empty panel, with no error anywhere.
    var c = Component{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .attrs = .{ .blur = 12, .tint = .{ 1, 1, 1, 0.0625 }, .backdrop = true },
        .steps = undefined,
        .source = .backdrop,
    };
    defer c.arena.deinit();

    try testing.expectEqual(element.ChainSource.backdrop, chainSource(@ptrCast(&c)));
    try testing.expectEqual(element.ChainSource.backdrop, snapshotChainSteps(@ptrCast(&c), .{ 100, 100 }).source);

    // Rule 1: the default must be the other value, or "it reports backdrop"
    // is a statement about a field that is always backdrop.
    c.source = .subtree;
    try testing.expectEqual(element.ChainSource.subtree, chainSource(@ptrCast(&c)));
    try testing.expectEqual(element.ChainSource.subtree, snapshotChainSteps(@ptrCast(&c), .{ 100, 100 }).source);
}
