#version 450
// text.vert — Phase 2: one textured quad via gl_VertexIndex.
//
// The vertex stage emits two triangles forming a unit quad whose
// corners are placed by the push-constant rect, then mapped to NDC
// using the viewport size also in push constants. This is the
// "single instance" shape — Phase 3 will switch to instanced draws
// reading the per-glyph SSBO so we can issue thousands of glyphs in
// one draw.

layout(push_constant) uniform PC {
    vec4 color;          // straight-alpha tint (a == opacity)
    vec2 dst_pos;        // top-left of the quad in pixels
    vec2 dst_size;       // size of the quad in pixels
    vec2 viewport_size;  // for NDC conversion
    vec2 uv_min;         // atlas UV at dst_pos
    vec2 uv_max;         // atlas UV at dst_pos + dst_size
} pc;

layout(location = 0) out vec2 v_uv;

// Two-triangle quad. Six corners indexed by gl_VertexIndex (0..5).
// Order is CCW so we stay consistent with frontFace = COUNTER_CLOCKWISE.
const vec2 CORNERS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 px = pc.dst_pos + corner * pc.dst_size;
    // Pixel-space → NDC. Vulkan's Y axis points down in framebuffer
    // coords, so the standard `y * 2 - 1` already matches: dst_pos.y
    // in pixels at the *top* of the window becomes -1 in NDC after
    // we pass 0 / viewport_height → -1.
    vec2 ndc = (px / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = mix(pc.uv_min, pc.uv_max, corner);
}
