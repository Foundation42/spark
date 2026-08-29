// display.glsl — the output display transform, shared by every shader that
// writes to the HOST'S attachment.
//
// A host may present to an SDR swapchain (8-bit UNORM, values are already
// display-referred) or to an HDR10 one (A2B10G10R10 + PQ / ST 2084, where a
// stored value is an absolute luminance code, not a brightness fraction).
// Spark's chrome is authored SDR: theme colours, glyph coverage, card fills.
// Written raw to a PQ surface those values read as 1000+ nit searchlights —
// white text becomes painful and a mid-grey card glows. So on a PQ surface
// the chrome is mapped to PAPERWHITE: the luminance a diffuse white page
// should sit at, which is what an SDR display would have shown.
//
// `display.x` selects: < 0.5 = passthrough (the surface wants what we
// already have), >= 0.5 = PQ encode. `display.y` is paperwhite in nits.
// Per-frame push constant rather than a pipeline variant, so one pipeline
// set serves both swapchain families and the host decides each frame.
//
// This is a straight port of matryoshka's `gizmoPq` (shaders/gizmo.frag),
// which solves the identical problem for its overlay chrome — the engine
// pushes `display` per frame from `hdr_output` + paperwhite and the gizmo
// fragment encodes itself. Keeping the two in lockstep is the point: HUD
// chrome and gizmo chrome sit on the same swapchain a millimetre apart, and
// two different transforms would show as two different whites.
//
// `src/gpu/display.zig` is the CPU mirror of `sparkPq`, and the readback
// gate in `src/tests/display_transform.zig` renders through this file and
// compares against that mirror. If you edit the maths here, that gate is
// what tells you the mirror no longer agrees.

#ifndef SPARK_DISPLAY_GLSL
#define SPARK_DISPLAY_GLSL

// Rec.709 (sRGB primaries) → Rec.2020, then ST 2084 (PQ) encode.
//
// `v` is a display-referred SDR value in 0..1. The 2.2 power is a decode to
// light — deliberately the pure power curve and not the piecewise sRGB EOTF,
// matching gizmoPq exactly. Scaling by paperwhite puts diffuse white where a
// page belongs rather than at PQ's 10000-nit ceiling.
vec3 sparkPq(vec3 v, float paperwhite_nits) {
    vec3 lin = paperwhite_nits * pow(max(v, vec3(0.0)), vec3(2.2));
    vec3 nits = vec3(
        dot(lin, vec3(0.6274040, 0.3292820, 0.0433136)),
        dot(lin, vec3(0.0690970, 0.9195400, 0.0113612)),
        dot(lin, vec3(0.0163916, 0.0880132, 0.8955950)));
    vec3 y = clamp(nits / 10000.0, vec3(0.0), vec3(1.0));
    vec3 ym = pow(y, vec3(0.1593017578125));
    return pow((0.8359375 + 18.8515625 * ym) / (1.0 + 18.6875 * ym), vec3(78.84375));
}

// The call every composite shader makes.
//
// MUST be applied to the UNPREMULTIPLIED colour, before the coverage/alpha
// multiply. Spark's pipelines blend with `srcFactor = ONE` and every shader
// premultiplies at output, and PQ is not linear: `pq(rgb * a)` is not
// `pq(rgb) * a`, and the first one darkens every anti-aliased glyph edge and
// every rounded corner as a function of its coverage. So the shape is always
//
//     vec3 rgb = sparkDisplay(colour.rgb, pc.display);
//     out_color = vec4(rgb * a, a);
//
// and never `sparkDisplay(colour.rgb * a, ...)`.
vec3 sparkDisplay(vec3 rgb, vec2 display) {
    if (display.x < 0.5) return rgb;
    return sparkPq(rgb, display.y);
}

#endif
