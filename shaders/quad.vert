#version 450
// quad.vert — instanced filled rectangle pipeline. One QuadInstance
// SSBO entry per quad; 6 verts per instance make the two triangles.
// Used for block chrome (code-block backgrounds, blockquote bars,
// thematic-break rules) and eventually link underlines.
//
// Same coordinate convention as text.vert: dst_pos / dst_size are in
// display pixels, viewport_size push-constant supplies the NDC
// conversion. The fragment receives `v_local` (pixel offset within
// the quad) so it can compute rounded-corner SDF anti-aliasing
// without a derivatives trick.
//
// `world_offset` subtracts a target-space origin so the same SSBO
// data renders correctly into both the main attachment (world_offset
// = (0, 0)) and any single_source offscreen target (world_offset =
// compose_region.xy). Without it, a quad at world (50, 1590) drawn
// into a 266x106 target produces NDC.y = 29 and gets clip-volume-
// culled; with it the math collapses to target-local coords and NDC
// stays in [-1, 1] for any target size. Phase B.5 substrate.

layout(push_constant) uniform PC {
    vec2 viewport_size;
    vec2 world_offset;
    // x = display mode (0 = passthrough, 1 = PQ), y = paperwhite nits.
    // Declared in BOTH stages of every pipeline that uses it: a push
    // constant block is one range shared by the stages, and the fragment
    // shader is where it is read. See shaders/display.glsl.
    vec2 display;
} pc;

struct QuadInstance {
    vec2 dst_pos;
    vec2 dst_size;
    vec4 color;     // NOT premultiplied — fragment premultiplies at
                    // output. Stored straight so theme authors can
                    // think in RGBA without doing the multiplication
                    // by hand.
    float radius;   // corner radius in pixels (0 = sharp corners).
    float _pad0;
    float _pad1;
    float _pad2;
};

layout(set = 0, binding = 0, std430) readonly buffer QuadBuffer {
    QuadInstance quads[];
};

layout(location = 0) out vec2 v_local;     // pixel offset within quad
layout(location = 1) out vec2 v_size;
layout(location = 2) out vec4 v_color;
layout(location = 3) flat out float v_radius;

const vec2 CORNERS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    QuadInstance q = quads[gl_InstanceIndex];
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 px = (q.dst_pos - pc.world_offset) + corner * q.dst_size;
    vec2 ndc = (px / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_local = corner * q.dst_size;
    v_size = q.dst_size;
    v_color = q.color;
    v_radius = q.radius;
}
