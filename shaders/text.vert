#version 450
// text.vert — Phase 0 stub. Will become the per-glyph instanced quad
// vertex stage in Phase 3: gl_VertexIndex picks the corner of a unit
// quad, gl_InstanceIndex indexes into a Glyph SSBO holding atlas UV,
// per-glyph transform, color, and the attention attribute for the LM
// metadata channel. For now it emits a fullscreen triangle so the
// pipeline compiles and validation has something well-formed to
// rasterise.

layout(location = 0) out vec2 v_uv;

void main() {
    // Fullscreen triangle via index arithmetic (no vertex buffer).
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    v_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
