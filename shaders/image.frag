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

void main() {
    vec4 c = texture(tex, v_uv);
    out_color = vec4(c.rgb * c.a, c.a);
}
