#version 450
// text.frag — Phase 6: mono coverage / colour bitmap / SDF distance,
// with the SDF branch consuming `attention` to modulate stroke
// weight + glow. This is the first piece of the chat.md vision
// where LM metadata directly drives rendering.
//
// All three branches output premultiplied-alpha colour because the
// pipeline is configured with `srcFactor = ONE` — see
// `text_pipeline.zig` for the rationale.

layout(set = 0, binding = 0) uniform sampler2D u_atlas_mono;
layout(set = 0, binding = 2) uniform sampler2D u_atlas_color;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 2) flat in uint v_tex_select;
layout(location = 3) flat in float v_attention;
layout(location = 0) out vec4 o_color;

void main() {
    if (v_tex_select == 0u) {
        // Mono: hinted-grayscale coverage. R8 channel is direct
        // opacity 0..1. Output premultiplied so the blend math works
        // with `srcFactor = ONE`.
        float coverage = texture(u_atlas_mono, v_uv).r;
        float a = v_color.a * coverage;
        o_color = vec4(v_color.rgb * a, a);
    } else if (v_tex_select == 1u) {
        // Colour: CBDT/sbix bitmap, already premultiplied by FT.
        // Tint with v_color.a as opacity only — never RGB, which
        // would repaint the emoji artwork.
        vec4 c = texture(u_atlas_color, v_uv);
        o_color = c * v_color.a;
    } else {
        // SDF: R channel encodes signed distance with 0.5 on the
        // glyph boundary (see src/font/sdf.zig). Bilinear sampling
        // gives sub-pixel edge precision; `fwidth` derives a screen-
        // space anti-aliasing width so the smoothstep stays one
        // pixel wide regardless of how aggressively the glyph is
        // scaled.
        //
        // `attention` shifts the threshold around 0.5 — higher
        // attention lowers the threshold so more pixels survive the
        // smoothstep, producing a visible weight pulse without
        // changing layout. Phase 6 v1 layered a warm halo on top of
        // this, pulled because single-channel SDF at radius 8 has
        // ~16 discrete byte-value steps near the edge — the halo
        // band landed in 2-3 of them and looked visibly pixelated.
        // True MSDF (corner channels) would fix that; underlines /
        // size-with-reflow / per-character PBR are the planned
        // directions for richer LM-driven attention effects when
        // they land in later phases.
        float dist = texture(u_atlas_mono, v_uv).r;
        float threshold = mix(0.52, 0.45, clamp(v_attention, 0.0, 1.0));
        float aa = max(fwidth(dist), 1e-4);
        float coverage = smoothstep(threshold - aa, threshold + aa, dist);
        float a = v_color.a * coverage;
        o_color = vec4(v_color.rgb * a, a);
    }
}
