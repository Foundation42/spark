#version 450
// text.frag — Phase 5: mono coverage OR premultiplied colour bitmap,
// routed by the per-glyph `tex_select` flag from the vertex stage.
//
// Both branches output premultiplied-alpha colour because the
// pipeline is now configured with `srcFactor = ONE` (see
// `text_pipeline.zig`). The mono branch multiplies the tint RGB by
// `coverage * alpha` so it lands at the same premultiplied
// magnitude that the CBDT bitmaps already are.
//
// Tinting colour emoji: we apply `v_color.a` as an opacity
// multiplier so callers can fade emoji in/out, but we do NOT tint
// the RGB — the sampled CBDT bitmap already carries the emoji's
// own colours and tinting them changes the artwork. Hue / sentiment
// effects on emoji come later (Phase 6+) when we have a richer
// per-glyph attribute channel.

layout(set = 0, binding = 0) uniform sampler2D u_atlas_mono;
layout(set = 0, binding = 2) uniform sampler2D u_atlas_color;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 2) flat in uint v_tex_select;
layout(location = 0) out vec4 o_color;

void main() {
    if (v_tex_select == 0u) {
        float coverage = texture(u_atlas_mono, v_uv).r;
        float a = v_color.a * coverage;
        o_color = vec4(v_color.rgb * a, a);
    } else {
        vec4 c = texture(u_atlas_color, v_uv);
        o_color = c * v_color.a;
    }
}
