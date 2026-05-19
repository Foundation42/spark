# Pattern-pass effects (stage 17 Phase A)

Three fragment-shader canaries dispatched directly into the framebuffer by the pass-graph compiler. No rasterizer-side geometry — each effect covers its `width × height` region with a fullscreen quad, and its uniforms ride a push-constant range straight to the fragment shader. The three factories deliberately exercise distinct param shapes to keep the typed-marshalling resolver honest: `:::gradient` takes vec4 colors plus an enum direction, `:::pattern` takes an enum type plus an integer seed, `:::noise` takes an integer seed plus float scale and octave count. See `docs/effects-spec.md` for the full Phase A roadmap.

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
