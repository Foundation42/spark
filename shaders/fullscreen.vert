#version 450

// Fullscreen-triangle vertex passthrough — shared by every effect
// fragment shader from effects-spec Phase A.5 onward. Three vertices
// produce a single oversize triangle covering the entire viewport;
// the rasterizer clips the parts outside [-1, 1]². One draw call,
// no vertex buffer, no IBO — the host issues `vkCmdDraw(cmd, 3, 1, 0, 0)`.
//
// Why a triangle and not a quad (two triangles): the shared edge of
// a quad causes some GPUs to invoke the fragment shader twice along
// that seam (helper-pixel duplication). One big triangle has no
// internal edges, so every pixel is shaded exactly once. Cheaper.
//
// vertex 0: (-1, -1) — bottom-left
// vertex 1: ( 3, -1) — bottom-right (off-screen, clipped to (1, -1))
// vertex 2: (-1,  3) — top-left (off-screen, clipped to (-1, 1))

layout(location = 0) out vec2 v_uv;

void main() {
    vec2 pos = vec2(
        (gl_VertexIndex == 1) ? 3.0 : -1.0,
        (gl_VertexIndex == 2) ? 3.0 : -1.0
    );
    // UV in [0, 1] — origin at the bottom-left of the framebuffer.
    // Fragment shaders flip Y at sample-time if they need
    // top-left-origin sampling (Vulkan textures default to top-left).
    v_uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);
}
