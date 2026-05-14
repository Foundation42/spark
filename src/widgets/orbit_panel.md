---
state:
  panel_color: orange
  panel_height: 60
  inner_color: yellow
  inner_radius: 6
---

A nested document. Frontmatter values become the **child state**;
parent attrs on the embed overlay onto them at create time so the
embed line in `demo.md` wins on conflict.

:::box {#outer color=${state.panel_color} width=100% height=${state.panel_height} radius=10}
:::

:::box {#inner color=${state.inner_color} width=60% height=28 radius=${state.inner_radius}}
:::

Drag the slider below to resize the outer panel. The slider is *inside* the embedded document, and its `target=panel_height` mutates **child state**, not the parent's — proving the input-scope plumbing routes events to the right state.

:::slider {#panel_height_slider target=panel_height min=20 max=160 value=${state.panel_height} width=320}
:::

These three components share the parent's registry but resolve under the scope `orbit/...` — no collision with the parent's ids even if they happened to share an `#id`.
