# layout — constraint substrate

> **Layout is not a tree walk; it is a system of relationships.**
> Providers declare what should be true. The solver settles. The
> walker reads the result. Components compose without knowing about
> each other.

This document captures the architectural decision to base
text_engine's layout on an incremental linear-constraint solver
(Cassowary, via a pure-Zig port of kiwi). Drafted late session 10
/ early session 11 (2026-05-16) as the substrate-tier follow-up
to crisp zoom. Load-bearing for every layout-shaped surface after
this: providers, tables, grids, flow-around-image, GPU-driven
geometry.

---

## The position

The current layout pass is a hierarchical tree walk. Each block
handler in `element_layout.zig` hand-rolls its cursor math: `x`
advances by `child.width`, `y` advances by `child.height`,
gutters and gaps are inline literals. The `:::box` chrome trick
(handle the chrome quad, shrink constraints for the body) is
bespoke per component.

This works at the project's current complexity. It does not
scale to:

- **Tables** — column widths depend on the widest cell across
  rows; the walker would need a two-pass measure-then-layout,
  hand-coded per table.
- **Grids** — row heights depend on the tallest cell; track
  widths depend on `fr` units; spanning cells couple rows and
  columns.
- **Flex** — `grow` and `shrink` redistribute free space across
  siblings; a one-pass walker can't see siblings' demands without
  another measure pass.
- **Text intrusion** — laying text around an image requires the
  text engine to know about the image's bounds before line
  breaking.
- **GPU-driven geometry** — a fluid sim emits a "preferred
  position with this strength"; surrounding components need to
  settle around it without being rewritten each frame.

All of these have the same shape: *I want to declare a
relationship, not compute a position*. That is what a constraint
solver gives us.

Two pillars:

1. **Compositional.** Providers (`:::flex`, `:::grid`, `:::table`,
   `:::stack`, `:::dock`, `:::masonry`) emit equations into a
   shared solver. They don't know about each other. They don't
   know about text. They don't know about images. They negotiate
   via the solver.
2. **Reactive.** A constraint can be edited per frame —
   `solver.suggestValue(var, x)`. GPU readbacks, slider drags,
   LLM stream growth, all funnel into the same input channel and
   the layout reflows incrementally.

The solver runs on the **CPU**. The GPU drives constraint
*inputs*, not the solver itself. See "the bidirectional GPU
channel" below for the full rationale.

---

## The model

A **variable** is a named continuous real. Each element gets
four: `x_min`, `x_max`, `y_min`, `y_max`. Some elements also get
content-derived measures (`intrinsic_width`, `baseline_y`).

An **expression** is a linear combination:

```
a₁·v₁ + a₂·v₂ + ... + aₙ·vₙ + c
```

A **constraint** is `expression OP 0` where `OP ∈ {==, ≤, ≥}`,
plus a **strength**.

Strengths form a four-tier scheme inherited from Cassowary,
packed via `create(a, b, c, w=1.0) = clamp(a*w,0,1000)*1e6 +
clamp(b*w,0,1000)*1e3 + clamp(c*w,0,1000)`:

| tier     | coefficient        | meaning                              |
|----------|--------------------|--------------------------------------|
| required | 1.001001e9         | inviolable; infeasibility is an error|
| strong   | 1e6                | structural; provider invariants      |
| medium   | 1e3                | author preferences (`width=300`)     |
| weak     | 1                  | content-derived hints                |

The exact `required` value is `1_001_001_000.0` —
`create(1000, 1000, 1000)`. **Do not** approximate it as `1e9` in
the port: `BadRequiredStrength` is checked by exact-equality
post-clip, so a near-required strength that drifts even slightly
below would be accepted as an edit-variable strength when it
shouldn't be.

Soft constraints (anything below required) may be violated to
make the system feasible; the solver minimises a weighted sum of
violations. That weighting is what makes "prefer this width but
allow shrinking under pressure" work without imperative code.

### Sketch API

```zig
const layout = @import("layout");

var solver = try layout.Solver.init(alloc);
defer solver.deinit();

const x_min = try solver.addVariable("box.x_min");
const x_max = try solver.addVariable("box.x_max");
const width = try solver.addVariable("box.width");

// width = x_max - x_min  (required)
_ = try solver.addConstraint(
    layout.expr(width).eq(layout.expr(x_max).minus(x_min)).required(),
);

// width prefers 300 (medium)
_ = try solver.addConstraint(
    layout.expr(width).eq(300).medium(),
);

// width is at least 100 (required)
_ = try solver.addConstraint(
    layout.expr(width).geq(100).required(),
);

solver.updateVariables();

const w = solver.value(width);  // 300, unless something fights it
```

This is the same library shape kiwi (C++), casuarius (Rust),
kiwi.js, and friends all ship. The expression-builder DSL keeps
callsites readable; the solver internals don't care how the
expression got built. Builder methods: `.plus` / `.minus` /
`.times` / `.divide` / `.negate` for expressions; `.eq` / `.leq`
/ `.geq` to terminate into a partial constraint; `.required` /
`.strong` / `.medium` / `.weak` / `.atStrength(s)` for the final
strength tier.

### Beyond the basics

Three Solver methods earn their keep in the text_engine flow:

- **`removeVariable(VariableId)`** — explicit variable cleanup.
  Neither Rust port has this; both reap via internal refcount.
  Our re-parse / cache-invalidate flow wants explicit control so
  the variable pool stays stable across re-parses keyed by
  `Element.id`.
- **`beginEdit()` / `commitEdit()`** — batched constraint edits.
  Adopted from casuarius. A provider emitting many constraints
  at once (table layout, grid set-up) defers the optimise pass
  to `commitEdit`; without this, every `addConstraint` triggers
  a full pass.
- **`fetchChanges() → []const Change`** — borrowed-slice of
  variables whose value changed since last fetch. Lets the
  walker re-emit quads only for the elements that actually
  moved, instead of polling every variable each frame.

---

## Kiwi

Kiwi is Chris Colbert's 2013 rewrite of the Cassowary algorithm.
BSD-3, ~3000 LOC of well-documented C++. Used by Enaml (Python),
multiple JS ports, several Rust ports. The de-facto modern
Cassowary.

Three properties make it the right pick:

1. **Incremental dual-simplex.** `addConstraint`,
   `removeConstraint`, `suggestValue` don't restart from scratch.
   Each is amortised O(log n) with respect to constraint count.
2. **Multi-strength.** Native support for required + three soft
   tiers, composable into arbitrary positive weights when needed.
3. **Edit variables.** Dedicated path for per-frame reactive
   inputs. `suggestValue` is the fast loop; the solver re-settles
   without re-pivoting most of the tableau.

### Algorithm sketch

Every constraint is rewritten into the form `expression = 0` by
introducing slack and error variables. Soft constraints contribute
error terms that the objective function minimises. The simplex
tableau holds basic vs non-basic variables; pivots swap them.
Edit variables enter the tableau marked, so suggesting a new
value reuses the existing pivots.

This is dense linear algebra at the level of a thousand-line
solver core. The right move is to port it once, test it hard,
and rely on it — not to reinvent it.

### Port plan

Pure-Zig port. Lives under `src/layout/kiwi/`, organised as a
self-contained module with zero text_engine deps so the boundary
stays clean (and so the solver can be lifted out and reused later
if it ever needs to be). Reasons:

- Project has **zero C++ deps** today (cmark, stb are C). Keep it.
- Allocator-aware (per-frame arena for ephemeral constraint sets,
  long-lived heap for persistent variables).
- Easier to debug; cleaner integration with our error sets.

Reference ports cross-checked during recon:

- **kiwi C++ v1.4.2** (commit `613c5bce`) — the canonical
  algorithm. Authoritative for simplex behavior, constants,
  invariants.
- **cassowary-rs v0.3.0** (commit `90d1df49`) — closer-to-kiwi
  shape. `Variable(usize)` from atomic counter,
  `Constraint(Arc<...>)` for pointer identity, `|REL|` macro DSL.
  Wire-format mirror.
- **casuarius v0.1.1** (commit `922a4735`) — actively
  maintained, generic-over-Variable, method-chain DSL. Source of
  the `begin_edit`/`commit_edit` / `fetch_changes` patterns we're
  adopting.

Three references reduce the chance of porting bugs.

Estimated effort: ~2 focused sessions for the solver + tests,
~1 more for the integration layer.

### Test discipline

LP solvers fail silently. Symptoms are "wrong values," not
"stack trace." Tests must:

- Cover the canonical Cassowary cases (the 1997 Badros/Borning
  paper's examples; the Enaml test suite's worked layouts; the
  GtkConstraintLayout regressions).
- Property-test feasibility: random constraint sets that we know
  are feasible should converge; required cycles should report
  loudly.
- Snapshot-test specific layouts (flex row, grid 3×3, table with
  one wide cell) so regressions show as diffs in expected
  values.

A solver port that ships without ~150 tests is not a solver
port.

---

## Integration

The solver is **persistent across frames**, owned by a new
`LayoutContext` (peer to `FrameCtx`). It survives re-parses;
only constraints attached to changed blocks get rebuilt.

### Where the solver lives

```zig
const LayoutContext = struct {
    solver: layout.Solver,
    var_pool: VariablePool,           // element_id → variables
    edit_vars: AutoHashMap(VarId, EditBinding),
    exclusions: ArrayList(ExclusionShape),
    // …
};
```

Lifetime: created once at startup, deinit on shutdown. The block
walker borrows it during layout passes.

**Scope decision**: one global solver, with scoped variable
namespacing (`scope/var_name`). Embedded-doc constraints
participate in the same tableau, so parent ↔ child layout coupling
is cheap and consistent.

### How providers emit constraints

```zig
// Inside :::flex {direction=row gap=20} provider
fn layout(self: *Flex, lc: *LayoutContext, container: Bounds) !void {
    var prev_x_max = container.x_min;
    for (self.children) |child| {
        const child_bounds = try lc.boundsFor(child);

        // Child sits after previous + gap (strong — flex rule)
        try lc.solver.addConstraint(
            expr(child_bounds.x_min).eq(prev_x_max.plus(20)).strong(),
        );
        // Child top-aligns with container (strong)
        try lc.solver.addConstraint(
            expr(child_bounds.y_min).eq(container.y_min).strong(),
        );
        // Child fits inside container (required)
        try lc.solver.addConstraint(
            expr(child_bounds.x_max).le(container.x_max).required(),
        );

        prev_x_max = child_bounds.x_max;
    }
}
```

The provider **emits, doesn't compute**. The solver settles. No
two-pass measure; the solver negotiates natively.

### How the walker reads positions

After the solver settles, the existing block walker reads
positions from the solver instead of accumulating cursor state:

```zig
const x = lc.solver.value(elem.bounds.x_min);
const y = lc.solver.value(elem.bounds.y_min);
const w = lc.solver.value(elem.bounds.x_max) - x;
const h = lc.solver.value(elem.bounds.y_max) - y;

try drawList.appendQuad(.{ .x = x, .y = y, .w = w, .h = h });
```

### Incremental update story

`layout_cache.zig` already keys cached blocks by content version.
The extension: each cached block also holds its **constraint
set** — a slice of `ConstraintHandle` returned by the solver.

On cache invalidation:

1. Solver removes the old handles (`removeConstraint` × N)
2. Block re-emits constraints, gets new handles
3. Solver re-settles (incremental — most of the tableau is
   unchanged)

Steady state (97.9% cache hit rate today): no constraint churn,
solver sits idle, walker reads stable values.

---

## The bidirectional GPU channel

The killer demo. A shader writes a tiny readback buffer per
frame; the host wraps the value as an edit variable; the solver
re-settles; surrounding layout reflows.

### Shape

```zig
// :::fluid-density {id=density …} running on the compute pool
const DensityShader = struct {
    readback: VkBuffer,           // host-visible, e.g. 16 bytes
    density_peak_var: VarId,      // edit var registered in solver

    fn onFrame(self: *DensityShader, lc: *LayoutContext) !void {
        const data = mapReadback(self.readback);
        try lc.solver.suggestValue(self.density_peak_var, data.peak_y);
    }
};
```

The surrounding markdown (notional — final attr syntax TBD in
Phase D):

```markdown
:::fluid-density {id=density width=400 height=200}
:::

:::box {bind_y=density.peak_y prefer=medium}
This box floats based on where the fluid density peaks.
:::
```

### Why this is cheap

`suggestValue` is the fastest path through kiwi — typical cost
~1-5µs for a single edit. The solver only re-pivots variables
whose basic relationship to the edit variable changed.
Surrounding elements with stable constraints don't move.

A 60Hz fluid sim emitting one edit per frame costs ~300µs/sec of
solver time. Negligible.

### Why this beats GPU-side solving

You get the same emergent capability (GPU drives layout) without:

- Implementing a 1500-LOC GLSL LP solver
- Paying compute-submit + barrier + readback overhead on the
  *solver itself* (already paying it on the simulation, which is
  the correct place)
- Debugging linear algebra through SPIR-V
- Forcing the solver to be data-parallel (LP isn't)

GPU does what GPU is good at (parallel simulation, particle
emission, density fields, attention maps). CPU does what CPU is
good at (branchy incremental LP). The pipeline barrier sits
between them at exactly the right semantic point: simulation
finishes → host reads scalar result → solver edit → render.

---

## Text intrusion / exclusion

Cassowary doesn't solve text-around-image natively. That is a
*coverage* problem, not a *constraint* problem. CSS `shape-outside`
is a separate pass after box layout settles; we follow the same
pattern.

### Shape

Components opt into "I exclude this region from inline flow" by
emitting an `ExclusionShape`:

```zig
const ExclusionShape = union(enum) {
    rect: Bounds,
    polygon: []Point,
    per_line: []LineSpan,  // y → [x_start, x_end] exclusions
};
```

The exclusion list lives on `LayoutContext.exclusions`. After the
solver settles, text layout consults it when breaking lines: for
each candidate line at `y`, query the exclusion list for active
x-ranges, break the line into available segments, flow glyphs
into the segments.

### Phasing

- **v1**: rect exclusions only. Covers `:::image` and `:::chart`
  floats. Per-line query is O(N) over exclusion count; with <10
  active floats per page that's negligible.
- **v2**: polygon exclusions. Real `shape-outside` semantics.
- **v3**: glyph-driven exclusions (text flowing around other
  text). Probably never needed.

---

## Glyph physical colliders (parked)

Mentioned for completeness because it came up in the
brainstorm. The "particles bouncing off text" demo lives on a
**separate substrate**:

- Glyph bounds → spatial hash (rebuilt each layout)
- Particle simulation queries the hash
- Particles emit Hit-style events for components that want to
  react

This doesn't entangle with layout. It's an emergent visual layer
on top of layout's settled positions. Lives in a future
`:::particles` provider. Listed here so we don't forget.

---

## Strength discipline

The most important convention in this whole document. Without
it, debugging Cassowary becomes miserable ("why is my width 287?
because the medium constraint conflicted with a weak one and got
weighted by 1.7×, that's why").

### The rule

| use case                                    | strength  |
|---------------------------------------------|-----------|
| `x_max ≥ x_min`                             | required  |
| container contains children                 | required  |
| `child.x_max ≤ parent.x_max`                | required  |
| grid columns equal width                    | strong    |
| flex children fill remaining space          | strong    |
| table column alignment                      | strong    |
| author `width=300`                          | medium    |
| author `height=auto`                        | medium    |
| intrinsic text width                        | weak      |
| intrinsic image natural size                | weak      |

Required is for things that, if violated, make the layout
*wrong* (children sticking out of containers, negative widths).
Strong is for provider invariants (the grid would stop being a
grid). Medium is for author intent. Weak is for content's
preferred-but-not-forced sizes.

### Infeasibility

A set of required constraints that contradict each other is
*infeasible*. Kiwi reports infeasibility via an explicit error,
not by returning bogus values. The block walker logs the failing
constraint chain and falls back to last-known-good positions for
the affected block.

We will absolutely hit infeasibility during development. The
loud-error discipline ensures it surfaces as a log line, not
silent visual drift.

---

## Variable identity & incremental updates

Variables are keyed by `Element.id` (or `auto:N` for unnamed
elements — the same scheme `:::name` blocks already use). The
variable pool is persistent; the same element across re-parses
reuses the same `VarId`.

Constraint sets are owned by the block that emitted them. The
`layout_cache.zig` Entry struct gains:

```zig
constraints: []ConstraintHandle,
```

On cache invalidation: `solver.removeConstraint` for each handle,
then the block re-emits, new handles stored. Steady-state cost
is zero.

Edit variables (GPU readback, slider drag, LLM-stream-driven
geometry) are registered once at component creation and remain
across frames. `suggestValue` is the per-frame call.

---

## Performance budget

Cassowary on a typical document (~200 elements, ~600
constraints):

| operation                  | cost      | frequency           |
|----------------------------|-----------|---------------------|
| initial solve              | 100-300µs | once on parse       |
| addConstraint              | 10-50µs   | block invalidate    |
| removeConstraint           | 10-50µs   | block invalidate    |
| suggestValue (edit var)    | 1-5µs     | per frame, per edit |
| value read                 | <100ns    | per element         |

At 60Hz the frame budget is 16.6ms. Even pathological cases
(100-block re-parse) cost <5ms in the solver — well within
budget.

At the project's current ~7600 fps Release (~130µs/frame), an
extra 20-50µs for solver work is measurable but acceptable for
the compositional payoff.

---

## Phasing

Each phase ships visible value standalone. None of them stake
the architecture on something we can't back out of.

### Phase A — kiwi.zig (the substrate)

Pure-Zig port of kiwi. Lives at `src/layout/kiwi/`:

- `variable.zig`, `expression.zig`, `constraint.zig`,
  `strength.zig`
- `solver.zig` — the simplex core
- `tests/` — canonical Cassowary tests + property tests

No integration yet; ships as a library. ~3000 LOC, ~150 tests.
**~2 sessions estimated.**

### Phase B — first integration

`LayoutContext` lives alongside `layout_cache`. `:::box` migrated
to declare via constraints. Block walker reads positions from
solver. Existing demos render identically. ~600 LOC churn across
`element_layout.zig`, `components/box.zig`. **~1 session.**

### Phase C — `:::flex`

The simplest non-trivial provider. Row / column, gap, grow,
shrink. Demo: side-by-side panels in markdown. ~400 LOC.
**~1 session.**

### Phase D — GPU-input channel

Single demo: a `:::density-shader`-style block, compute pass
writing a readback buffer, edit variable per frame, surrounding
box reflows. Validates the bidirectional pattern end-to-end.
**~1 session.**

### Phase E — exclusion / text intrusion

Rect exclusions only (v1). `:::image {flow=around}` demo: text
flows around an image. Per-line break consults exclusion list.
**~1 session.**

### Phase F — `:::grid` and `:::table`

The "real" layout primitives that motivate the whole substrate.
Grid columns with `fr` units, row heights from tallest cell,
spanning cells. Tables with auto-sized columns. **~2 sessions.**

Total horizon: ~8 focused sessions to land a fully
constraint-based layout substrate with at least four working
providers and the GPU-input channel.

---

## Non-goals

- **GPU-side LP solving.** Branchy incremental simplex is not
  GPU-friendly. CPU stays in charge of the solver.
- **Animation-driven constraints.** Constraints settle once per
  frame. Animation is a separate concern (interpolate target
  values, `suggestValue` each tick).
- **A constraint *language* in markdown attrs.** No
  `@width = @height/2` magic string parsing. Constraints are
  emitted via Zig method chaining in provider code. Markdown
  stays declarative-attribute, not algebraic.
- **Auto Layout's full priority float.** Four named tiers cover
  everything we need; arbitrary positive weights are a debugging
  surface we don't want.
- **JIT-compiled constraint evaluation.** Pure interpreted is
  fast enough.
- **Vendoring C++ kiwi.** Pure-Zig port is the right move for a
  zero-C++-deps codebase.

---

## Open questions

These are not blockers; capture them so future-us doesn't
re-litigate them blind.

1. **Solver scope across embedded documents.** Default position
   is one global solver, scoped variable namespacing. If we hit
   pathological coupling (parent re-solve thrashing because of
   child churn), the fallback is per-scope sub-solvers with
   manual bridge constraints. Re-evaluate during Phase B.
2. **LLM-stream constraint churn.** A stream that re-parses
   every chunk emits ~10 invalidations/sec. Incremental updates
   should absorb this; measure during Phase B and reconsider if
   profile says otherwise.
3. **Zoom + constraints.** Crisp zoom (session 10) currently
   computes `max_w = viewport_world_w - 80`. With constraints,
   zoom becomes `solver.suggestValue(viewport_width_var,
   w / zoom)`. Clean. Confirm the world-coord story holds end to
   end during Phase B.
4. **Per-frame edit-var rate ceiling.** How many concurrent GPU
   inputs can the solver absorb before pivots cascade? Benchmark
   during Phase D.
5. **Per-line exclusion data structure.** Naïve list-of-rects is
   O(N·M) per layout (N lines × M floats). With <10 floats per
   page this is fine; with hundreds, an interval tree per
   y-range becomes worth it. Defer until E.

---

## What this replaces

Once Phase B lands, `element_layout.zig`'s cursor-accumulation
logic largely goes away. The walker becomes a constraint
emitter + position reader. The current 1302 LOC of bespoke
per-kind layout code drops to ~400 LOC of constraint emission
plus the solver port.

The compositional payoff: every new provider — `:::flex`,
`:::grid`, `:::table`, `:::dock`, `:::masonry` — is ~200 LOC of
constraint emission. The substrate carries the negotiation.

That is what we are buying. The Cassowary algorithm pays for it
in code we'll port once; every provider afterwards is cheap.

---

## In one line

**Layout is a system of relationships, not a tree walk.**
Constraints declare them. Kiwi settles them. The GPU contributes
edit variables, not solver math. Every provider after that is
~200 LOC.
