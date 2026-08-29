#version 450

// :::frosted_glass — single-source filter. Samples the rendered
// child content from the offscreen target, applies a single-pass
// box blur, then composites a tint color over the blurred result.
// The "modern OS" panel look: blurred contents + light overlay.
//
// Effects-spec Phase B.6 — second user-facing single_source factory.
// Ratifies the post-B.6.a cache substrate (no temporary
// `disable_cache` workaround needed) and the per-pipeline
// `world_offset` push constant from B.5 by virtue of using the same
// substrate path drop_shadow uses.
//
// Algorithm (v1: 9-tap box blur, matches drop_shadow's tap shape):
//   1. Sample a 3x3 grid of taps around v_uv, separated by
//      blur_radius pixels.
//   2. Average to a blurred RGBA value.
//   3. Composite tint OVER the blurred result via standard "over"
//      blend (tint.a controls intensity).
//
// Separable two-pass Gaussian with proper weights is a Phase C
// optimization. v1 produces the modern-OS "blurred panel + tint
// overlay" look at a fixed quality — sufficient for the visible
// deliverable.
//
// textureSize() converts pixel offsets → UV. The host knows
// blur_radius in pixels; the shader normalises via
// `1.0 / textureSize()`. Same shader works for any target_size.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_target;

// Push-constant block mirrors `FrostedGlassUniforms` in
// frosted_glass.zig exactly. std140 alignment: blur_radius (float)
// at offset 0; tint_color (vec4) bumps to offset 16 due to
// vec4's 16-byte alignment requirement (12 bytes implicit pad).
// Total 32 bytes.
#include "display.glsl"

// The display transform's per-frame push, at a FIXED offset so ONE record
// path can write it for every effect whatever its own uniforms look like.
// `element.PASS_UNIFORM_OFFSET` (16) is where each effect's own block
// starts; the Zig struct it mirrors describes the bytes from there on, and
// its offsets are relative to it rather than to this block.
// NOTE on premultiplication. This shader composites its own blur/tint and
// writes `vec4(rgb, alpha)` with rgb NOT divided by alpha, while the
// pipeline blends with srcFactor = ONE. That predates the display transform
// and is left exactly as it was: the encode below is applied to the value
// this shader already produced, so an SDR frame is byte-identical and an
// HDR one is finally in the right luminance. Straightening the
// premultiplication is its own change, with its own before/after.
layout(push_constant) uniform Params {
    vec2 display;      //  0..8   mode, paperwhite — see display.glsl
    vec2 _display_pad; //  8..16
    float blur_radius;
    vec4 tint_color;
} u_params;

void main() {
    vec2 inv_size = 1.0 / vec2(textureSize(u_target, 0));

    // 9-tap box blur of the child content.
    vec4 acc = vec4(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 tap_uv = v_uv + vec2(float(dx), float(dy)) * u_params.blur_radius * inv_size;
            acc += texture(u_target, tap_uv);
        }
    }
    acc /= 9.0;

    // Composite tint OVER blurred result via standard "over" blend.
    // tint.a controls intensity: 0 = blur only, 1 = fully tinted
    // (blur invisible). The modern-OS look sits around 0.05–0.15.
    vec3 rgb = acc.rgb * (1.0 - u_params.tint_color.a) + u_params.tint_color.rgb * u_params.tint_color.a;
    float alpha = acc.a * (1.0 - u_params.tint_color.a) + u_params.tint_color.a;

    out_color = vec4(sparkDisplay(rgb, u_params.display), alpha);
}
