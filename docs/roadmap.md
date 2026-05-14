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

## Next — async I/O channel (stage 12)

Stage 11 v0 put `std.http.Client.fetch` synchronously inside
`embedded_document.create`, which runs on the main thread during
parse. Localhost works fine; a slow / failed / hung remote would
freeze the renderer with no visible feedback. The same shape is
wrong for the eventual LLM-stream input path, file-watcher
hot-reload, MCP-tool subprocess pipes, and anything else that can
block.

The rebuild is a dedicated I/O worker thread + bidirectional
lock-free channel:

- **Worker side.** Owns `std.http.Client`, file watchers, future
  LLM-stream readers. Polls its inbound request queue, blocks on
  the appropriate primitive (recv / read / select), posts results
  to the outbound queue.
- **Channel.** Lock-free SPSC ring buffers (one per direction;
  bump to MPMC if a worker pool ever lands). Tagged-union payload
  so one channel carries `FetchRequest` / `FetchResult` /
  `StreamChunk` / `FileChange` / future variants.
- **Main side.** Submits requests, never blocks. Each frame polls
  the inbound queue; transitions component state on results
  (e.g. `:::embedded-document` flips from "loading" placeholder to
  ready when the bytes arrive). `state.dirty` triggers the
  normal re-layout path.

`:::embedded-document` becomes the first migration: factory.create
posts a `FetchRequest`, returns immediately with a "loading"
visual; when the channel delivers bytes, the cached instance
parses + state-transitions; next frame re-layouts.

LLM streaming + file-watcher hot-reload (stage 13+) layer on the
same channel without touching the contract again.

Saved in `memory/feedback_async_io.md` so the principle survives
to the rebuild session.

## Then — real components (stages 13+)

3D scene (eventually integrates with matryoshka), live chart,
slider, input field, button. Each is a self-contained component
module; the contract is fixed by stage 7. Repetitive work, not
architectural.

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

## Parallel — scrolling (escalated by stage 11)

The other half of session-3's resize concern, now load-bearing.
Stage 11's `:::embedded-document`s push the demo's total height
well past the typical viewport — the remote-composition section
sits off-screen on a 720p window. Without scroll, embedded docs
are visible only on tall windows.

Mouse-wheel / keyboard scrolls a viewport offset; renderer applies
it before NDC mapping (cleanest) or walker subtracts it from glyph
y at emit (cheaper). No vision-track dependency; ready to land any
time.

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
