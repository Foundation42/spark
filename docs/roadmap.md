# spark — roadmap

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

## Shipped — headless documents (stage 10)

`:::embedded-document {headless=true}` parses the child markdown,
populates child state, instantiates child components (auto_start
streams fire, `:::chart` ingest works, registry routing by id
stays intact) — but `layoutAndRender` short-circuits with a
zero-size box and emits no draw data. Invisibility propagates
behaviourally: nested visual content arbitrarily deep stays
hidden regardless of its own `headless` flag, because the layout
walker simply never descends.

Two toggle paths land in the same stage. The reactive-attr path
re-reads the `headless` attr on every `update()` call, so
`headless=${state.x}` composes with the existing Binding subsystem
— flip state, doc visibility flips. The `handle_update` path adds
`set-headless` and `toggle-headless` actions for direct/LLM
mutation without bouncing through state. The demo uses the
reactive-attr path with state-target buttons (stage 13b.1).

The cache-warming use case is the manifesto's pattern made
concrete: a headless doc can hold `:::svg-stream` / `:::image-
stream` components with `auto_start=true` that pre-fetch the
asset cache for a visible doc later. Component instances exist,
HTTP requests fire, meshes/textures build — just not on screen.

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

More SVG generators (Stability SD-Vector, Bytedance Doubao-Vector
on OpenRouter). 3D scene (eventually integrates with matryoshka),
live chart beyond sparkline, form, table. Each is a self-contained
component module; the contract is fixed by stage 7. Repetitive
work, not architectural.

## Shipped — retained layout cache (stage 14a)

`src/layout_cache.zig` — per-block cache keyed on
`(elem_id, max_w, theme)`. Content version held outside the key as
an Entry field so a bump replaces the slot in place (no leak on
1000-chunk streams). Leaf-ish kinds (paragraph / heading /
code_block / thematic_break) cache automatically; custom
components opt in via `vtable.content_version` and out via
`vtable.disable_cache`. LLM-stream nulls `cache_blocks` before
recursing into its child tree (per-chunk re-parse changes inner
pointer identity).

Idle: 97.9% cache hit rate, 56 entries, ~7600 fps with chart at
60 Hz + box color cycle. Chart's per-tick `state.dirty` no longer
re-walks the whole document.

## Shipped — glslc -O for release builds

Mapped Zig's `optimize` → glslc flags in `compileShaderStage`.
Debug → `-O0` (default), ReleaseSafe / ReleaseFast → `-O`,
ReleaseSmall → `-Os`. Text fragment SPIR-V shrank 34% (3040 →
2008 bytes).

## Shipped — worker pool split (stage 14d)

Two `JobSystem` instances now live side by side, owned by main.
The compute pool keeps the original sizing (`cpu_count - 2`
workers, all hot for parallel layout + tessellation). The I/O
pool is sized for concurrency, not parallelism — 24 workers,
each happily parked on `req.read` for the upstream duration of
a stream. `IoChannel.init` takes the I/O pool;
`submitHttpGet` / `submitHttpStream` schedule onto it so blocking
HTTP never touches the compute workers.

Re-arms stage 14b by dropping `PARALLEL_MIN_WALKS` back to `2`
in `src/element_layout.zig`. The infrastructure (mutex around
GlyphCache, classification, blitPrivate / snapshotFromPrivate)
that was retained through the parked period now fires again.
Multi-stream demo (3 LLM + svg-stream + image-stream) confirms
no main-thread hang, no fan spinup.

Zero contract changes — `submitHttpStream` still returns a
Handle synchronously and posts completions through the channel
asynchronously, same as before. Only the pool routing moved.

## Shipped — persistent asset cache (stage 14e)

Browser-style content-addressable cache for expensive remote
assets (Recraft V4.1 SVG envelopes, Gemini image preview envelopes
— both ~$0.08/firing). New `src/asset_cache.zig` with flat-
directory layout: `<hex-sha256>` bytes files plus a
`manifest.json` index tracking per-entry `size`, `created_at_ms`,
`last_accessed_at_ms`, optional `source` descriptor + `content_type`.
Configurable byte budget (default 500 MB), LRU eviction on
overflow, atomic manifest writes (tmp + `rename` within the cache
dir). `pruneOlderThan` / `pruneAll` / `setBudget` knobs for
future CLI / debug surfaces.

Lives at `${XDG_CACHE_HOME:-$HOME/.cache}/spark/assets`.
Each cacheable consumer derives its own key:
`sha256(prefix | provider | endpoint | model | system | prompt | max_tokens)`.
The prefix carries a schema version (`svg-stream:v1`,
`image-stream:v1`) so a future key-shape change silently bypasses
old entries rather than colliding.

`:::svg-stream` and `:::image-stream` opt in. Cache-hit fast path
in `kickStream` reads bytes synchronously (sub-ms on SSD), feeds
them into the existing `finalizeResponse` parser, goes straight to
`.done`. No `IoChannel` traffic, no spinner, no charge. On cache
miss, the existing submit path runs; the successful `.end` writes
the accumulated envelope to disk.

## Shipped — state-target button dispatch (stage 13b.1)

Button `onInput` splits at click time. `target=state.path`
writes `body` straight into the scope-local state via the
dispatcher's `on_input` state pointer (matching how `:::slider`
and `:::input` have scoped state mutations since stage 9).
`target=#id` keeps the existing `registry.handleUpdate` path
against the host registry — a button in a child doc still
reaches parent-scope or sibling-scope components.

`action=` is optional for state-target dispatch (state mutation
is a single primitive verb; the wire format accepts `action=`
for symmetry with component-target but ignores it).

Closes the reactive-attr loop end-to-end. Headless config demo
now reads `headless=${state.config_hidden}` and uses two
state-target buttons (Show / Hide) instead of bouncing through
the `handle_update` arm.

## Shipped — persistent reactive state (stage 13b.2)

`State` grew `saveToFile` and `loadFromFile`. JSON format with a
version field: `{"version":1,"entries":{"key":"value", ...}}`.
Atomic write (tmp + rename within the same directory) so a crash
leaves either the old file or the new one. New `persist_dirty`
flag independent of `dirty` — host throttles disk writes on its
own cadence without disturbing the renderer's repaint signal.

Lives at `${XDG_STATE_HOME:-$HOME/.local/state}/spark/state.json`
(state is user data, not regenerable cache — XDG conventions put
them under different roots so `rm -rf ~/.cache` doesn't lose
slider positions).

Main loads the file between `state_mod.fromSource(demo_md)` and
`markdown.parseWithState` so persisted values overlay onto
frontmatter defaults *before* component Bindings subscribe.
Throttled flush every 60 frames (~1 s at 60 fps) if dirty; final
flush on graceful exit catches the tail. The slider-drag pattern
(60 sets/s) coalesces to one disk write per second.

Restart picks up where the user left off. Dragged slider
positions, button-driven state mutations, input contents all
survive.

## Shipped — cost-aware parallel-walk classification (stage 14f)

`ElementVTable.parallel_layout_cheap: bool` flag (default false).
The stage-14b dispatcher counts only *expensive* snapshot-eligible
walks toward `PARALLEL_MIN_WALKS`; cheap walks still dispatch in
parallel **when** an expensive sibling pushes us over, but on
chart-only-dirty frames the dispatcher stays serial — no
`Counter.wait` spin for work that finishes in microseconds anyway.

Chart, svg-stream, image-stream opt in (their re-walks are O(N)
memcpy in microseconds — column quads, mesh-slice rebind,
descriptor-set emit). Paragraph / heading / code_block stay
default expensive — HarfBuzz shaping is always heavy enough to
dispatch.

## Parked — finer-grained walk-cost memoisation

The static vtable flag (14f) handles the present problem.
Future-stage refinement: cache the actual last-walk time on each
element + gate dispatch on `>N us` measured cost. Worth the
complexity only if frame-time profiling flags it.

## Shipped — raster `:::image-stream` (stage 14c)

Mirror of `:::svg-stream` for image-class models (target:
google/gemini-3.1-flash-image-preview). Same OpenAI-shaped wire
format; data URL contains a PNG/JPG instead of an SVG, decoded
via vendored `stb_image` into per-component `VkImage` + sampler.

New pieces: `vendor/stb/`, `src/gpu/image_texture.zig`,
`src/gpu/image_pipeline.zig`, `shaders/image.{vert,frag}`,
`DrawList.images`, `src/components/image_stream.zig`. Render order
extended to tris → images → quads → glyphs.

Each component owns one descriptor set from the pipeline's pool
(MAX_IMAGES = 32). Texture reused across re-fires when
dimensions match; reallocated otherwise. Descriptor rewritten in
place via `vkUpdateDescriptorSets` so cached layout entries stay
valid.

## Shipped — markdown ↔ ANSI composability (stage 5b)

` ```ansi ``` ` fenced code blocks in markdown route through
`ansi.parse`; the result lands as `CodeContent.sub_block` and
`layoutCodeBlock` recurses into it with the same chrome the
`.raw` arm gives. Theme is cloned with `body = code_block` so SGR
text picks up the mono font for terminal-like spacing — same
pattern `main.zig` uses for the standalone ANSI demo. Closes the
markdown-↔-ANSI loop the `CodeContent` contract was designed for.
~70 LOC production + 95 LOC tests.

## Shipped — emoji font fallback (stage 5c)

Theme grew `fallback_font_id` + `font_registry` pointers; the
markdown parser scans every text leaf and splits on coverage
boundaries — codepoints the primary font has stay in primary
runs, codepoints only the fallback covers spin off into sibling
text leaves with `font_id = fallback`. Inline-flow walker handles
the resulting mixed-font runs identically to emphasis/strong
cascades.

Variation Selector 16 (U+FE0F) on a dual-presentation base like
U+2764 (❤) forces the colour-emoji route even when the body font
has a monochrome glyph for the same base. VS15 (U+FE0E)
symmetrically pins to primary. ZWJ + variation selectors +
zero-width spaces inherit from the run they're decorating so
multi-codepoint emoji ligature sequences stay on one font.
~185 LOC.

## Shipped — crisp zoom (multi-size atlas)

Zoom used to be a post-layout scale on a fixed-size bitmap, so
any non-1 zoom level fuzzed text through bilinear filtering. Now
the atlas grows per zoom bucket: when a paragraph lays out at
zoom=N, each glyph gets rasterised at `style.font_id.display_px ×
N` pixels and the layout emits a world-space dst_size that
shrinks by `1/N`. The host's existing `× zoom` post-layout
multiply then takes the world quad to native bitmap pixels on
screen — 1:1 bilinear sampling, crisp at every zoom level.

`FontRegistry.effectiveFontId(base, target_px)` looks up (or
lazily creates) a sibling entry with the same TTF reopened at a
different rasterisation size. SDF + strike-only colour fonts
return their base id (their bitmaps are zoom-independent — SDF's
distance field AAs at any display size, emoji strikes are fixed
in the font file).

`world_scale = base.display_px / eff.actual_px` collapses to the
right thing across all lanes: 1.0 for mono z=1 (bit-identical to
the pre-crisp path); 1/N for mono z=N (scaled bitmap fills the
same world footprint); `base.scale` for SDF and strike-only colour
(zoom-independent bitmaps).

Prewarm runs on the main thread before workers fan out, iterating
only the host-loaded base entries (effective entries are
dead-end leaves; cascading onto them produces exponential blow-up
via `display_px × zoom` compounding). `AtlasFull` triggers a
coarse LRU reset — clear glyph cache + atlas reset + block cache
clear + retry once. Sub-frame "blink" recovery rather than a
freeze. ~470 LOC across font registry / layout / atlas / main.

Viewport-aware `max_w`: layout's wrap constraint is now
`extent.width / zoom - 80`, so the world-coord column width
shrinks as you zoom in (text re-wraps tighter, fits inside the
viewport) and expands as you zoom out (more words per line, no
right-side gutter). Browser-style "the whole page zooms".

Mono atlas bumped 768 → 2048 (4 MB R8, trivial on any modern
GPU) to hold ~30 distinct zoom levels' worth before the LRU path
kicks in.

## Shipped — half-pixel chop fix

Removed a 0.5-texel UV inset that was originally meant to defend
against neighbour-glyph bleed at downscale, but the atlas
already keeps a 2-texel zero-cleared gutter between glyphs and
bilinear sampling can never reach further than 1 texel past a
quad edge. The inset was redundant — and at 1:1 it turned the
top + bottom rows into a 52.5/47.5 mix with the gutter, visibly
clipping the bottom (and top) half-pixel of every glyph. Removed
→ texel-center alignment at integer zoom levels, downscale paths
still protected by the gutter.

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

~~**v0 limitation: pre-rasterized text becomes fuzzy at non-1.0 zoom.**~~
~~The atlas glyphs are at fixed pixel sizes; the transform stretches~~
~~them. SDF glyphs (ATTENTION) stay crisp because the SDF shader~~
~~re-resolves at any scale.~~ Crisp zoom landed in session 10 — text
is now pixel-perfect at every magnification via a multi-size atlas
keyed by `(font, glyph, target_px)`. See the "Shipped — crisp zoom
(multi-size atlas)" section above.

~10k fps Release with active scroll/zoom + all of 8a/8b/9/11
running.

## Shipped — ANSI underline + strikethrough + reverse

The parked SGR visuals from session-10-era backlog. The link
underline emit path generalised into a `DecorationRun` tracker
that closes a span on attribute-off and emits one quad per
contiguous run. Three trackers run side by side in `emitLine` —
underline (markdown link OR ANSI SGR 4), strikethrough (SGR 9),
and run background (SGR 7 reverse; future SGR bg-set codes share
the field).

`Style` gained `underline` / `strikethrough` / `reverse` / `bg`
fields; `Theme` gained `strikethrough_thickness_em` /
`strikethrough_offset_em` (matching the `link_underline_*_em`
shape) and `background` (page-bg colour for reverse-mode contrast
text, defaulting to the renderer's `clear_color`). SGR 4 / 9 / 7
set the flags; 24 / 29 / 27 clear them; SGR 0 reset clears all
three. SgrState's `toStyle` performs the reverse swap: pre-swap
fg → `Style.bg`, theme background → `Style.color`. Same
`Style.bg` field will land the parked ANSI bg-set codes when a
demand surfaces.

Demo: the `​```ansi` fence in `demo.md` gained two lines exercising
all three plus combined modes (bold + underline + cyan, red +
strike, yellow + reverse). 5 unit tests in `ansi.zig` covering
set / clear / SGR-0 reset / combined SGR. ~120 LOC across
`element.zig`, `ansi.zig`, `element_layout.zig`, `demo.md`,
`tests.zig`.

## Shipped — kiwi constraint solver (stage 15A)

Pure-Zig port of Chris Colbert's kiwi (modern Cassowary, BSD-3,
~3000 LOC C++). Incremental dual-simplex tableau, four-tier
strengths (required / strong / medium / weak), edit variables for
reactive inputs. Lives at `src/layout/kiwi/` as a self-contained
module with zero spark deps — clean boundary, tested in
isolation. ~3,000 LOC + 300+ unit tests (Zig translation of the
canonical kiwi C++ test corpus, partial — translation is task #201,
still pending). One session of recon (kiwi source map, Rust port
translation guide, canonical test corpus), one session of porting
primitives + solver core, ongoing corpus translation. Closes Phase
A of the stage 15 plan.

## Shipped — LayoutContext + :::box integration (stage 15B)

`LayoutContext` wraps the kiwi `Solver` plus a `bounds_map` keyed
by `@intFromPtr(component_ctx)` — opaque stable keys, no string
ids required from components. Each frame: `solver.reset()`
(preserves pool capacity), constraint-aware providers declare
constraints on their children, `updateVariables` settles, walker
reads positions from `bounds_map`. `:::box` migrated to the
constraint path: declares `x`, `y`, `width`, `height` variables,
posts the box-model edit constraints, reads its laid-out rect
back through `getBounds(@intFromPtr(c))`. The old hierarchical
cursor math still runs for non-constraint elements (paragraphs,
headings) — they live alongside constraint-aware providers in
the same walker. Phase B closed.

## Shipped — :::flex provider (stage 15C)

First constraint-aware provider. `:::flex {#id direction=row gap=N}`
arranges children left-to-right (column direction parked) with a
uniform gap. Each child is constraint-aware (`:::box` today); the
flex parent allocates per-child track widths and posts position
constraints into the shared solver. Body re-parsed via
`markdown.parseWithStateAndScope` so children carry full reactive
state. Flex-grow / shrink / justify=space-between deferred — those
need a measure-pass protocol (Phase C.3, parked). Phase C v0
shipped end of session 12.

## Shipped — :::grid provider + parallel-walk hardening (stage 15F.1, 15d.1, 15e)

The first multi-axis layout primitive. `:::grid {#id
columns="100px 1fr 1fr" column-gap=N row-gap=N}` arranges children
row-major across mixed fixed/flex tracks. `MAX_TRACKS=32` inline
storage avoids arena growth across `update()`. `parseTrack`
handles `100px`, `100`, `1fr`, `2.5fr`; rejects `0fr` and garbage.
`resolveTrackWidths` sums fixed widths, subtracts from
`(avail - total_gap)`, distributes the remainder by `fr` weight,
clamps to 0.

Mid-session-13 a parallel-walk race surfaced: the stage-14b
dispatcher reached `box.layoutViaConstraints` on worker threads,
multiple workers wrote to the shared `LayoutContext.solver`
concurrently, and Zig 0.14's `AutoArrayHashMap` pointer-stability
safety lock tripped under `row.substitute → cells.fetchOrderedRemove`.
Fix (stage 15d.1): `LayoutContext` grew a `std.Thread.Mutex` held
across the full add-constraints + `updateVariables` + value-read
sequence in `box.layoutViaConstraints` via `defer unlock`. ~19 LOC
of real change. Critical section ~10-30µs per box. Re-enabled the
parallel walker for grid + flex layouts under load.

Stage 15e replaced the early equal-width-track grid with the
fr-track + axis-split gap form. Closes Phase F.1; `:::table` and
named tracks defer. Manifest of the constraint layer: ~300 tests
across solver primitives + LayoutContext + flex + grid.

## Shipped — drag-to-suggest channel (stage 15D)

Phase D of the stage 15 plan, delivered in session 15. CPU-side
input drives the kiwi solver via a persistent suggestion channel —
no compute-shader readback yet (parked until a fluid-sim-style
demo actually needs it; mouse input was the load-bearing case).

`LayoutContext` grew:
- `Axis` enum (`width` / `height` / `x` / `y`).
- `suggestions: HashMap(SuggestionKey {component_key, axis}, f64)`
  that survives `beginPass`. Dragged layouts stay where they were
  put across frames.
- `bumpers: HashMap(u64, VersionBumper)` cleared per pass,
  re-registered each walk by participating components.
  `setSuggestion` fires the bumper for the target's key so the
  retained block-layout cache invalidates and the next walk picks
  up the new value.
- Public API: `setSuggestion` / `clearSuggestion` / `getSuggestion`
  / `clearAllSuggestions` / `registerBumper`. Idempotent —
  re-suggesting the same value is a no-op.

`:::box` opted in: when a width/height suggestion exists for its
key, skips the required equality and uses `addEditVariable(x_max,
medium) + suggestValue(x_max, origin + sw)` with a `geq 0` floor
so drags can't invert. Registers its version-bumper trampoline
each walk.

`:::handle` is the new drag-aware component. Attrs `target=#id`
(resolved through new `Registry.lookupSibling` that finds the
caller's own scope and qualifies the target within it),
`axis=horizontal|vertical`, `width`, `height`, `color`. Captures
the cursor's world position and the target's current size at
mouse_down; each mouse_move computes
`new_size = drag_start_size + (cursor_world_now - drag_start_cursor_world)`
and calls `setSuggestion`. Resize and stay resized.

`:::flex` and `:::grid` got `disable_cache = true` — they compose
children's draws into a single cache entry, so a child's version
bump alone wouldn't invalidate the container. Hierarchical cache
invalidation parked.

**The frozen-origin bug** surfaced during shake-out: the dispatcher
latches `fc.captured` at mouse_down (`hit.box.x` is a value
snapshot), so every subsequent `local[0]` is relative to the
*frozen* handle x. The handle's first cut reconstructed cursor world
as `c.last_box.x + local[0]` — double-counting the handle's own
motion → positive feedback → bar raced away from the cursor.
Christian caught it from physical observation when the logged data
looked superficially right; the fix is a `drag_start_handle_origin`
snapshot at mouse_down. Rule captured in
`memory/project_drag_frozen_origin.md` for any future
drag-aware widget.

Demo: a flex row with cyan box, handle, magenta box. Drag the
handle, cyan resizes through the solver, magenta shifts. The
manifesto's flywheel made tangible.

## Shipped — inline component substrate (stage 15E + 15E.2-15E.5)

Six commits in session 15 took inline components from
hand-built-demo-only to a real markdown surface hosting six
distinct visual languages flowing through prose. **Distinct from
"Phase E text exclusion"** in the original stage 15 plan (CSS
`shape-outside` magazine wrap — still parked, see below); this
shipped the parallel concept of *components participating in line
layout* alongside text runs.

**Stage 15E — text intrusion runtime (`05cd2fa`).** New
`Element.inline_object` variant + `IntrinsicMetrics` +
`ElementVTable.measure_inline` slot. Inline-flow walker (`element_layout.zig`)
extended with a fourth `InlineToken.object` variant that
participates in `max(ascender)` / `max(line_height)` resolve,
closes decoration runs at object boundaries, dispatches
`vtable.layout_and_render` at the resolved baseline. `emitInlineObject`
helper translates four `valign` modes (baseline / middle / top /
bottom) into concrete origins. First inhabitant: `::badge` pill.

**Stage 15E.2 — markdown surface (`cc74a6d`).** `::name {attrs}`
inline syntax (single-colon, mirroring triple-colon `:::block`
form). Preprocess gained per-line character-by-character scanner
that honours backtick code spans + requires a word boundary before
`::`. Matches become `<!--ti:N-->` sentinels cmark renders as
inline HTML; mapper detects + materialises as `inline_object`.
`parseAttrsBlock` + `parseDirectiveName` extracted as shared helpers
across block + inline directive parsing.

**Stage 15E.3 — ::sparkline (`bbda045`).** Mini bar chart from
comma-separated data. Normalises 0..max, renders bars as quads.
Sits on baseline; line-height grows to accommodate the chart.

**Stage 15E.4 — ::kbd + ::progress (`948f07b`).** `::kbd` =
keyboard-key chrome (raised-cap shadow + mono label + accent
border). `::progress` = inline pill bar with `value` + `max` attrs
so arbitrary state ranges can drive it without manual scaling. The
demo binds `value=${state.box_radius} max=40` so the slider's
0..40 drag reactively reshapes the progress bar through the
existing `Binding` machinery — substrate composition made visible.

**Stage 15E.5 — ::status + ::tag (`5d006d9`).** `::status` =
coloured dot ± label (dot-only mode for compact rows, dot+label
for dashboard prose). `::tag` = hashtag-style outlined chip (no
fill, knockout border, accent text). Brings the inline_object
roster to six types — enough vocabulary to write a real admin /
dashboard page in markdown.

Inline vocabulary now: `text`, `line_break`, `emphasis`, `strong`,
`code`, `link`, plus `inline_object` hosting `badge`, `sparkline`,
`kbd`, `progress`, `status`, `tag`. Each new component is 30-80
lines on top of the substrate.

## Shipped — measure-pass protocol + `:::flex` grow (stage 15 Phase C.3)

Session 16. The constraint substrate gains a measure pass:
`ElementVTable.measure_block` returns `BlockMetrics { width, height,
grow }`; `element_layout.measureBlock(elem, constraints, lc)`
dispatches the same shape as `layoutAndRender` over Element kinds
with no DrawList side effects. Built-in kinds report sensible
defaults (paragraph/heading claim `max_w`; container.stack_v
recurses; spacer takes its height); `.custom` dispatches to the
vtable slot with a scratch-DrawList fallback when none is
implemented.

`:::box` implements `measure_block` and parses a new `grow=N`
attribute. `:::flex` runs the slack-distribution algorithm for
row-direction layouts with a finite parent width — fixed-width
children claim their intrinsic, grow children share what's left
proportionally. The resolved width flows through `constraints.max_w`
to each child's `layoutAndRender`; boxes at the default `width=100%`
resolve to the slot naturally. Same mechanism `:::grid` already used
for `1fr` track distribution.

Demo proof: `:::flex` row with `grow=1` on the middle child stretches
to fill the window; resize plays back live. Second row demonstrates
proportional 1:2:1 splits across three grow children.

## Shipped — child caching for `:::flex` + `:::grid` (stage 15 Phase C.4)

Session 16. Flex/grid children walk via `layoutAndRenderCached`
instead of `layoutAndRender` — unchanged children blit out of the
block-layout cache instead of running the constraint-solver
round-trip + emit cycle every frame.

Two infrastructure pieces made this drag-safe:

- **`LayoutContext.last_sizes`** — persistent map (across
  `beginPass`) keyed by component pointer, populated by the new
  `ElementVTable.on_layout_complete` hook. The hook fires on
  every walk — `layoutAndRenderCached` calls it after `blitEntry`
  on hit, `layoutAndRender`'s `.custom` branch calls it on miss.
  Drag handlers read from this map when the per-pass `bounds_map`
  is empty (which happens whenever the target was cache-hit and
  didn't re-add itself to the solver).
- **Bumper persistence.** Bumpers no longer clear on `beginPass`
  — they're a static fact about the component, not per-frame
  state, and cache-hit components don't get a chance to re-register
  them mid-walk. `:::box.install(registry, layout_context)` now
  stashes the layout context so `deinit_` can call
  `unregisterBumper(key)` + `clearSize(key)` when the component is
  destroyed, keeping the persistent maps from holding pointers
  into freed memory.

`handle.startDrag` gains a third fallback in its size-lookup chain:
`suggestion → bounds_map → last_sizes → 0`.

## Shipped — hierarchical cache invalidation (stage 15 Phase C.5)

Session 16, completing Phase C. Flex/grid now cache as a whole —
`disable_cache=true` comes off both. Their `content_version` is
their own version XOR'd with each child's
`versionFor(child) ^ elementIdentity(child)`; the identity-mixing
dodges the A XOR A = 0 trap where two siblings with the same
version would otherwise cancel each other.

Recursion is implicit. Each container aggregates its immediate
children; nested containers already encapsulate their descendants
in their own `content_version`. A `:::box` inside a `:::grid` inside
a `:::flex` rolls bumps all the way up: box's bump → grid's
aggregated version changes → flex's aggregated version changes →
flex cache invalidates.

`layout_cache.aggregateChildVersions(children)` is the shared
helper. The combined approach (parent-cached AND children-cached
via Phase C.4) stores both the container's full output and each
child's output — ~2x cache memory for those elements. Idle
dashboards blit one entry per flex/grid; single-cell mutations
re-walk just the affected cell while siblings hit their per-block
caches.

## Next — text exclusion, more components, GPU channels

The remaining session-15 / session-16 spillover, plus the deeper
graphics integration.

- **Text exclusion / shape-outside (original Phase E).**
  `:::image {flow=around}` — markdown wraps around an SVG / raster
  figure via an `ExclusionShape` layered over the settled solver
  positions. CSS `shape-outside` semantics; per-line break
  decisions consult the exclusion shapes. Magazine-grade layout
  from a markdown file. **Different from inline_object** (which
  flows components *with* text runs); this routes text *around*
  block-level visuals. The substrate's natural next sitting —
  intrusion + exclusion is the visually-completing pair.
- **More inline components.** The substrate makes them cheap
  (~50 LOC each). Candidates that came up: `::spinner`, `::link`
  (semantic, hover-able), `::math`, `::code` (different from
  monospace span — actual chrome).
- **Compute-shader → suggestion channel.** The GPU-readback
  variant of Phase D that the original roadmap framed. Mouse input
  was the load-bearing demo case; compute-shader feedback (fluid
  sim warps the document) is the next frontier when a real demo
  needs it.
- **Cache eviction policy.** Phase C.5 doubles cache footprint for
  flex/grid (parent + children both cached). Orphaned entries from
  re-parses already accumulate slowly. LRU or TTL eviction is
  overdue generally; lands when memory pressure surfaces.

Full design position in [`layout.md`](layout.md).

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

Specific edge cases in the current tree-walk layout. Stage 15
(constraint substrate, see [`layout.md`](layout.md)) is the
strategic answer to several of these; individual fixes may also
land before then.

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

- **ANSI background colours (SGR 40-47 / 100-107 / 48;…)** — bg-
  quad emission infrastructure landed with reverse video; the
  remaining work is wiring the SGR bg-set codes into
  `SgrState.bg` (currently parsed-and-discarded). Trivial once a
  demand surfaces.

## Naming — RESOLVED: spark

The rename landed in session 20 (mechanical: module, exe, env
prefixes, cache/state paths — library-spec Phase 4 row 11), and the
repo went upstream as `Foundation42/spark` on 2026-08-29. The
candidates this section used to park (`glow`, `forge`, `litho`,
something matryoshka-branded) lost to the name the project had
already grown into. Journey docs keep `text_engine` where it was
true at the time of writing.
