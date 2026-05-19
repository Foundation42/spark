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
layout(push_constant) uniform Params {
    vec4 from;       // 0..16
    vec4 to;         // 16..32
    uint direction;  // 32..36 — 0=vertical, 1=horizontal, 2=diagonal
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
    out_color = mix(u.from, u.to, t);
}
