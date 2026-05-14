---
state:
  primary: red
  secondary: yellow
  tertiary: green
  bar_height: 36
---

This document was **loaded over HTTP** from `http://127.0.0.1:8080/remote_panel.md`. The host's demo server is serving `src/widgets/` on localhost; the embedded-document factory fetched and parsed it at startup, then cached the bytes for the rest of the session.

The first bar's colour comes from the *parent's* `state.box_color` via `primary=${state.box_color}` on the embed line, so it follows the 1.5s colour cycle — a live state path reaching across the network boundary.

:::box {#a color=${state.primary} width=80% height=${state.bar_height} radius=8}
:::

:::box {#b color=${state.secondary} width=60% height=${state.bar_height} radius=8}
:::

:::box {#c color=${state.tertiary} width=40% height=${state.bar_height} radius=8}
:::
