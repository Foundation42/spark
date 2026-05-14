# text_engine — roadmap

The destination crystallised end-of-session-3 into a **live-
document runtime**: markdown source as the declarative interface,
native Vulkan components instantiated via `:::name {attrs}` block
extensions, reactive frontmatter state, targeted LLM-streamed
micro-updates. Full pitch + architectural mapping +
design-decision rationale lives in [`vision.md`](vision.md).

This roadmap is the staging path from where we are (markdown
rendering + chrome + ANSI + resize) to where we're going (live
documents). Session 4 starts on stage 7a.

## Next — block extension parser (stage 7a)

`markdown.zig` recognises `:::name {attrs}\nbody\n:::` syntax and
emits a `custom` Element with vtable + ctx pointer.

- cmark doesn't support `:::` blocks natively. Three approaches
  considered (vision doc has the full list); leaning toward
  walking cmark's paragraph output to detect leading `:::` lines.
  Keeps the vendored cmark untouched.
- Attribute parser handles `{#id key=val key="quoted val"}`.
- Components without a registered factory render a fallback
  "missing component: name" box — clear failure mode for authors
  / LLMs that pick the wrong directive name.

## Then — component registry + cache (stage 7b)

Host registers `name → ComponentFactory`. Cache keyed by `#id`
(or auto-generated stable position-based ID) persists instances
across re-layouts. `custom.ctx` carries the cached instance.

- Components without `#id` get an auto-generated stable ID from
  position in the tree (parent's ID + sibling index). Stable
  across trivial edits; not stable across structural reorders —
  right trade-off for stage 7b.
- Lifecycle: instantiated on first appearance, destroyed after N
  consecutive layouts without appearing. Avoids thrashing on edits.

## Then — first concrete component (stage 7c)

`:::box {color, width, height}` as the minimal loop validator.
Renders a coloured quad. Proves: parse → registry → cached
instance → layout returns Box → quad emit, end-to-end.

Or jump straight to `:::chart` if visual impact wins over minimal
scope — same loop, more LOC. Lean toward `:::box` first.

## Then — frontmatter state + bindings (stage 7d → 7e)

YAML frontmatter (a small hand-rolled subset — `key: value` pairs
under a `state:` block — until we need lists / nested maps).
`${state.x}` interpolation in attribute values, resolved at
component construction (7d), then reactive: state mutations
notify subscribers, bindings re-evaluate, component setters fire
(7e).

## Then — input handling (stage 7f)

Walker grows a parallel `hitTest(point, root) → ?Element` pass.
Per-component `onInput` vtable callback. The slider → state
mutation → chart title refresh loop closes here.

## Then — `:::update` micro-stream path (stage 8)

The LLM-streamed-delta-into-live-component hot path. Markdown
recognises `:::update {#id action=...}` and routes the body to
the target component's handler directly — bypasses cmark, bypasses
text layout, microsecond hot path.

## Then — real components (stages 9+)

3D scene (eventually integrates with matryoshka), live chart,
slider, input field, button. Each is a self-contained component
module; the contract is fixed by stage 7. Repetitive work, not
architectural.

## Parallel / orthogonal — retained layout cache

The walker currently re-runs on every resize. Caching the laid-out
glyphs + quads between frames and only re-laying-out when the
content tree or viewport changed recovers the ~6% perf loss from
stage 6a. More important when documents grow into the multi-page
range. Not blocking the vision work above; lands when content
demand justifies it.

## Parallel — markdown ↔ ANSI composability (stage 5b)

Originally planned as stage-5-followup but bumped by the vision
work. ` ```ansi ``` ` fenced code blocks in markdown route
through `ansi.parse`, output stuffed into `CodeContent.sub_block`;
`layoutCodeBlock` recurses into it. Closes the markdown-↔-ANSI
loop. Small commit (~50 LOC). Lands when convenient.

## Parallel — scrolling

The other half of session-3's resize concern. Mouse-wheel /
keyboard scrolls a viewport offset; renderer applies it before
NDC mapping (cleanest) or walker subtracts it from glyph y at
emit (cheaper). Independent of vision work; lands when documents
get tall enough that resize-reflow alone stops being enough.

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
