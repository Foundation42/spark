#version 450

// :::pattern — geometric pattern fill (checker / stripes / grid /
// dots) parameterised by an enum + a seed for cell-size variation.
// Effects-spec Phase A.5 second canary. Different param shape from
// :::gradient (enum + integer vs vec4×2 + enum) exercises the
// resolver's typed-marshalling more diversely.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

// Push-constant block — see gradient.frag for the policy comment.
layout(push_constant) uniform Params {
    uint pattern_type;  // 0=checker, 1=stripes, 2=grid, 3=dots
    uint seed;          // perturbs the cell count
} u;

void main() {
    // Cell count derived from seed so different seeds produce
    // visually distinct grids without changing the math.
    float cells = 8.0 + float(u.seed % 8u);
    vec2 scaled = v_uv * cells;
    vec2 i = floor(scaled);
    vec2 f = fract(scaled);

    float v;
    if (u.pattern_type == 0u) {        // checker
        v = mod(i.x + i.y, 2.0);
    } else if (u.pattern_type == 1u) { // stripes
        v = mod(i.x, 2.0);
    } else if (u.pattern_type == 2u) { // grid
        v = (f.x < 0.1 || f.y < 0.1) ? 1.0 : 0.0;
    } else {                            // dots
        vec2 c = f - 0.5;
        v = (length(c) < 0.3) ? 1.0 : 0.0;
    }
    out_color = vec4(vec3(v), 1.0);
}
