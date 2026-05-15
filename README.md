# text_engine

A live-document runtime for Zig + Vulkan host engines. One Element
contract that markdown, ANSI terminals, future native components
(charts, 3D scenes, sliders), and (long-term) Dear ImGui-shaped
game UI all flow through. **What we're building** is documented in
[`docs/vision.md`](docs/vision.md): markdown as the declarative
interface to a live, component-driven runtime that an LLM can
author, mutate, and stream updates into.

End of session 5 the substrate is alive on every axis: a top
markdown doc with chrome, an ANSI fixture, a rainbow SDF
"ATTENTION", a live rounded box driven by frontmatter state + two
sliders, a streaming `:::chart` fed at 60 Hz through the
`:::update` wire format, a `:::embedded-document` loading
`src/widgets/orbit_panel.md` recursively, **and** a second
`:::embedded-document` loading `src/widgets/remote_panel.md` over
HTTP from a localhost server the demo spins up at startup —
parent reactive state crosses the network boundary so the first
remote bar follows the colour cycle. ~11.5k fps Release. Source
for the parent document is [`src/demo.md`](src/demo.md); the
local embed is
[`src/widgets/orbit_panel.md`](src/widgets/orbit_panel.md); the
remote embed is
[`src/widgets/remote_panel.md`](src/widgets/remote_panel.md).

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
- [`docs/journey-session-4.md`](docs/journey-session-4.md) — the
  substrate ships: block extension parser, component registry,
  reactive state, input handling, sliders driving live geometry.
  Plus the document-composition flywheel.
- [`docs/journey-session-5.md`](docs/journey-session-5.md) — the
  fast lane and the streaming showcase: `:::update` wire format
  (8a) + `:::chart` component (8b), state-target dispatch driving
  the box colour and component-target dispatch driving a 60-Hz
  sparkline trace.
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
- [x] **Stage 7c** — first concrete component: `:::box`. Lives in
  `src/components/box.zig`. Parses `color` (named + hex), `width` /
  `height` (px + %), `radius` from `Spec.attrs` and emits one
  rounded quad. `update` wired so attr edits hit the cached
  instance in place (the "cheap edit" path `:::update` will use
  later). Demo's `:::box` block renders as a 200×80 blue rounded
  rectangle alongside the two red placeholders for the still-
  unregistered `:::3d-scene` / `:::chart`. 21 unit tests.
- [x] **Stage 7d** — frontmatter state + static `${}` interpolation.
  YAML `state:` block parsed into a `State { set, get }` map;
  `${path}` (or `${state.path}`) in attribute values resolves
  through it at parse time. Hand-rolled YAML subset — `key: value`
  with quoted/bare strings, comments. Bare-value scanner
  `${...}`-aware so template `}` doesn't truncate. Unresolved
  paths stay literal so authors notice typos. Demo's `:::box`
  attrs now flow from frontmatter; edit YAML → rebuild → box
  reflects the new state. 31 unit tests.
- [x] **Stage 7e** — reactive state. `state.set(path, value)` fires
  subscribers. The registry auto-subscribes a `Binding` per `${}`
  reference during `resolve`; mutations re-substitute the cached
  instance's templated attrs and call `factory.update` with a
  fresh Spec. Preprocess now keeps attrs templated; the registry
  does substitution at resolve time. `state.dirty` drives
  re-layout. Demo cycles `box_color` every 1.5s through five
  shades; ~13.3k fps Release. 39 unit tests.
- [x] **Stage 7f** — input handling. `ElementVTable` gains optional
  `on_input`; walker registers interactive elements in
  `DrawList.hits` (laid-out box + vtable + ctx). Main loop polls
  glfw cursor + button state, diffs, dispatches `mouse_down` /
  `mouse_move` / `mouse_up` with pointer capture (deepest hit on
  press keeps events until release). First interactive component:
  `:::slider` — drag-to-set a numeric `target` state path. Demo
  ships two sliders driving the box's radius and height; the
  whole loop (drag → state.set → registry binding → factory.update
  → re-layout) runs at ~13.3k fps. 43 unit tests.

### Session 5 — live-document plumbing continued

- [x] **Stage 8a** — `:::update` micro-stream wire format. Two
  dispatch backends: component-target (`{#id action=NAME}\nBODY\n:::`
  → `Factory.handle_update`) and state-target
  (`{target=state.path}\nVALUE\n:::` → `state.set`). New optional
  `Factory.handle_update` vtable slot; box opts in with
  `set-color`/`-radius`/`-width`/`-height`. `update.applyAll(arena,
  state, registry, source)` parses + dispatches a whole burst,
  arena reset between cycles. Demo cycles box colour every 1.5s
  through five shades via the state-target path; ~13.3k fps Release
  unchanged. 53 unit tests.
- [x] **Stage 8b** — `:::chart` streaming component. Ring-buffer
  of f32 samples; filled-column sparkline rendering (axis-aligned
  quads, no rotated geometry needed). Opts into
  `handle_update`: `action=append` (body=float) + `action=clear`.
  No state binding — chart owns data opaquely, so the 8a pitfall
  with templated attrs doesn't apply. Demo runs a 60 Hz synthetic
  feed (layered sines + noise) through the component-target path;
  ~12k fps Release with ~240 updates dispatched per 4s. 62 unit
  tests total.
- [x] **Stage 9** — `:::embedded-document {#id src=... attr=val}`.
  Recursive document composition. Built-in factory reads the child
  file, parses through `markdown.parseWithStateAndScope` with a
  fresh child `State` (`parent` pointer set for dirty bubble),
  applies non-`src` parent attrs as overrides on child state,
  grafts the parsed Element subtree into the host layout. Cache
  keys for child components are scope-prefixed
  (`Registry.resolve` grew `scope: ?[]const u8`) so a
  `:::box {#bx}` in the embed never collides with a parent-level
  `#bx`. `Registry.deinitScope` tears down child instances when
  the embedded doc itself is GC'd. Demo embeds
  `src/widgets/orbit_panel.md`; ~11.2k fps Release with all of
  8a + 8b + 9 active.
- [x] **Stage 11 v0** — remote `:::embedded-document` over HTTP.
  `src=` accepts `http://` / `https://` / `file://` / paths. URL
  loader goes through `std.http.Client.fetch` and caches bytes in
  memory for the program lifetime. Demo binds a tiny local HTTP
  server on `127.0.0.1:8080` serving `src/widgets/` so the URL
  embed works dependency-free. Parent reactive state crosses the
  network boundary: `primary=${state.box_color}` on the URL embed
  drives the remote widget's first bar through the colour cycle.
- [x] **Polish — scroll, zoom, keyboard nav, embedded-input
  scope.** Mouse wheel scrolls (60 px / notch, eased tween toward
  target); Ctrl+wheel zooms (×1.10 / notch, clamped 0.25–4);
  PgUp/PgDn/Home/End drive scroll, Ctrl+= / Ctrl+- / Ctrl+0 drive
  zoom. Post-layout `world → screen` transform pass; mouse coords
  un-transform for hit-test. `LayoutCtx` + `Hit` grew optional
  state pointers so a `:::slider` inside an
  `:::embedded-document` mutates **child state** not parent's —
  the demo's orbit widget grew a slider that resizes its own
  outer panel. Plus a load-bearing fix to a latent
  hashmap-rehash invalidation in `Registry.resolve` that surfaced
  when stress-tested through nested resolves; rule captured in
  memory as `project_registry_pointer_rules.md` so future
  recursive factories don't rederive it.
- [x] **Stage 12 — async I/O channel.** Work-stealing thread pool
  in `src/jobs.zig` (Chase-Lev deque, ported from valkyr) +
  `IoChannel` in `src/io_channel.zig` (fire-and-forget submit,
  mutex-guarded MPSC completion queue, main-thread `drain` once
  per frame). `embedded-document` HTTP fetch migrated off the
  main thread: the Component renders a soft-grey "loading…"
  placeholder until the body lands, then swaps to the parsed
  child tree and bubbles `state.dirty`. Cancellation: `deinit_`
  during loading nulls the `PendingFetch.component` slot so the
  completion handler discards cleanly. Foundation re-usable for
  LLM streams (stage 13), file-watcher hot-reload, MCP pipes.
- [x] **Stage 13a — live LLM authoring.** `IoChannel` grew a
  `submitHttpStream` variant (POST + chunked response,
  `.chunk`/`.end`/`.end_err` `Result` variants). New
  `:::llm-stream` component posts an Ollama chat-completion
  request with `stream: true`; NDJSON chunks land on the drain
  queue per frame; line-buffered parser extracts each
  `message.content` token and appends to a display buffer; the
  accumulated buffer is re-parsed as markdown on every chunk so
  the child Element tree grows token-by-token. Phases
  `.loading` → `.streaming` → `.done` (or `.failed`); placeholders
  for the off-content states. Cancellation uses the same
  Pending↔Component back-pointer discipline as stage 12. Routing
  in main.zig's `drainHandler` is kind-based (one-shot →
  embedded-document, stream → llm-stream); will need a real
  router-table when multiple consumers issue the same request
  kind.
- [x] **Stage 13a.5 — multi-provider streaming.** Same component,
  pluggable provider. `provider=openai` switches the body shape
  (OpenAI-compatible `max_tokens` field, `Authorization: Bearer`
  header) and the chunk parser (SSE events with `data:` framing
  and `[DONE]` terminator instead of NDJSON). One wire-format
  covers DeepSeek, OpenRouter, OpenAI proper, Together, Groq,
  Mistral, and anything else that speaks OpenAI's chat API.
  `IoChannel.HttpStreamRequest` grew `extra_headers` to plumb
  the auth header. Tiny `src/dotenv.zig` reads `~/.env`'s
  `KEY=VALUE` pairs at startup; `api_key_env=` attribute names
  which entry the factory should read for the Bearer token. Demo
  stacks three providers side-by-side — local Ollama, remote
  DeepSeek, and Gemini-2.5-Flash via OpenRouter — all streaming
  into the same Vulkan-rendered document concurrently.
- [x] **Stage 13b — button → LLM trigger.** New `:::button`
  component (`src/components/button.zig`) — clickable rect with
  `label=`, `target=#id`, `action=name`, optional `body=`. On
  primary mouse_up inside it, calls
  `registry.handleUpdate(target, action, body)`. `:::llm-stream`
  grew `auto_start=false` + `Phase.idle` (subtle grey "ready"
  placeholder) + a `handle_update` arm that re-fires
  the stream on `action=start` — cancels any in-flight (nulls
  the back-pointer, the worker keeps running but the completion
  handler discards), clears content + line buffer, resets the
  arena, kicks off a fresh fetch. Demo now has three `Run …`
  buttons next to three idle `:::llm-stream` blocks; click to
  trigger, click again to re-run. ~7.5k fps idle.

## What's next

[`docs/roadmap.md`](docs/roadmap.md). Open queue: **stage 13b**
(input field + button — closes the user→LLM authoring loop),
**stage 10** (headless documents), **retained layout cache**
(skip re-walk when neither tree nor inputs changed; the
stream-driven re-parse dropped FPS from 9.3k→5.9k during
streaming, so this is now load-bearing), **crisp zoom**
(multi-size atlas + re-layout-on-zoom), **persistent URL cache**
(disk-backed so remote widgets survive restarts). None of them
block each other.
