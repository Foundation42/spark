#version 450
// text.vert — Phase 3: per-glyph instanced quad.
//
// `gl_VertexIndex` picks a corner of the unit quad (0..5 for two
// triangles); `gl_InstanceIndex` picks a GlyphInstance from the SSBO.
// The vertex stage assembles pixel-space position from
// `dst_pos + corner * dst_size`, converts to NDC against the viewport
// size in push constants, and forwards atlas UV + per-glyph colour
// to the fragment stage. One `vkCmdDraw(6, n_glyphs, 0, 0)` draws an
// entire paragraph in one submit.

layout(push_constant) uniform PC {
    vec2 viewport_size;
} pc;

struct GlyphInstance {
    vec2 dst_pos;     // top-left pixel
    vec2 dst_size;    // pixel size
    vec2 uv_min;      // atlas UV at dst_pos
    vec2 uv_max;      // atlas UV at dst_pos + dst_size
    vec4 color;       // per-glyph straight-alpha tint
};

layout(set = 0, binding = 1, std430) readonly buffer GlyphBuffer {
    GlyphInstance glyphs[];
};

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

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
}
