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
  arena, kicks off a fresh fetch.

- [x] **Stage 13c — `:::input` field.** Single-line editable
  text field with UTF-8 buffer + caret blink + arrows / home /
  end / backspace / delete / enter. Click to focus, Esc clears.
  `element.InputEvent` grew `char_input`, `key_down`,
  `focus_gained`, `focus_lost` channels. `Hit.focusable` via the
  vtable so the walker stamps it onto the emitted Hit
  automatically — a manual `hits.append` would get shadowed by
  the walker's. `:::llm-stream.handleUpdate` accepts the typed
  text as a prompt override; button keeps the canned default for
  retry.

- [x] **Stage 13d.1 — `:::svg` + triangle pipeline + earcut.**
  End-to-end vector graphics. Mini SVG parser (M/L/C/z + rgb
  fills + translate, ~600 lines), Bezier flatten + Mapbox-port
  earcut tessellator with hole stitching (~700 lines), new
  Vulkan VBO+IBO triangle pipeline + shaders. Render order:
  triangles → quads → text. `:::svg {src= width= height=}` reads
  a file, parses, tessellates once, caches the mesh. Petunias.svg
  fixture lands as a 125-path, 4174-triangle bowl-of-petunias.

- [x] **Stage 13d.2 — parallel tessellation.**
  `tessellateParallel` fans out one Job per `<path>` across the
  JobSystem, each worker tessellates into its own
  `c_allocator`-backed Mesh, serial merge on the main thread
  with index rebasing. **8.17× speedup** on Petunias (22 ms → 2.7
  ms), basically linear because path costs are wildly uneven and
  the work-stealer absorbs the long-tail. Equivalence test
  confirms identical vert/index counts across serial / parallel.

- [x] **Stage 13d.3 — `:::svg-stream` (Recraft V4.1).** Live
  vector generation. Send `stream:false` to OpenRouter (Recraft
  is one-shot despite the chat-completions wrapper), accumulate
  raw response, on `.end` parse the JSON envelope, extract
  `choices[0].message.images[0].image_url.url`, base64-decode the
  data URL, run through `svg.parse` + `tessellateParallel`,
  swap in the mesh. Refactored IoChannel completion routing in
  the process: every `PendingX` struct now starts with an
  `io.PendingHeader` (function-pointer first field), so
  `drainHandler` dispatches polymorphically and new consumers no
  longer touch `main.zig`.

### Session 8 — caching, parallelism, raster image gen

- [x] **Stage 14a — retained per-block layout cache.**
  `src/layout_cache.zig`. Key is `(elem_id, max_w, theme)`;
  content version held *outside* the key as an Entry field so a
  bump replaces the slot in place (a 1000-chunk LLM stream
  doesn't leak 1000 entries). Leaf-ish kinds (paragraph /
  heading / code_block / thematic_break) cache automatically;
  custom components opt in via `vtable.content_version` and out
  via `vtable.disable_cache`. LLM-stream nulls `cache_blocks`
  before recursing into its child tree (per-chunk re-parse
  changes inner pointer identity). **97.9% cache hit rate at
  idle, 56 entries, ~7600 fps with chart at 60 Hz.**

- [x] **glslc -O for release builds.** Mapped Zig's `optimize`
  to glslc flags in `compileShaderStage`. Debug → `-O0` (default),
  ReleaseSafe / ReleaseFast → `-O`, ReleaseSmall → `-Os`. Text
  fragment SPIR-V shrank **34%** (3040 → 2008 bytes).

- [x] **Stage 14b — parallel cache-miss layouts (re-armed by 14d).**
  One mutex around `GlyphCache.getOrRasterize` (the only
  shared-write surface); classify-then-dispatch worker pattern in
  `layoutStackVParallel` (workers walk into private DrawLists at
  origin (0,0); main merges in order + snapshots). Built in
  session 8, then **parked** because `httpStreamJob` pinned
  `JobSystem` workers for the entire 5-15 s upstream wait — with
  multiple streams + the parallel walker on top, the compute pool
  starved and the main thread spun in `Counter.wait`. Stage 14d
  (worker pool split, below) removes the contention; dropping
  `PARALLEL_MIN_WALKS` back to `2` re-arms the dispatcher.

- [x] **Stage 14c — raster `:::image-stream` (Gemini image
  preview).** Mirror of `:::svg-stream` for image-class models.
  Same OpenAI-shaped wire format; data URL contains a PNG/JPG
  instead of an SVG. Vendored `stb_image` (matryoshka pattern,
  `vendor/stb/`). New `src/gpu/image_texture.zig` (per-image
  `VkImage` + view + sampler + staged upload, reuses Atlas's
  pub-promoted `Staging` / `findMemoryType` / `cmdImageBarrier`
  helpers). New `src/gpu/image_pipeline.zig` + `shaders/image.*`
  (textured-quad pipeline, per-image descriptor sets from a
  pool, push constants for viewport + dst rect). `DrawList.images`
  is the new draw layer. Render order: tris → images → quads →
  glyphs. Texture reused across re-fires when dimensions match;
  reallocated + descriptor rewritten in place otherwise.

- [x] **Stage 14d — worker pool split (compute ≠ I/O).** Two
  `JobSystem` instances live side by side. The compute pool keeps
  `cpu_count - 2` workers all hot for parallel layout +
  tessellation; a dedicated I/O pool with 24 workers handles
  blocking HTTP — each happily parked on `req.read` for the
  upstream wait. `IoChannel` is now wired to the I/O pool;
  `submitHttpGet` / `submitHttpStream` no longer touch compute
  workers. Re-arms 14b by dropping `PARALLEL_MIN_WALKS` back to
  `2`. The two pools coexist on the existing JobSystem shape with
  zero contract changes.

- [x] **Stage 14e — persistent asset cache.** Browser-style
  content-addressable cache for expensive remote assets (Recraft
  SVG envelopes, Gemini image envelopes — both ~$0.08/firing).
  New `src/asset_cache.zig` with `manifest.json` index, sha256
  keys, 500 MB default budget, LRU eviction on overflow, atomic
  manifest writes (tmp + rename), `pruneOlderThan` / `pruneAll` /
  `setBudget` knobs. Lives at
  `${XDG_CACHE_HOME:-$HOME/.cache}/text_engine/assets`. The two
  expensive stream components opt in and route cache hits straight
  into `finalizeResponse` — no `IoChannel` traffic, no spinner,
  no charge.

- [x] **Stage 10 — headless documents.** `:::embedded-document
  {headless=true}` parses its child markdown, populates child
  state, instantiates child components (auto_start streams fire,
  `:::chart` ingest works, registry routing by id stays intact) —
  but `layoutAndRender` short-circuits with a zero-size box and
  emits no draw data. Invisibility propagates behaviourally:
  nested visual content arbitrarily deep stays hidden regardless
  of its own flag. Two toggle paths land in the same stage: a
  reactive-attr path (`headless=${state.x}`) composing with the
  Binding subsystem, and a `handle_update` arm (`set-headless` /
  `toggle-headless`) for direct/LLM mutation.

- [x] **Stage 13b.1 — state-target `:::button` dispatch.**
  `target=state.path` writes `body` straight into the scope-local
  state via the dispatcher's `on_input` state pointer (matching
  slider / input scoping). `target=#id` keeps the existing
  `registry.handleUpdate` path. Closes the reactive-attr loop
  end-to-end — the headless demo now uses state-target buttons
  driving `headless=${state.config_hidden}` instead of bouncing
  through the `handle_update` arm.

- [x] **Stage 13b.2 — persistent reactive state.** `State` grew
  `saveToFile` / `loadFromFile` (atomic JSON write at
  `${XDG_STATE_HOME:-$HOME/.local/state}/text_engine/state.json`,
  version-tagged) and a `persist_dirty` flag independent of
  `dirty`. Main loads between `fromSource` and `parseWithState`
  so persisted values overlay onto frontmatter defaults before
  components subscribe. Throttled flush every 60 frames if dirty;
  final flush on graceful exit. Slider positions, button-driven
  state mutations, input contents all survive restarts.

- [x] **Stage 14f — cost-aware parallel-walk classification.**
  `ElementVTable.parallel_layout_cheap: bool` flag. Chart, svg-
  stream, image-stream opt in (their re-walks are O(N) memcpy in
  microseconds — dispatch overhead would dominate). The stage-14b
  dispatcher counts only *expensive* walks toward
  `PARALLEL_MIN_WALKS`; cheap walks still dispatch in parallel
  when expensive siblings push us over, but chart-only-dirty
  frames stay serial.

## Manifesto

[`docs/manifesto.md`](docs/manifesto.md) — written mid-session-9
in response to the recent push from some quarters to default LLM
outputs to HTML. The stance the engine has been building toward
since session 2 got explicit: **markdown is the universal
interface; make it live.**

## What's next

[`docs/roadmap.md`](docs/roadmap.md). Open queue: **more image-
class probes** (Stability SD-Vector, Bytedance Doubao-Vector,
OpenAI gpt-image-1 — curl-first reconnaissance per
[[reference-recraft-wire]]), **selection + clipboard for
`:::input`** (shift-arrow, double-click word selection, ctrl-A/C/V),
**stage 5b — markdown ↔ ANSI composability** (~50 LOC, fenced
` ```ansi ``` ` blocks route into `CodeContent.sub_block`),
**cache-warming headless demo** (manifesto pattern made concrete),
**crisp zoom** (multi-size atlas + re-layout-on-zoom),
**MCP / WASM provenance components**.
