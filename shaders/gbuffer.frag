#version 450

// :::gbuffer — a window onto a surface the HOST owns.
//
// The panels campaign's Northstar: place a panel anywhere on screen
// and see through it, in just that region, to what is underneath —
// the world-space normals, the raw albedo, a depth. Its buttons draw
// over the top for free, because a `.host_named` pass is a background
// to its own children exactly as a backdrop is.
//
// **Why this is a shader and not a blit.** A blit converts a FORMAT.
// Every surface worth looking at needs its VALUES remapped: a normal
// is signed and lives in [-1,1], a depth is non-linear and spends
// most of its range in the first metre, a motion vector is a
// direction and a magnitude wearing one vec2. None of that survives a
// copy. So the host's image arrives through a sampler and the
// remapping happens here — which is also why the G-buffer images
// needed `SAMPLED` usage added rather than `TRANSFER_SRC`.
//
// **The window.** `u_params.window` is written by spark at record
// time, not by the component: it needs the element's laid-out box and
// the host surface's own dimensions, and neither exists when the
// attributes are parsed. `(scale.xy, offset.xy)` maps this quad's own
// [0,1] UV onto the fraction of the surface the panel covers, so the
// panel shows what is genuinely beneath it and keeps doing so when it
// is dragged. The divisor is the surface's SPAN — the screen extent
// its full UV range covers — which is NOT its resolution: a half-res
// buffer covers the same screen with fewer texels, and a buffer
// written at a reduced dispatch footprint covers less of the screen
// than its allocation suggests. See `HostSurfaceImage.span_w`.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_surface;

#include "display.glsl"

// Modes. Kept as a float because the whole push block is scalars and
// an int would be the only one — see `GbufferUniforms` in
// components/effects/gbuffer.zig, which owns the names.
const int MODE_RAW     = 0; // straight through, for a surface already a picture
const int MODE_NORMAL  = 1; // signed direction -> colour
const int MODE_ALBEDO  = 2; // unsigned colour, alpha forced opaque
const int MODE_DEPTH   = 3; // non-linear scalar -> a curve you can read
const int MODE_LUMA    = 4; // one channel, as grey
const int MODE_HEAT    = 5; // one channel, as a ramp that separates values grey cannot
const int MODE_HDR     = 6; // radiance past 1.0 -> a picture, via exposure and a curve

layout(push_constant) uniform Params {
    vec2 display;      //  0..8   mode, paperwhite — see display.glsl
    vec2 _display_pad; //  8..16
    // The effect's own block starts here (element.PASS_UNIFORM_OFFSET).
    vec4 window;       // 16..32  scale.xy, offset.xy — WRITTEN BY SPARK
    float mode;        // 32..36
    float scale;       // 36..40
    float bias;        // 40..44
    float alpha;       // 44..48
    float channel;     // 48..52  which lane the scalar modes read
} u_params;

// Which lane `depth`, `luma` and `heat` take their scalar from.
//
// Not every scalar worth looking at is in `.r`. `producer.g` is the CSM
// visibility term beside a routing flag in `.r`; `sun.a` is the shadow
// gate under the radiance; `reflection.a` says whether the trace hit
// anything at all; `gtrans.a` is the foliage flag. All four are a
// channel selector away from being visible, and none of them is
// reachable by adding another mode.
float lane(vec4 src) {
    int ch = int(u_params.channel + 0.5);
    if (ch == 1) return src.g;
    if (ch == 2) return src.b;
    if (ch == 3) return src.a;
    return src.r;
}

// A ramp for a scalar whose interesting variation is small.
//
// `ao` and `shadow` live in a narrow band near 1.0, where a grey ramp
// shows a flat white sheet — the values are all there and the eye
// cannot separate them. This is the inferno family (black -> purple ->
// red -> orange -> pale yellow), chosen over the usual rainbow for one
// reason: it is MONOTONIC IN LIGHTNESS. A rainbow's green is lighter
// than its yellow-adjacent neighbours, so a rainbow-ramped image reads
// as banded where the data is smooth, and reads wrong in greyscale and
// to a colourblind viewer. This one keeps the "brighter means more"
// that a grey ramp has, and spends hue on discrimination.
vec3 heat(float t) {
    t = clamp(t, 0.0, 1.0);
    const vec3 c0 = vec3(0.001, 0.000, 0.014);
    const vec3 c1 = vec3(0.259, 0.039, 0.406);
    const vec3 c2 = vec3(0.578, 0.148, 0.404);
    const vec3 c3 = vec3(0.865, 0.317, 0.226);
    const vec3 c4 = vec3(0.988, 0.998, 0.645);
    float s = t * 4.0;
    if (s < 1.0) return mix(c0, c1, s);
    if (s < 2.0) return mix(c1, c2, s - 1.0);
    if (s < 3.0) return mix(c2, c3, s - 2.0);
    return mix(c3, c4, s - 3.0);
}

void main() {
    // NO Y flip, and the reason is worth stating because the vertex
    // shader's own comment invites one.
    //
    // `fullscreen.vert` says its UV origin is "the bottom-left of the
    // framebuffer". That is the OpenGL reading of the same arithmetic.
    // In Vulkan's NDC, y = -1 is the TOP of the viewport, so
    // `pos * 0.5 + 0.5` already gives 0 at the top — the same origin a
    // texture samples from. Every other effect on this path samples
    // `v_uv` straight and comes out the right way up; flipping here
    // mirrored the window vertically, which reads as a panel showing
    // the sky when it sits over the ground.
    //
    // The window's own offset is in the same top-down screen space
    // (`compose_region.y` counts down from the top), so the two agree
    // with no correction between them.
    vec2 uv = v_uv * u_params.window.xy + u_params.window.zw;

    vec4 src = texture(u_surface, uv);
    int mode = int(u_params.mode + 0.5);

    vec3 rgb;
    if (mode == MODE_NORMAL) {
        // A world-space normal is signed. Renormalise first: the
        // G-buffer stores 0 where nothing was written (non-rep pixels),
        // and normalising a zero vector is a NaN that spreads through
        // the tonemap. Length check, then the standard remap.
        vec3 n = src.xyz;
        float len = length(n);
        rgb = len > 1e-4 ? (n / len) * 0.5 + 0.5 : vec3(0.0);
    } else if (mode == MODE_ALBEDO) {
        rgb = src.rgb;
    } else if (mode == MODE_DEPTH) {
        // Depth spends most of its range very close to the eye, so a
        // linear ramp reads as a white sheet. The reciprocal curve
        // gives back the near field; `scale` tunes where it sits.
        float d = lane(src) * u_params.scale + u_params.bias;
        rgb = vec3(1.0 / (1.0 + max(d, 0.0)));
    } else if (mode == MODE_LUMA) {
        rgb = vec3(lane(src) * u_params.scale + u_params.bias);
    } else if (mode == MODE_HEAT) {
        rgb = heat(lane(src) * u_params.scale + u_params.bias);
    } else if (mode == MODE_HDR) {
        // Radiance, not a picture. `composite`, `sun`, `nee`,
        // `env_diff`, `reflection`, `light_*` and `storage` all run
        // well past 1.0, and the clamp at the bottom of this shader
        // turns a bright scene into a flat white rectangle — the data
        // is all there and none of it is legible.
        //
        // `scale` is the exposure: it multiplies BEFORE the curve, so
        // turning it down brings the highlights back rather than
        // dimming an already-clipped picture.
        //
        // Reinhard, per channel, on purpose. It is monotonic, it maps
        // [0,inf) onto [0,1), and it applies to each channel
        // independently — so a pixel that is bright in red only stays
        // red. A luminance-based operator would be prettier and would
        // hide exactly the per-channel imbalance somebody opens this
        // panel to find. Nothing here is grading; it is reading.
        vec3 e = max(src.rgb * u_params.scale, 0.0);
        rgb = e / (1.0 + e) + u_params.bias;
    } else {
        rgb = src.rgb;
    }

    if (mode == MODE_NORMAL || mode == MODE_ALBEDO || mode == MODE_RAW) {
        rgb = rgb * u_params.scale + u_params.bias;
    }

    // The surface holds DATA and this shader has just made a PICTURE
    // out of it, so the display transform applies exactly as it does
    // to anything else spark authors — unlike a backdrop, whose pixels
    // arrived already carrying it. `spark.zig` picks `displayFor(att)`
    // for `.host_named` for this reason.
    rgb = sparkDisplay(clamp(rgb, 0.0, 1.0), u_params.display);
    float a = u_params.alpha;
    // Premultiplied out, like every other compose on this path.
    out_color = vec4(rgb * a, a);
}
