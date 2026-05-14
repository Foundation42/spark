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
        float dist = texture(u_atlas_mono, v_uv).r;

        // Attention modulates the SDF threshold around 0.5. Tight
        // range (0.52 → 0.45) keeps the weight wave subtle —
        // visible variation in stroke thickness without the glyph
        // pumping noticeably wider or thinner. Phase 6 first pass
        // used 0.55 → 0.40 and looked too bouncy at mid-attention.
        float threshold = mix(0.52, 0.45, clamp(v_attention, 0.0, 1.0));

        float aa = max(fwidth(dist), 1e-4);
        float coverage = smoothstep(threshold - aa, threshold + aa, dist);

        // Outer glow band — narrow (0.10 wide vs 0.20 originally) so
        // the halo reads as "this glyph is hot" rather than a fuzzy
        // smear. Intensity caps lower too (0.4 vs 0.6) so the
        // brightest letter doesn't wash out its neighbours.
        float glow_band = smoothstep(threshold - 0.10, threshold - aa, dist);
        float glow = glow_band * v_attention * 0.4;

        vec3 tint = v_color.rgb;
        // Glow shifts hue slightly warmer than the base tint — gives
        // the LM-flagged glyph a "this is hot" feel without a second
        // colour input. Tune later when we have real attention data.
        vec3 glow_rgb = mix(tint, vec3(1.0, 0.85, 0.40), 0.7);

        float core_a = v_color.a * coverage;
        float halo_a = v_color.a * glow;
        // Premultiply both contributions, then add. The halo can
        // tint a few pixels outside the glyph; the core is the glyph
        // itself. Both blend cleanly with srcFactor=ONE downstream.
        vec3 rgb_pm = tint * core_a + glow_rgb * halo_a;
        float a_pm = core_a + halo_a * (1.0 - core_a);
        o_color = vec4(rgb_pm, a_pm);
    }
}
