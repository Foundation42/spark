#version 450
// tri.frag — solid-fill triangle output. Premultiplied alpha at
// output so the pipeline's blend setting (srcFactor = ONE) works
// alongside quad / text. No SDF, no derivatives — flat colour.

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(v_color.rgb * v_color.a, v_color.a);
}
