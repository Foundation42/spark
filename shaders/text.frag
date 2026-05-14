#version 450
// text.frag — Phase 6: mono coverage / colour bitmap / SDF distance,
// with `attention` driving (a) a per-glyph `color → hot_color` hue
// lerp on the mono + SDF branches, and (b) an additional weight
// pulse on the SDF branch via threshold modulation. The colour
// atlas (emoji) deliberately ignores attention — emoji artwork
// should never be tinted by the LM signal.
//
// All branches output premultiplied-alpha colour because the
// pipeline blend is configured with `srcFactor = ONE` — see
// `text_pipeline.zig` for the rationale.

layout(set = 0, binding = 0) uniform sampler2D u_atlas_mono;
layout(set = 0, binding = 2) uniform sampler2D u_atlas_color;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 2) flat in uint v_tex_select;
layout(location = 3) flat in float v_attention;
layout(location = 4) in vec4 v_hot_color;
layout(location = 0) out vec4 o_color;

void main() {
    float att = clamp(v_attention, 0.0, 1.0);
    // Lerp base colour toward hot_color by attention. Default
    // attention is 0 so non-animated spans render at exactly
    // v_color — opt-in colour modulation.
    vec3 tint_rgb = mix(v_color.rgb, v_hot_color.rgb, att);

    if (v_tex_select == 0u) {
        // Mono: hinted-grayscale coverage. R8 channel is direct
        // opacity 0..1. Output premultiplied so the blend math
        // works with `srcFactor = ONE`.
        float coverage = texture(u_atlas_mono, v_uv).r;
        float a = v_color.a * coverage;
        o_color = vec4(tint_rgb * a, a);
    } else if (v_tex_select == 1u) {
        // Colour (emoji): sample CBDT/sbix bitmap, already
        // premultiplied. Tint by v_color.a as opacity only — never
        // RGB, which would repaint Noto's artwork.
        vec4 c = texture(u_atlas_color, v_uv);
        o_color = c * v_color.a;
    } else {
        // SDF: R channel encodes signed distance with 0.5 on the
        // glyph boundary (see src/font/sdf.zig). Bilinear sampling
        // gives sub-pixel edge precision; `fwidth` derives a
        // screen-space anti-aliasing width.
        //
        // `attention` shifts the threshold around 0.5 — higher
        // attention lowers the threshold so more pixels survive,
        // giving a visible weight pulse without layout changes.
        // Combined with the hue lerp above, high-attention glyphs
        // visibly thicken AND shift toward hot_color.
        float dist = texture(u_atlas_mono, v_uv).r;
        float threshold = mix(0.52, 0.45, att);
        float aa = max(fwidth(dist), 1e-4);
        float coverage = smoothstep(threshold - aa, threshold + aa, dist);
        float a = v_color.a * coverage;
        o_color = vec4(tint_rgb * a, a);
    }
}
