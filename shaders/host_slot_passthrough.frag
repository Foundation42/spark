#version 450

// Default composite shader for the `.host_slot` PassShape arm
// (Effects-spec Phase B.7). Trivial passthrough: samples the
// host-filled offscreen target and writes the result to the
// compose region on the destination attachment. No push-constant
// block — `recordHostSlotCompose` doesn't push uniforms (v1
// HostSlotStep carries none).
//
// Distinct from `copy.frag` (the B.4.b SingleSourcePipelineCache
// substrate test shader) precisely because copy.frag declares a
// push-constant `alpha` it expects to be written. Reusing copy.frag
// here would either force `recordHostSlotCompose` to push a fixed
// alpha = 1.0 (hardcoding a uniform shape into the dispatch site,
// which Phase D real composite shaders would have to inherit) or
// leave the push range undefined (validation noise + possibly
// black output depending on driver). A dedicated passthrough is
// the lower-friction path.
//
// Phase D real-scene composite shaders (tone-map, vignette, etc.)
// register alongside this one and may declare their own push-
// constant ranges; the dispatch site stays passthrough-shaped
// because Phase D pairs each shader with its own dispatch helper
// when it lands.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_target;

#include "display.glsl"

// The display transform's per-frame push, at a FIXED offset so ONE record
// path can write it for every effect whatever its own uniforms look like.
// `element.PASS_UNIFORM_OFFSET` (16) is where each effect's own block
// starts; the Zig struct named below describes the bytes from there on and
// its offsets are relative to it, not to this block.
// This shader has no uniforms of its own, so the block is the head alone.
layout(push_constant) uniform Params {
    vec2 display;      // 0..8
    vec2 _display_pad; // 8..16
} u_params;

void main() {
    vec4 src = texture(u_target, v_uv);
    // Premultiplied source — see copy.frag for why the round trip.
    vec3 straight = src.a > 0.0 ? src.rgb / src.a : src.rgb;
    vec3 rgb = sparkDisplay(straight, u_params.display);
    out_color = vec4(rgb * src.a, src.a);
}
