# spark — session 23 journey

2026-05-19, third session of the day (after a break with new
glasses, fresh towel, hot tea, and improbability drive at idle).
Effects-spec Phase B.6 was sketched in session 22 as the
"cache-fix + frosted_glass" closer; it ballooned into a four-SHA
arc that ratifies the substrate, fixes a deferred TODO that turned
out to be worse than predicted, abstracts the factory boilerplate
behind a comptime generator, and ships a third user-facing
single_source effect (Liquid Glass) authored via that generator.
Each step ratifies the previous one.

Commits this session:

```
4fd64bf feat: B.6.d — :::liquid_glass + first effect via SingleSourceFactory
71bc6dc refactor: B.6.c — SingleSourceFactory comptime generator
6ccff00 feat: B.6.b — :::frosted_glass + Phase 2 nested-pattern skip
ed14822 fix: B.6 substrate — cache replay-with-offset for primitive routing tags
```

Four commits, one continuous arc. The B.6.c generator is the
load-bearing one — it's where the per-factory cost drops from
~300 LOC of mechanical boilerplate to ~45-150 LOC of real
per-effect content, and B.6.d immediately validates the new
API surface against a fresh consumer.

## The plan at session start

Session 22 closed B.5 with two outstanding bugs masked behind a
`disable_cache = true` workaround on drop_shadow's vtable. The
plan for B.6 was:

- **B.6.a** — proper fix for the cache re-tagging bug (the
  workaround landed because the cache layer didn't store primitive
  routing tags, so `blitEntry` re-tagged everything with the outer
  walker's current target).
- **B.6.b** — `:::frosted_glass`, the second single_source factory
  per the spec.
- **B.7** — `:::placeholder_scene` HostSlotPass stub.
- **B.8** — acceptance wrap (two_instances effect coverage,
  determinism docs, FPS canary).

Three sequencing options for B.6 itself:

- **(A)** Cache fix first, then frosted_glass.
- **(B)** Frosted_glass first with `disable_cache = true` (matching
  drop_shadow), then cache fix removes both flags in one SHA.
- **(C)** Both as one bundle.

Christian's framing chose A on two grounds:

> The fail-safe asymmetry favors A. If the cache fix has a subtle
> visual regression … landing it with drop_shadow as the only
> consumer makes the diagnostic loop trivial: "the existing
> visible-shadow demo now looks wrong; the only thing that changed
> was the cache layer."

> Workaround flags ossify. Option B's "land frosted_glass with
> disable_cache = true first, then remove both flags" sounds clean
> in theory, but in practice two consumers carrying the same
> workaround creates social inertia — it works, why bother fixing
> it? — and the substrate fix slips.

Both are general principles worth carrying forward. The first
keeps diagnostic loops tight by minimising surface area at the
time of the substrate change. The second prevents workaround
flags from accreting load-bearing status. Going with A.

## Phase B.6.a — cache replay-with-offset (`ed14822`)

Before writing code I asked: how big is this fix actually? If it's
localized to `SingleSourcePipelineCache` keying I can do it
inline; if it ripples into descriptor pool families or hasher
tagging that's a sub-arc and worth scoping first. The answer was
**localized**: 4 files, ~150 LOC total.

The bug shape, articulated as a code comment so the next reader
sees it:

  - `Entry` (the cache value) stores cached glyph/quad/tri/image
    primitives.
  - It did NOT store their parallel `*_targets` routing arrays.
  - `blitEntry` (cache-hit path) re-stamped every blitted primitive
    with the **outer walker's** `current_target_dispatch_index`.
  - For a cached subtree containing its own `.single_source`
    effect, the inner primitives WERE tagged correctly when
    snapshotted (the walker's target push was active), but on
    blit they got re-stamped with the outer target (typically
    `MAIN_TARGET`).
  - Result: the effect's wrapped content drew on MAIN instead of
    the offscreen target; the compose dispatch sampled an empty
    target.

The fix mirrors the snapshot/blit pattern already used for
cached `pass_dispatches`:

  - `Entry` gains 4 parallel arrays — `glyph_targets`,
    `quad_targets`, `tri_targets`, `image_targets`.
  - `snapshotEntry` dups them, rebasing local pd indices to
    start at 0 (so the entry is self-contained). `MAIN_TARGET`
    stays as the sentinel.
  - `blitEntry` replays with offset: `MAIN_TARGET` → outer
    walker's active target (so a cached subtree blitted inside
    an enclosing single_source correctly inherits it); other
    indices → `cached + pd_base` (where `pd_base` is the live
    `pass_dispatches.items.len` captured before the cache
    entry's own dispatches get merged in).
  - Three defunct `appendGlyphsTaggingWith` helpers in
    `element.zig` (called only by `blitEntry`) deleted; four
    `appendGlyphsReplayingTargets` helpers take their place.

**The MAIN_TARGET sentinel decision is the load-bearing one** and
got a code comment at the resolution site. The sentinel semantically
means "outer context's active target at render time," NOT "literally
the framebuffer." That's what makes the cache compose under
nesting — a cached subtree blitted inside an enclosing effect
correctly routes its outer-tagged primitives to that effect's
offscreen target, not the screen.

Christian's third note before I started:

> The bonus nested test is the right scope-tightening. `:::drop_shadow`
> inside a cacheable container is exactly the path that would catch
> off-by-one in pd_start/pd_base rebase. Without that test, the
> non-nested case passes trivially (rebase is identity when
> pd_start = 0).

The integration test does two walks of a doc with `:::drop_shadow`
in one Spark; asserts (1) hash equality across the snapshot → blit
cycle, (2) at least one cached quad routes to the live
single_source dispatch's `sequence_index` on the cache-hit walk.
Both load-bearing — assertion #2 is the literal pre-B.6 bug:
that count would be 0.

**Wire format v3 baseline stayed invariant.** The hasher reads
the live DrawList + pass_dispatches, not cache internals; the
existing gradient doc uses one fresh Spark per iteration so
`blitEntry` is never hit. Verified before writing the code, noted
in the test comment so a future reader doesn't have to re-derive
why the baseline didn't need bumping to v4.

Visible-shadow demo confirmed at 11.6K fps Release with cache
restored. Single SHA, drop_shadow flag flipped off in the same
commit because the substrate change has no visible behavior
without it.

## Phase B.6.b — `:::frosted_glass` + Phase 2 nested-pattern skip (`6ccff00`)

`:::frosted_glass` is the spec's second canary single_source. The
factory shape mirrors drop_shadow: same pipeline cache, same
descriptor layout, same Spark-side wiring. Differences: no layout
inflation (renders within child bounds), uniforms are
`{blur_radius: f32, _pad[3]: f32, tint_color: vec4}` instead of
drop_shadow's offset+blur+color.

Shader is a 9-tap box blur sampling the offscreen target, then
a standard "over" composite of the tint on top. Single pass,
fragment-only.

First smoke run: visible, but on a flat-color box child it just
looks like a softly-edged rectangle. Christian's framing —

> It's definitely doing something! Difficult to tell on a flat
> background.

— and the right next move was to put high-frequency content
inside the panel so the blur is visible: a `:::pattern
{type=checker}` and a `:::noise`.

That's where the demo got interesting in the wrong way.

### The bug

Panels with pattern/noise children rendered the **raw pattern**
(no blur, no tint, no edge softening visible). The noise panel was
**solid black**. Box-child panels worked fine.

Round 1 hypothesis: shader was passthrough because uniforms
weren't reaching the GPU. I built a 4-quadrant diagnostic shader:

  - top-left: solid `tint_color.rgb`
  - top-right: grayscale = `blur_radius / 32`
  - bottom-left: raw `texture(u_target, v_uv)`
  - bottom-right: solid red (sanity — compose fired)

Box-child panel: all four quadrants showed correctly. Pattern-child
panels: showed only the raw pattern. No red BR even, despite my
shader outputting alpha=1 there. So the compose dispatch was
**not firing** for pattern-child cases — or its output was
discarded.

Round 2 hypothesis: maybe compose isn't firing at all for these.
Simplified the diagnostic shader to **solid opaque magenta** with
no uniforms, no texture sampling. If the compose draw recorded
and executed, the panel must be magenta. Otherwise something else.

Result: box-child panels magenta. Pattern-child panels: still
showing the raw pattern. **Compose not firing for pattern-child
cases.**

Round 3 — verify by instrumentation. Added `std.debug.print` to
`recordSingleSourceCompose`. The result was the diagnostic that
unblocked the thinking:

```
DBG compose: seq=10 (drop_shadow)
DBG compose: seq=11 (#glass_subtle, box child)
DBG compose: seq=12 (#glass_second_box, box child)
DBG pattern: seq=13 viewport=(40,2177,240x80)   ← !!
DBG compose: seq=14 (#glass_checker, pattern child)
```

Compose was being CALLED for all of them. The pattern dispatch
at sequence 13 was running on MAIN **between** the box-child
composes and the pattern-child compose. The compose at 14 was
recording its draw, completing the function, but its output
wasn't visible.

Christian's framing at this point:

> Hmmm, is this the same problem we had earlier with draws in
> the wrong place. There was talk of using a negative offset
> viewport, but we ended up doing it a much cleaner way. I think
> the problem we keep running into is we have two different
> co-ordinate systems that aren't being properly tracked.

That re-anchored the thinking. The coord-system framing is
exactly what B.5's `world_offset` push constant fixed — and
this had a similar shape: dispatches being routed to the wrong
place because of an ordering or framing mistake. I grepped
`spark.zig` for `TODO(B.6)` and found exactly this case predicted
at line 723, dated from session 22:

> TODO(B.6): forward iteration treats patterns inside single_source
> subtrees as top-level. The walker emits patterns BEFORE their
> single_source parent (post-order), so a forward walk encounters
> nested patterns and dispatches them at the main attachment AND
> inside the parent's offscreen pass — double-rendering. Doesn't
> trigger on current effect.md because `:::drop_shadow { :::box }`
> wraps a content element (`:::box` emits no dispatches). B.6's
> `:::frosted_glass { :::gradient … }` (or any shape wrapping a
> pass-emitting child) will surface it.

### Why the symptom was worse than the TODO predicted

The TODO predicted **double-rendering** — pattern would draw on
MAIN AND in the parent's offscreen target. The actual symptom
was **the subsequent compose disappeared**. Pattern's MAIN
dispatch somehow suppressed the next compose dispatch's output
even though the compose's `vkCmdDraw` was recorded with a valid
pipeline, descriptor set, viewport, scissor, and push constants.

I added prints for descriptor set / image view / sampler handles;
all distinct and non-null per compose. I verified the blend state
(premultiplied alpha over, with alpha=1 magenta the compose's
output should fully overwrite). I verified the color write mask
(RGBA). I verified the pipeline format matched MAIN. I verified
Phase 1 ran BEFORE Phase 2. Nothing surfaced as the smoking gun
mechanism.

Going with the structural fix anyway: Phase 2 should never
dispatch nested patterns — they're already handled by Phase 1
inside the parent's offscreen target. The fix is a pre-computed
`is_nested[pd_len]` bitmap, populated by walking every
single_source's `subtree_dispatch_range`. Phase 2's iteration
skips marked indices.

Verified by removing the pattern dispatch — compose magenta
became visible on all panels. Bug structurally gone regardless of
the GPU-level mechanism for the suppression.

**The lesson worth carrying forward**: deferred TODOs that name
their forcing function deserve trust on existence, but the
**predicted symptom may understate the actual one**. The TODO
said "double-rendering" (cosmetic, both visible). Reality was
"compose suppressed" (one disappears). Pattern: implement the
forcing-function consumer, observe the real failure, then design
the fix against what's actually broken. Don't pre-fix based on
the predicted symptom — the prediction might be wrong about what
the symptom even looks like.

Memory captured in `project_spark_effects_spec.md` under B.6.b.

## Phase B.6.c — SingleSourceFactory comptime generator (`71bc6dc`)

After B.6.b shipped, Christian asked:

> How easy is it to add another one like the frosted_glass by the
> way?

The honest answer: about 300 LOC, of which 200+ are boilerplate
that's identical across every single_source factory (Component
struct, create/update/deinit, snapshot_uniforms, layoutAndRender,
vtable, Factory declaration). The truly per-effect surface is
~30-40 LOC: Uniforms extern struct, `applyAttrs` mapping spec
attrs to uniforms, optional inflation math.

Christian's follow-up was the right question:

> What do we need to do to reduce that 300 LOC to negligible? I'm
> talking about the Zig side — not the shader itself?

The answer is a comptime generator. Zig's type system handles this
cleanly: `SingleSourceFactory(.{...})` returns a struct exposing
`.factory` (ready to register) and `.install(spark)` (one-line
registration). The generator handles all the boilerplate by
parameterising over `Uniforms`, `apply_attrs`, and optional
inflation.

Per-factory file becomes:

```zig
const Uniforms = extern struct { ... };

fn applyAttrs(spec: *const components.Spec) Uniforms {
    return .{
        .blur_radius = params.resolve(f32, spec, "blur", 12.0),
        ...
    };
}

pub const Effect = pass.SingleSourceFactory(.{
    .name = "frosted_glass",
    .shader = "frosted_glass.frag",
    .Uniforms = Uniforms,
    .apply_attrs = applyAttrs,
});
pub const factory = Effect.factory;
pub const install = Effect.install;

test "Uniforms: std140 layout offsets" { ... }  // still per-factory
```

**What stays per-factory (load-bearing):**

  - **Uniforms struct with explicit std140 padding.** Auto-padding
    would defeat [[feedback-std140-offset-lockin]]'s point —
    silent reorders compile cleanly but render GPU garbage; the
    explicit `@offsetOf` test is the only catch.
  - **`applyAttrs`** — the only real per-effect logic (mapping
    spec → uniforms).
  - **Inflation math** when the effect reserves halo room.

**What the generator handles uniformly:** Component, create
(arena init + scope dup + fail-fast resolver check + body parse),
update (re-applies attrs, bumps version), deinit_, snapshot_uniforms
(memset 0 + memcpy bytes), layoutAndRender (walks child at
inflated origin, returns inflated box — passthrough when inflation
is zero), vtable, Factory.pass_shape.

Comptime guard on `@sizeOf(Uniforms) <= MAX_PASS_UNIFORM_BYTES`
inside the helper — fails at compile time rather than truncating
silently at runtime.

Numbers:

  - `drop_shadow.zig`: 355 → 155 LOC (-56%)
  - `frosted_glass.zig`: 230 → 85 LOC (-63%)
  - `single_source_factory.zig`: 250 LOC new helper
  - Net today: -95 LOC across files
  - Per-future-factory: ~150 LOC saved

Breaks even at the 3rd single_source factory. We already had 2
(drop_shadow + frosted_glass); the 3rd was a "when, not if"
question, so the refactor paid back the same session.

**Pattern for future helpers** worth carrying forward: wait for
≥2 implementations before generalising so the helper's API is
grounded in observed variation, not predicted variation.
Drop_shadow alone wouldn't have surfaced the optional-inflation
axis cleanly — only with frosted_glass (no inflation) as the
second consumer did the generator's optional-config shape become
obvious. Generalising from one example would have over-fit to
drop_shadow's shape; generalising from two surfaced exactly the
axis of variation worth parameterising.

Refactor only — no behavior change. Tests + visual demo unchanged.

## Phase B.6.d — `:::liquid_glass` (`4fd64bf`)

Christian:

> Okay, I was wondering if we could sneak a filter in for me as a
> test of that new stuff? I was looking at some of the Apple Liquid
> Glass attempts on shadertoy.

He sent three shadertoy examples — a refraction box, a "liquid
glass with photo icon" with directional blur, and a full
physics-based liquid glass with caustics and dispersion. The
shadertoys all assume two things our v1 substrate doesn't expose:
mouse-driven panel position (we render fixed panels) and sampling
of "what's behind the glass" (we only sample the child's offscreen
target — there's no second sampler bound to MAIN).

Scope decision: "liquid glass on the child's content." Refraction
bends the panel's own content near the rounded corners; rim
highlight traces the edge; chromatic aberration adds prismatic
flash at corners; optional tint composites on top. The Apple
see-through look is deferred to Phase D's HostSlotPass or a
future ChainPass variant.

Shader algorithm:

  1. Rounded-box SDF at v_uv space (the target IS the panel, so
     half_size = 0.5 along both axes naturally).
  2. Alpha edge fade via smoothstep — opaque inside, transparent
     outside, soft crossing. Early-out for fully transparent
     fragments saves the rest of the work.
  3. Refraction strength curve: `bend = pow(1 - depth_in, 2)`
     for sharper-near-edge falloff. Pull sampling UV back toward
     center proportional to bend.
  4. Chromatic aberration: R and B sampled along the radial
     direction at small offsets scaled by bend; G centered. Clean
     panel center, prismatic flash at corners.
  5. Rim highlight: difference of two smoothsteps on -sd produces
     a thin bright band just inside the edge.
  6. Tint composite via standard "over" blend.

Factory file:

```
99 src/components/effects/liquid_glass.zig
```

99 LOC for a new single_source factory. ~20 are the real per-effect
surface (Uniforms + applyAttrs + factory declaration + the
SingleSourceFactory call). The rest is doc + offset lock-in test +
pass_shape assertion test.

This is the validation of the B.6.c generator's API. It's the
first effect **authored via** the generator (not refactored to
use it), and it proves the API holds up for new effects, not
just for converting existing ones.

Demo: three liquid_glass panels in effect.md — checker (high-
contrast input shows refraction + CA clearly), noise (softer
input, rim dominates), solid box (baseline for rim + tint
without competing content). The checker panel turned out
visually striking — the chromatic aberration produces vivid
rainbow halos following the rounded corners. Christian's
reaction:

> That's fun — looks correct! Was a nice palate cleanser!

Perf at session close: 1082 fps Release with 8 single_source
dispatches per frame (1 drop_shadow + 4 frosted_glass + 3
liquid_glass) plus rasterizer load.

## What carried forward cleanly

- **The "spec is the task list" cadence**. Four commits across
  the arc, each a discrete progress marker. No TaskCreate
  overhead. Christian's standing rule from session 22 held.
- **Per-phase commit shape**. Each SHA is independently
  understandable: substrate fix, feature + structural bug, refactor,
  feature. Easy to bisect; easy to read in `git log`.
- **Substrate-vs-consumer commit sequencing**. The Option A
  decision (substrate fix first, drop_shadow flag flip in the
  same SHA) compresses diagnostic loops. Same logic applied to
  the Phase 2 nested-pattern skip — landed with frosted_glass
  as the consumer that proves it works.
- **Visual ratification before committing**. Every behavior-change
  SHA got a "please run the demo, tell me what you see" beat
  before the commit. Caught the B.6.b bug class before it could
  bake in.
- **Memory captures during the session, not after**. The Phase 2
  nested-pattern lesson, the generator's "wait for 2 consumers"
  pattern, the MAIN_TARGET sentinel semantics — all captured in
  `project_spark_effects_spec.md` at the moment they were earned.
  Faster than batch-updating at session end and less risk of
  losing the framing.

## What hurt

- **The B.6.b diagnostic round was longer than it should have
  been.** I theorised through descriptor pool capacity, blend
  state, color write mask, pipeline format, render pass scoping,
  and pipeline-layout compatibility before instrumenting the
  actual dispatch order. Christian's coord-system framing was
  the unblocker — without it I'd probably have kept theorising.
  The lesson generalises: when "everything I can check from the
  CPU side looks correct but the GPU isn't producing the
  expected output", **stop theorising and instrument the actual
  command order**. The TODO at line 723 was already in the
  codebase predicting this exact case; I should have grepped
  for it earlier rather than rediscovering it the hard way.
- **I never confirmed the GPU-level mechanism for why the nested
  pattern dispatch suppressed the subsequent compose.** Pipeline
  rebind, descriptor invalidation, push-constant range
  compatibility — all checked and looked correct. The fix
  (don't dispatch the nested pattern in Phase 2) is structurally
  correct regardless of why the symptom was what it was, but I
  shipped it without root-cause understanding. If a similar
  pattern surfaces in Phase C (chain effects, multi-pass), the
  mystery mechanism might bite again. Worth pinning for
  follow-up if it comes up.
- **The "predicted symptom vs actual symptom" lesson was earned
  expensive.** The TODO said "double-rendering" — I assumed that
  meant "both visible, fix the duplication later." The actual
  symptom was "compose suppressed", which is qualitatively
  different. Trust deferred TODOs on existence; don't trust
  them on symptom shape until you've reproduced the failure.

## What's banked + what's pending

**Phase B is now substantially overshot from the spec's canary
list.** The spec called for `:::drop_shadow` + `:::frosted_glass`
as Phase B's user-facing deliverables; we shipped those plus
`:::liquid_glass` as a bonus authored via the generator. The
substrate is stable enough that bonus effects are ~30-minute
adds.

**Still pending in Phase B**:

  - **B.7** — `:::placeholder_scene` HostSlotPass stub. Test-only
    factory with a clear-to-color callback, registered by
    `integration_render.zig` only. Lights up the `.host_slot`
    union arm end-to-end so the variant doesn't bitrot before
    Phase D. Structural plumbing.
  - **B.8** — acceptance wrap. Extend `two_instances.zig` with
    per-Spark target pool isolation under effect-using docs;
    drop_shadow + frosted_glass + liquid_glass determinism docs
    in `integration_render.zig`; FPS canary spot-check.

Both are structural — no more user-visible effects in v1.
Natural session boundary here.

**Cross-cutting opportunities surfaced in this session**:

  - Phase 2 nested-pattern handling now uses a per-frame
    `is_nested` bitmap allocation. Fine for v1, but if Phase C
    chain effects push the dispatch count high enough, this could
    be hoisted to a layout-time pre-computation. Not urgent.
  - The GPU-level mechanism for pattern→compose suppression
    remains unconfirmed. If Phase C surfaces similar weirdness,
    revisit with RenderDoc capture and a minimal repro.
  - The SingleSourceFactory generator is the prototype for
    similar generators when Phase C lands ChainPass and Phase D
    lands HostSlotPass. Same shape applies — wait for ≥2
    implementations before generalising.

Phase B.6 closes clean across four SHAs. The cache substrate
holds. The Phase 2 nested-pattern bug is structurally fixed. The
generator drops per-factory cost from ~300 LOC to ~45-150. Three
single_source factories ship. The path to B.7 → B.8 is now
well-scoped — both are short structural arcs.

Coming back with a fresh head. 🪆🥃
