# Shader effects (stage 17)

Pattern-pass and single-source effects exercised through the pass-graph compiler. Pattern factories cover their `width × height` region with a fullscreen quad whose fragment shader reads push-constant uniforms straight to the GPU; single-source factories render their wrapped child content into an offscreen target, then composite a filtered result (blur, glass) back over the main attachment. See `docs/effects-spec.md` for the full roadmap.

Load this doc with `./spark_demo src/effect.md`.

## Gradient — vec4 + enum

Two colors interpolated across the region in the chosen direction. Author-friendly hex literals get parsed into normalised RGBA and pushed as `vec4` uniforms; `direction` resolves through the enum-aware param marshaller.

:::gradient {from=#1a1a2e to=#0f3460 direction=vertical width=320 height=80}
:::

:::gradient {from=#ff6b6b to=#feca57 direction=horizontal width=320 height=80}
:::

:::gradient {from=#0f3460 to=#16213e direction=diagonal width=320 height=80}
:::

## Pattern — enum + int

Procedural geometric fills selected by `type`. The seed perturbs each pattern deterministically so a re-render produces identical pixels — the determinism hasher (Phase A.0) leans on that. Four variants ship: `checker`, `stripes`, `grid`, `dots`.

:::pattern {type=checker seed=0 width=320 height=80}
:::

:::pattern {type=stripes seed=2 width=320 height=80}
:::

:::pattern {type=grid seed=0 width=320 height=80}
:::

:::pattern {type=dots seed=7 width=320 height=80}
:::

## Noise — int + float

Fractal-Brownian-motion noise. `seed` picks the field, `scale` controls cell size, `octaves` stacks higher-frequency layers on top of the base — the third param shape, two floats riding alongside an int.

:::noise {seed=1 scale=12.0 octaves=4 width=320 height=80}
:::

:::noise {seed=42 scale=4.0 octaves=2 width=320 height=80}
:::

:::noise {seed=99 scale=24.0 octaves=6 width=320 height=80}
:::

## Drop shadow — single-source filter (Phase B)

The first user-facing single_source factory. Wraps any child content, renders it into an offscreen target sized to the child plus an inflation halo, then composites a blurred + offset + tinted version of that target underneath the original. Inflation is `blur` pixels on every side plus `max(0, offset)` on the lower-right and `-min(0, offset)` on the upper-left — so a `blur=8 offset_x=4 offset_y=4` wrapping a 200×80 box reserves a 220×100 region with the box at (8, 8) inside.

:::drop_shadow {#shadow_demo offset_x=6 offset_y=6 blur=10 color=#000c}
:::box {color=#0d9488 width=240 height=80 radius=8}
:::
:::
