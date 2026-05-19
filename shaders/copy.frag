#version 450

// :::copy — substrate smoke shader for single-source effects.
// Effects-spec Phase B.4.b.1. Not a user-facing factory — it
// exists so the SingleSourcePipelineCache's eager-compile path
// gets exercised end-to-end at substrate-test time, before B.5
// ships the first real filter (`:::drop_shadow`).
//
// Trivial passthrough: samples the offscreen target via the
// combined-image-sampler descriptor and writes the result to
// `compose_region` on the destination attachment, modulated by
// a single-float push-constant. Two things this validates that
// `gradient.frag` / `pattern.frag` / `noise.frag` cannot:
//
//   1. The combined-image-sampler descriptor binding shape
//      (set 0, binding 0) matches the SingleSourcePipelineCache's
//      VkDescriptorSetLayout exactly. Validation layers catch
//      shader-vs-layout mismatch at vkCreateGraphicsPipelines.
//   2. The push-constant range coexists with a descriptor set
//      (pattern shaders only exercise push constants, no
//      descriptors — different pipeline-layout shape).
//
// V flip: `fullscreen.vert` produces v_uv with origin at the
// framebuffer's bottom-left. Vulkan textures sample with origin
// at the top-left, so `texture()` against `v_uv` directly would
// render upside-down. Filter shaders that land at B.5+ choose
// their own sampling orientation; for substrate validation we
// just want the bind to work, so a straight passthrough is fine
// — orientation correctness is a B.5 concern, not a B.4.b one.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_target;

// Push-constant block mirrors `CopyUniforms` on the Zig side.
// One f32, padded to 4 bytes; substrate test sets `alpha = 1.0`
// to exercise the bind without altering the sampled value.
layout(push_constant) uniform Params {
    float alpha;
} u_params;

void main() {
    out_color = texture(u_target, v_uv) * u_params.alpha;
}
