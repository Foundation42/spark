#version 450

// One axis of a separable Gaussian reduced to a SINGLE channel, tinted on
// the way out. The drop shadow's blur. Effects-spec Phase C.2 — the first
// shader written to run as a CHAIN step rather than as a whole effect.
//
// The kernel itself lives in `gaussian.glsl`, shared with
// `gaussian_rgba.frag`. What is left here is the shadow-specific part: the
// offset, the channel reduction, the spread, and the tint.
//
// **What it replaces.** The Phase B.5 drop shadow was a 9-tap box: three
// taps per axis, separated by the full blur radius. That does not read as a
// blur, it reads as NINE COPIES of the content, which is what a capture of
// the matryoshka Lab showed at blur=8 — the heading legible three times
// across and three times down. A box blur with taps at the sample spacing is
// a blur; a box blur with taps at the radius is a ghost.
//
// **Channel selection, not a hardcoded `.a`.** The first pass blurs the
// child's ALPHA (the silhouette casting the shadow); the second pass blurs
// the first pass's output, which is a greyscale image. Reading `.a` on the
// second pass would work on an 8-bit target and destroy the shadow on a
// 10-bit HDR one, where the swapchain format is A2B10G10R10 and alpha
// carries TWO BITS. `channel` is a dot-product mask, so pass one reads
// alpha, pass two reads red, and the intermediate rides in the ten-bit
// channels on both swapchain families.
//
// **Reduce after the blur, not during it.** This shader used to accumulate
// `dot(texel, channel) * w` inside its own loop. Blurring all four channels
// and taking the dot afterwards is the same number, exactly and not just
// nearly: a mask with one 1 and three 0s selects a lane, and that lane's
// accumulation is the identical sequence of multiplies and adds either way.
// The dot is free — `texture()` fetches four channels regardless — and the
// kernel becomes shareable, which is the whole point.
//
// **Orientation.** `fullscreen.vert` hands us `v_uv` derived from Vulkan
// NDC, where y = -1 is the TOP of the framebuffer — so v_uv has its origin
// at the top-left, exactly like `texture()`'s. Sampling at `v_uv` directly
// is upright, and +offset.y moves the shadow DOWN, which is what an author
// writing `offset_y=4` means. (The comment in `fullscreen.vert` calls the
// origin bottom-left; that is a GL habit and it is wrong about Vulkan.)

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_source;

#include "gaussian.glsl"

// Mirrors `GaussianUniforms` in `drop_shadow.zig` exactly. std140: two
// vec2s pack into the first 16 bytes, each vec4 takes its own 16, and the
// two trailing floats share the last slot.
layout(push_constant) uniform Params {
    // The display head every effect block carries, so one record path can
    // write push constants for all of them. This shader NEVER encodes: a
    // chain step's destination is a ping-pong pool target, and the encode
    // belongs at the composition point exactly once. The record path sends
    // it `Push.offscreen` (passthrough) and the member goes unread.
    vec2 display;      //  0..8
    vec2 _display_pad; //  8..16
    vec2 corner_size;  // 16..24  the composite region, in pixels
    float corner_radius; // 24..28  corner radius, in pixels
    float _corner_pad;   // 28..32  — see element.CornerPush
    vec2 direction;   // (1,0) for the horizontal pass, (0,1) for vertical
    vec2 offset;      // where the shadow sits relative to the caster, pixels
    vec4 channel;     // dot-product mask: (0,0,0,1) alpha, (1,0,0,0) red
    vec4 tint;        // premultiplied output colour, scaled by the blurred value
    float sigma;      // gaussian sigma, in pixels
    float spread;     // 0..0.95 — Photoshop's "Spread", applied after the blur
} u;

void main() {
    vec2 base = v_uv - u.offset * sparkTexel(u_source);
    float a = dot(sparkGaussian(u_source, base, u.direction, u.sigma), u.channel);

    // Spread fattens the shadow by lifting the whole falloff and clipping
    // the top — the cheap read of Photoshop's pre-blur dilate. At 0 it is
    // the identity, which is why it is safe as the default.
    a = clamp(a / max(1.0 - u.spread, 1e-3), 0.0, 1.0);

    out_color = u.tint * a;
}
