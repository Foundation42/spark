#version 450

// :::liquid_glass — rounded-box SDF refraction + chromatic aberration
// + rim highlight + optional tint. Inspired by Apple's Liquid Glass
// effect on macOS Tahoe / iOS 19 panels.
//
// **Scope note.** This shader works ENTIRELY on the child's rendered
// content in the offscreen target. There's no sampling of MAIN, so
// the "refraction" is of the child itself — text/patterns inside the
// panel bend near the rounded corners as if viewed through curved
// glass. The Apple "see-through to background" look needs a second
// sampler bound to MAIN, which the v1 single_source pipeline layout
// doesn't expose. Phase D's HostSlotPass or a future ChainPass variant
// could light up that path.
//
// Effects-spec Phase B.6.d — third user-facing single_source factory.
// First factory authored AFTER the SingleSourceFactory comptime
// generator (B.6.c) — proves the generator's API holds up for new
// effects, not just refactor targets.
//
// **Algorithm:**
//   1. SDF from a rounded-box centered in v_uv space. Negative inside,
//      zero at the edge, positive outside.
//   2. Alpha edge fade via smoothstep — soft corner falloff.
//   3. Refraction: near the edge (depth_in low), bend the sampling UV
//      back toward center. Sharper near the edge via pow(1-depth, 2).
//      Deep inside is undistorted.
//   4. Chromatic aberration: tiny offset between R/G/B sampling
//      directions, scaled by the same edge-proximity factor as
//      refraction. Subtle prismatic effect at corners.
//   5. Rim highlight: bright thin band just inside the edge,
//      brightness scaled by `rim_brightness`.
//   6. Tint overlay: standard "over" composite of tint on the
//      refracted+highlighted result.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_target;

// Push-constant block mirrors `LiquidGlassUniforms` in
// liquid_glass.zig exactly. Four scalars pack into the first vec4
// slot (offset 0..16); vec4 `tint` lands at offset 16..32. Total
// 32 bytes.
#include "display.glsl"
#include "corner.glsl"

// The display transform's per-frame push, at a FIXED offset so ONE record
// path can write it for every effect whatever its own uniforms look like.
// `element.PASS_UNIFORM_OFFSET` (16) is where each effect's own block
// starts; the Zig struct it mirrors describes the bytes from there on, and
// its offsets are relative to it rather than to this block.
// PREMULTIPLICATION, straightened 2026-08-31. This shader used to write
// `vec4(rgb, alpha)` with rgb NOT multiplied by alpha, while the pipeline
// blends with srcFactor = ONE. So every partially covered edge pixel added
// full-strength colour over `(1 - a)` of the background: the antialiased
// corners came out with a bright fringe, which reads as the "crispiness" a
// rounded panel had and a square one did not. Its own header called this
// out and deferred it; this is that change.
layout(push_constant) uniform Params {
    vec2 display;      //  0..8   mode, paperwhite — see display.glsl
    vec2 _display_pad; //  8..16
    vec2 corner_size;  // 16..24  the composite region, in pixels
    float corner_radius; // 24..28  corner radius, in pixels
    float _corner_pad;   // 28..32  — see element.CornerPush
    float refraction;      // 32..36  bend strength [0..0.5]
    float edge_softness;   // 36..40  RIM width [0..0.05]
    float rim_brightness;  // 40..44  edge highlight intensity [0..1]
    float _pad;            // 44..48
    vec4 tint;             // 48..64  overlay color (alpha = intensity)
} u_params;

void main() {
    // v_uv covers the offscreen target [0..1]^2. Center at origin
    // for the refraction maths, which is direction-only.
    vec2 p = v_uv - 0.5;

    // The edge, in PIXELS. This used to be an SDF in normalised UV
    // against a half-extent of vec2(0.5), which made the corner an
    // ellipse on any panel that was not square and made the AA band a
    // different width on each axis. See corner.glsl.
    vec2 half_px = u_params.corner_size * 0.5;
    float r_px = min(u_params.corner_radius, min(half_px.x, half_px.y));
    float sd_px = sparkRoundedBoxSDF((v_uv - 0.5) * u_params.corner_size, half_px, r_px);

    // Back to a fraction of the panel's short side, so `refraction`
    // keeps the meaning it had: a bend that reaches this far in from
    // the edge, whatever the panel's size.
    float short_side = max(min(u_params.corner_size.x, u_params.corner_size.y), 1.0);
    float sd = sd_px / short_side;

    // Coverage, one pixel wide at any size, from the shared helper.
    float alpha = sparkCornerCoverage(v_uv, u_params.corner_size, u_params.corner_radius);
    if (alpha <= 0.0) {
        out_color = vec4(0.0);
        return;
    }

    // Refraction strength: 1 right at the edge (inside), 0 deep
    // inside. Sharper near edge via pow(1-depth, 2).
    float depth_in = clamp(-sd / max(u_params.refraction, 1e-4), 0.0, 1.0);
    float bend = (1.0 - depth_in) * (1.0 - depth_in);

    // Pull the sampling UV back toward center proportional to bend.
    // Deep inside (bend=0): refracted_uv == v_uv (no distortion).
    // Near edge (bend=1): pulled toward center by refraction units.
    vec2 to_center = -p;
    vec2 refracted_uv = v_uv + to_center * bend * u_params.refraction;

    // Chromatic aberration — R and B sample along the radial
    // direction at small offsets, G samples at the refracted UV.
    // Strength scales with bend so corners get the prismatic flash
    // and the panel center stays clean.
    float ca = bend * u_params.refraction * 0.3;
    vec2 ca_dir = normalize(p + vec2(1e-6)); // avoid divide-by-zero at exact center
    float r_ch = texture(u_target, refracted_uv + ca_dir * ca).r;
    float g_ch = texture(u_target, refracted_uv).g;
    float b_ch = texture(u_target, refracted_uv - ca_dir * ca).b;
    vec3 rgb = vec3(r_ch, g_ch, b_ch);

    // Rim highlight — a thin bright band just inside the edge.
    // Width controlled by edge_softness; intensity by rim_brightness.
    float rim_inner = u_params.edge_softness * 4.0;
    float rim_outer = u_params.edge_softness * 8.0;
    float rim = smoothstep(0.0, rim_inner, -sd) - smoothstep(rim_inner, rim_outer, -sd);
    rgb += rim * u_params.rim_brightness;

    // Tint composite — standard "over" blend. tint.a = 0 means
    // tint is invisible; tint.a = 1 means tint fully replaces.
    rgb = rgb * (1.0 - u_params.tint.a) + u_params.tint.rgb * u_params.tint.a;

    // Premultiplied, like every other composite on this path. The
    // pipeline blends srcFactor = ONE, so an unmultiplied edge pixel
    // fringes; see the header.
    out_color = vec4(sparkDisplay(rgb, u_params.display) * alpha, alpha);
}
