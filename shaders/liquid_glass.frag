#version 450

// :::liquid_glass — rounded-box SDF refraction + chromatic aberration
// + rim highlight + optional tint. Inspired by Apple's Liquid Glass
// effect on macOS Tahoe / iOS 19 panels.
//
// **Scope note.** This shader works ENTIRELY on the child's rendered
// content in the offscreen target. There's no sampling of MAIN, so
// the "refraction" is of the child itself — text/patterns inside the
// panel bend near the rounded corners as if viewed through curved
// glass. The Apple "see-through to background" look needs a second
// sampler bound to MAIN, which the v1 single_source pipeline layout
// doesn't expose. Phase D's HostSlotPass or a future ChainPass variant
// could light up that path.
//
// Effects-spec Phase B.6.d — third user-facing single_source factory.
// First factory authored AFTER the SingleSourceFactory comptime
// generator (B.6.c) — proves the generator's API holds up for new
// effects, not just refactor targets.
//
// **Algorithm:**
//   1. SDF from a rounded-box centered in v_uv space. Negative inside,
//      zero at the edge, positive outside.
//   2. Alpha edge fade via smoothstep — soft corner falloff.
//   3. Refraction: near the edge (depth_in low), bend the sampling UV
//      back toward center. Sharper near the edge via pow(1-depth, 2).
//      Deep inside is undistorted.
//   4. Chromatic aberration: tiny offset between R/G/B sampling
//      directions, scaled by the same edge-proximity factor as
//      refraction. Subtle prismatic effect at corners.
//   5. Rim highlight: bright thin band just inside the edge,
//      brightness scaled by `rim_brightness`.
//   6. Tint overlay: standard "over" composite of tint on the
//      refracted+highlighted result.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_target;

// Push-constant block mirrors `LiquidGlassUniforms` in
// liquid_glass.zig exactly. Four scalars pack into the first vec4
// slot (offset 0..16); vec4 `tint` lands at offset 16..32. Total
// 32 bytes.
layout(push_constant) uniform Params {
    float radius;          // corner radius, normalized [0..0.5]
    float refraction;      // bend strength [0..0.5]
    float edge_softness;   // smoothstep width at edge [0..0.05]
    float rim_brightness;  // edge highlight intensity [0..1]
    vec4 tint;             // overlay color (alpha = intensity)
} u_params;

// Signed distance to a rounded rectangle. p centered at origin,
// half_size in same scale. Returns negative inside, positive
// outside, zero at the edge. Standard IQ formulation.
float sdRoundedBox(vec2 p, vec2 half_size, float r) {
    vec2 d = abs(p) - half_size + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

void main() {
    // v_uv covers the offscreen target [0..1]^2. Center at origin
    // for SDF math.
    vec2 p = v_uv - 0.5;

    // SDF from the panel edge. The target IS the panel, so
    // half_size is exactly 0.5 along both axes in v_uv space.
    float sd = sdRoundedBox(p, vec2(0.5), u_params.radius);

    // Alpha edge fade — opaque inside, transparent outside, smooth
    // crossing. Early-out for fully transparent fragments saves the
    // refraction + sampling work entirely.
    float alpha = smoothstep(u_params.edge_softness, -u_params.edge_softness, sd);
    if (alpha <= 0.0) {
        out_color = vec4(0.0);
        return;
    }

    // Refraction strength: 1 right at the edge (inside), 0 deep
    // inside. Sharper near edge via pow(1-depth, 2).
    float depth_in = clamp(-sd / max(u_params.refraction, 1e-4), 0.0, 1.0);
    float bend = (1.0 - depth_in) * (1.0 - depth_in);

    // Pull the sampling UV back toward center proportional to bend.
    // Deep inside (bend=0): refracted_uv == v_uv (no distortion).
    // Near edge (bend=1): pulled toward center by refraction units.
    vec2 to_center = -p;
    vec2 refracted_uv = v_uv + to_center * bend * u_params.refraction;

    // Chromatic aberration — R and B sample along the radial
    // direction at small offsets, G samples at the refracted UV.
    // Strength scales with bend so corners get the prismatic flash
    // and the panel center stays clean.
    float ca = bend * u_params.refraction * 0.3;
    vec2 ca_dir = normalize(p + vec2(1e-6)); // avoid divide-by-zero at exact center
    float r_ch = texture(u_target, refracted_uv + ca_dir * ca).r;
    float g_ch = texture(u_target, refracted_uv).g;
    float b_ch = texture(u_target, refracted_uv - ca_dir * ca).b;
    vec3 rgb = vec3(r_ch, g_ch, b_ch);

    // Rim highlight — a thin bright band just inside the edge.
    // Width controlled by edge_softness; intensity by rim_brightness.
    float rim_inner = u_params.edge_softness * 4.0;
    float rim_outer = u_params.edge_softness * 8.0;
    float rim = smoothstep(0.0, rim_inner, -sd) - smoothstep(rim_inner, rim_outer, -sd);
    rgb += rim * u_params.rim_brightness;

    // Tint composite — standard "over" blend. tint.a = 0 means
    // tint is invisible; tint.a = 1 means tint fully replaces.
    rgb = rgb * (1.0 - u_params.tint.a) + u_params.tint.rgb * u_params.tint.a;

    out_color = vec4(rgb, alpha);
}
