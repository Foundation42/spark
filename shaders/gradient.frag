#version 450

// :::gradient — interpolate between two vec4 colors based on UV +
// a direction enum. Effects-spec Phase A.5 first canary fragment
// shader. Uniform layout mirrors `GradientUniforms` on the Zig
// side (extern struct, std140-compatible padding).

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0, std140) uniform Params {
    vec4 from;       // 0..16
    vec4 to;         // 16..32
    uint direction;  // 32..36 — 0=vertical, 1=horizontal, 2=diagonal
    // std140 pads scalars to the next vec4 boundary (16-byte align).
    // The Zig-side struct mirrors this with `_pad: [3]u32`.
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
