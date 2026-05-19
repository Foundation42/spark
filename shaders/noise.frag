#version 450

// :::noise — hash-based value noise, octaves-summed for a fractal
// look. Effects-spec Phase A.5 third canary. Param shape (integer
// seed + integer octaves + float scale) is again deliberately
// distinct from gradient and pattern, exercising the resolver's
// f32 + u32 marshalling at the same time.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0, std140) uniform Params {
    uint seed;
    uint octaves;
    float scale;
    // std140 padding to next vec4; mirrored on Zig side.
} u;

// 2D hash → [0, 1) via Inigo Quilez's iqint-style scramble. Cheap,
// deterministic, no precomputed tables.
float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    vec2 p = v_uv * u.scale + float(u.seed);
    float v = 0.0;
    float amp = 1.0;
    float total = 0.0;
    // Cap octaves at 8 — anything more than that produces no visible
    // detail at typical canvas sizes and risks fragment-shader
    // latency spikes on weak GPUs.
    uint count = min(u.octaves, 8u);
    for (uint i = 0u; i < count; ++i) {
        v += hash(p) * amp;
        total += amp;
        p *= 2.0;
        amp *= 0.5;
    }
    v = total > 0.0 ? v / total : 0.0;
    out_color = vec4(vec3(v), 1.0);
}
