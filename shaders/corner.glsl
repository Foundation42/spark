// corner.glsl — rounded-corner coverage for effect composites.
//
// A rounded corner is a property of the COMPOSITE: the shape the finished
// pass is poured into, not something any particular filter computes. So the
// radius rides in the fixed push head (`element.CornerPush`) alongside the
// display transform, and every effect shader that lands on a real surface
// multiplies its alpha by `sparkCornerCoverage`.
//
// ## Why this is in pixels
//
// `liquid_glass.frag` used to compute its own SDF in normalised UV against
// a half-extent of `vec2(0.5)`. Two things go wrong with that, and both are
// visible:
//
//   1. **The corner is an ellipse.** On a 320x210 panel a radius of 0.15 is
//      48 pixels across and 31.5 down. It is only a circle on a square
//      panel, and no panel is square.
//   2. **The antialiasing band is a guess.** A fixed `edge_softness` in a
//      stretched space is a different number of pixels on each axis and
//      changes with the panel's size and the zoom. Too small and the corner
//      aliases; too large and it smears. There is no value that is right at
//      two sizes.
//
// `quad.frag` has always done it correctly for block chrome — SDF in pixel
// space, one-pixel smoothstep band — and this is the same maths, shared,
// with the band taken from the screen-space gradient rather than from a
// constant so it stays one pixel under any transform.

#ifndef SPARK_CORNER_GLSL
#define SPARK_CORNER_GLSL

// Signed distance to a rounded rectangle. `p` is centre-relative,
// `half_size` and `r` in the same units. Negative inside, zero on the
// edge. The standard IQ formulation, same as `quad.frag`'s.
float sparkRoundedBoxSDF(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Coverage in [0, 1] for a fragment at `uv` (the target's own [0,1] range)
// inside a composite `size_px` across with `radius_px` corners.
//
// Returns exactly 1.0 for a zero radius, before any of the maths runs, so
// the overwhelmingly common square case costs a compare.
float sparkCornerCoverage(vec2 uv, vec2 size_px, float radius_px) {
    if (radius_px <= 0.0) return 1.0;

    vec2 half_size = size_px * 0.5;
    // A radius past the half-extent is a stadium, not a bad value — clamp
    // rather than refuse, so `radius=9999` reads as "as round as it goes"
    // instead of inverting the SDF.
    float r = min(radius_px, min(half_size.x, half_size.y));
    float d = sparkRoundedBoxSDF((uv - 0.5) * size_px, half_size, r);

    // The AA band, in the fragment's own footprint. `fwidth` is the
    // screen-space derivative of the distance, so `d / fwidth(d)` is the
    // distance measured in PIXELS however the composite is scaled — one
    // pixel of coverage at any size, aspect or zoom, with no knob.
    float w = max(fwidth(d), 1e-5);
    return clamp(0.5 - d / w, 0.0, 1.0);
}

#endif
