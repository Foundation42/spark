// gaussian.glsl — one axis of a separable Gaussian, shared by every effect
// that blurs.
//
// **Why separable.** A Gaussian blur of radius R is O(R²) samples per pixel
// done directly and O(R) done as two 1D passes, because a 2D Gaussian is the
// outer product of two 1D ones. At the radii a UI actually asks for that is
// the difference between a shader that is fine on a card and one that is
// fine on a full-screen panel — and it is the reason the chain substrate
// exists at all. The two passes are the same shader with `direction`
// swapped, which is why this is a function and not a copy in each caller.
//
// **Why it is shared.** `gaussian_alpha.frag` (drop shadow) and
// `gaussian_rgba.frag` (frosted glass, and bloom after it) differ only in
// what they do with the blurred value. The kernel — the tap ceiling, the
// weights, the normalisation — is one thing, and two copies of it would
// drift the first time somebody tuned one.

#ifndef SPARK_GAUSSIAN_GLSL
#define SPARK_GAUSSIAN_GLSL

// The tap ceiling. sigma is clamped against it so the loop is bounded on any
// input: a runaway `blur` attribute costs a wide-but-finite blur rather than
// a hung GPU. 3 sigma covers 99.7% of the kernel, so a radius of 96 is a
// sigma of 32 — a 96px reach, well past what a panel asks for.
const int SPARK_GAUSSIAN_MAX_RADIUS = 96;

// One texel, in UV. Callers that displace their sampling point (a drop
// shadow's offset) need it before they can call the kernel, so it is exposed
// rather than left inside.
vec2 sparkTexel(sampler2D src) {
    return 1.0 / vec2(textureSize(src, 0));
}

// The blurred RGBA at `base`, along `direction` ((1,0) horizontal, (0,1)
// vertical).
//
// **Weights are evaluated, not tabulated.** A table would need a uniform
// buffer or a branchy switch on radius, and exp() is one instruction.
//
// **Normalised by the ACCUMULATED weight**, not by the analytic
// 1/(sigma·sqrt(2pi)). A truncated kernel does not sum to one, and dividing
// by the analytic constant darkens every result slightly — most at small
// sigma, where the truncation bites hardest.
//
// **Premultiplied in, premultiplied out.** Every offscreen target spark
// samples here was written by a pipeline that premultiplies at output, and a
// weighted sum of premultiplied colour is exactly the premultiplied weighted
// sum. Blurring straight colour would bleed the RGB of fully transparent
// texels into the result and halo every edge with whatever was in the
// cleared target's colour channels.
vec4 sparkGaussian(sampler2D src, vec2 base, vec2 direction, float sigma_in) {
    vec2 inv = sparkTexel(src);
    float sigma = clamp(sigma_in, 1e-4, float(SPARK_GAUSSIAN_MAX_RADIUS) / 3.0);
    int radius = int(ceil(sigma * 3.0));

    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (int i = -radius; i <= radius; i++) {
        float w = exp(-0.5 * float(i) * float(i) / (sigma * sigma));
        acc += texture(src, base + direction * float(i) * inv) * w;
        wsum += w;
    }
    return acc / max(wsum, 1e-6);
}

#endif
