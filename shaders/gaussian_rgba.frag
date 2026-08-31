#version 450

// One axis of a separable Gaussian over ALL FOUR channels, with an optional
// tint laid over the result. The frosted-glass blur, and the sibling of
// `gaussian_alpha.frag` — same kernel (`gaussian.glsl`), different reduction.
//
// **Why a second shader rather than a mode flag.** The two differ in their
// OUTPUT algebra, not their sampling. The alpha one collapses four channels
// to a coverage and multiplies a tint by it — a shadow is one colour at
// varying opacity. This one keeps the colour it sampled and composites a
// tint OVER it — frosted glass is the content, softened, behind a wash.
// A single shader doing both would carry a branch on every fragment of every
// pass to pick between two three-line endings.
//
// **What it replaces.** `frosted_glass.frag` was a 9-tap box blur, and its
// own header said "matches drop_shadow's tap shape" — which is exactly the
// tap shape that turned out to be nine ghosts rather than a blur. It read as
// less obviously broken there only because the thing being ghosted was
// already a flat panel; at `blur=28` on real content it smeared into the
// same triple image. The tap shape is now the Gaussian the name always
// claimed.
//
// **Premultiplied throughout, and it never encodes.** The source is a pool
// target written by pipelines that premultiply at output; the destination is
// another pool target. So there is no straighten/encode/re-premultiply round
// trip here — the display transform belongs at the composition point onto
// the host's attachment, exactly once, and that is `copy.frag`'s job at the
// end of the chain. The `display` member is present because every effect
// block carries the same fixed head, and it goes unread. The old
// `frosted_glass.frag` DID encode, and its header carried a note admitting
// it wrote non-premultiplied rgb against a `srcFactor = ONE` blend; moving
// the composite into the chain retires both problems rather than porting
// them.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_source;

#include "gaussian.glsl"

// Mirrors `GaussianRgbaUniforms` in `frosted_glass.zig` exactly. std140:
// `direction` takes the first vec2 and pads to the vec4 boundary, `tint`
// takes its own 16, and `sigma` opens the last slot.
layout(push_constant) uniform Params {
    vec2 display;      //  0..8   unread — see the header
    vec2 _display_pad; //  8..16
    vec2 corner_size;  // 16..24  the composite region, in pixels
    float corner_radius; // 24..28  corner radius, in pixels
    float _corner_pad;   // 28..32  — see element.CornerPush
    vec2 direction;    // (1,0) for the horizontal pass, (0,1) for vertical
    vec2 _dir_pad;
    vec4 tint;         // PREMULTIPLIED wash, laid over the blur. (0,0,0,0) = identity
    float sigma;       // gaussian sigma, in pixels
} u;

void main() {
    vec4 blurred = sparkGaussian(u_source, v_uv, u.direction, u.sigma);

    // Premultiplied "over": the tint is the source, the blur is the
    // destination. Both sides are already premultiplied, so this is the
    // whole composite — no divide, no re-multiply. `tint.a = 0` leaves
    // `blurred` untouched, which is why the horizontal pass can carry a zero
    // tint and the vertical one can carry the author's.
    out_color = u.tint + blurred * (1.0 - u.tint.a);
}
