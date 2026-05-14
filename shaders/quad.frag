#version 450
// quad.frag — filled rectangle with optional rounded corners +
// edge anti-aliasing. Outputs premultiplied alpha so the shared
// pipeline blend setting (srcFactor = ONE) works alongside the
// glyph pipeline.
//
// radius == 0 path: flat fill, no SDF math — the common case for
// block chrome where corners are sharp.
//
// radius > 0 path: standard rounded-box signed distance + smoothstep
// AA over a 1-pixel band. Distance is in pixel space (because v_local
// + v_size are pixel coords), so the smoothstep band is constant
// regardless of quad size — anti-aliasing looks consistent at any
// scale.

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_size;
layout(location = 2) in vec4 v_color;
layout(location = 3) flat in float v_radius;

layout(location = 0) out vec4 out_color;

float roundedBoxSDF(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    float coverage;
    if (v_radius <= 0.0) {
        coverage = 1.0;
    } else {
        // Centre-relative pixel position; SDF gives negative inside,
        // positive outside, zero on the edge.
        vec2 p = v_local - v_size * 0.5;
        float d = roundedBoxSDF(p, v_size * 0.5, v_radius);
        coverage = 1.0 - smoothstep(-0.5, 0.5, d);
    }
    // Premultiply at output so srcFactor = ONE blend works.
    out_color = vec4(v_color.rgb * v_color.a * coverage, v_color.a * coverage);
}
