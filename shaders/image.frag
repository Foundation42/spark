#version 450
// image.frag — sample one RGBA8 texture, output premultiplied alpha.
//
// stb_image hands us straight (non-premultiplied) RGBA bytes; we
// premultiply at output so the pipeline's `srcFactor = ONE` blend
// composites correctly with quads and glyphs sitting above us in
// the render order. (Order at frame time: tris → images → quads →
// glyphs — images sit just above SVG fills so they read as part of
// the document background layer.)

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

#include "display.glsl"

// Same push-constant block as the vertex stage — one range, both stages.
// Only `display` is read here; the layout must still match exactly.
layout(push_constant) uniform PC {
    vec2 viewport_size;
    vec2 world_offset;
    vec2 dst_pos;
    vec2 dst_size;
    vec2 display;
} pc;

void main() {
    vec4 c = texture(tex, v_uv);
    // Display transform before the premultiply — see display.glsl. Images
    // are authored SDR artwork like every other bit of chrome, so they map
    // to paperwhite too rather than blazing at the PQ ceiling.
    vec3 rgb = sparkDisplay(c.rgb, pc.display);
    out_color = vec4(rgb * c.a, c.a);
}
