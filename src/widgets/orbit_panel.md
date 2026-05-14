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

These two `:::box` components share the parent's registry but resolve
under the scope `orbit/outer` and `orbit/inner` — no collision with
the parent's `#bx` even if they shared an `#id`.
