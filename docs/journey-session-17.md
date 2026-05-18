# text_engine — session 17 journey
2026-05-18 (same day as 15 and 16; the layout chapter wanted another follow-up)

Session 16 closed Phase C — measure protocol, child caching, hierarchical
invalidation — and left a "Next" section listing four candidates for
whatever came after. Christian's pick this morning, towel in hand:
**text exclusion / shape-outside**, the original Phase E from way back
in the stage-15 plan, parked since session 12.

Three commits in:

```
1e8ea33 feat: five more inline components (::price, ::diff, ::issue, ::pr, ::ago)
815349d feat: four new inline components (::trend, ::rating, ::dot, ::commit)
acf8e7b feat: stage 15 Phase E text exclusion v1 (float=left|right)
```

Phase E v1 lands. The inline drawer grows from six components to fifteen.
The substrate paid for itself in nines.

What follows is the path.

## Phase E — text exclusion, v1

The thesis was simple and old: a `:::box` opted into "float" should
sit at the column's left or right edge, paragraphs around it wrapping
to fit. CSS `shape-outside` semantics for our markdown.

`docs/layout.md` had written down the architectural commitment over a
year ago: *coverage problem, not constraint problem; layered
consultation atop settled positions.* The Cassowary solver settles
box geometry; the float pass is a separate query the inline-flow
walker makes per line. The solver never has to know about floats.

### The four moving pieces

**E.1 — `LayoutContext.exclusions`.** A new `ExclusionRect` type
(`{x_min, y_min, x_max, y_max, side: .left|.right}`) and an
`ArrayListUnmanaged` of them on `LayoutContext`. Cleared on
`beginPass`; repopulated as the walk runs. Helper `lineBounds(y,
line_h, x_min, x_max)` returns `[line_left, line_right]` — for each
active exclusion overlapping `[y, y+line_h]`, push the line edge
inward by the rect's projection. `exclusionsHash()` folds the list
into a single u64 for cache-key participation.

**E.2 — the wrap loop consults exclusions.** `layoutInlineFlow`'s
greedy wrap got two changes. First, the line's emit origin moves
from `origin[0]` to `line_left`. Second, the wrap test moves from
`pen_x + width > max_x` to `pen_x + width > line_right`. After every
y advance (forced break or wrap), re-query `lineBounds` — the new
line might be inside or outside the float's y-range, so the
left/right shift varies per line. `query_line_h` uses the body
font's line_height as the per-line probe height; mixed-size content
can exceed this slightly, but the float rect spans the full floated
element so off-by-a-few-pixels in the probe doesn't move the
decision.

**E.3 — float as an attribute on `:::box`.** Christian picked
"attribute on box" over a wrapping `:::float` directive — terser,
matches the manifesto's `:::image {flow=around}` framing. New
attribute: `float=left|right|none` (default `none`). New
`FlowKind` enum (`.normal | .float_left | .float_right`) and
`ElementVTable.flow_kind: ?fn(ctx) FlowKind = null`. Box parses the
attribute, implements `flow_kind`, and — critically —
`on_layout_complete` registers the rect exclusion on every walk
(cache hit and miss alike), mirroring how `last_sizes` survives
cache hits from Phase C.4.

Floated boxes auto-default to 120×120 if dimensions aren't set
explicitly — a `100%`-wide float would devour the column and defeat
the purpose. `fromSpec` tracks an `explicit_width` /
`explicit_height` flag and backfills pixel defaults only when float
is on AND the author left them implicit.

**E.4 — stack_v gains a float branch.** Serial path: for each child,
poll `flow_kind`. If `.float_left` / `.float_right`, place the child
at the appropriate edge (right floats call `measure_block` to get
the width before placement) and **do not advance** `y` — the
in-flow cursor stays put, and following paragraphs continue at the
same y, wrapping around the float silhouette. Stack tracks a
separate `max_bottom_y` that includes float bottoms so the stack's
reported height covers float-only zones (otherwise a container
ending mid-float would visually clip).

The gap-before-child logic also got float-aware: gaps apply only
between two normal-flow children, not between a float and an
adjacent normal child (they share a y, so a gap between them would
be wrong).

Parallel `layoutStackVParallel` bails out to serial when any child
floats — the parallel walker's "every child gets origin (0,0)"
contract doesn't fit edge-positioning. Floats are rare enough that
forfeiting parallelism for sections that have one is the right
tradeoff for now; if it becomes hot, the parallel path can grow a
float-aware merge phase.

### The cache-invalidation puzzle

This was the bit that needed a moment. A paragraph at stack
position N+1 (after a float at N) caches its laid-out glyphs. The
cache key is `(elem_id, max_w, theme, zoom)`. **None of those see
the exclusion.** A float landing above the paragraph: the cache
still hits, and we replay the stale wrap.

Solution: `Key.pass_seed: u64`, new field, fold in
`lc.exclusionsHash()` at cache-lookup time. A float entering /
leaving rotates the seed → fresh key → miss → re-wrap. Stable
floats across frames produce identical seeds, so cached paragraphs
keep hitting once the document settles. The hash is cheap (one pass
over <10 rects in the common case).

Three call sites of `keyFor` to update: `layoutAndRenderCached`,
`classifyChild` (parallel path), and three test fixtures
constructing `Key` literals. All five tracked down at once.

### Visual landing

Two demo paragraphs, two floats — orange left, teal right. Text
wraps around each; lines hug the float until y escapes its bottom;
column reopens cleanly. Christian's verdict on the first run:

> Looks and works great! Very nice!

No second-pass needed. The architectural commitments held: the
solver didn't have to know, the existing measure_block protocol
gave right-floats their width, the existing on_layout_complete hook
gave us re-registration on cache hits, and the cache key gained one
field. ~437 lines of net code.

## Phase F — nine new inline components

Christian: "Oh, well we have plenty of time left this session I think.
Shall we knock out a few more inlines?"

Existing inline drawer at session-start: `badge`, `sparkline`, `kbd`,
`progress`, `status`, `tag`. Six components.

### Round one — `::trend`, `::rating`, `::dot`, `::commit`

**`::trend`** — delta indicator. Reads `value` like `+12.4%` or
`-2.1%`, classifies the sign (handling `-0`, `0%`, sign-less zero
edge cases), picks one of ▲ green / ▼ red / — neutral. The
`up_color` / `down_color` overrides let "up = bad" metrics flip
polarity ("latency down 23ms" should read green even though the
delta is negative).

**`::rating`** — star scale. `value=4.5 max=5` composes `★★★★½` in
a buffer at ingest time, tracks the byte offset where filled stars
end so the layout pass can colour-split the single shaped run.
Halves round to nearest; values out of range clamp. The half-glyph
(U+00BD `½`) tints with the empty colour to read as "this slot
isn't full."

**`::dot`** — thinner cousin of `::status`. 0.40em diameter (vs
status's 0.55em), label-less by design, baseline-aligned to the
x-height of surrounding prose. For sprinkling into sentences
("build • passing, • flaky, • blocked") where `::status` with a
label would dominate. The smaller-diameter / no-label split keeps
it semantically distinct from status — different jobs, different
visual weight.

**`::commit`** — git ref chip. Mono hash on a flat slate plate, no
border / no shadow (subtler than `::kbd`). Auto-truncates to the
conventional 7-char short hash. Optional `repo=foo/bar` composes as
`foo/bar@hash` in GitHub / Linear style.

### Round two — `::price`, `::diff`, `::issue`, `::pr`, `::ago`

**`::price`** — currency-formatted amount. Picks symbol + decimal
style + decimal count from the currency code: USD `$` two-decimal
dot, EUR `€` two-decimal comma, GBP `£` two-decimal dot, JPY `¥`
zero-decimal. Mono digits keep tabular columns aligned. Six tests
covering rounding edge cases (12.999 → 13.00; 12.1 → 12.10).

**`::diff`** — add / remove change summary. Renders `+437 −17` in
green / red, U+2212 mathematical minus for proper typography. Same
single-shape / two-colour-half trick `::rating` uses — one HarfBuzz
pass, the cluster boundary between "+N " and "−M" decides where the
colour switches. Both halves default to zero so authors can omit
whichever they don't need.

**`::issue` + `::pr`** — GitHub-style refs. One module
(`gh_ref.zig`), two registrations sharing one Component struct. The
`kind` field on the Component picks the palette in the render
pass: purple plate for issues, green plate for PRs, matching
GitHub's own conventions. Optional `repo=...` composes as
`repo#N`. The dual-registration / one-module pattern is the right
shape for variants that differ only in palette / strings.

**`::ago`** — relative timestamp. Static for v1 — author supplies
the duration ("3m" / "2h" / "5d"), the component appends " ago",
renders in italic via `theme.applyEmphasis`. Special-cases "just
now" / "now" so the suffix isn't repeated. A future version parses
an ISO timestamp and self-updates as the clock ticks (the
"live-document" promise gets to cash in here).

### What the substrate earned

Every component in this batch followed the same skeleton:

1. `Component` struct holding state + buffered render text
2. `ingest()` that re-builds the text from attrs on every update
3. `install(registry)` registering the factory
4. `vtable` with `layout_and_render`, `measure_inline`,
   `content_version`
5. `computeGeometry` shared between measure and render
6. Tests for ingest edge cases + vtable shape

~200 LOC each. Zero changes to the wrap loop. Zero changes to the
measure protocol. Zero changes to the cache layer. The Phase E.1
inline_object substrate from session 15 paid for itself a tenth
time today, and the eleventh / twelfth / thirteenth would be even
cheaper.

The two-colour-via-cluster-split trick (`::rating` and `::diff`)
also clicked into place naturally. The shape pass produces one run;
ShapedRun is a struct of `{glyphs: []Glyph, allocator: Allocator}`;
splitting it into two sub-runs that share the parent's allocator
costs nothing (the arena cleans up the original allocation, the
sub-runs aren't `deinit`'d). Two `appendShapedRun` calls, two
colours, one shape. The fanciest typographic move in the drawer
costs maybe ten lines of code.

## Where this leaves us

Phase E v1 closed. The inline drawer is fifteen components deep —
arguably as wide as it needs to be for now; further additions are
*more of the same shape* rather than new territory. The path that
opened in stage 15E.1 (six components ago) has been walked to its
natural width.

What's left in the roadmap's "Next":

- **Text exclusion polygons / per-line spans** (Phase E v2) — real
  shape-outside, not just rects. Polygon convexity tests on every
  line.
- **More inline components** — covered, mostly. Diminishing
  returns.
- **Compute-shader channel** — GPU compute for solver / animation.
- **Cache eviction policy** — the C.5 memory-doubling made this
  overdue.
- **Task #201 — corpus translation** — still pending from session
  13.

Christian's signal at session end: *"big one coming up next."*
Phase E v2 polygons or the compute-shader channel both feel like
"big" — either would be a meaty session. Cache eviction is more
plumbing than architecture; could land alongside or stand alone.

Three sessions in three weeks have closed Phase B (constraint
substrate), Phase C (measure + cache hierarchy), and Phase E
(coverage / shape-outside). The layout chapter, started a year ago,
has settled.

🌐🐢🐬🌸☕🚀
