#version 450
// text.frag — Phase 2: sample the R8 glyph atlas as alpha coverage,
// emit `color.rgb` modulated by `color.a * coverage`.
//
// R8_UNORM atlas: the FreeType glyph bitmap is 8-bit grayscale,
// uploaded straight into the R channel. We read that as alpha
// coverage so glyph edges blend correctly against the framebuffer.
// Phase 6 splits this into hinted-coverage vs MSDF-coverage branches
// keyed by a per-glyph fx_kind flag.

layout(set = 0, binding = 0) uniform sampler2D u_atlas;

layout(push_constant) uniform PC {
    vec4 color;
    vec2 dst_pos;
    vec2 dst_size;
    vec2 viewport_size;
    vec2 uv_min;
    vec2 uv_max;
} pc;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

void main() {
    float coverage = texture(u_atlas, v_uv).r;
    o_color = vec4(pc.color.rgb, pc.color.a * coverage);
}
