# text_engine

Rich-text rendering for Zig + Vulkan host engines. Built to power
matryoshka HUD / in-game UI first, with a scriptable LM-aware terminal
layered on top later.

End of session 1 the demo renders heading + subtitle + mixed-size
styled spans + colour emoji + a rainbow SDF "ATTENTION" word with
per-glyph attention driving weight + hue, all in one instanced draw
call per frame at ~14,700 fps in Release.

```
                    ┌──────────────────────────────────┐
                    │   text_engine                    │
                    │                                  │
                    │   shape → cache → atlas → SSBO   │
                    │   3 lanes: mono / colour / sdf   │
                    │   per-glyph attention + hot_color│
                    └──────────────────────────────────┘
```

## Docs

- [`docs/architecture.md`](docs/architecture.md) — what it is, how
  the source is organised, the data flow, atlas lanes, GlyphInstance
  layout, design decisions, known limitations.
- [`docs/journey.md`](docs/journey.md) — narrative of session 1.
  How we got from `chat.md` to a working text engine in one stretch.
- [`docs/roadmap.md`](docs/roadmap.md) — what's next. Composable
  layout engines (ANSI + Markdown), richer LM effects, library
  separation, document model.
- [`chat.md`](chat.md) — the original brainstorm that started it.

## Three-tier plan

1. **text_engine (this repo)** — styled-text rendering library.
   Font management, HarfBuzz shaping, glyph atlas (mono + colour +
   SDF), Makepad-style row-baseline layout, styled spans,
   per-glyph LM attribute channel.
2. **Terminal emulator + Markdown layout** — pluggable layout
   engines built on top of (1), ideally composable. The ANSI
   parser in `~/dev/ac/src/terminal.zig` is the starting point.
3. **LM / semantic plugins** — read buffer, write per-token
   attention / sentiment / entity metadata back through the
   library's per-glyph SSBO channels. Drives heatmap colouring,
   semantic folding, predictive completion. Last, not first.

Library-first because matryoshka and other engines need rich text
*now*; proving the API against a non-terminal surface first prevents
shape-locking around grids.

## Cooperative-embed surface

Same policy as `valkyr_gpu` in `~/dev/tripvulkan`: the library does
not own a Vulkan instance, device, surface, or swapchain. The host
hands the library its `VkDevice` + per-frame `VkCommandBuffer` and
the library records draw work into them. Vulkan, FreeType, HarfBuzz,
glfw are linked by the host exe, not by the library module.

The standalone `text_engine_demo` exe in `src/main.zig` is a dogfood
surface — owns its own window and exercises the library through the
same module a host engine would.

## Build

```sh
zig build                              # build the demo
zig build run                          # build + run
zig build -Doptimize=ReleaseFast run   # release build
```

Requires Zig ≥ 0.14.1, `glslc`, and system FreeType / HarfBuzz / glfw /
Vulkan (loader + headers). Defaults to DejaVu Sans + Noto Color Emoji
from `/usr/share/fonts/` — override with:

```sh
TEXT_ENGINE_FONT=/path/to/font.ttf zig build run
TEXT_ENGINE_EMOJI_FONT=/path/to/emoji.ttf zig build run
TEXT_ENGINE_EXIT_AFTER=5 zig build run    # auto-close after N seconds
TEXT_ENGINE_VK_VERBOSE=1 zig build run    # device-pick diagnostics
```

## Phase status — session 1

- [x] **Phase 0** — build skeleton, shader compile + embed pipeline,
  narrow public module surface.
- [x] **Phase 1a** — glfw window + Vulkan 1.3 instance/device/swapchain,
  validation layer in Debug, debug-utils messenger.
- [x] **Phase 1b** — clear-colour frame loop via dynamic rendering +
  synchronization2, frames-in-flight, swapchain recreate.
  ~7,600 fps uncapped at 1280×720.
- [x] **Phase 2** — FreeType-rasterised first glyph, textured quad
  via R8_UNORM atlas + linear sampler.
- [x] **Phase 3** — HarfBuzz shaping, per-glyph SSBO, instanced draw,
  shelf-packed atlas, baseline-relative layout. v1 "rich text on
  screen" milestone.
- [x] **Phase 4** — FontRegistry, GlyphCache, Style + Span + Line +
  Paragraph types, layoutParagraph with row-level baseline
  resolution (lifted from Makepad's turtle). Mixed-size spans share
  a baseline; repeat glyphs serve straight from atlas.
- [x] **Phase 5** — colour emoji via dual atlas (R8 mono + RGBA8
  color), per-glyph `tex_select` routing, premultiplied-alpha
  blend, strike-aware scale factor.
- [x] **Phase 6** — SDF lane (single-channel, padded source) sharing
  the R8 mono atlas. Per-glyph `attention` modulates SDF threshold
  (weight pulse) AND lerps `color → hot_color` (hue shift). First
  piece of the LM-driven rendering vision wired up end-to-end.
  Demo's rainbow wave rolls per-glyph hues across "ATTENTION" while
  attention animates per-frame in the SSBO.

## What's next

[`docs/roadmap.md`](docs/roadmap.md). Headline: **pluggable,
composable layout engines** (ANSI + Markdown), then the parked
rendering issues, then richer attention effects via `fx_kind`
(underline / size-pulse / per-character PBR), then the
library/demo boundary refactor when matryoshka starts consuming.
