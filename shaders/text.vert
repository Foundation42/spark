#version 450
// text.vert — Phase 6: per-glyph instanced quad with mono / colour /
// SDF lane routing + per-glyph attention attribute.
//
// `gl_VertexIndex` picks a corner of the unit quad (0..5 for two
// triangles); `gl_InstanceIndex` picks a GlyphInstance from the SSBO.
// `tex_select` routes the fragment to the right atlas (0 = mono R8
// coverage, 1 = colour RGBA8 premultiplied, 2 = SDF R8 distance).
// `attention` + `hot_color` drive the LM-driven hue shift + SDF
// weight pulse in the fragment.

layout(push_constant) uniform PC {
    vec2 viewport_size;
} pc;

struct GlyphInstance {
    vec2 dst_pos;
    vec2 dst_size;
    vec2 uv_min;
    vec2 uv_max;
    vec4 color;
    vec4 hot_color;
    uint tex_select;
    float attention;
    uint fx_kind;
    // std430 pads the struct to 80 bytes — Zig side declares an
    // explicit `_pad: u32` to match the trailing slot.
};

layout(set = 0, binding = 1, std430) readonly buffer GlyphBuffer {
    GlyphInstance glyphs[];
};

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;
layout(location = 2) flat out uint v_tex_select;
layout(location = 3) flat out float v_attention;
layout(location = 4) out vec4 v_hot_color;

const vec2 CORNERS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    GlyphInstance g = glyphs[gl_InstanceIndex];
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 px = g.dst_pos + corner * g.dst_size;
    vec2 ndc = (px / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = mix(g.uv_min, g.uv_max, corner);
    v_color = g.color;
    v_hot_color = g.hot_color;
    v_tex_select = g.tex_select;
    v_attention = g.attention;
}
