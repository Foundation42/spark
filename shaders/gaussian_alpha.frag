#version 450

// One axis of a separable Gaussian over a single channel, tinted on the
// way out. Effects-spec Phase C.2 — the first shader written to run as a
// CHAIN step rather than as a whole effect.
//
// **Why separable.** A Gaussian blur of radius R over an image is O(R²)
// samples per pixel done directly, and O(R) done as two 1D passes, because
// a 2D Gaussian is the outer product of two 1D ones. At the blur radii a
// drop shadow actually wants that is the difference between a shader that
// is fine on a card and one that is fine on a full-screen panel — and it is
// the reason the chain substrate exists at all. The two passes are the same
// shader with `direction` swapped.
//
// **What it replaces.** The Phase B.5 drop shadow was a 9-tap box: three
// taps per axis, separated by the full blur radius. That does not read as a
// blur, it reads as NINE COPIES of the content, which is what a capture of
// the matryoshka Lab showed at blur=8 — the heading legible three times
// across and three times down. A box blur with taps at the sample spacing
// is a blur; a box blur with taps at the radius is a ghost.
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
// **Orientation.** `fullscreen.vert` hands us `v_uv` derived from Vulkan
// NDC, where y = -1 is the TOP of the framebuffer — so v_uv has its origin
// at the top-left, exactly like `texture()`'s. Sampling at `v_uv` directly
// is upright, and +offset.y moves the shadow DOWN, which is what an author
// writing `offset_y=4` means. (The comment in `fullscreen.vert` calls the
// origin bottom-left; that is a GL habit and it is wrong about Vulkan.)

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_source;

// Mirrors `GaussianUniforms` in `drop_shadow.zig` exactly. std140: two
// vec2s pack into the first 16 bytes, each vec4 takes its own 16, and the
// two trailing floats share the last slot.
layout(push_constant) uniform Params {
    vec2 direction;   // (1,0) for the horizontal pass, (0,1) for vertical
    vec2 offset;      // where the shadow sits relative to the caster, pixels
    vec4 channel;     // dot-product mask: (0,0,0,1) alpha, (1,0,0,0) red
    vec4 tint;        // premultiplied output colour, scaled by the blurred value
    float sigma;      // gaussian sigma, in pixels
    float spread;     // 0..0.95 — Photoshop's "Spread", applied after the blur
} u;

// The tap ceiling. sigma is clamped so the loop is bounded on any input:
// a runaway `blur` attribute costs a wide-but-finite shadow rather than a
// hung GPU. 3 sigma covers 99.7% of the kernel, so RADIUS 96 is a sigma of
// 32 — a 96px halo, well past what a UI shadow asks for.
const int MAX_RADIUS = 96;

void main() {
    vec2 inv = 1.0 / vec2(textureSize(u_source, 0));
    vec2 base = v_uv - u.offset * inv;

    float sigma = clamp(u.sigma, 1e-4, float(MAX_RADIUS) / 3.0);
    int radius = int(ceil(sigma * 3.0));

    // Weights are evaluated rather than tabulated: a table would need a
    // uniform buffer or a branchy switch on radius, and exp() is one
    // instruction. The normalisation is by the ACCUMULATED weight, not by
    // the analytic 1/(sigma*sqrt(2pi)) — a truncated kernel does not sum to
    // one, and dividing by the analytic constant darkens every shadow
    // slightly, more so at small sigma where the truncation bites hardest.
    float acc = 0.0;
    float wsum = 0.0;
    for (int i = -radius; i <= radius; i++) {
        float w = exp(-0.5 * float(i) * float(i) / (sigma * sigma));
        vec4 texel = texture(u_source, base + u.direction * float(i) * inv);
        acc += dot(texel, u.channel) * w;
        wsum += w;
    }
    float a = acc / max(wsum, 1e-6);

    // Spread fattens the shadow by lifting the whole falloff and clipping
    // the top — the cheap read of Photoshop's pre-blur dilate. At 0 it is
    // the identity, which is why it is safe as the default.
    a = clamp(a / max(1.0 - u.spread, 1e-3), 0.0, 1.0);

    out_color = u.tint * a;
}
