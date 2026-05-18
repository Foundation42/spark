# text_engine — session 16 journey
2026-05-18 (same day as session 15; the layout chapter wanted a follow-up)

Session 15 closed with the inline substrate humming, six new components
flowing alongside prose, drag-to-suggest plumbing live. The roadmap's
"Next" section listed four candidates — measure-pass protocol,
hierarchical cache invalidation, text exclusion, more inline components
— and Christian, towel in hand, said *foundational work*.

Three commits later:

```
8d6e7a3 stage 15 Phase C.5  hierarchical cache invalidation
c266ec0 stage 15 Phase C.4  child caching for :::flex + :::grid
d26d67d stage 15 Phase C.3  measure-pass protocol + flex grow
```

Phase C is now closed. The constraint substrate has the *three* hooks
a real layout engine needs:

- **B (last session, last year)** — boxes declare bounds as solver
  variables, solver-resolved positions feed back into render.
- **C.3** — containers can ask children for their intrinsic size +
  grow weight before placement. Slack distribution becomes
  solver-mediated.
- **C.4 + C.5** — the cache framework knows when a descendant
  changed without each ancestor having to be told. Idle dashboards
  blit once; live charts re-walk only what they touch.

What follows is the path through.

## Phase C.3 — the measure pass

The thesis was simple: `:::flex` should ask children *how wide do you
want to be* before placing them. Today's flex chains children
left-to-right at their content widths, gap between them, and the row
shrinks to fit. To make a middle box stretch to fill a row — to make
`grow=1` mean anything — the parent needs a measurement of children
that's separate from their placement.

### What the engine already had

The inline-flow walker already had a `measure_inline` vtable slot
returning `IntrinsicMetrics { width, ascender, descender }` — added in
session 15 for `inline_object`. That was the prior art for "ask a
component how big it wants to be, without making it render anywhere."
Block-level needed its own slot.

### The cut

- **`BlockMetrics`** new struct (width + height + grow weight). Distinct
  from `IntrinsicMetrics` so inline-context measurement stays clean —
  `grow` is meaningful only at block level, only inside a flex.
- **`ElementVTable.measure_block`** new optional slot. Mirrors
  `measure_inline`'s shape but takes `Constraints` instead of `em_px`
  — block-context measurement reads `max_w`, not text size.
- **`element_layout.measureBlock(elem, constraints, ctx)`** the
  dispatcher. Switch over Element kinds, sensible defaults for
  built-ins (paragraph/heading/list claim `max_w`; container.stack_v
  recurses; spacer takes its height), `.custom` calls the vtable slot
  with a fallback path that runs `layout_and_render` into a throwaway
  DrawList.
- **`:::box` implements `measure_block`** — reports its attr-driven
  width and parses a new `grow=N` attribute.
- **`:::flex` runs the algorithm** for row-direction layouts with a
  finite parent width:
  - measure each child → metrics + grow
  - `slack = max_w − Σ(intrinsic for grow=0 children) − Σ(gaps)`
  - children with `grow > 0` claim `(weight / Σweights) * slack`
  - final width per child flows through as `constraints.max_w` in the
    placement walk

A small design decision worth flagging: the slack-distribution
mechanism does NOT use the suggestion channel. Suggestions are for
drag handlers — external mutations to the layout from outside the
walk. Flex distribution is internal to the walk, computed each frame.
Passing the resolved width as `constraints.max_w` lets boxes at the
default `width=100%` naturally claim the slot; boxes with explicit
`width=80px` keep their declared size regardless. The grid had
already pioneered this pattern with its `1fr` tracks — flex grow is
the per-child version of the same math.

### Demo

Two new flex rows in `demo.md`:

```
:::flex #grow_row direction=row gap=8
  :::box {color=orange width=80 height=48 radius=6}
  :::box {color=cyan grow=1 height=48 radius=6}
  :::box {color=orange width=80 height=48 radius=6}
:::

:::flex #grow_proportional direction=row gap=8
  :::box {color=purple grow=1 height=40 radius=6}
  :::box {color=green grow=2 height=40 radius=6}
  :::box {color=purple grow=1 height=40 radius=6}
:::
```

First row: fixed–grow–fixed. Resize the window, the middle box
stretches. Second row: 1:2:1 split, the middle panel claims half the
row's slack, side panels split the rest.

## Phase C.4 — child caching

Phase C.3 done, flex working, but `:::flex` and `:::grid` still had
`disable_cache=true` on them from session 15D. The reason was real:
flex caches its full output (children's quads, glyphs, hits) into one
block-cache entry keyed on flex's content_version. When a child opts
into the suggestion channel and a drag bumps the child's version, the
flex's entry doesn't know — the cache hits, the stale baked-in child
output replays.

The fix in session 15 was a sledgehammer: disable caching on flex/grid
entirely, re-walk every frame. Correct but wasteful. Session 16's
Phase C.4 picks up the rebuild.

### The first instinct that didn't work

The obvious move was *switch flex/grid children from `layoutAndRender`
to `layoutAndRenderCached`*. One-line change in each. Then each child
caches individually, the suggestion-driven invalidation chain works
per-child, flex itself stays disable_cache=true to dodge the original
problem.

Walking through the consequences uncovered two related traps that
neither file flagged:

**Trap 1 — handle reads from `bounds_map`, but the box is no longer
in it.** `handle.startDrag` reads the target box's current size from
`lc.bounds_map.get(target_key)` to seed the drag. That map is
populated by box's `layoutViaConstraints` — which runs only on cache
miss. After the first frame, box cache-hits; `bounds_map` is empty
for it; handle reads 0; the drag jumps.

**Trap 2 — bumpers are per-pass, but cache-hit components don't
re-register.** `setSuggestion` fires the registered bumper to bump
the target's version. The bumper is registered in
`box.layoutViaConstraints`. Cache hit → no registration this frame →
`setSuggestion` finds no bumper → version doesn't bump → cache stays
hit forever. A static drag.

Both traps stem from the same shape: data the cache-hit path used to
get for free (because layout always ran) becomes invisible the moment
caching enters the picture.

### The fix

Three coordinated pieces:

1. **`ElementVTable.on_layout_complete`** new optional slot —
   `fn(ctx, box, lc) void`. Called by the cache framework on every
   walk, hit or miss. Cache-aware path: fires from
   `layoutAndRenderCached` after `blitEntry` on hit; from
   `layoutAndRender`'s `.custom` branch on miss. Components participate
   by implementing it; built-in element kinds get a no-op.

2. **`LayoutContext.last_sizes`** persistent map (across `beginPass`)
   keyed by `@intFromPtr(ctx)`, holding the box's resolved `(w, h)`
   after every walk. Box's `on_layout_complete` writes here; handle
   reads from here as the third fallback in its size-lookup chain
   (`suggestion → bounds_map → last_sizes → 0`). Drag works on first
   mouse_down regardless of cache state.

3. **Bumpers persist across `beginPass`.** They're a *static* fact
   about the component (function pointer + ctx), not per-frame state.
   The old per-pass clearing existed to defend against deinit'd
   components leaving stale entries; the defence moves to explicit
   `unregisterBumper(key)` in component deinit. `:::box` gains an
   `install(registry, layout_context)` entry point so it can stash the
   context for use in `deinit_`.

After all three: switch flex/grid children to
`layoutAndRenderCached`. The flex/grid containers themselves still
keep `disable_cache=true` — partial-change invalidation works per-
child, but parent-level idle blitting is left to the next phase.

### What this earned

The common case (idle dashboard) used to do, per frame, per flex:
construct child slice, alloc measure scratch, measure each child,
dispatch each child via cached lookup, blit. After Phase C.4: the
constraint-solver round-trip + quad emit per box go away on cache
hits. The flex itself still re-walks, but the per-child work is now
a single hashmap lookup + a blit.

## Phase C.5 — hierarchical aggregation

The Phase C.4 commit comment explicitly punted parent-level caching
to a "follow-on … the current cost of one re-walk per frame for the
flex's own measure + dispatch is small." Christian, with three words
("Sure thing cache!"), and the architecture asking to be closed out,
said do the follow-on now.

### The shape

A container's effective `content_version` is its *own* version XOR'd
with each child's contribution. A child's contribution is
`versionFor(child) XOR elementIdentity(child)`. The identity mix is
critical:

> *Without identity-mixing, two siblings with version=5 would
> contribute `5 XOR 5 = 0`. Their changes cancel. A bump of either to
> 6 contributes `6 XOR 6 = 0`. The aggregate hides the change. The
> cache stays hit on a real mutation. Pointer-keying each term
> dodges this.*

Recursion is implicit: each container aggregates its *immediate*
children, and a container that is itself a child already has its
descendants encapsulated in its own `content_version`. A box inside a
grid inside a flex rolls all the way up — box's bump changes grid's
aggregated version; grid's change changes flex's aggregated version;
flex's cache invalidates.

### The cut

- **`layout_cache.aggregateChildVersions(children)`** new helper that
  XOR-folds `(versionFor(child) ^ elementIdentity(child))` across a
  slice.
- **`flex.contentVersion`** XOR's self.version with the aggregation
  over `c.root.container.children`.
- **`grid.contentVersion`** the same, over its cells.
- **`disable_cache=true`** comes off flex *and* grid. Container caches
  as a whole; children also cache via `layoutAndRenderCached`. Idle
  frames: one parent blit. Single-change frames: aggregated version
  flips → parent cache miss → re-walk children → unchanged children
  hit their per-block caches → only the mutated child re-walks fresh
  → parent re-snapshots.

### Side note on memory

The combined approach (parent-cached AND children-cached) stores
both the container's full output and each child's output. ~2x cache
memory for those elements. For the typical small dashboard, this
isn't material. A real eviction policy (LRU, TTL) is overdue
generally — orphaned entries from re-parses already accumulate
slowly — but it can land separately.

## What the closing chapter looked like

The session's drama was small. No frozen-origin saga, no "I AM
MOVING IT SLOWLY!!!" Each piece compiled cleanly, each piece tested
green, each piece passed visual verification on the first run. The
two traps in Phase C.4 (handle's `bounds_map` lookup, bumper
per-pass clearing) were caught by reading the code carefully *before*
flipping the switch — the prep work paid off.

Three commits, all green, all live. Phase C is closed; the measure
protocol, the cache hierarchy, and the suggestion channel all stand
on independent legs but slot into one another cleanly. The flex grow
demo works because the measure pass works. The drag works through a
cache hit because `last_sizes` exists. The whole flex caches because
aggregation propagates child bumps without anyone having to be told.

## What's next

Phase C is done. The remaining roadmap (from session 15's closer)
still has:

- **Text exclusion / shape-outside** — the original Phase E, the
  partner to text intrusion (15E). Floats that text flows around.
- **More inline components** — the substrate makes them cheap.
- **Compute-shader channel** — GPU compute for solver/animation.
- **Task #201 — corpus translation** — still pending from session 13.

The natural next sitting is text exclusion: visually satisfying,
completes the intrusion/exclusion pair, will give the inline-flow
walker its second real algorithmic concern (the first being the
inline tokens themselves).

But Phase C closing is its own kind of completion. The layout
constraint substrate is real now. The cache substrate is real. The
inline component substrate is real. The session 14 manifesto pitched
the document-as-program; sessions 15 and 16 made it *fast* enough to
ship.

🌐🐢🐬🌸☕🚀
