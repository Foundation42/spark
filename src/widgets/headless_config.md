---
state:
  greeting: "Hello from a headless document!"
  build_label: "session 9 / stage 10"
  invisible_counter: 0
---

# Section that should NOT appear

This entire markdown body lives inside a headless `:::embedded-document`.
Frontmatter values populate the child state (visible via the parent state
pointer if a future feature exposes cross-scope reads), but **none of
this prose, no headings, no quotes** make it to the screen.

> If you can see this paragraph, the headless flag isn't working — the
> doc was supposed to consume zero vertical space.

:::box {#never_visible color=#ff00ff width=100% height=200 radius=12}
:::

A 200px magenta box that you also shouldn't be seeing. The Component is
still instantiated (it ran through `factory.create`), the registry
holds it under the scope `config/never_visible`, but the layout walk
skips it because the outer `:::embedded-document` is headless.
