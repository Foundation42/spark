#version 450
// text.vert — Phase 5: per-glyph instanced quad with mono/color atlas
// routing.
//
// `gl_VertexIndex` picks a corner of the unit quad (0..5 for two
// triangles); `gl_InstanceIndex` picks a GlyphInstance from the SSBO.
// `tex_select` rides through to the fragment stage so it can sample
// from the appropriate atlas (0 = mono R8 coverage, 1 = color RGBA8
// premultiplied bitmap).

layout(push_constant) uniform PC {
    vec2 viewport_size;
} pc;

struct GlyphInstance {
    vec2 dst_pos;     // top-left pixel
    vec2 dst_size;    // pixel size
    vec2 uv_min;      // atlas UV at dst_pos
    vec2 uv_max;      // atlas UV at dst_pos + dst_size
    vec4 color;       // per-glyph straight-alpha tint
    uint tex_select;  // 0 = mono, 1 = color
    // std430 pads the struct to 64 bytes (16-byte stride alignment).
    // Zig side declares an explicit `_pad: [3]u32` to match.
};

layout(set = 0, binding = 1, std430) readonly buffer GlyphBuffer {
    GlyphInstance glyphs[];
};

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;
// `flat` because the same value applies to all three vertices of a
// triangle — no interpolation needed and `flat int` saves a few
// cycles per fragment over a smoothed varying.
layout(location = 2) flat out uint v_tex_select;

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
    v_tex_select = g.tex_select;
}
