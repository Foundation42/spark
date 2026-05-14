#version 450
// text.frag — Phase 0 stub. Phase 2 introduces atlas sampling and
// grayscale alpha coverage; Phase 6 splits this into hinted-coverage
// vs MSDF-coverage branches keyed by a per-glyph `fx_kind` flag, with
// the attention attribute modulating the MSDF threshold (thin / bold
// / glow) so the LM overlay can drive visual emphasis without a
// re-bake. For now it just emits a recognisable color so we can eyeball
// the pipeline running.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

void main() {
    o_color = vec4(v_uv, 0.4, 1.0);
}
