#version 450
// tri.frag — solid-fill triangle output. Premultiplied alpha at
// output so the pipeline's blend setting (srcFactor = ONE) works
// alongside quad / text. No SDF, no derivatives — flat colour.

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 out_color;

#include "display.glsl"

// Same push-constant block as the vertex stage — one range, both stages.
// Only `display` is read here; the layout must still match exactly.
layout(push_constant) uniform PC {
    vec2 viewport_size;
    vec2 world_offset;
    vec2 display;
} pc;

void main() {
    // Display transform before the premultiply — see display.glsl.
    vec3 rgb = sparkDisplay(v_color.rgb, pc.display);
    out_color = vec4(rgb * v_color.a, v_color.a);
}
