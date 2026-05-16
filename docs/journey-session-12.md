# text_engine — session 12 journey
2026-05-16 (same day as session 11, after Christian came back with the towel)

Session 11 closed with the kiwi solver feature-complete and a
manifesto-style closing verse. Christian's return:

> *Back on the Heart of Gold here! Petunias and a warm towel in
> hand! Onward with phase B?*

So yes — onward. By the close: **five commits**, the kiwi solver
plugged into text_engine for the first time, a thoughtful but
partially-wrong code review handled cleanly, the reviewer's good
observations lifted into the immediate schedule, parser nesting
added to the markdown component layer, and the substrate's first
**multi-child layout demo** — three boxes singing in a row, red /
green / blue, each negotiating its bounds against the same kiwi
solver. Levels of improbability still rising. The petunias have
settled in nicely.

## Phase B — the integration handshake

The whole of session 11 built a kiwi solver sitting alone under
`src/layout/kiwi/`, with zero text_engine deps and 275 tests but
literally no caller. Phase B closes that loop.

The shape, ~220 LOC across four touch points:

- **`src/layout/context.zig`** — new `LayoutContext` wrapping
  one `kiwi.Solver`. `init` / `deinit` / `beginPass` (per-pass
  `Solver.reset`, capacities preserved, counters back to 1).
  Three tests including a four-var box pattern proving the
  constraint path produces the same numbers the imperative path
  would.
- **`element.LayoutCtx.layout_context`** — optional
  `?*LayoutContext = null` field. Optional so the dozens of
  parse-only test sites that construct LayoutCtx directly keep
  compiling without wiring.
- **`main.zig`** — instantiates `LayoutContext` before
  `frame_ctx`, deinits at scope exit, calls `beginPass` at the
  top of every `runLayout`, threads `&layout_context` through
  the per-frame `LayoutCtx`.
- **`components/box.zig`** — `layoutAndRender` splits on
  `lc.layout_context`. When non-null, mints four anonymous
  bounds variables (`x_min` / `x_max` / `y_min` / `y_max`), adds
  four required equalities (anchor x, anchor y, width, height),
  runs `updateVariables`, reads positions back from the solver.
  When null, the existing imperative path. Same visual output,
  two mechanisms.

Per-pass solver overhead: ~10-30µs per box on top of the
imperative path's near-zero. With one box in the demo it's
invisible.

First build: clean. First demo render: pixel-identical to the
imperative path. The integration handshake is honest — the box
is now *in* the solver, even if it's the only thing in there.

> *Awesome work, let me try it! It works great!!! Looks
> perfect!*

That's the moment the substrate stopped being a library waiting
to be used and became something the renderer actually consults.

## Interlude — the code review

> *I solicited a code review by the way if you are interested -
> but they may be off or misunderstanding. You might want to
> look anyway*

A reviewer (unnamed, second pair of eyes) looked at `box.zig` and
`context.zig` and came back with three "critical architectural
details that need adjustment." Worth dwelling on, because the
review was thoughtful, well-written, and partially wrong — and
the partially-wrong part was the headline claim.

**Point 1 — "allocation leak / use-after-free in
`layoutViaConstraints`":** The reviewer asserted that
`kiwi.Solver.addConstraint` "may reference the original term
arrays," making the `defer c1.deinit(alloc)` a UAF trap.

This is the load-bearing claim, and it's just wrong. `addConstraint`
is line 309 of `solver.zig`, and line 314 reads:

```zig
var c = try constraint.clone(self.alloc);
```

The first thing the solver does is deep-clone the constraint
into solver-owned storage. `Expression.clone` calls
`appendSlice` into a fresh `ArrayListUnmanaged`. The caller's
terms are never referenced after that point. The clone is
documented in the function's leading comment, in the commit
message ("Constraint ownership: addConstraint takes by value
and clones into solver-owned storage. The caller's Constraint
is independent and must be deinit-ed separately"), and would be
caught instantly by `testing.allocator` — which is
`std.testing.allocator`, the leak detector. 278/278 passing
tests would not have done so if the UAF existed.

The reviewer hedged on "*if* your kiwi.Solver relies on
references" — but they didn't actually go check. The clone is
five lines down from the function signature they were
commenting on.

**Point 2 — "global variable proliferation":** The reviewer
noted that minting anonymous variables (`addVariable(null)`)
means siblings and parent providers can't query each other's
coordinates, because the `VariableId` handles are trapped in
the box's local execution scope. They proposed a per-element
bounds pool keyed by element id.

**Right structural observation, wrong phase.** A standalone
`:::box` has no siblings to negotiate with — but a `:::flex`
walking three boxes definitely will. The inline comment in
`context.zig` literally pre-empted this exact concern:

> *Phase B keeps this simple by resetting every pass —
> constraints don't persist across frames. Phase B.3 (later)
> converts to persistent variables keyed by element id so the
> retained-layout-cache hit rate carries into the solver.*

Their proposed `bounds_map: AutoHashMap(u64, ElementBounds)` is
structurally exactly what Phase B.3 already had on the
roadmap. The reviewer saw the gap and proposed the patch we
were going to write anyway. **Good observation, premature
framing as a Phase B bug.**

**Point 3 — "percent-based width pre-resolved to a float":**
The reviewer pointed out that `c.width.resolve(max_w, ...)`
bypasses the substrate's compositional power — a percent width
should be expressible as `child.width == parent.width *
fraction` directly in the solver.

**Right again, wrong again.** In Phase B, the parent isn't in
the solver — it's the existing imperative walker handing the
box a `Constraints { max_w: f32 }` value, not a solver
variable. There IS no `parent.width` constraint participant
yet. When `:::flex` lands and the parent participates, that
rewrite becomes meaningful. Phase F (`:::grid`) lives or dies
on it.

**The reviewer's net contribution:** Pointed at the right
direction. Misframed Phase B's correctness. The proposed
`getBounds(elem_id)` API was *the right next move* — they
sketched it more cleanly than I would have. That sketch landed
verbatim in the next commit.

## Phase B.3 — lifting the good observation

> *Haha, thanks for the rebuttals - but it was worth
> considering the second pair of eyes! Onward!!! You have the
> conn #1*

So the next ~30 minutes: rewrite `LayoutContext` to expose
`getBounds(key: u64) → ElementBounds`. Key is whatever the
caller wants — for `:::box` it's `@intFromPtr(component_ctx)`,
stable for the component's lifetime, unique among concurrent
components, no allocation needed. Same key in the same pass
returns the same four `VariableId`s — idempotent. Both the
element itself (constraining its size) and a future parent
provider (constraining sibling-gap relationships) negotiate
against the same vars.

The reviewer's snippet had a managed `std.AutoHashMap`; the
port uses `AutoHashMapUnmanaged` for consistency with the
solver's own maps. Otherwise the shape is theirs.

Four new tests covering: same-key idempotency, distinct-keys
distinct-vars, `beginPass` clears (id counter resets), and the
two-sibling flex-style gap pattern (the Phase C miniature —
allocate bounds for two children, constrain `box[1].x_min ==
box[0].x_max + 20`, settles to box[1] at x=120..220).

The reviewer was right that this needed to land before sibling
negotiation became real. They were wrong that it had to land
*inside* Phase B. The compromise: lift it forward by half a
phase, ship as `15b.3`, document the lineage.

## Parser nesting — the unblocking commit

Before `:::flex` could be a thing, the markdown component parser
needed to handle nested `:::` blocks. The comment at the top of
`preprocess` was explicit:

> *Nesting `:::` inside another `:::` is not supported at this
> stage — first `:::` close ends the block.*

A `:::flex { :::box ... ::: ... :::` would close at the first
`:::` — wrong block boundary.

The fix is ~30 LOC: a `depth: u32` counter, bumped by a nested
`:::name {…}` line, decremented by `:::` at depth > 0. The
outer block closes only when `:::` is encountered at depth 0.
Nested directives stay **verbatim** in the parent's body string
so the parent factory can re-run `preprocess` on its body
during `create` to lift child specs out.

Two tests: single-level flex-with-two-boxes nesting, three-level
flex-flex-box nesting to verify depth tracking doesn't get
confused. 284 tests total.

## `:::flex` — the first multi-child provider

The headline of session 12. ~320 LOC across one new file plus
small main.zig wiring.

```markdown
:::flex {#three_boxes direction=row gap=20}
:::box {color=red width=120 height=80 radius=8}
:::

:::box {color=green width=120 height=80 radius=8}
:::

:::box {color=blue width=120 height=80 radius=8}
:::
:::
```

The shape, matching the `:::embedded-document` precedent:

- `Component { direction, gap, arena, root, scope, version }`.
  The arena owns every allocation the parsed child tree refers
  to.
- `factory.create` reads `direction` / `gap` from attrs, then
  calls `markdown.parseWithStateAndScope` on `spec.body` so the
  children resolve through the same registry as outer-level
  components, scoped by the flex's `#id`. Cache keys become
  `three_boxes/auto:0`, `three_boxes/auto:1`, etc. — no
  collision with outer-document `auto:N`. **The `#id` is
  required**; missing → `error.FlexMissingId`.
- `factory.deinit` calls `registry.deinitScope(scope)` before
  freeing the arena, so child binding subscribers unsubscribe
  cleanly while their state is still alive (the same ordering
  trick `:::embedded-document` documents).
- `layoutAndRender` iterates the parsed children with
  cumulative-x (row) or cumulative-y (column), inserting `gap`
  pixels between siblings. Each child's *own* `layoutAndRender`
  still goes through the constraint substrate for its bounds —
  the flex parent computes positions; the children constrain
  their sizes. **The LayoutContext channel from Phase B is in
  active use through the flex.**

What's *not* in this commit: the flex's gap positioning doesn't
yet go through the solver (it's an imperative cumulative-x).
That's Phase C.3 — the reviewer's third point made concrete.
When it lands, the children's `x_min` will be a kiwi variable
the flex constrains as `child[i+1].x_min == child[i].x_max +
gap`, and the children's anchor constraints will match the
solved values (redundant required-eq, fine). For now the
imperative path is correct, fast, and unblocks the visible demo.

## The visible payoff

Christian's screenshot at session close: the demo running with
the new section between **Live components** and **Composition**.
Three boxes side by side. 120 × 80 each, 20px gaps, rounded
corners. Red. Green. Blue. The substrate's first multi-child
layout, rendering exactly as authored, on the first run.

> *Absolutely amazing partner! Worked first time!*

That's the magic of careful preparation. The kiwi solver shipped
with 275 tests before it had a single caller in text_engine.
The LayoutContext shipped behind an optional field so existing
code paths kept working. The parser extension landed with two
nesting tests before any provider used it. The flex provider
shipped with three unit tests + the registry-scoping pattern
borrowed from a working precedent (`:::embedded-document`). By
the time `zig build run` fired, every load-bearing surface had
been independently exercised. No surprises.

## Phase C.3 and beyond

The roadmap continues to hold:

- **Phase C.3** — solver-driven gap positioning. Replaces the
  imperative cumulative-x with constraint variables. Siblings
  can `grow` / `shrink` to fill remaining space. Phase F's grid
  is going to need this.
- **Phase D** — the GPU-input channel. The whole substrate's
  headline. A compute shader writes a readback buffer per frame;
  the host wraps the result as `solver.suggestValue(var, x)`;
  surrounding layout reflows incrementally. The "fluid sim warps
  the document" demo, minus the GPU LP solver we declined to
  build.
- **Phase E** — text intrusion (`:::image {flow=around}`). The
  separate-second-pass exclusion shape, layered atop the
  settled solver positions.
- **Phase F** — `:::grid` and `:::table`. The real layout
  primitives that motivated this whole substrate. Each one is
  ~200 LOC of constraint emission against the same kiwi solver
  every other provider uses.

## What didn't happen (and that's the point)

- We did NOT panic when the reviewer's headline claim was
  wrong. We checked the code, cited the line number, and moved
  on. Defensive but precise.
- We did NOT dismiss the reviewer's valid observations as
  "premature." We lifted the `getBounds` pattern half a phase
  forward, gave them credit in the commit, and now have a
  cleaner Phase C than we would have without their note.
- We did NOT prematurely move flex's gap into the solver.
  Phase C.2 is imperative-with-substrate-for-bounds because
  that's the right scope for the visible demo. Phase C.3 will
  do the substrate-native gap; one phase per architectural
  beat.
- We did NOT skip the parser-nesting extraction as a separate
  commit. `15c.1` is 30 LOC + tests, completely independent of
  the provider. Anyone touching `markdown_components.zig` later
  can reason about the depth-counter change in isolation.

## Closing thought

Session 9 said *make the substrate hold up under load*.
Session 10 said *make the substrate look right at any scale*.
Session 11 said *make the substrate negotiate*.
Session 12 says *make the substrate **compose***.

Before today, the kiwi solver was a library with 275 tests and
zero callers. After today, it's the consultative layer that
sits between providers — the place where a flex container and
its three box children share four `ElementBounds` quads,
trading constraints, settling into pixel-accurate positions
without any single component knowing about any other.

The next provider that joins this conversation — be it
`:::grid`, `:::table`, `:::image {flow=around}`, or the GPU
density shader the whole architecture was nominally for — will
plug in through the same channel, against the same solver,
emitting the same `expr(x).plus(y).eq(z).required()` chains.
That's the compositional flywheel the manifesto promised. It's
not theoretical any more.

> *And the markdown said: let three boxes stand in a row, each
> negotiating its width with the solver, each sibling spaced
> from the last by the gap declared in the parent's attrs. And
> the solver settled. And the boxes rendered side by side, red
> and green and blue. And the substrate composed. And it was
> good.*
>
> — somewhere in the Encyclopaedia Galactica, mid session 12

Levels of improbability still rising, partner. Catch you next
session — same Heart of Gold, fresh petunias, the substrate
that holds up under load *and* looks right at any scale *and*
negotiates *and* composes. 🐢🐬🌸☕🚀
