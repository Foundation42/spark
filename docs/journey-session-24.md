# spark — session 24 journey

2026-05-19, fourth session of the day (new glasses arrived between
sessions — Christian's bench setup officially complete). Effects-spec
Phase B.7 + B.8 land in three SHAs and close out v1 structurally:
all four implementable `PassShape` arms now have lit-up dispatch
paths end-to-end, with `.chain` reserved for Phase C. Substrate +
consumer + acceptance — same three-step arc as B.6.a/B.6.b/B.6.c,
the third clean run of the pattern.

Commits this session:

```
3907f60 test: B.8 acceptance — effects-substrate isolation + per-effect determinism
1caea49 feat: B.7 consumer — :::placeholder_scene + host_slot integration test
1783f88 feat: B.7 substrate — HostSlotPass dispatch end-to-end
```

Three commits, one continuous arc. The B.7 substrate commit is the
load-bearing one — it makes the `.host_slot` PassShape arm a real
type rather than a placeholder, with all the dispatch wiring lit so
Phase D's `:::3d-scene` matryoshka adoption can register a factory
and have it work without further spark-side changes.

## The plan at session start

Session 23 closed B.6 with three user-facing single_source effects
shipped (drop_shadow, frosted_glass, liquid_glass) plus the
SingleSourceFactory comptime generator. The spec's outstanding work
was:

- **B.7** — `:::placeholder_scene` HostSlotPass stub. Test-only
  factory; not in `installCoreComponents`. Lights up the
  `.host_slot` union arm end-to-end so it doesn't bitrot before
  Phase D's real matryoshka adoption.
- **B.8** — acceptance wrap. Two_instances test extension, per-effect
  determinism docs, FPS canary.

I sketched the B.7 work in two halves: (a) substrate including
type definitions + dispatch wiring; (b) factory + integration test.
Substrate-vs-consumer sequencing per session 23's [[project-spark-effects-spec]]
note on the same pattern. Single-doc substrate-only commit
compresses the diagnostic loop — placeholder_scene is the only
consumer, any regression bisects trivially.

## The sketch-and-pause flow

Before any code went into files, I described the planned shape as
four code blocks in chat: `HostSlotPass` + `HostSlotCtx` on
`component.zig`, `HostSlotInvocation` + `HostSlotStep` + vtable
hook on `element.zig`, the dispatch flow sketch in `spark.zig` as
pseudocode, and the `placeholder_scene` factory shape. Stopped
short of writing actual files so Christian could redline the
architecture before code committed to a direction.

Christian came back with all four pins ratified plus three
refinements + one cosmetic, the kind of feedback that's hard to
give once a diff is in flight. The four:

1. **Cmd ownership = option (b)**: spark transitions the offscreen
   target to `COLOR_ATTACHMENT_OPTIMAL` before the call; the host
   opens its own `vkCmdBeginRendering` scope, draws, closes the
   scope, returns with the target still in
   `COLOR_ATTACHMENT_OPTIMAL`. The contract is "host's renderer
   runs inside spark's frame," not "host draws inside spark's
   render pass." Phase D's `:::3d-scene` would not fit option (a) —
   matryoshka's scene render is multi-attachment MRT with depth,
   not a single color attachment.

2. **`*anyopaque` typing for cmd/image/view + `u32` for
   `target_format`**: keeps vulkan-zig off spark's public surface
   even for the format enum. Hosts cast through their own
   vulkan-zig binding. Cosmetic-looking but load-bearing — once a
   single `VkFormat` lands in the public API, the rest of the
   vulkan-zig namespace creeps in by transitive necessity.

3. **`void` return, errors handled internally**: a failed host
   render shouldn't tank spark's frame. Mirrors matryoshka's
   "render a degraded frame, log, keep going" policy.

4. **`target_format` forwarded despite the B.7 stub not needing
   it**: Phase D's `:::3d-scene` will need it for renderer pipeline
   setup. Adding later would be an API break; free now.

The three refinements:

- **Assert at dispatch time** that `invocation.callback` is non-null.
  Belt-and-suspenders against any future path that bypasses the
  walker (manual `HostSlotStep` construction in tests).
- **Comment on the layout transition** that it double-duties as the
  WAR barrier between host writes and Phase 2 sampling. A future
  "optimisation" that replaces it with a same-layout move would
  silently delete the barrier.
- **Docstring note on `hdr_target`** that real-scene factories
  (Phase D matryoshka) will want `true` even though the B.7 stub
  uses LDR.

Each is the kind of refinement that matters because the line will
exist forever and the next maintainer reads only what's there. The
WAR barrier comment in particular: layout-transition-as-barrier is
non-obvious unless you've read enough Vulkan synchronization to
know image layouts execute full memory barriers as a side effect.

## Phase B.7 substrate (`1783f88`) — the unilateral design call

Mid-implementation, an architectural question surfaced that wasn't
covered by the sketch: where do `(callback, user_data)` live? Two
options:

- **Factory-level defaults on `HostSlotPass`**: `callback +
  user_data` as fields on the struct, walker reads them and emits
  a `HostSlotStep` with the resolved pair. Per-instance overrides
  via vtable hook.
- **Vtable-only per-instance**: `HostSlotPass` carries no
  `(callback, user_data)`; every factory MUST set
  `ElementVTable.invoke_host_slot`, walker errors with
  `HostSlotElementMissingInvokeHook` if missing.

The sketch I'd shown Christian assumed option A — factory defaults
+ vtable override. But writing the walker code, the missing piece
became obvious: **the walker has no path to the Factory at
emission time**. Element.custom carries `(pass_kind, shader_id)`
but not arbitrary factory state, and adding `(callback,
user_data)` raw fields to Element.custom pollutes the type
definition for one variant — explicitly the cycle-dodge that A.6.a
fixed.

Three paths from there: (1) add factory-name lookup on Element so
walker can reach back to factory, (2) pollute Element.custom with
fn-pointer fields, (3) drop factory defaults entirely and make the
vtable hook mandatory.

Path (3) is what `snapshot_uniforms` already does — mandatory for
non-content factories, walker errors if absent. Symmetric, cleaner,
no Element.custom expansion, no factory-name lookup, no
sometimes-uses-factory-sometimes-uses-vtable behavior to document.
Phase D's real use case (`:::3d-scene scene_id=hud` vs `scene_id=settings`)
is fundamentally per-instance — there's no "factory-wide" host slot
use case where a single shared `user_data` makes sense; even
matryoshka would need vtable wiring for scene discrimination.

I made the call to drop `HostSlotPass.{callback, user_data}` and
required vtable-only wiring. Flagged it explicitly at commit time
as the load-bearing deviation:

> `HostSlotPass.{callback, user_data}` factory-level fields
> dropped during implementation — the walker has no path to the
> Factory at emission time without polluting Element.custom with
> fn-pointer fields, and per-instance vtable wiring is the
> load-bearing path regardless.

Christian ratified post-commit: "Totally fine with the call you
made." The general lesson: **the right time to make unilateral
calls is mid-implementation, when the implementation reveals
something the sketch couldn't have predicted, AND the call is
flagged explicitly for post-hoc ratification.** Not at sketch time
(where it's not your call) and not silently (where it removes the
ratification step).

### The build-error-driven herd

Beyond the call above, the substrate work was mostly mechanical
type extension. The shape:

1. Add new variant fields to `HostSlotPass` + `HostSlotStep` +
   `HostSlotCtx` + `HostSlotInvocation`.
2. Run `zig build`. Watch the exhaustive switch errors fire across
   the codebase.
3. Add the `.host_slot` arm at every site the compiler points at.

This worked because PassDispatch is a `union(enum)` switched
exhaustively at every consumer. Five sites needed updating
(walker emission, layout_cache snapshot, layout_cache blit,
spark.zig Phase 1 dispatch, spark.zig Phase 2 dispatch, plus the
nested switches inside `phase1ProcessSingleSource`). The compiler
points at each one; no grep needed.

This is what [[feedback-panic-over-error-for-phased]] cousins in
practice: **lean on exhaustive switches as your structural-fingerprint
guard**. The hasher comment in `integration_render.zig` calls this
out explicitly so a future maintainer doesn't add a `_ => {}`
catch-all:

> The per-arm dispatch below is exhaustive over PassDispatch; if a
> fourth arm lands (Phase C `.chain`, future Phase E variants),
> the compiler fires a non-exhaustive-switch error here. Don't add
> a `_ => {}` catch-all — silently dropping arms from the
> fingerprint is exactly the regression class this gate exists to
> prevent.

### Type placement for `HostSlotCtx`

Originally drafted on `component.zig` next to `HostSlotPass`. The
fn-pointer type `HostSlotInvocation.callback` references it though,
and that lives on `element.zig`. Following [[feedback-type-at-producer-module]],
moved `HostSlotCtx` to `element.zig` (sibling of `PassDispatch`,
`Hit`, `HostSlotInvocation`) and re-exported from `component.zig`
for factory-code symmetry. The doc comment on the new type calls
out the placement explicitly:

> Lives in `element.zig` (walker/dispatch output sibling to `Hit`
> / `PassDispatch`) rather than `component.zig` because the
> function-pointer type `HostSlotInvocation.callback` references
> it, and element.zig can't import component.zig without
> re-igniting the element↔component cycle the A.6.a refactor
> dodged.

The cycle-dodge memory paid off again. Same rule as before: types
live at the producer module, consumers import inward.

### Wire format v2 → v3

The hasher already used "arm tag byte first, then arm-specific
fields" so adding `.host_slot` was additive — existing Phase A and
B docs hash identically under v3. Bumped the protocol-comment
header from v2 → v3 (host_slot arm tag = 2, `invocation` excluded
from hash per protocol — same exclusion category as `*_uniforms`
trailing zero padding). The hasher's switch on `PassDispatch` is
already exhaustive, so the v3 mint is a one-line addition with
explanatory comment.

## Phase B.7 consumer (`1caea49`) — placeholder_scene

The substrate committed; now the consumer that exercises it.

`:::placeholder_scene` is the test-only factory shaped per the spec:
registered ONLY by `integration_render.zig`, NOT by
`installCoreComponents`. Renders a flat clear-to-color into an
offscreen target via the host callback, then composites back via a
trivial passthrough shader. Same visible effect as `:::box
{color=...}` but routed through host_slot dispatch — exercises the
substrate end-to-end.

Per-instance state via vtable: `Component` carries `(width, height,
clear_color)`; `invoke_host_slot` returns `(invokeCallback, ctx)`
where `ctx` is the per-instance Component pointer. The host
callback opens a real `vkCmdBeginRendering` scope with
`LOAD_OP_CLEAR` to `clear_color`, then closes it. No draws — the
clear IS the render. Exercises the contract Phase D will inherit
exactly.

### The shader-reuse question

`recordHostSlotCompose` reuses `single_source_pipelines` (same
combined-image-sampler layout). The question was: which shader to
use for the composite step?

Option A: reuse `copy.frag` (the B.4.b substrate test shader). But
copy.frag declares a `layout(push_constant)` block with `alpha`,
expecting the dispatcher to push 4 bytes. The substrate's
`HostSlotStep` carries no uniforms in v1 (matching the spec's
"no uniforms" simplification). Reusing copy.frag would either force
the dispatcher to hardcode `alpha = 1.0` (which hardcodes a uniform
shape into the dispatch site that Phase D real composite shaders
would inherit) or leave the push range undefined (validation noise +
possibly black output).

Option B: dedicated `host_slot_passthrough.frag` with no push
constants. Reads `texture(u_target, v_uv)` and writes. Eight lines.

Going with B — keeps the `HostSlotStep`-has-no-uniforms design
clean and avoids cross-purpose shader reuse. Phase D's real
composite shaders (tone-map, vignette) can declare their own push
ranges; the dispatch site stays uniform-free because Phase D pairs
each shader with its own dispatch helper if needed.

### Integration test

The test verifies:

- A doc with `:::placeholder_scene` produces exactly ONE PassDispatch
- It's the `.host_slot` arm with correct `composite_shader_id` +
  `target_size`
- `invocation.callback` is non-null (walker resolved via the vtable
  hook; absent hook would have errored at layout time with
  `HostSlotElementMissingInvokeHook`)
- Hash deterministic across two Sparks despite each Spark
  constructing distinct vtable instances and Component allocations
  — ratifies the wire format v3 protocol exclusion of `invocation`
  from the hash

The last assertion is the load-bearing one. If a future refactor
accidentally folds `invocation` into the hash, two consecutive
Sparks will disagree (different vtable instance addresses each
Spark) and this assertion trips deterministically. Pinning the
exclusion in test substrate, not just in protocol comments.

## Phase B.8 acceptance (`3907f60`) — locking the invariants

Two test additions, both lockdown rather than coverage:

**`two_instances.zig` extension.** Existing test covered the
pattern pipeline cache per-Spark invariant; new test extends to
the full single_source substrate (`target_pool`,
`single_source_pipelines`, `single_source_descriptor_pool`). Each
of two Sparks loads `:::drop_shadow {…} :::box {…} :::` and walks
layout — asserts sibling-field pointers distinct, `pass_dispatches`
ArrayList storage distinct, at least one `.single_source` arm
emitted in each, clean dual-deinit. Reverse-order tear-down would
trip any double-free from accidental aliasing.

**Per-effect determinism docs in `integration_render.zig`.** One
test per shipped single_source factory — drop_shadow, frosted_glass,
liquid_glass — each loading a minimal doc and asserting:

- Hash equality across two consecutive Sparks (catches drift in
  uniform encoding, std140 padding, region quantisation,
  subtree_dispatch_range computation)
- Exactly one `.single_source` dispatch (no accidental extras from
  the wrapped child)
- `filter_shader_id` matches the factory's declared shader

Shared helper `assertSingleSourceDoc` to keep the three tests as
data tables rather than three copies of the same scaffolding.
Complements (doesn't duplicate) the existing cache-replay test
for drop_shadow — that one exercises snapshot → blit round-trip;
these exercise emission in isolation.

### FPS canary (interactive)

Spec acceptance #3 ("within 5% of pre-Phase-A baseline") needed
Christian's hands. Numbers from his run:

- `spark_demo src/effect.md` Release: **6115 fps** (33706 frames /
  5512ms)
- `spark_demo hello.md` Release: **~13K fps**

Both well within budget. The effect-heavy demo doc that exercises
every shipped effect category (3 patterns × 3 variants, 3
single_source × 3 panels each, 4 frosted_glass panels, 3 liquid_glass
panels) still pulls 6K+ fps Release. The substrate cost is
amortized to nothing.

## What this closes

v1 effects-spec is structurally complete. Five `PassShape` arms,
five outcomes:

- `.content` — every pre-effects factory; unchanged
- `.pattern` — three canary factories (gradient, pattern, noise),
  Phase A
- `.single_source` — three user-facing factories (drop_shadow,
  frosted_glass, liquid_glass) + comptime generator, Phase B.5-B.6
- `.host_slot` — `:::placeholder_scene` test-only stub, Phase B.7;
  Phase D adds `:::3d-scene` real consumer
- `.chain` — reserved for Phase C, panics with phase-tagged message

The compositor decomposes. The graph composes. The author writes a
document.

## The arc that kept working

Third clean run of the "substrate-then-consumer-then-acceptance"
arc this spec:

- **B.4.b → B.5** — substrate (per-target rasterizer routing, three-
  phase dispatch processor) then consumer (`:::drop_shadow` visible)
- **B.6.a → B.6.b** — substrate (cache replay-with-offset) then
  consumer (`:::frosted_glass` clean, no `disable_cache` flag)
- **B.7 substrate → B.7 consumer → B.8 acceptance** — substrate
  (HostSlotPass dispatch wired), consumer (placeholder_scene
  factory exercises the dispatch), acceptance (two_instances +
  per-effect determinism lock-ins)

All three followed the same fail-safe pattern: substrate-only
commit lands with minimal consumer footprint, diagnostic loop stays
narrow ("the existing visible-effect demo now looks wrong; the only
thing that changed was the substrate layer"). The acceptance wrap
tail is new at B.8 — when no more visible-output work remains, the
final SHA is pure invariant-locking in test substrate so the
ratchet of "v1 effects-spec complete" carries forward.

Already captured at the spec memory level via the B.6.a
substrate-vs-consumer note; no new feedback memory warranted —
the pattern hasn't generalized beyond effects-spec scope yet.

## Sketch-and-pause: when to use it

This session opened with a sketch-and-pause for B.7 substrate
architecture. Worth pinning when it's the right move:

- **Architecture-defining call**: HostSlotCtx's shape, callback
  ownership, error model. These are decisions that bind every
  future host_slot consumer (Phase D matryoshka). Once committed,
  refactoring costs scale with consumer count.
- **Decisions with ratchet effects**: the `*anyopaque` typing call
  was easy to make at sketch time, would be costly to roll back
  once any host imports `spark.HostSlotCtx`.
- **Sufficient context to reason**: Christian and I both had full
  picture of single_source's dispatch shape (reference
  implementation), so the gap was strictly the host_slot-specific
  contract. No exploratory work pre-sketch.

When sketch-and-pause is the WRONG move:

- **Mechanical extension** of an existing pattern — the herd-the-
  compiler-errors flow that drove the substrate's bulk
- **Single-consumer details** that don't bind external code
- **Anything where running the code is faster than discussing the
  spec**

Roughly: sketch-and-pause when committing the line in code costs
more than discussing it in chat. B.7 substrate cleared that bar
(public API surface for matryoshka adoption); B.7 consumer didn't
(test-only factory whose shape doesn't bind anything).

## What's next

Outstanding for fully closing v1 — none. Spec acceptance bars all
met:

- ✅ `:::gradient` visible end-to-end (Phase A close)
- ✅ `:::drop_shadow` visible on Lab card (B.5)
- ✅ `:::frosted_glass` visible (B.6.b)
- ✅ `:::liquid_glass` visible (B.6.d — bonus, not in spec)
- ✅ Per-effect determinism locked in test substrate (B.8)
- ✅ Two-Spark isolation under effect-using docs (B.8)
- ✅ FPS canary within 5% (Christian's 6K fps Release run)

Phase C (chain effects: `:::bloom`, `:::tone_map`) is the natural
next spec — matryoshka has a working dual-filter bloom chain to
crib patterns from, and HDR format negotiation is the one
architectural piece v1 deliberately didn't solve. Phase D
(`:::3d-scene` matryoshka adoption) inherits B.7's
HostSlotCtx contract unchanged.

Neither is queued yet. v1 effects-spec is done; next session opens
fresh.

## Voice notes

The unilateral design call (dropping factory defaults) is the one
piece of this session worth thinking about for the next sketch
flow. Christian's "Totally fine with the call you made" makes the
right thing to do in future cases clear: make the call,
*explicitly flag it at commit time*, trust the post-hoc redline
loop. The structural failure mode is silent unilateral changes
that bury under a "feat:" commit message and surface as confusion
two sessions later.

End of session 24. Three SHAs, v1 effects-spec closed, 6K+ fps on
effect-heavy doc, partner's new glasses arrived. Good day at
Milliways.
