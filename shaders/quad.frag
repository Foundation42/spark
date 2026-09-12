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
//
// nose > 0: the right end tapers to a point, so the quad draws as a
// TAG rather than a rectangle. Two half-planes `max`-ed into the same
// distance, which is what an intersection is — so the taper's edges
// get the smoothstep already there and need no geometry of their own.
// Chris, 2026-09-12, on the node graph's bare connector nodes: *"can
// we do it mathematically in the shader?"* We can, and it is the only
// place it can be done: the quad layer draws OVER the triangle layer
// whatever order things were emitted in, so a diagonal built out of
// triangles would sink underneath every wire on the canvas.

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_size;
layout(location = 2) in vec4 v_color;
layout(location = 3) flat in float v_radius;
layout(location = 4) flat in float v_nose;

layout(location = 0) out vec4 out_color;

#include "display.glsl"

// Same push-constant block as the vertex stage — one range, both stages.
// Only `display` is read here; the layout must still match exactly.
layout(push_constant) uniform PC {
    vec2 viewport_size;
    vec2 world_offset;
    vec2 display;
} pc;

float roundedBoxSDF(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Distance to the tapered right end: the two edges running from
// (w - nose, 0) and (w - nose, h) to the tip at (w, h/2), as outward
// half-planes. Exact on the edges, and inside a pixel of the tip it
// under-reads by a hair — which is a smoothstep band, not a shape.
float noseSDF(vec2 local, vec2 size, float nose) {
    vec2 back = vec2(size.x - nose, 0.0);
    vec2 n_up = normalize(vec2(size.y * 0.5, -nose));
    vec2 n_dn = normalize(vec2(size.y * 0.5,  nose));
    return max(dot(local - back, n_up),
               dot(local - vec2(back.x, size.y), n_dn));
}

void main() {
    float coverage;
    if (v_radius <= 0.0 && v_nose <= 0.0) {
        coverage = 1.0;
    } else {
        // Centre-relative pixel position; SDF gives negative inside,
        // positive outside, zero on the edge. A radius of 0 here is a
        // plain box, which is exactly right when only the nose is set.
        vec2 p = v_local - v_size * 0.5;
        float d = roundedBoxSDF(p, v_size * 0.5, v_radius);
        if (v_nose > 0.0) d = max(d, noseSDF(v_local, v_size, v_nose));
        coverage = 1.0 - smoothstep(-0.5, 0.5, d);
    }
    // Display transform BEFORE the premultiply — PQ is not linear, so
    // encoding the premultiplied value would darken every anti-aliased
    // corner as a function of its own coverage. See display.glsl.
    vec3 rgb = sparkDisplay(v_color.rgb, pc.display);
    // Premultiply at output so srcFactor = ONE blend works.
    float a = v_color.a * coverage;
    out_color = vec4(rgb * a, a);
}
