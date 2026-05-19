#version 450
// tri.vert — flat-color triangle mesh pipeline (stage 13d.1).
//
// Unlike quad / text (which are instanced, with one SSBO entry per
// primitive and 6 verts generated per instance), this pipeline is a
// straightforward VBO + IBO setup: one vec2 position + vec4 colour
// per vertex, indexed triangle list. Best fit for SVG fills where
// triangle count varies wildly per path and per-vertex colour is
// uniform within a path (the tessellator bakes the path's fill
// into every vertex).
//
// Same coordinate convention as quad.vert: positions are in display
// pixels, viewport_size push-constant supplies the NDC conversion.
// `world_offset` mirrors quad.vert's: subtracts a target-space
// origin so the same VBO data renders into both the main attachment
// (world_offset = (0, 0)) and any single_source offscreen target
// (world_offset = compose_region.xy). Phase B.5 substrate.

layout(push_constant) uniform PC {
    vec2 viewport_size;
    vec2 world_offset;
} pc;

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec4 v_color;

void main() {
    vec2 ndc = ((in_pos - pc.world_offset) / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_color = in_color;
}
