# text_engine — roadmap

The destination crystallised end-of-session-3 into a **live-
document runtime**: markdown source as the declarative interface,
native Vulkan components instantiated via `:::name {attrs}` block
extensions, reactive frontmatter state, targeted LLM-streamed
micro-updates. Full pitch + architectural mapping +
design-decision rationale lives in [`vision.md`](vision.md).

This roadmap is the staging path from where we are (the full
live-document substrate: parse → registry → cache → static
interpolation → reactivity → input → first interactive component →
`:::update` wire format → first streaming component → recursive
document composition) to where we're going (headless docs, remote
sources, LLM-driven authoring). Session 5 shipped stages 8a, 8b,
and 9 — the substrate is recursive, streaming, *and* live.

## Shipped — block extension parser (stage 7a)

`markdown.zig` recognises `:::name {attrs}\nbody\n:::` syntax and
emits a `custom` Element backed by a placeholder vtable. Approach:
pre-scan source for `:::` blocks before cmark sees it; lift each
block into a sidecar `Spec` slice; replace the byte range with a
`<!--te:N-->` HTML comment sentinel bracketed by blank lines so
cmark treats it as a standalone `CMARK_NODE_HTML_BLOCK`; mapper
intercepts the sentinel pattern and emits the `custom` Element.
Keeps vendored cmark completely untouched.

- `src/markdown_components.zig` — `Spec`/`Attr` types, `preprocess`,
  `parseDirectiveLine`, `extractSentinelIndex`, `placeholder_vtable`
  rendering the red-bordered "missing component: NAME" panel.
- Attribute grammar: `{#id key=val key="quoted val"}`. Directive
  names allow digit-leading (`3d-scene`); keys / ids letter-leading.
- Fenced code blocks tracked during pre-scan so embedded `:::`
  doesn't get hijacked.
- Tests in source: `parseDirectiveLine`, `preprocess` happy path +
  fenced-code passthrough + unterminated-block error,
  `extractSentinelIndex`. All passing.

## Shipped — component registry + persistent cache (stage 7b)

Host registers `name → Factory`. Cache keyed by `Spec.id` or by
auto-generated `auto:N` (where N is the sentinel index of the
`:::` block — order-based, simpler than position-based, swap to
position-based when LLM-driven structural rewrites prove the
simple scheme isn't enough). `custom.ctx` carries the
factory-produced instance pointer.

- `src/component.zig` — `Instance`, `Factory { create, update?,
  deinit? }`, `Registry { register, beginParse, resolve, gc }`.
  `update` is the cache-hit path so an instance can react to attr
  changes between parses without being destroyed.
- `markdown.parse` gained `?*Registry` param + calls
  `registry.beginParse()` at the top. HTML_BLOCK arm tries
  `resolve` first, falls back to placeholder.
- Host calls `registry.gc()` after swapping the new Element tree
  into place — destroys instances unused for more than
  `sweep_threshold` consecutive parses (default 4).
- Tests cover register/resolve, cache-hit reuse, gc threshold,
  factory-name-change destroy-and-recreate, update-sees-latest.
- `zig build test` step added so unit tests can resolve the
  transitive C-header chain through `element.LayoutCtx`.

Demo unchanged: no factories registered yet, every `:::` still
hits the placeholder. Infrastructure is dormant, ready for 7c.

## Shipped — first concrete component (stage 7c)

`:::box` lives in `src/components/box.zig`. Reads `color` (named or
`#RGB` / `#RRGGBB` / `#RRGGBBAA` hex), `width`, `height` (pixels or
`%`), and `radius` (pixels) from `Spec.attrs`. Emits one rounded
quad through the existing quad pipeline. `update` is wired so attr
changes between parses mutate the cached instance in place — the
"cheap edit" path the `:::update` micro-stream will eventually
exploit. Missing-or-unparseable color → opaque magenta indicator.

Visible payoff: the `:::box` block in `demo.md` now renders as a
200×80 blue rounded rectangle. `:::3d-scene` and `:::chart` stay
as red missing-component placeholders (factories not registered).

`zig build test` now runs through a single entry point
(`src/tests.zig`) so subdirectory test files can reach siblings via
`../`-style relative imports without hitting Zig's module-root
guard. 21 tests total: parser + registry + box parsing helpers.

## Shipped — frontmatter state + static `${}` interpolation (stage 7d)

YAML frontmatter (hand-rolled subset — `key: value` pairs under a
`state:` block; quoted/bare strings; comments honoured; nested
maps + lists deferred). `${path}` interpolation in attribute
values, resolved at component construction time. Bare `${path}`
and `${state.path}` both work — `state.` prefix is optional.

- `src/state.zig` — `State { set, get }`, `parseFrontmatter`,
  `extractFrontmatter`. Hand-rolled rather than vendoring a YAML
  parser because the surface we need is tiny.
- `markdown.parse` peels the `--- ... ---` block off the source
  head, parses it into a temporary State, threads through to
  `preprocess` so attribute values get substituted at parse time.
  Bare-value scanner is now `${...}`-aware so template `}` doesn't
  truncate values.
- Unresolved `${path}` leaves the literal in place — loud failure
  mode, easier for authors / LLMs to notice typos.
- Demo's `:::box` block now sources color / width / radius from
  frontmatter; `:::3d-scene`'s `src` interpolates `target_id`.

## Shipped — reactive state (stage 7e)

State is now observable. `state.set(path, value)` fires
subscribers. The registry auto-subscribes a `Binding` callback per
`${}` reference during `resolve`: when the path mutates, the
binding re-substitutes the cached instance's templated attrs and
calls `factory.update` with a fresh Spec.

Key shape decisions baked in:

- Preprocess keeps **templated** attrs (with `${}` literal); the
  registry substitutes internally when invoking factory.create /
  factory.update. That way the templates are always available
  for re-substitution on mutations.
- `Binding` is heap-allocated separately from the Entry so
  Subscriber callbacks hold a stable `*Binding` ctx even if the
  registry's instances map reallocates.
- Subscriptions are soft-deleted on `unsubscribe` so peer
  pointers stay valid mid-fire. Compaction can land later.
- `state.dirty` flag drives re-layout — drawCb checks it
  alongside the extent-change trigger; cleared after runLayout.

Demo cycles `box_color` through five colours every 1.5s. The
registry's subscriber fires factory.update on the cached box
instance, which updates its color field; dirty flag triggers
re-layout; the quad pipeline picks up the new colour. ~13.3k fps
Release through the cycle, 99.6% cache hit rate.

39 unit tests passing, including `reactive: state.set fires
factory.update on bound component` and `reactive: gc unsubscribes
the binding`.

## Shipped — input handling (stage 7f)

`ElementVTable` grew an optional `on_input` callback. The walker
appends an entry to `DrawList.hits` for any `custom` element that
exposes `on_input` — a flat layer of (laid-out Box, vtable, ctx)
tuples we walk in reverse on each mouse event so the deepest hit
wins. No bubbling at 7f; lands when a real use-case needs it.

`InputEvent` is a closed union — `mouse_down` / `mouse_up` /
`mouse_move` with a `MouseEvent` payload carrying `local`
(relative to the hit's box), `button`, and `button_down` (the
held-state flag, so mouse_move doubles as the drag channel).

`main.zig` polls `glfwGetCursorPos` + `glfwGetMouseButton` each
frame, diffs vs the previous frame, and dispatches with pointer
capture: the hit that received `mouse_down` keeps receiving
events until release, so drags don't break when the cursor
leaves the thumb's box.

First interactive component: `src/components/slider.zig`. Track +
filled track + thumb visuals; drag updates a numeric state path
declared via the `target` attribute. The demo wires two — radius
and height for the box. Drag → state.set → registry binding
fires → factory.update on `:::box` → `state.dirty` triggers
re-layout → new quad. 43 unit tests.

## Shipped — `:::update` micro-stream wire format (stage 8a)

The LLM-streamed-delta path — bypasses cmark, bypasses the Element
walker, bypasses text layout. Two dispatch backends:

- **Component-target.** `:::update {#id action=NAME}\nBODY\n:::`
  → `Registry.handleUpdate(id, action, body)` → cached instance's
  `Factory.handle_update`. New optional vtable slot; components
  opt-in. Errors with `UnknownComponentId` or `NoUpdateHandler` for
  missing surfaces — caller drops + logs at its policy.
- **State-target.** `:::update {target=state.path}\nVALUE\n:::`
  → `state.set(path, body)` → 7e reactive substrate propagates
  through `Binding.refire` to bound component instances. The
  canonical path for declarative-state mutations from an outside
  agent.

`update.applyAll(arena, state, registry, source)` parses + dispatches
every `:::update` block found in `source` and returns the count
applied. Per-update overhead is one attr-list slice + one body dupe
in caller-supplied arena. Demo loop emits one state-target directive
every 1.5s and reuses the arena via `reset(.retain_capacity)` — 0
allocations in steady state, holds the existing ~13.3k fps Release.

Box gained `handle_update` accepting `set-color`/`-radius`/`-width`/
`-height`. The visible demo uses the state-target path because the
box's color is templated (`${state.box_color}`); component-target
dispatch is covered by unit tests + ready to drive the upcoming
`:::chart`. 53 unit tests passing.

## Shipped — `:::chart` streaming showcase (stage 8b)

The visceral component-target demo. `src/components/chart.zig` —
ring buffer of f32 samples, axis-aligned column rendering (filled
sparkline), `handle_update` accepts `action=append` (body=one
float) and `action=clear`. The chart owns its data opaquely so it
runs *without* a state Binding — the design pitfall flagged on
`:::box` (component-target updates fighting templated attrs) doesn't
apply.

Demo wires a 60 Hz synthetic data source: layered sines + noise,
each tick emitting `:::update {#telemetry action=append}\nVALUE\n:::`
through `update.applyAll`. 4-second smoke: 241 updates dispatched,
12.0k fps Release with the full re-layout firing on every chart
append. 9 new unit tests.

Attribute grammar mirrors box's: `min`, `max`, `width`, `height`,
`color`, `bg`, `radius`, plus chart-specific `type=line` and
`capacity=N` (default 128, set at create only — resize would
discard history).

## Shipped — `:::embedded-document` (stage 9)

The composition flywheel kickoff. Built-in factory reads `src=` from
disk, parses through `markdown.parseWithStateAndScope` with a fresh
child `State` (`parent` pointer set so dirty bubbles up), and grafts
the resulting Element subtree into the host doc's layout. Non-`src`
attrs overlay onto child state — parent always wins over child
frontmatter.

Scoped cache keys: `Registry.resolve` grew an optional `scope`
param; when non-null the effective key becomes `"{scope}/{id_or_auto:N}"`.
Child components in the embedded doc share the parent's Registry
but their cached instances live under prefixed keys, so a child's
`:::box {#bx}` never collides with a parent-level `#bx`.

New `Registry.deinitScope(prefix)` sweeps every instance under a
given scope — called by the embedded-doc factory.deinit before
freeing child state so child bindings unsubscribe cleanly while
their subscribed-to state is still alive.

State grew a `parent: ?*State = null` field. `set()` walks up the
chain flipping `dirty` so a host that only watches the root state
still sees mutations inside any nested document.

Demo `src/widgets/orbit_panel.md` shows two stacked `:::box`
elements taking colour + dimensions from child state, plus parent
overlay (`panel_color=cyan inner_color=magenta`) that wins over
the widget's frontmatter (orange / yellow). ~11.2k fps Release with
all of 8a + 8b + 9 active.

**v0 limitations** (deferred to follow-up stages):

- **Interactive components inside embedded docs** route input to the
  parent state, not child state. The walker stamps the root state
  pointer onto every Hit; fixing it means plumbing state through
  `LayoutCtx` and `Hit`. v0 demo uses non-interactive child
  components.
- **External `:::update`** wire-format directives can't target
  scoped components; `:::update {#bx ...}` always looks up the
  parent-scope `bx`. Future: `id="scope/leaf"` or `scope=` attr.
- **`src=` is a CWD-relative path.** No base-dir resolution, no
  URLs, no content-hash cache. Stage 11 layers that on.
- **`update` of a live embedded-doc doesn't honour `src` changes** —
  author changes the `#id` to force destroy + recreate.
- **Module-globals in `embedded_document.zig`** (registry + theme +
  parent state captured at install time). The `Factory.create`
  signature doesn't expose host context; a future contract change
  (per-factory config pointer, or a `*Host` ctx through create) is
  the right fix.

## Next — document composition continued (stages 10–11)

See [`vision.md`](vision.md) "Document composition + the flywheel"
for the full pitch. Stage 9 shipped above; the remaining two
flywheel pieces:

- **Stage 10 — headless documents.** A document parsed without
  a viewport: factories instantiate, state lives, subscribers
  fire, but no `layoutAndRender` runs. Other documents subscribe
  to its state paths or read its AST via `markdown.parse`'s
  return value. The runtime equivalent of a "data layer" doc — a
  shared state machine that visible docs project from.
- **Stage 11 — remote component sources.** The `src=` of a
  `:::embedded-document` can be a URL. Loader is a factory that
  fetches + parses + caches. Local-first; offline fallbacks;
  content-addressed caching layer. Same shape as 9, different
  loader.

## Shipped — async I/O channel (stage 12)

Stage 11 v0 put `std.http.Client.fetch` synchronously inside
`embedded_document.create`, which runs on the main thread during
parse. Localhost worked fine; a slow / failed / hung remote would
have frozen the renderer with no visible feedback. The same shape
is wrong for the eventual LLM-stream input path, file-watcher
hot-reload, MCP-tool subprocess pipes, and anything else that can
block.

The fix is a two-layer concurrency primitive:

- **`src/jobs.zig`** — work-stealing thread pool (Chase-Lev deque),
  ported from valkyr. Worker count defaults to `cpu_count - 2`,
  min 2. Workers own per-worker LIFO deques, steal FIFO when their
  own deque is empty, progressive yield → 100µs sleep when idle.
  Foundation primitive — reused later for parallel layout, mesh
  build, anything CPU-bound.
- **`src/io_channel.zig`** — `IoChannel` on top: `submitHttpGet`
  packages a request into a Job, schedules it onto the pool;
  worker runs the blocking fetch; pushes a `Completion` onto a
  mutex-guarded MPSC completion queue. Main thread calls
  `channel.drain(handler)` once per frame; handler routes the
  completion to whatever component owns the in-flight request
  (today: `embedded-document` only). Mutex queue (not lock-free
  MPSC) is fine for v0 — completion volume is tiny; swap a Vyukov
  MPSC in when load justifies.

`embedded-document` is the first migration: factory.create posts
a fetch and returns a Component in `phase = .loading`; the
component renders a soft-grey "loading {url}…" placeholder until
the bytes land. Completion handler caches the body, applies
frontmatter + snapshotted parent overlays, parses, swaps the
Component to `.ready`, bubbles `state.dirty` to wake the next
re-layout.

Cancellation discipline: `deinit_` during the loading phase
nulls the `PendingFetch.component` slot so the completion
handler discards the body cleanly without dereferencing freed
Component memory. PendingFetch is owned by the completion
handler; Component holds it only for cancel-signaling.

Local file `src=` paths stay synchronous — filesystem reads are
fast and the loading-state machinery isn't worth the complexity
there.

LLM streaming + file-watcher hot-reload (stage 13+) layer on the
same channel without touching the contract again — they just need
new `Request` variants (currently `http_get` only) and matching
completion routing.

Tests cover the channel end-to-end (synthetic post→drain
roundtrip, worker-thread post via scheduled job, deinit
releasing undrained bodies, handler-can-resubmit) and the
embedded-document overlay snapshot/refresh helpers. The
Pending↔Component cancellation invariant is captured in
`memory/project_io_channel_cancellation.md`.

## Shipped — live LLM authoring (stage 13a)

The headline payoff of stage 12. `IoChannel` grew a streaming
variant (`submitHttpStream` + `Result.chunk/.end/.end_err`); the
new `:::llm-stream` component posts a `stream: true` chat
request to Ollama and renders the response as a child markdown
tree that re-parses on every chunk. Tokens visibly stream into
the document.

Memory: every Component holds `content: []u8` (accumulated
`message.content` from each chunk) + a per-instance arena that's
reset before each re-parse. The arena reset means the
intermediate Element trees don't accumulate; only the raw
content buffer + the latest parsed tree are live.

Routing: completions dispatch by result kind in main.zig's
`drainHandler` (`.ok`/`.err` → embedded-document; `.chunk`/`.end`
/`.end_err` → llm-stream). Fragile-by-design; a real router
table lands when a third consumer needs the same kind.

Cost: re-parsing the whole accumulated content on each chunk
drops FPS from ~9.3k baseline to ~5.9k during active streaming
and recovers post-stream. Stage's retained layout cache is the
right fix — currently parked.

Demo: a `:::llm-stream` block in `demo.md` prompts `qwen3.5:2b`
for a Vulkan haiku and watches the heading + lines materialise.
Disable the demo block (or stop Ollama) to fall back to a red
"LLM stream failed: …" placeholder.

## Shipped — multi-provider streaming (stage 13a.5)

`provider` attr added: `ollama` (default) or `openai`. The
OpenAI mode covers DeepSeek, OpenRouter, OpenAI proper, Together,
Groq, Mistral, and anything else that speaks the
`POST /chat/completions` SSE-streaming wire format — they all
share the same body shape (`messages`/`stream`/`max_tokens`) and
the same chunk shape (`choices[0].delta.content`,
`data: {...}\n\n` events, `data: [DONE]` terminator). One
implementation, an entire ecosystem.

`IoChannel.HttpStreamRequest` grew an `extra_headers` slice so
Bearer-token auth (and any future custom headers) can ride along.
The worker dupes them into its context and forwards to
`client.open(..., .extra_headers = ...)`.

API keys come from `~/.env` via a deliberately tiny
`src/dotenv.zig` (KEY=VALUE pairs, optional quoted values,
comments + blank lines skipped, last-write-wins on duplicates).
The factory reads `api_key_env=NAME` from the spec to know which
entry to pull. Process env vars are NOT consulted — keeps the
key-discovery story to one place. Add a process-env fallback
later if a deployment needs it.

Demo now stacks three providers side-by-side: local Ollama,
remote DeepSeek, and `google/gemini-2.5-flash` via OpenRouter.
All three streaming concurrently runs at ~7.6k fps Release.

## Shipped — button + LLM trigger (stage 13b)

`:::button` is the first non-slider interactive component.
Attrs: `label=`, `target=#id`, `action=name`, optional `body=`.
The on_input arm fires `registry.handleUpdate(target, action,
body)` on primary mouse_up. Simpler than going through the
`:::update` byte stream — buttons are a click→dispatch shortcut.
Currently component-target only; pair with the existing
`:::update` emitter when a button needs to mutate state directly.

`:::llm-stream` grew `auto_start=false` + `Phase.idle` + a
`handle_update(action=start)` arm. The kickStream pathway is now
reusable for both first-mount-fire and click-driven re-fire. On
re-fire it nulls the in-flight Pending's back-pointer (so the
worker's chunks are quietly discarded), clears the content +
line buffer, resets the arena, and submits fresh.

Demo: three `Run …` buttons sit next to three idle
`:::llm-stream` blocks (Ollama / DeepSeek / OpenRouter-Gemini).
Click to trigger; click again to watch a fresh stream paint in.

## Shipped — input field (stage 13c)

`:::input` — single-line editable text field. Cursor + UTF-8
buffer + caret blink + arrows / home / end / backspace / delete /
enter. Click to focus (vtable's `focusable=true` propagates onto
the walker's Hit), Esc clears focus. Enter dispatches
`registry.handleUpdate(target, action, body=buffer)`.

`element.InputEvent` grew `char_input`, `key_down`,
`focus_gained`, `focus_lost` channels; `KeyEvent` carries the
GLFW keycode + mod mask. `FrameCtx.focused: ?Hit` tracks current
focus; GLFW char callback registered alongside the existing key
+ scroll callbacks.

`:::llm-stream.handleUpdate` now respects a non-empty body as a
prompt override — so the input dispatches the typed text as the
new prompt, while the button keeps the canned default for retry.

Demo: three input fields, one above each LLM stream. Type a
question, hit Enter, three providers answer in parallel.

## Shipped — `:::svg` + triangle pipeline (stage 13d.1)

End-to-end vector graphics. New mini SVG parser scoped to the
Recraft V4.1 subset (M/L/C/z paths with rgb fills + translate).
New CPU tessellator: recursive cubic-Bezier flattening +
Mapbox-port earcut for arbitrary simple polygons (with hole
stitching). New Vulkan triangle pipeline (VBO + IBO indexed
draw, flat-colour shaders, premul alpha blend matching
quad/text). Render order: triangles → quads → text so SVG fills
sit under chrome + glyphs.

`:::svg {src= width= height=}` reads a file, parses,
tessellates once at create time, caches the mesh per-component,
transforms viewBox coords to screen at layout. Failure flips to
red placeholder.

The Petunias.svg fixture (125 paths, 4174 triangles) became the
calibration target — Recraft V4.1's output is sharply
constrained (no `<g>`, no gradients, no strokes), which kept
the parser tight.

## Shipped — parallel tessellation (stage 13d.2)

`svg_tessellate.tessellateParallel(allocator, paths, mesh,
job_system, opts)` — one Job per `<path>`, each worker
tessellates into its own `c_allocator`-backed `Mesh`, serial
merge on the main thread with index rebasing.

**8.17×** speedup on Petunias's 125 paths (22 ms → 2.7 ms).
Basically linear scaling because path costs are wildly uneven (1
cubic vs 30+ cubics) and the work-stealing pool absorbs the
long-tail without main-thread coordination. Equivalence test
confirms identical vertex + index counts across serial /
parallel paths.

## Shipped — `:::svg-stream` (stage 13d.3)

`:::svg-stream {provider= endpoint= model= api_key_env= prompt=
max_tokens= width= auto_start=}` — vector graphics generated
on demand by an image-class model. Default targets
`recraft/recraft-v4.1-vector` on OpenRouter.

The wire format is **not** chat-shaped despite the
`/chat/completions` endpoint. Send `stream:false`, accumulate
raw HTTP chunks, parse the JSON envelope on `.end`, find
`choices[0].message.images[0].image_url.url`
("`data:image/svg+xml;base64,...`"), strip the prefix, base64-
decode, run through `svg.parse` + `tessellateParallel`. Phase
model is `{idle, loading, done, failed}` — there's no real
intermediate streaming state since Recraft itself is one-shot.

Refactored the IoChannel completion routing in the process:
`io.PendingHeader` (function-pointer first field of every
PendingX struct) replaces the old result-kind switch in
`drainHandler`. Adding a new consumer no longer touches
`main.zig`.

## Then — more components (stage 13d.4+)

Raster `:::image` (PNG/JPG via base64 data URL, mirrors the
SVG-stream shape with a texture pipeline instead of triangles).
More SVG generators (Stability SD-Vector, Bytedance Doubao-Vector
on OpenRouter). 3D scene (eventually integrates with
matryoshka), live chart beyond sparkline, form, table. Each is
a self-contained component module; the contract is fixed by
stage 7. Repetitive work, not architectural.

## Parallel — retained layout cache

Bumped to active-watch priority by stage 8b's measurements. The
chart's 60 Hz feed re-walks the entire markdown document on every
append because `state.dirty` triggers full re-layout — that's the
13.3k fps → 12.0k fps gap. Caching laid-out glyphs + quads at the
Element level + only re-walking elements whose ctx mutated since
last frame recovers most of the cost. ~12k → ~16k fps is plausible
on the current demo, more on chart-heavy docs.

Sized right for after the composition track, or as a backfill when
chart-density demos start landing.

## Parallel — markdown ↔ ANSI composability (stage 5b)

Originally planned as stage-5-followup but bumped by the vision
work. ` ```ansi ``` ` fenced code blocks in markdown route
through `ansi.parse`, output stuffed into `CodeContent.sub_block`;
`layoutCodeBlock` recurses into it. Closes the markdown-↔-ANSI
loop. Small commit (~50 LOC). Lands when convenient.

## Shipped — scroll + zoom (post-stage-11)

Scroll wheel scrolls; Ctrl+scroll zooms. Both implemented as a
post-layout transform pass on the DrawList: `screen = (world - scroll) * zoom`
applied to every glyph + quad's position and size in one O(N)
walk per layout. World-space layout stays unchanged; mouse coords
un-transform on the input side so `Hit.box` comparisons stay in
world coords.

`FrameCtx` grew `scroll_y` / `zoom` / `max_scroll_y` fields. GLFW
scroll callback (registered via window user pointer) dispatches on
`GLFW_KEY_LEFT_CONTROL` / `GLFW_KEY_RIGHT_CONTROL` state. Bounds
clamping happens at the callback (scroll) and at the end of
`runLayout` (recomputed `max_scroll_y` against new content height).

Zoom range 0.25× – 4×, 10% per wheel-notch step. Scroll: 60 px per
wheel-notch.

**v0 limitation: pre-rasterized text becomes fuzzy at non-1.0 zoom.**
The atlas glyphs are at fixed pixel sizes; the transform stretches
them. SDF glyphs (ATTENTION) stay crisp because the SDF shader
re-resolves at any scale. The proper crisp-zoom fix is a
multi-size font atlas + re-layout-on-zoom-change — moderate
rebuild, deferred.

~10k fps Release with active scroll/zoom + all of 8a/8b/9/11
running.

## Eventually — LM connection (tier 3)

Once the rendering channels (`attention`, `hot_color`, `fx_kind`)
and the live-document runtime are both stable, plug in real LM
signals as the producer of state mutations + `:::update` streams.
This is the closing of the loop from `chat.md`'s original vision:
the LM doesn't just produce text — it produces a *live document*
that updates in place as the model's understanding evolves.

## Parked — rendering issues

Captured in [`memory/project_known_issues.md`](../../../.claude/projects/-home-chrisbe-dev-terminal/memory/project_known_issues.md). Surface when relevant:

- **Atlas overflow** — `error.AtlasFull` after enough unique
  glyphs. LRU eviction or grow + recreate descriptor.
- **Gamma correction** — fine at 20 px, matters at 14 px.
- **Font fallback** — `"Hello 🎉"` in one text run loses the
  emoji because DejaVu's glyph for U+1F389 is `.notdef`.
- **Single-channel SDF** — corners slightly soft under extreme
  zoom.

## Parked — layout issues

- **Break-anywhere wrap** — a single word wider than `max_w`
  overflows. Character-level break fallback when no whitespace
  is available.
- **Tab + Unicode whitespace** — tokenizer splits on ASCII space
  only.
- **Bidirectional text** — HB shapes each run correctly, but
  line composition assumes LTR.
- **Body-relative cascade** — emphasis inside a heading swaps
  to body italic font. Per-block font families fix it.

## Parked — visuals waiting for primitives we now have

Now that stage 4 shipped quad / line primitives, these get
unblocked:

- **ANSI underline + strikethrough + reverse** — SGR parses them,
  Style flags exist; needs the quad/line emit path that link
  underlines pioneered.
- **ANSI background colours** — per-character quad emission
  during inline-flow emit. Possible now but moderate
  engineering.

## Parked — naming

`text_engine` is visibly the wrong name for what's becoming a
live-document runtime. Rename when stage 7c ships (first concrete
component) — at that point the runtime layer above the contract
is real enough to anchor the name.

Candidates that came up:
- `glow` (live + glowing)
- `forge` (runtime/factory feel)
- `litho` (printed page + dynamic)
- something tied to matryoshka (sibling brand)
