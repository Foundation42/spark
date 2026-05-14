#version 450
// text.frag — Phase 3: sample per-glyph atlas region as coverage,
// modulate the per-glyph colour from the SSBO. Phase 6 will split
// the coverage branch (hinted-grayscale vs MSDF) keyed by a per-glyph
// fx_kind flag carried through the SSBO + a v_kind varying.

layout(set = 0, binding = 0) uniform sampler2D u_atlas;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 o_color;

void main() {
    float coverage = texture(u_atlas, v_uv).r;
    o_color = vec4(v_color.rgb, v_color.a * coverage);
}
