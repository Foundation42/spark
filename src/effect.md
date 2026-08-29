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

## Drop shadow — chain effect (Phase B.5, rebuilt at C.2)

The first user-facing effect, and now the first CHAIN consumer. Wraps any child content, renders it into an offscreen target sized to the child plus an inflation halo, then runs a **separable two-pass Gaussian** over the child's silhouette and lays the child back over the result. Inflation is `blur` pixels on every side plus `max(0, offset)` on the lower-right and `-min(0, offset)` on the upper-left — so a `blur=8 offset_x=4 offset_y=4` wrapping a 200×80 box reserves a 220×100 region with the box at (8, 8) inside.

`blur` is the shadow's visible reach in pixels; sigma is `blur / 3`, so three sigma lands exactly on that halo and a shadow cannot spill outside the region reserved for it. `spread` (0..0.95) is Photoshop's Spread — the blurred alpha is divided by `1 - spread` and clipped, which fattens the core.

**What B.5 shipped, and why it changed.** The original was a 9-tap box blur with taps separated by the whole blur radius, which does not read as a blur — it reads as nine copies of the content. A capture of matryoshka's Lab at `blur=8` showed its heading three times across and three times down. A Gaussian of radius R costs O(R²) samples done directly and O(R) done as two 1D passes, and two passes means two images, which is exactly what the C.1 ping-pong pool was built for.

The chain is three steps over three pool targets: horizontal Gaussian of the child's alpha (offset applied here, once), vertical Gaussian tinted into the shadow colour, then the child copied back over it with `load = .keep`. That third step is what `ChainLoad` exists for — a drop shadow ends in a composite, not a filter.

:::drop_shadow {#shadow_demo offset_x=6 offset_y=6 blur=10 color=#000c}
:::box {color=#0d9488 width=240 height=80 radius=8}
:::
:::

Heavier blur with spread, for comparison — the falloff is smooth at any radius, which is the property the box blur never had:

:::drop_shadow {#shadow_soft offset_x=0 offset_y=8 blur=24 spread=0.2 color=#0009}
:::box {color=#16213e width=240 height=80 radius=12}
:::
:::

## Frosted glass — single-source filter (Phase B.6)

Second single_source consumer. Renders the wrapped child into an offscreen target, then a single-pass 9-tap box blur smears the contents and a tint colour composites over the result — the modern-OS panel look. No inflation: the effect stays within the child's natural bounds. The pipeline shape (combined-image-sampler + push-constant uniforms) mirrors drop_shadow; the post-B.6.a cache substrate handles both factories without per-factory workaround flags. The blur shows convincingly only when the child has spatial-frequency content to smear — solid-colour children only show edge softening, so the four panels below escalate from flat fill to high-frequency pattern + noise.

Subtle tint over a solid panel — baseline. Edge softening visible; interior is flat by construction.

:::frosted_glass {#glass_subtle blur=10 tint=#ffffff14}
:::box {color=#1a1a2e width=240 height=80 radius=8}
:::
:::

Checker pattern wrapped in frosted glass — maximum-contrast input. The blur averages adjacent black/white squares into mid-grey; the tint overlays on top.

:::frosted_glass {#glass_checker blur=12 tint=#0d948828}
:::pattern {type=checker seed=0 width=240 height=80}
:::
:::

Same wrap, heavier blur — the squares dissolve almost completely; the tint dominates the visible result.

:::frosted_glass {#glass_checker_heavy blur=28 tint=#16213e40}
:::pattern {type=checker seed=0 width=240 height=80}
:::
:::

FBM noise wrapped in frosted glass — the per-pixel jitter blurs into a soft cloudy texture, then the tint washes over. Demonstrates the substrate composes with any pass-emitting child.

:::frosted_glass {#glass_noise blur=16 tint=#ffffff10}
:::noise {seed=42 scale=8.0 octaves=4 width=240 height=80}
:::
:::

## Liquid glass — rounded-box refraction (Phase B.6.d)

Third single_source factory, and the first authored via the B.6.c `SingleSourceFactory` generator (~100 LOC for the whole factory file). Rounded-box SDF defines the panel; sampling UV bends back toward center near the edges, simulating a curved-glass lens; chromatic aberration adds a prismatic flash at corners; a thin rim highlight traces the edge; an optional tint washes over. Refraction works on the child's content (not on what's behind the panel) — the Apple "see-through" look needs MAIN sampling, which is Phase D territory.

A checker pattern through liquid glass — high-contrast input shows the corner refraction + chromatic aberration clearly:

:::liquid_glass {#liquid_checker radius=0.18 refraction=0.2 rim_brightness=0.5}
:::pattern {type=checker seed=0 width=240 height=80}
:::
:::

FBM noise through liquid glass — softer source, the rim highlight dominates the visible result:

:::liquid_glass {#liquid_noise radius=0.25 refraction=0.15 rim_brightness=0.4 tint=#0d948820}
:::noise {seed=42 scale=8.0 octaves=4 width=240 height=80}
:::
:::

Solid box through liquid glass — baseline, edges + rim + tint visible without competing content:

:::liquid_glass {#liquid_box radius=0.3 refraction=0.1 rim_brightness=0.6 tint=#16213e30}
:::box {color=#ffffff width=240 height=80 radius=8}
:::
:::
