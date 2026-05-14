---
state:
  box_color: blue
  box_width: 240
  box_radius: 12
  target_id: "SAT-04"
---

# text_engine

## Stage 3 — markdown source becomes the tree

Same renderer as before — only the construction path changed. This document is parsed by *cmark* into an AST, then walked into an `element.Element` tree.

## Inline cascade

This paragraph uses *italic* and **bold** and ***bold-italic*** and `inline code` and a [link](https://example.com).

Underlines honour wrap — [this is a longer link with enough text inside its anchor that it spans more than one line, producing one underline quad per visible line of the link](https://example.com).

## Nesting

- block kinds nest
- indent shrinks `max_w` for nested content
- and items hold multiple blocks:
  1. first nested
  2. second nested

> Quotes indent their content, and indent propagates through Constraints so the inline-flow inside this quote wraps on the narrower available width — not on the full viewport width.

---

## Code

```zig
fn render(elem: Element) !void {
    // code blocks: monospace, preformatted
}
```

## Live components (stage 7a)

Block extensions parse, thread through the mapper as a sidecar, and re-materialise as `custom` Elements. The registry doesn't exist yet — every directive renders as a *missing-component* fallback panel. Real components arrive at stage 7c.

:::box {#bx color=${state.box_color} width=${state.box_width} height=80 radius=${state.box_radius}}
:::

:::3d-scene {#orbit-view src="models/${state.target_id}.gltf" width=100% height=400px}
animation: "orbital_drift"
:::

:::chart {#telemetry type=line x=time y=velocity}
time, velocity, temperature
00:01, 7400, 24.5
00:02, 7450, 24.8
:::
