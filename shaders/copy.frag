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
#include "display.glsl"
#include "corner.glsl"

// The display transform's per-frame push, at a FIXED offset so ONE record
// path can write it for every effect whatever its own uniforms look like.
// `element.PASS_UNIFORM_OFFSET` (16) is where each effect's own block
// starts; the Zig struct named below describes the bytes from there on and
// its offsets are relative to it, not to this block.
layout(push_constant) uniform Params {
    vec2 display;      //  0..8   mode, paperwhite — see display.glsl
    vec2 _display_pad; //  8..16
    vec2 corner_size;  // 16..24  the composite region, in pixels
    float corner_radius; // 24..28  corner radius, in pixels
    float _corner_pad;   // 28..32  — see element.CornerPush
    float alpha;       // 16..20  `CopyUniforms` on the Zig side
} u_params;

void main() {
    vec4 src = texture(u_target, v_uv);
    // The sampled target is PREMULTIPLIED — it was rendered by pipelines
    // that premultiply at output. PQ is not linear, so `pq(rgb * a)` is not
    // `pq(rgb) * a`; encoding the premultiplied value darkens every
    // antialiased edge as a function of its own coverage. Undo, encode,
    // redo. See display.glsl's note, which says the same thing for the
    // shaders that own their colour rather than sampling it.
    vec3 straight = src.a > 0.0 ? src.rgb / src.a : src.rgb;
    vec3 rgb = sparkDisplay(straight, u_params.display);
    // The composite's corner, from the fixed head. `copy.frag` is the
    // final composite for BOTH chain effects, so this one line is what
    // gives `:::drop_shadow` and `:::frosted_glass` rounded corners.
    float a = src.a * u_params.alpha
        * sparkCornerCoverage(v_uv, u_params.corner_size, u_params.corner_radius);
    out_color = vec4(rgb * a, a);
}
