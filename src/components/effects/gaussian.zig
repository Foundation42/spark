//! The host side of `shaders/gaussian.glsl` — what every blurring effect
//! shares, so that `blur` means one thing across all of them.
//!
//! There are two blur shaders, differing only in what they do with the
//! blurred value:
//!
//!   * `gaussian_alpha.frag` reduces four channels to a coverage via a
//!     dot-product mask and multiplies a tint by it. A shadow is one colour
//!     at varying opacity. [[AlphaUniforms]]
//!   * `gaussian_rgba.frag` keeps the colour it sampled and lays a tint over
//!     it. Frosted glass is the content, softened, behind a wash.
//!     [[RgbaUniforms]]
//!
//! Both run as CHAIN steps, never as whole effects: a separable blur is two
//! images, and two images is what the ping-pong pool is for.
//!
//! ## Why `blur` is not sigma
//!
//! Authors write a REACH — "blur=12" means the softness extends about twelve
//! pixels — and the kernel wants a sigma. Three sigma covers 99.7% of a
//! Gaussian, so the conversion is `blur / 3`, and it lives here rather than
//! in each effect because the two must agree. In `:::drop_shadow` the number
//! is load-bearing twice over: the same `blur` is the layout inflation, so a
//! sigma of `blur / 2` would put the shadow's tail outside the halo reserved
//! for it and clip it against the target edge.

const std = @import("std");
const component_mod = @import("../../component.zig");
const element = @import("../../element.zig");
const shader_resolver = @import("../../pass/shader_resolver.zig");

/// `gaussian_alpha.frag` — blur, reduce to one channel, tint by coverage.
pub const ALPHA_SHADER: component_mod.ShaderId = shader_resolver.shaderIdFromName("gaussian_alpha.frag");

/// `gaussian_rgba.frag` — blur four channels, lay a tint over.
pub const RGBA_SHADER: component_mod.ShaderId = shader_resolver.shaderIdFromName("gaussian_rgba.frag");

/// Three sigma is the kernel's practical width, so a `blur` of N pixels is a
/// sigma of N/3. Naming the constant keeps the shaders, the inflation maths
/// and the two effects from drifting apart.
pub const SIGMA_PER_BLUR: f32 = 1.0 / 3.0;

/// Author's `blur` → the shader's sigma. Clamped at zero: `blur=-4` is a
/// typo, not a request to invert the kernel.
pub fn sigmaFor(blur: f32) f32 {
    return @max(blur * SIGMA_PER_BLUR, 0.0);
}

/// std140 block for `shaders/gaussian_alpha.frag`, from
/// `element.PASS_UNIFORM_OFFSET` on.
///
///   direction : vec2  —  0..8    axis of this pass, in texels
///   offset    : vec2  —  8..16   displacement, pixels
///   channel   : vec4  — 16..32   dot mask selecting the channel to blur
///   tint      : vec4  — 32..48   premultiplied output colour
///   sigma     : f32   — 48..52
///   spread    : f32   — 52..56
pub const AlphaUniforms = extern struct {
    direction: [2]f32,
    offset: [2]f32,
    channel: [4]f32,
    tint: [4]f32,
    sigma: f32,
    spread: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

/// std140 block for `shaders/gaussian_rgba.frag`, from
/// `element.PASS_UNIFORM_OFFSET` on.
///
///   direction : vec2  —  0..8    axis of this pass, in texels
///   _pad0     :       —  8..16   vec4 alignment for `tint`
///   tint      : vec4  — 16..32   PREMULTIPLIED wash; all-zero is identity
///   sigma     : f32   — 32..36
pub const RgbaUniforms = extern struct {
    direction: [2]f32,
    _pad0: [2]f32 = .{ 0, 0 },
    tint: [4]f32,
    sigma: f32,
    _pad1: [3]f32 = .{ 0, 0, 0 },
};

/// Straight RGBA → premultiplied.
///
/// Every one of these shaders blends premultiplied and scales its tint by a
/// coverage, so a straight colour arrives too bright. The bug hides in the
/// defaults: a black shadow is `rgb * a == rgb` for any a, and a 6% white
/// wash is nearly invisible either way — it shows up the first time somebody
/// authors a saturated colour at partial alpha.
pub fn premultiply(c: [4]f32) [4]f32 {
    const a = std.math.clamp(c[3], 0, 1);
    return .{ c[0] * a, c[1] * a, c[2] * a, a };
}

/// Zero the whole slot before copying. The uniform block is hashed whole by
/// the frame fingerprint, so uninitialised tail bytes would make an
/// otherwise-identical frame hash differently run to run.
pub fn writeUniforms(out: *[element.MAX_PASS_UNIFORM_BYTES]u8, bytes: []const u8) void {
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
}

/// Read a uniform block back out of a step, for tests.
///
/// `uniform_bytes` is a byte array with no alignment guarantee, so it is
/// COPIED rather than pointer-cast — an `@alignCast` here panics, which is a
/// test failing for a reason that has nothing to do with the effect.
pub fn readUniforms(comptime T: type, step: element.ChainPassStep) T {
    var out: T = undefined;
    @memcpy(std.mem.asBytes(&out), step.uniform_bytes[0..@sizeOf(T)]);
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "AlphaUniforms: std140 layout offsets" {
    // Lock-in test. These offsets ARE the GLSL push_constant block's
    // contract; an "innocent" field reorder that compiles cleanly would push
    // misaligned uniforms to the GPU and render garbage. See
    // [[feedback-std140-offset-lockin]].
    try testing.expectEqual(@as(usize, 0), @offsetOf(AlphaUniforms, "direction"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(AlphaUniforms, "offset"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(AlphaUniforms, "channel"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(AlphaUniforms, "tint"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(AlphaUniforms, "sigma"));
    try testing.expectEqual(@as(usize, 52), @offsetOf(AlphaUniforms, "spread"));
    try testing.expectEqual(@as(usize, 64), @sizeOf(AlphaUniforms));
    try testing.expect(@sizeOf(AlphaUniforms) <= element.MAX_PASS_UNIFORM_BYTES - element.PASS_UNIFORM_OFFSET);
}

test "RgbaUniforms: std140 layout offsets" {
    // `tint` is the one that bites: a vec4 aligns to 16, so it does NOT
    // follow `direction` at offset 8. Dropping `_pad0` still compiles and
    // still fits, and every wash would arrive as the direction vector.
    try testing.expectEqual(@as(usize, 0), @offsetOf(RgbaUniforms, "direction"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(RgbaUniforms, "tint"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(RgbaUniforms, "sigma"));
    try testing.expectEqual(@as(usize, 48), @sizeOf(RgbaUniforms));
    try testing.expect(@sizeOf(RgbaUniforms) <= element.MAX_PASS_UNIFORM_BYTES - element.PASS_UNIFORM_OFFSET);
}

test "sigmaFor: three sigma is the authored reach" {
    // The property the constant exists for, stated as the equation the
    // inflation maths depends on. If this drifts, a drop shadow's tail
    // starts being clipped by the halo reserved for it.
    try testing.expectApproxEqAbs(@as(f32, 12), sigmaFor(12) * 3, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 4), sigmaFor(12), 1e-5);
    // A negative reach collapses to no blur rather than a reflected kernel.
    try testing.expectEqual(@as(f32, 0), sigmaFor(-4));
}

test "premultiply: the saturated case, which the defaults hide" {
    // Rule 1. `premultiply` on BLACK changes nothing at all — black times
    // anything is black — so a gate that only ever used a shadow's default
    // colour would pass against no premultiplication whatsoever.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0.5 }, &premultiply(.{ 0, 0, 0, 0.5 }));

    const red = premultiply(.{ 1, 0, 0, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), red[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), red[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), red[3], 1e-6);

    // Alpha is clamped, so an over-bright authored alpha cannot make the
    // colour channels exceed it and break the premultiplied invariant.
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, &premultiply(.{ 1, 1, 1, 4 }));
}

test "writeUniforms: a dirty slot comes back with a zeroed tail" {
    // **The slot is POISONED first, and that is the whole test.**
    // `ChainPassStep.uniform_bytes` defaults to all-zeros, so a step built
    // from a struct literal has a zeroed tail whatever `writeUniforms` does.
    // Asserting on such a step passes against a `writeUniforms` with no
    // `@memset` at all — which is exactly what an earlier version of this
    // gate did, and a mutation walked straight through it.
    //
    // The property is real: the frame fingerprint hashes the whole 256-byte
    // array, so a caller that rewrites a slot IN PLACE with a shorter block
    // would leave the previous effect's bytes in the tail and make two
    // identical frames hash differently. Today's `buildSteps` reassigns the
    // whole literal every walk and cannot hit it; the guarantee is here so
    // the next one does not have to know that.
    var step = element.ChainPassStep{
        .composite_shader_id = RGBA_SHADER,
        .source_pool_local = 0,
        .dest_pool_local = 1,
        .uniform_len = @sizeOf(RgbaUniforms),
    };
    @memset(&step.uniform_bytes, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), step.uniform_bytes[element.MAX_PASS_UNIFORM_BYTES - 1]);

    const in = RgbaUniforms{ .direction = .{ 0, 1 }, .tint = .{ 0.25, 0, 0, 0.5 }, .sigma = 4 };
    writeUniforms(&step.uniform_bytes, std.mem.asBytes(&in));

    // Round-trips through a slot with no alignment guarantee.
    const out = readUniforms(RgbaUniforms, step);
    try testing.expectEqualSlices(f32, &in.tint, &out.tint);
    try testing.expectEqual(@as(f32, 4), out.sigma);

    for (step.uniform_bytes[step.uniform_len..]) |b| try testing.expectEqual(@as(u8, 0), b);
}
