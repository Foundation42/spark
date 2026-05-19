#version 450
// image.vert — textured-quad pipeline (stage 14c).
//
// Each draw issues one `vkCmdDraw(6,1,0,0)` with the per-image
// descriptor bound (combined image sampler at set 0 / binding 0).
// Push constants supply the destination rect and the viewport scale
// for the NDC conversion — same convention as quad.vert / tri.vert.
//
// We generate the unit square via `gl_VertexIndex` like quad.vert,
// then position it at `dst_pos + corner * dst_size`. The matching UV
// is the corner itself (0..1 across each axis) so the sampler reads
// the whole image stretched to the destination rect.
//
// `world_offset` mirrors quad.vert's: subtracts a target-space origin
// so the same dst_pos renders into both the main attachment
// (world_offset = (0, 0)) and any single_source offscreen target
// (world_offset = compose_region.xy). Phase B.5 substrate.

layout(push_constant) uniform PC {
    vec2 viewport_size;
    vec2 world_offset;
    vec2 dst_pos;
    vec2 dst_size;
} pc;

layout(location = 0) out vec2 v_uv;

const vec2 CORNERS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 px = (pc.dst_pos - pc.world_offset) + corner * pc.dst_size;
    vec2 ndc = (px / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = corner;
}
