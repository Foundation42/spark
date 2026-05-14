# text_engine

Rich-text rendering for Zig + Vulkan host engines. One Element
contract that markdown, ANSI terminals, and (long-term) Dear ImGui-
shaped game UI all flow through.

End of session 2 the demo renders a markdown document — heading
levels, mixed-style paragraph with bold-italic-link-code cascade,
nested lists, wrapping blockquote, fenced code block — plus a
rainbow SDF "ATTENTION" with per-glyph attention animation, all in
one instanced draw call per frame at ~14k fps Release. Source for
the document is [`src/demo.md`](src/demo.md), parsed at startup
through the vendored cmark.

```
                ┌────────────────────────────────────────────┐
                │   markdown source (src/demo.md)            │
                │             │                              │
                │             ▼                              │
                │    cmark AST  ──►  markdown.parse()        │
                │                            │               │
                │                            ▼               │
                │                     Element tree           │
                │                            │               │
                │                            ▼               │
                │              element_layout.walker         │
                │                            │               │
                │                            ▼               │
                │           shape → cache → atlas → SSBO     │
                │           3 lanes: mono / colour / sdf     │
                │           per-glyph attention + hot_color  │
                └────────────────────────────────────────────┘
```

## Docs

- [`docs/architecture.md`](docs/architecture.md) — Element contract,
  Theme, source layout, data flow, atlas lanes, GlyphInstance,
  design decisions, known limitations.
- [`docs/journey-session-1.md`](docs/journey-session-1.md) —
  rendering plumbing: build, Vulkan, FreeType, HarfBuzz, atlas, SDF,
  attention.
- [`docs/journey-session-2.md`](docs/journey-session-2.md) — the
  contract: Element / Theme / cascade / wrap / markdown parser.
- [`docs/roadmap.md`](docs/roadmap.md) — what's next. Quad/line
  primitives, ANSI engine, retained mode, LM effects.
- [`chat.md`](chat.md) — the original brainstorm that started it.

## Three-tier plan

1. **text_engine (this repo)** — styled-text rendering library with
   the Element contract + walker + Theme. ✅ live.
2. **Layout engines** — markdown ✅, ANSI terminal (next), syntax
   highlighter, valkyr token streams, eventually Dear ImGui-shaped
   widgets. All produce Element trees the walker consumes unchanged.
3. **LM / semantic plugins** — read buffer, write per-token
   attention / sentiment / entity metadata back through the per-glyph
   SSBO channels. Drives heatmap colouring, semantic folding,
   predictive completion. Last, not first.

Library-first because matryoshka and other engines need rich text
*now*; proving the API against multiple producers (markdown done,
ANSI next) prevents shape-locking around any one consumer.

## Cooperative-embed surface

Same policy as `valkyr_gpu` in `~/dev/tripvulkan`: the library does
not own a Vulkan instance, device, surface, or swapchain. The host
hands the library its `VkDevice` + per-frame `VkCommandBuffer` and
the library records draw work into them. Vulkan, FreeType, HarfBuzz,
glfw are linked by the host exe, not by the library module. cmark
ships as a vendored static archive built by `build.zig` and linked
into the host.

The standalone `text_engine_demo` exe in `src/main.zig` is a dogfood
surface — owns its own window and exercises the library through the
same module a host engine would.

## Build

```sh
zig build                              # build the demo
zig build run                          # build + run
zig build -Doptimize=ReleaseFast run   # release build
```

Requires Zig ≥ 0.14.1, `glslc`, and system FreeType / HarfBuzz / glfw
/ Vulkan (loader + headers). cmark is vendored under `vendor/cmark/`
and built as part of `zig build`.

Defaults to DejaVu Sans family (regular + bold + oblique + bold-
oblique + mono) and Noto Color Emoji from `/usr/share/fonts/` —
override with:

```sh
TEXT_ENGINE_FONT=/path/to/font.ttf zig build run
TEXT_ENGINE_BOLD_FONT=/path/to/bold.ttf zig build run
TEXT_ENGINE_ITALIC_FONT=/path/to/italic.ttf zig build run
TEXT_ENGINE_BOLD_ITALIC_FONT=/path/to/bold-italic.ttf zig build run
TEXT_ENGINE_MONO_FONT=/path/to/mono.ttf zig build run
TEXT_ENGINE_EMOJI_FONT=/path/to/emoji.ttf zig build run
TEXT_ENGINE_EXIT_AFTER=5 zig build run    # auto-close after N seconds
TEXT_ENGINE_VK_VERBOSE=1 zig build run    # device-pick diagnostics
```

## Stage status

### Session 1 — rendering plumbing

- [x] **Phase 0** — build skeleton, shader compile + embed pipeline.
- [x] **Phase 1a** — glfw window + Vulkan 1.3, validation, debug-utils.
- [x] **Phase 1b** — clear-colour loop, frames-in-flight, swapchain.
- [x] **Phase 2** — FreeType first glyph, R8 atlas, textured quad.
- [x] **Phase 3** — HarfBuzz, per-glyph SSBO, instanced draw, shelf
  packer, baseline-relative layout.
- [x] **Phase 4** — FontRegistry, GlyphCache, Style + Span + Line +
  Paragraph, row-level baseline resolution.
- [x] **Phase 5** — colour emoji via dual atlas (R8 + RGBA8),
  per-glyph `tex_select`, premultiplied-alpha blend.
- [x] **Phase 6** — SDF lane, per-glyph `attention` modulating
  threshold + colour lerp.

### Session 2 — the contract + markdown

- [x] **Stage 1** — Element contract: text / line_break / paragraph /
  heading / container / custom + LayoutCtx + DrawList + Constraints
  + Box. Session-1 demo re-rendered through the walker.
- [x] **Stage 2a** — block nesting: list / list_item / quote /
  code_block / spacer. Hand-built torture demo nests every kind.
- [x] **Stage 2b** — word wrap honouring `Constraints.max_w`. Wrap
  inside indented quotes is the proof point.
- [x] **Stage 2c** — Theme struct + inline structural kinds
  (emphasis / strong / code / link). Cascade lives in the producer
  via `theme.apply*`; walker stays transparent.
- [x] **Stage 3a** — vendor cmark 0.31.2, build as static archive,
  smoke-test FFI.
- [x] **Stage 3b** — markdown → Element mapper. `src/demo.md` is
  now the demo content; ~200 lines of hand-built tree literals
  deleted.

## What's next

[`docs/roadmap.md`](docs/roadmap.md). Headline for session 3:
**quad/line draw primitives** (unlocks code-block backgrounds,
quote bars, thematic breaks, link underlines), then the **ANSI
layout engine** as the second contract consumer (closing the
markdown↔ANSI composition loop), then retained mode + document
model for the eventual terminal app.
