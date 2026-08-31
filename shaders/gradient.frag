#version 450

// :::gradient — interpolate between two vec4 colors based on UV +
// a direction enum. Effects-spec Phase A.5 first canary fragment
// shader. Uniform layout mirrors `GradientUniforms` on the Zig
// side (extern struct, std140-compatible padding).

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

// Push-constant block per Phase A.6.b pipeline layout. std430-style
// tightly packed (matches `extern struct GradientUniforms` exactly).
// No descriptor set — uniforms ride in `vkCmdPushConstants` directly.
#include "display.glsl"
#include "corner.glsl"

// The display transform's per-frame push, at a FIXED offset so ONE record
// path can write it for every effect whatever its own uniforms look like.
// `element.PASS_UNIFORM_OFFSET` (16) is where each effect's own block
// starts; the Zig struct it mirrors describes the bytes from there on, and
// its offsets are relative to it rather than to this block.
layout(push_constant) uniform Params {
    vec2 display;      //  0..8   mode, paperwhite — see display.glsl
    vec2 _display_pad; //  8..16
    vec2 corner_size;  // 16..24  the composite region, in pixels
    float corner_radius; // 24..28  corner radius, in pixels
    float _corner_pad;   // 28..32  — see element.CornerPush
    vec4 from;       // 16..32
    vec4 to;         // 32..48
    uint direction;  // 48..52 — 0=vertical, 1=horizontal, 2=diagonal
    // Zig-side struct pads with `_pad: [3]u32` so sizeof is 48 and
    // every subsequent push-constant range starts at a vec4 boundary
    // if effects grow more fields.
} u;

void main() {
    float t;
    if (u.direction == 0u) {        // vertical — y-axis
        t = v_uv.y;
    } else if (u.direction == 1u) { // horizontal — x-axis
        t = v_uv.x;
    } else {                        // diagonal — (x+y)/2
        t = (v_uv.x + v_uv.y) * 0.5;
    }
    vec4 col = mix(u.from, u.to, t);
    // Unpremultiplied by construction — encode the colour, keep the alpha.
    float a = col.a * sparkCornerCoverage(v_uv, u.corner_size, u.corner_radius);
    out_color = vec4(sparkDisplay(col.rgb, u.display), a);
}
