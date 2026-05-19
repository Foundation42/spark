#version 450

// :::drop_shadow — single-source filter. Samples the rendered child
// content from the offscreen target and composites:
//   * the original child at v_uv (unchanged), AND
//   * a blurred + shifted alpha mask of the child, tinted by
//     shadow_color, blended UNDER the child.
//
// Effects-spec Phase B.5 — first user-facing single_source factory.
// Substrate validation lands at B.5 alongside the visible Lab card
// shadow output. The substrate (SingleSourcePipelineCache,
// SingleSourceDescriptorPool, three-phase dispatch processor) is
// already proven by B.4.b.1–4's tests; this shader is the first
// real consumer.
//
// **Algorithm (v1: 9-tap box blur).** For each output pixel:
//   1. Sample the original child at v_uv. If alpha > 0 we keep it.
//   2. Sample the child's alpha channel at v_uv shifted by -offset
//      (the shadow's "source position"), averaged over a 3x3 box of
//      taps separated by blur_radius pixels. This is the blurred
//      shadow alpha at this fragment.
//   3. Multiply by shadow_color → tinted shadow at this fragment.
//   4. Composite shadow UNDER child via standard "over" blend:
//      child + shadow * (1 - child.a).
//
// Real gaussian blur with proper falloff is a Phase C optimization
// (separable two-pass, weighted taps). v1 produces a recognizable
// shadow at the right position and color — sufficient for the
// substrate-validation milestone.
//
// **textureSize() to convert pixel offsets → UV.** The host knows
// offset_xy and blur_radius in pixels; the shader converts via
// `1.0 / textureSize()`. This means the same shader works for
// any target_size without target_size in uniforms.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_target;

// Push-constant block mirrors `DropShadowUniforms` in
// drop_shadow.zig exactly. std140 alignment: offset (vec2) +
// blur_radius (float) + _pad (float) packs into one vec4 slot
// before shadow_color (vec4) gets its own slot at offset 16.
layout(push_constant) uniform Params {
    vec2 offset;
    float blur_radius;
    float _pad;
    vec4 shadow_color;
} u_params;

void main() {
    vec2 inv_size = 1.0 / vec2(textureSize(u_target, 0));

    // Original child at this fragment (unchanged).
    vec4 child = texture(u_target, v_uv);

    // Shadow sample position: shift backwards by offset to get
    // "where the child was, viewed from the shadow's perspective."
    // Then box-blur 3x3 around that position, scaled by blur_radius.
    vec2 shadow_uv = v_uv - u_params.offset * inv_size;
    float blur_a = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 tap_uv = shadow_uv + vec2(float(dx), float(dy)) * u_params.blur_radius * inv_size;
            blur_a += texture(u_target, tap_uv).a;
        }
    }
    blur_a /= 9.0;

    vec4 shadow = u_params.shadow_color * blur_a;

    // Composite: shadow under child via "over" blend.
    out_color = child + shadow * (1.0 - child.a);
}
