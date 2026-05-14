# text_engine

A live-document runtime for Zig + Vulkan host engines. One Element
contract that markdown, ANSI terminals, future native components
(charts, 3D scenes, sliders), and (long-term) Dear ImGui-shaped
game UI all flow through. **What we're building** is documented in
[`docs/vision.md`](docs/vision.md): markdown as the declarative
interface to a live, component-driven runtime that an LLM can
author, mutate, and stream updates into.

End of session 3 the demo renders a markdown document with full
chrome (code-block backgrounds, blockquote bars, thematic rules,
link underlines), an ANSI fixture (8-color / 256-color / truecolor
/ bold / italic / multi-line), and a rainbow SDF "ATTENTION" with
per-glyph attention animation — all reflowing on window resize at
~13.5k fps Release. Source for the document is
[`src/demo.md`](src/demo.md), parsed at startup through vendored
cmark.

```
       ┌───────────────────────────────────────────────────────┐
       │   producers                                           │
       │     markdown.parse  (src/demo.md → cmark AST → tree)  │
       │     ansi.parse      (escape stream → tree)            │
       │     hand-built      (e.g. SDF ATTENTION rainbow)      │
       │     future: live components via :::name {attrs}       │
       │                          │                            │
       │                          ▼                            │
       │                  Element tree                         │
       │                  (text, line_break, emph, strong,     │
       │                   code, link, paragraph, heading,     │
       │                   container, spacer, list, list_item, │
       │                   quote, code_block, thematic_break,  │
       │                   custom { vtable, ctx })             │
       │                          │                            │
       │                          ▼                            │
       │             element_layout.walker (event-driven)      │
       │                          │                            │
       │                          ▼                            │
       │                  DrawList { glyphs, quads }           │
       │                          │                            │
       │      quads first (chrome), glyphs on top (text)       │
       │                          │                            │
       │                          ▼                            │
       │              one vkCmdBeginRendering pass             │
       └───────────────────────────────────────────────────────┘
```

## Docs

- [`docs/vision.md`](docs/vision.md) — where this is going.
  Markdown as the declarative interface to a live, component-driven
  runtime. Block extensions, reactive frontmatter state, targeted
  LLM micro-updates. The destination.
- [`docs/architecture.md`](docs/architecture.md) — Element contract,
  Theme, source layout, data flow, atlas lanes, GlyphInstance,
  design decisions, known limitations.
- [`docs/journey-session-1.md`](docs/journey-session-1.md) —
  rendering plumbing: build, Vulkan, FreeType, HarfBuzz, atlas, SDF,
  attention.
- [`docs/journey-session-2.md`](docs/journey-session-2.md) — the
  contract: Element / Theme / cascade / wrap / markdown parser.
- [`docs/journey-session-3.md`](docs/journey-session-3.md) — the
  chrome and the vision: quad pipeline, link underlines, ANSI
  engine, resize reflow, live-documents pitch.
- [`docs/roadmap.md`](docs/roadmap.md) — staging path from current
  state to live-documents runtime.
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

### Session 3 — chrome + second producer + resize, then the vision

- [x] **Stage 4a** — quad pipeline: code-block backgrounds, quote
  bars, thematic rules. New SPIR-V pair + descriptor set; DrawList
  grew `quads` field; walker handlers emit chrome.
- [x] **Stage 4b** — link underlines via per-line emit tracking.
  Underline geometry deferred to the line-emit pass so wrapping
  links naturally produce one underline per visible line.
  Font-metric-driven (thickness + offset are em fractions).
- [x] **Stage 5a** — ANSI engine. Second tier-2 producer. State
  machine + 256-colour palette + SGR cascade from `~/dev/ac/src/
  terminal_parser.zig`, adapted to emit Element trees instead of
  cell-grid writes.
- [x] **Stage 6a** — resize-aware relayout. drawCb runs the layout
  pass when the swapchain's extent changes; poll-based detection
  in the renderer handles compositors (Wayland) that don't signal
  OUT_OF_DATE_KHR on resize.
- 🌟 **Vision crystallised** end of session 3 —
  [`docs/vision.md`](docs/vision.md) captures the live-documents
  runtime direction.

### Session 4 — live-document plumbing

- [x] **Stage 7a** — block extension parser. `:::name {attrs}\nbody\n:::`
  pre-scanned into a sidecar `Spec` slice; the byte range becomes a
  `<!--te:N-->` HTML comment cmark passes through as
  `CMARK_NODE_HTML_BLOCK`; mapper intercepts the sentinel and emits a
  `custom` Element. No registry yet — every directive renders as a
  red-bordered "missing component: NAME" placeholder panel. cmark
  itself stays untouched.
- [x] **Stage 7b** — component registry + persistent instance cache.
  `Registry { register, beginParse, resolve, gc }` with `Factory {
  create, update?, deinit? }`. Cache keyed by explicit `Spec.id` or
  `auto:N` derived from sentinel index (order-based — position-
  based when needed). `update` lets cached instances absorb attr
  changes across parses without being destroyed. `markdown.parse`
  takes an optional registry; null preserves 7a placeholder
  behaviour. `zig build test` step added. Demo unchanged — no
  factories registered yet, dormant infrastructure ready for 7c.

## What's next

[`docs/roadmap.md`](docs/roadmap.md). Headline for the rest of
session 4: **first concrete component** (`:::box` with color + size
attrs), then **reactive frontmatter state + bindings**, then **input
handling**, then the **`:::update` micro-stream hot path** that
lets an LLM push deltas into a live chart at 15k fps without
touching the document layout.
