# spark — session 22 journey

2026-05-19, second session of the day. Effects-spec Phase B
substrate (B.1 → B.4.b) lands the GPU plumbing for offscreen-target
effects; Phase B.5 ships the first user-facing single_source
factory (`:::drop_shadow`); the same factory validates
end-to-end through matryoshka's cooperative-embed. The
substrate-first discipline that ran through Phase A holds here too,
but Phase B is where it earns its keep — the substrate smoke tests
verify the API surface, six bugs surface only once a real factory
drives the substrate, and one final keystone bug (a Phase 1 / SSBO
timing trap) surfaces only once a real consumer (matryoshka) drives
the factory.

Commits this session:

```
961e434 polish: B.5 demo — dim cool gray clear color
8c33859 polish: B.5 demo visibility — light surface + teal hex literal
6e1cf7d fix: B.5 substrate — drop_shadow renders end-to-end
64de156 fix: B.5 — descriptor pool per-frame-slot families for multi-frame-in-flight
b666ab6 fix: B.5 — cache pass_dispatches across hits + clamp scissor offset
aaf1981 fix: B.5 — mergePrivatePassDispatches must translate layout/compose regions
f4ff7ff fix: B.5 — skip-past-subtree fencepost in three iteration sites
cb948a5 polish: B.5 — parallel walker pd race + pre_draw_fn ordering
e63a385 feat: effects B.5 — :::drop_shadow factory (first visible single-source filter)
b4f2d81 feat: effects B.4.b.4 — rasterizer per-target subrange routing
42ca8bb feat: effects B.4.b.3 — three-phase dispatch processor (structural keystone)
2f4cf98 feat: effects B.4.b.2 — per-frame descriptor pool + reset-cadence symmetry
457f74e feat: effects B.4.b.1 — single-source pipeline cache + copy.frag substrate
cf199f3 polish: B.4.a TODO note + spark.zig PassDispatch union access fix
03df5fd feat: effects B.4.a — drawlist target routing (parallel arrays + emit helpers)
621cc4c feat: effects B.2/B.3 — PassDispatch tagged union + walker single-source emission
d04c148 feat: effects B.1 — TargetPool real implementation
```

Seventeen commits, one continuous arc. The substrate keystone
(`6e1cf7d`) is the load-bearing one — it's where the milestone
becomes visible.

## The plan at session start

Phase A closed in the previous session (A.0 through A.7 + the
spec's locked-in answers migration). The handoff into Phase B was
already sketched in the spec: B.1 (TargetPool real impl) lands the
allocator that single_source effects consume; B.2/B.3 extend
PassDispatch into a tagged union (`.pattern` / `.single_source` /
…) and teach the walker to emit `.single_source` entries with
subtree-range capture; B.4.a wires drawlist primitives into per-
target parallel arrays so quads/glyphs/tris/images can be routed
into either the main attachment or an offscreen target; B.4.b
brings up the GPU machinery (compose pipeline cache + descriptor
sets + the three-phase dispatch processor that orchestrates Phase
1 offscreen passes, Phase 2 main attachment, Phase 3 release);
B.5 lands the first user-facing single_source factory.

Christian's framing at session start, preserved verbatim because
it set the cadence:

> the spec is the task list

No TaskCreate. Per-phase commits as progress markers. Sub-letter
ordering (B.4.b.1, .2, .3, .4) when a phase naturally splits.
Worked cleanly through the whole arc.

## Phase B.1 — TargetPool real implementation

The TargetPool stub from A.3 (`acquire` / `release` `@panic("Phase
B: …")`) gets its real body. Pool keyed by `(width, height,
format)`; entries are VkImage + VkImageView + VkDeviceMemory
triples allocated lazily on first `acquire`, returned to the pool
on `release`, swept on frame-end. The "sweep" catches any
straggler that wasn't released (a panic-path failure between
acquire and release would leave a handle outstanding — the sweep
catches it before next frame).

Mid-frame ref-count discipline (Decision #4 from the spec) didn't
land here — the simplest acquire/release with a frame-end sweep
covered the substrate-test cases. Will revisit when a real
multi-consumer chain effect (Phase C bloom) drives the count
above 1.

Per-Spark sibling field per [[feedback-spark-sibling-fields]] —
TargetPool is engine-owned state, lives alongside the other
per-instance allocators. No promotion to a wrapper struct.

`d04c148`. Tests: lifecycle (acquire → release → reuse same
handle), key-isolation (different `(w, h, format)` returns
different handles), per-Spark isolation (two TargetPools allocate
distinct images).

## Phase B.2/B.3 — PassDispatch as tagged union, walker emits

The A.6.a PassDispatch was a flat struct (shader_id, region,
uniforms). Phase B needs it to fork: `.pattern` arms render
in-place into the parent attachment; `.single_source` arms wrap a
child subtree, render it into an offscreen target, then composite
back. The two need different payload shapes — pattern's region IS
the draw bounds; single_source's region is the COMPOSE bounds with
a separate `target_size` and a `subtree_dispatch_range` capturing
which pd entries fall inside its subtree.

Tagged union shape:

```zig
pub const PassDispatch = union(enum) {
    pattern: PatternStep,        // existing A.6.a shape
    single_source: SingleSourceStep,  // new B.2/B.3 shape
};

pub const SingleSourceStep = struct {
    target_size: [2]u32,
    filter_shader_id: ShaderId,
    filter_uniforms: [MAX_PASS_UNIFORM_BYTES]u8,
    filter_uniforms_len: u32,
    compose_region: PassRegion,
    subtree_dispatch_range: [2]u32,  // half-open [start, end)
    sequence_index: u32,
};
```

Walker change in `element_layout.zig`'s `.custom` arm: for
`pass_kind == 2` (single_source), capture
`dispatch_start = pd.items.len` BEFORE walking the child, walk,
then append the `.single_source` dispatch with
`subtree_dispatch_range = [dispatch_start, seq]` where `seq =
pd.items.len` POST-walk. Any pattern dispatches the child emitted
fall naturally inside this range. No recursive data structure
needed — the range IS the nesting.

Wire format hash extension: integration_render's `hashFrame` walks
the union with an exhaustive switch. Tagged union variant tags hash
into the fingerprint so a future re-ordering surfaces immediately
in the determinism test.

`621cc4c`.

## Phase B.4.a — drawlist routing (parallel target arrays)

The trap B.4.a solves: when a `.single_source` factory wraps a
child, the child's drawlist primitives (the box quad, any glyphs,
any tris) need to render into the offscreen target — not the main
attachment. Pre-B.4.a, every drawlist primitive landed on the main
attachment unconditionally.

Solution: parallel target-tag arrays alongside each primitive list
in DrawList:

```zig
pub const DrawList = struct {
    quads: std.ArrayList(QuadInstance),
    quad_targets: std.ArrayList(u32),   // NEW: per-quad tag
    glyphs: std.ArrayList(GlyphInstance),
    glyph_targets: std.ArrayList(u32),  // NEW
    tris: std.ArrayList(TriVertex),
    tri_targets: std.ArrayList(u32),    // NEW (parallel to tris, not tri_indices)
    images: std.ArrayList(ImageDraw),
    image_targets: std.ArrayList(u32),  // NEW
    ...
};
```

Tag values: `MAIN_TARGET = maxInt(u32)` is the sentinel for "main
color attachment, no offscreen routing"; any other value is the
INDEX into pass_dispatches of the single_source dispatch whose
target this primitive should render into.

Walker push/pop in the `.custom` arm:

```zig
const saved_target = ctx.current_target_dispatch_index;
if (cu.pass_kind == 2 and ctx.pass_dispatches != null) {
    ctx.current_target_dispatch_index = dispatch_start;
}
defer ctx.current_target_dispatch_index = saved_target;
// ... walk child here; appendQuad et al. tag with current_target_dispatch_index
```

Emit helpers (`appendQuad`, `appendGlyph`, etc.) write the current
target tag into the parallel arrays at append time. The iteration
helper `element.runs(targets, target_idx)` yields contiguous index
ranges matching a given target — clean for Phase 1's per-target
draw recording later.

Wire format v3: target arrays hash into the fingerprint.

`03df5fd` + `cf199f3` (the latter a follow-up fix where I'd missed
the PassDispatch union-access pattern in a switch — `pd[i].pattern`
vs `pd[i].single_source` instead of the post-Phase-A flat-struct
field access).

## Phase B.4.b — the GPU substrate (4 sub-commits)

The biggest piece of Phase B. Splits naturally into four:

**B.4.b.1 — single_source pipeline cache + copy.frag substrate.**
`SingleSourcePipelineCache` parallels `PatternPipelineCache`'s
shape but with a different descriptor-set layout (combined image
sampler at slot 0 for sampling the offscreen target) and a shared
fullscreen vertex shader. First registered shader is `copy.frag`
(literally `out_color = texture(u_target, v_uv)`) — substrate
smoke test, not a real effect. Per-Spark sibling field on Spark.
Pipeline state: stateless overlay, premultiplied-alpha blend, no
depth, dynamic viewport + scissor. `457f74e`.

**B.4.b.2 — per-frame descriptor pool + reset-cadence symmetry.**
`SingleSourceDescriptorPool` owns a chain of `VkDescriptorPool`
allocations, hands out sets via `acquire(view, sampler)`. Resets
at frame boundary via the same reset-cadence Spark already uses
for the target pool — kept symmetric so any future GPU resource
that needs per-frame lifetime slots in next to these without
inventing a third cadence. `2f4cf98`.

**B.4.b.3 — three-phase dispatch processor (the structural
keystone).** The orchestration that turns a flat
`pass_dispatches` list into ordered Vulkan command-buffer
recording:

- **Phase 1** (`dispatchOffscreenPasses`, called from preDrawCb):
  forward iteration over pd with skip-past-subtree — every
  `.single_source` recursively processes its subtree (nested
  patterns + nested single_sources) into the offscreen target,
  barriers target to `SHADER_READ_ONLY_OPTIMAL`, stores target
  handle in `dispatch_target_map[index]` for Phase 2 lookup.
- **Phase 2** (`endFrame`'s main pass loop): iterates pd again
  with the same skip-past-subtree shape. Top-level `.pattern`
  arms render directly to main attachment. Top-level
  `.single_source` arms compose-sample their pre-rendered targets
  via descriptor sets bound at Phase 2 time. Per-target
  rasterizer routing for MAIN renders quads/glyphs/tris/images
  tagged with `MAIN_TARGET`.
- **Phase 3** (end of `endFrame`): wholesale-releases every Phase 1
  acquire back to the target pool. Symmetric with Phase 1's
  acquires.

Same iteration shape in both Phase 1 and Phase 2 — adding a future
union arm means changing one switch in two places, not redesigning
either loop. `42ca8bb`.

**B.4.b.4 — rasterizer per-target subrange routing.** Phase 1
needed a way to render only the subset of drawlist primitives
matching a given target index, into that target's framebuffer.
Extended each pipeline's `recordDraw*` API with a `firstInstance`
+ `instanceCount` (for instanced pipelines) or `firstIndex` +
`indexCount` (for tri); Phase 1 iterates `element.runs(...,
dispatch_index)` and issues one draw per run. By walker
construction, a target's primitives form ONE contiguous run per
pipeline type — the iterator tolerates multiple runs as a
generality. `b4f2d81`.

At end of B.4.b, the substrate is in place. No factory consumes
it yet. `copy.frag` is the only registered single_source shader.
The substrate tests pass.

## Phase B.5 — `:::drop_shadow` (the visible milestone)

The first user-facing single_source factory. Architecturally
simple — `Factory.pass_shape = .{ .single_source = .{ .shader_id
= ..., .layout_inflation = .{ .from_params = computeInflation } }
}`, parses spec attrs (`blur`, `offset_x`, `offset_y`, `color`),
computes an inflation Edges from those, holds a `DropShadowUniforms`
extern struct (std140-padded) for the GPU compose. Wraps child
content; layout returns the inflated box so `target_size = inflated
box.{w,h}` (invariant: inflation flows through layout AND the
walker's target_size via the same Edges value).

Shader: 9-tap box blur over an offset-shifted sample of the
target's alpha. v1 — calls itself out as v1 in the file header
("Real gaussian blur is a Phase C optimization"). Sufficient for
the visible milestone.

`e63a385`.

It built. Smoke-tested clean. Then I asked Christian to verify
visually, and the six-bug iteration started.

## The six bugs that surfaced during B.5 verification

None of these were caught by the substrate smoke tests. Each
surfaced from a real-factory + real-runtime interaction the smoke
suite was structurally blind to.

### Bug 1 — parallel walker pd race (cb948a5)

`std.ArrayList(PassDispatch).ensureTotalCapacityPrecise` panic from
worker threads racing on `append`. The walker's `.custom` arm both
reads (for dispatch_start / seq capture) and writes (for the
dispatch emission) `ctx.pass_dispatches` — and the parallel walker
was sharing one ArrayList across workers. Concurrent `append`s tore
`items.len` against `items.ptr` during a grow.

Fix: per-worker `private_pd` field on `WalkSpec`, parallel to the
existing `private_dl`. Workers append into their own private pd at
worker-local indices (starting at 0). Merge phase
(`mergePrivatePassDispatches`) appends them into the shared pd at
post-merge positions, offsetting every dispatch's `sequence_index`
and `subtree_dispatch_range` by the merge base. Symmetric with
`blitPrivate`'s positional translation of drawlist primitives.

### Bug 2 — pre_draw_fn ordering (same commit)

`dispatchOffscreenPasses` ran BEFORE `drawCb`'s `layoutAndRender`
populated `pass_dispatches`. So Phase 1 saw an empty pd list →
`dispatch_target_map` sized at 0 → endFrame's Phase 2 accessed
`dispatch_target_map.items[10]` and panicked.

Fix: extend Renderer's `pre_draw_fn` signature with the swapchain
extent, restructure main.zig's `preDrawCb` to do
`attachCmd → beginFrame → layoutAndRender → dispatchOffscreenPasses`
inside it. `drawCb` collapses to just `spark.endFrame()`. The
visible-milestone work all happens before the main pass starts.

### Bug 3 — skip-past-subtree fencepost ×3 (f4ff7ff)

`i = ss.subtree_dispatch_range[1]` infinite-looped on the
single_source itself because the single_source sits AT
`subtree[1]` (walker captures `seq = pd.items.len` BEFORE
appending, then appends at pd[seq]). So `subtree_dispatch_range
= [10, 10]` means "subtree is empty AND single_source is at
index 10." Advancing by `subtree[1] = 10` keeps `i` at 10.

Fix: `i = ss.subtree_dispatch_range[1] + 1` in three iteration
sites (Phase 1 top-level, Phase 1's recursive nested loop, Phase
2's main attachment loop). Same fix mirrored everywhere.

### Bug 4 — mergePrivatePassDispatches region translation (aaf1981)

All patterns/composes rendered at (0, 0) when walked in parallel
workers. Workers compute positions at their own origin (0, 0); the
merge phase translates DRAWLIST primitives by `child_origin` via
`blitPrivate`, but never translated the pd entries' regions. So
`layout_region.x/y` stayed at worker-local zero.

Fix: extend `mergePrivatePassDispatches` to take the same `origin`
parameter and translate `pattern.layout_region` + `single_source.
compose_region` by `(ox, oy)` to match `blitPrivate`'s drawlist
translation. Same value flowing through both — can't drift.

### Bug 5 — cache pass_dispatches loss across frames (b666ab6)

Patterns disappeared after frame 1. Layout cache stored drawlist
content but not pass_dispatches; cache hits silently dropped
dispatches because `blitEntry` had no path to replay them.

Fix: add `Entry.pass_dispatches` field. `snapshotEntry` dups the
slice + translates to block-local (regions relative to (0, 0),
indices relative to 0). `blitEntry` translates back by current
origin + offsets indices by current pd base. Full snapshot/blit
symmetry — same shape as the drawlist primitives.

Also in the same commit: negative scissor offset on scroll
(`vkCmdSetScissor offset.y (-6) is negative`) when an effect
scrolled partly off-screen. Clamp via `@max(0, @round(vx))`.

### Bug 6 — descriptor pool reset race under MAX_FRAMES_IN_FLIGHT=2 (64de156)

`vkResetDescriptorPool ... currently in use by VkCommandBuffer`.
The renderer keeps 2 frames concurrent; resetting frame N's
descriptor pool while frame N's GPU work is still running
invalidates sets that are referenced by an in-flight command
buffer.

Fix: `SingleSourceDescriptorPool.advance()` rotates between
per-frame-slot Families. Each Family owns its own pool chain;
frame N writes/acquires into family[N % 2]; rotation at frame
start resets the NEWLY-active family (which the OTHER family had
last used 2 frames ago — well past GPU completion). Per-slot fence
already serializes the per-slot lifetime.

This is the classic multi-frame-in-flight reset hazard. Substrate
smoke tests run synchronously without multi-frame pacing — the bug
was structurally invisible to them.

---

After all six fixed, the smoke ran clean. Christian re-tested
interactively. The box showed up at the wrong place (cache
re-tagging — see below), then after a `disable_cache = true`
workaround, the box vanished entirely.

The seventh bug — the keystone — was about to surface.

## The keystone bug — Phase 1 SSBO timing trap + world_offset

Christian: "Hmm — no shadow. There is something else as well. If
I resize the window, the magenta box disappears momentarily — then
it comes back a second later. Kind of the opposite of what we were
seeing with the other shader areas."

Then after `disable_cache`: "the magenta (now teal) box is not
rendering at all."

I almost talked myself out of trusting that observation by asking
"are you scrolling to the section?" Christian — who'd been
scrolling — pushed back: "Yes, of course I'm scrolling. lol. The
box *used* to show up at 64de156 — but a lot has changed between
then and now."

[[feedback-trust-physical-observation]] — exactly the case it
exists for. Stopped second-guessing, started diagnosing.

### What was happening

Two bugs masking each other. Independent, both real, both fixed
in the same SHA.

**Bug 7a — cache re-tagging.** The block layout cache's
`blitEntry` re-tags cached drawlist primitives with the OUTER
walker's `lc.current_target_dispatch_index`. The walker's
`.custom` arm is bypassed on cache hit — so for a single_source
factory wrapping rasterizer content, the wrapped child's
quads/glyphs get tagged with `MAIN_TARGET` instead of the
offscreen dispatch index. Content draws on the main attachment AND
the compose dispatch samples an empty target.

Pre-disable_cache, this was the visible symptom (magenta box at
wrong position, no shadow). The cache hit re-tagged the box, it
rendered on main attachment in world coords, and the resize
transient ("box disappears, then comes back") was the cache
invalidating + repopulating across a frame.

`disable_cache = true` workaround on drop_shadow's vtable: forces
a fresh walker pass every frame, the `.custom` arm fires, target
tagging is correct. Proper fix (store target tags in cache
entries + replay-with-offset on blit, mirror of `blitPrivate`'s
`rebaseTargets`) deferred to when B.6's `:::frosted_glass`
forces it — second consumer is the YAGNI-but-not-too-aggressively
forcing function.

**Bug 7b — Phase 1 SSBO timing.** With cache disabled, the box
quad's target tag was correct (dispatch_index = 10). Phase 1's
per-target routing fired. The compose ran. Nothing visible.

Diagnostic round 1: temporarily set the offscreen target's clear
color to magenta. Christian's screenshot showed a magenta
rectangle at the compose region — but no teal box inside. That
confirmed: compose works, target is initialized, but the box quad
never landed in the target.

The actual trap, once I stopped pattern-matching and started
tracing operation order:

> Phase 1 RECORDS its draws in `preDrawCb`, but the SSBO upload
> happens later, in `endFrame`'s `writeQuads/writeMesh/writeGlyphs`
> after the world→screen transform on the drawlist. Vulkan
> executes recorded draws in submission order with the SSBO state
> AT SUBMIT TIME — so by the time Phase 1's draws actually
> execute on GPU, each instance's `dst_pos` is already
> `(world - scroll) * zoom`. Not the world coords the walker
> emitted.

I'd been computing `world_offset_target = compose.world.xy`
(WORLD coords). The SSBO had SCREEN coords. The subtraction
produced nonsense NDC; the box's vertices fell outside the clip
volume; the triangle was culled; the target stayed empty; the
compose sampled magenta-clear.

Captured to memory as [[project-ssbo-phase1-timing]].

### The fix shape

Initial proposal: negative-viewport + 16384-dimension trick (set
viewport.x = -compose.x, viewport.width = 16384, push viewport_size
= 16384). Mathematically correct but Christian pushed back hard:

> The math is non-obvious — anyone debugging an offscreen-target
> rendering issue 6 months from now reads viewport = (-1580, ...,
> 16384, 16384) and has to reverse-engineer the trick before they
> can think about their bug.

Plus device-limit dependence (`maxViewportDimensions` minimum
guaranteed is 4096×4096 per spec, `viewportBoundsRange` minimum is
`[-8192, 8191]`) and the trick doesn't compose with Phase C's
multi-resolution chain passes.

His counter-proposal: add `world_offset: vec2` push constant to
each rasterizer pipeline. Vertex shader becomes:

```glsl
vec2 local_pos = world_pos - world_offset;
vec2 ndc = local_pos / viewport_size * 2.0 - 1.0;
```

Main target callers pass `(0, 0)`, math collapses to existing
transform. Offscreen-target callers pass `compose.screen.xy`
(SCREEN, because of the SSBO timing trap). Three readable steps
in the shader; no device limits; composes with future Phase C
mips; same plumbing unlocks future "render this primitive at a
different position than its world coord suggests" features
(sticky tooltips, drag-preview overlays).

I implemented it across all four rasterizer pipelines (quad,
text, tri, image) + matching shader updates + `comptime` size
lock-ins per the std140 discipline + the SSBO-timing-aware
SCREEN-coord computation in Phase 1's per-target routing.

Captured to memory as
[[feedback-explicit-over-clever-gpu]].

`6e1cf7d`. The shadow showed up — teal box with dark blurred halo
offset down-right against the dim background.

## Matryoshka validation — compound-app milestone 2

Christian: "Okay dokey — I'll try it out in Matryoshka itself,
then we can start a new session — after acceptance."

Yesterday's milestone (2026-05-18) banked the basic matryoshka
adoption: spark HUD with sliders + sparkline rendering inside
matryoshka's path tracer at 61 fps. Today's milestone is
substrate-evolution validation: does B.5's GPU substrate (Phase 1
offscreen passes + descriptor pool + per-target rasterizer
routing) carry through matryoshka's cooperative-embed unchanged?

Matryoshka's integration test was an honest one — wrap matryoshka's
Lab card header in `:::drop_shadow { :::box { … } }`. No
matryoshka-side code changes; just markup.

First-run result: drop_shadow halo rendered around a magenta
rectangle. The matryoshka-side agent flagged it as a substrate
propagation failure (failure mode (a) from its pre-flight
prediction).

It wasn't. The substrate WAS propagating — drop_shadow's halo was
visible, meaning Phase 1 + compose + descriptor pool all carried
through. The magenta was spark's `:::box` color-fallback indicator
(designed behavior: "missing color → opaque magenta so authors
spot the typo"). Matryoshka's markup hit two spark limits at once:

1. `:::box {style="card"}` — spark's box doesn't recognize a
   `style` attribute; `style="card"` was ignored, no color
   provided, fallback fired.
2. `:::box` is a leaf component — it doesn't render child content
   (its `body` is treated as an `handleUpdate` target field, not
   inline children). The heading + paragraph inside `:::box { …
   }` weren't being rendered.

After the markup change (drop the `:::box` wrap, let drop_shadow
wrap heading + paragraph directly), Christian's screenshot showed
the shadow rendering on the actual "Lab" heading text in
matryoshka's HUD. Milestone 2 banked.

The shadow on text reads as a stippled-ghost of the glyph shapes
rather than a smooth halo — that's the 9-tap box blur's known
limitation, exactly what `drop_shadow.frag`'s header already calls
out as Phase C work (separable two-pass gaussian with proper
weighted taps). The substrate is the load-bearing part and it
holds.

## What B.5 proved about substrate-vs-integration testing

The matryoshka-side agent's framing, preserved because it's a
clean general lesson:

> Substrate smoke tests verify the API surface; end-to-end
> integration tests verify the GPU-pacing / runtime-context
> reality. Both classes matter and neither subsumes the other.

The two SHOWCASE B.5 bugs that prove this isn't theoretical:

- **world_offset / SSBO timing.** Substrate smoke tests verified
  the per-target draw-recording APIs work. They couldn't catch
  "the rasterizer pipelines' NDC transform uses viewport_size as
  denominator, dst_pos in world coords, but the SSBO at submit
  time has SCREEN coords" without an end-to-end factory driving
  rasterizer content into an offscreen target.
- **Per-frame-slot descriptor pool families.** Smoke tests run
  synchronously without `MAX_FRAMES_IN_FLIGHT` pacing — frame N+1
  starting before frame N's GPU work completes is structurally
  invisible to synchronous tests. Surfaced only when the compose
  dispatch ran across multiple in-flight frames.

Captured to memory as
[[feedback-smoke-vs-integration-testing]]. Generalizes to every
future substrate↔factory interface — Phase B.7's HostSlotPass when
matryoshka's `:::3d-scene` lands, Phase C's ChainPass when bloom
arrives.

## Memory captures this session

Four new memories in `~/.claude/projects/-home-chrisbe-dev-terminal/
memory/`:

- [[feedback-explicit-over-clever-gpu]] — prefer explicit shader-
  level transforms over clever viewport-state tricks; the magic-
  constants approach loses to self-documenting math even when
  mathematically equivalent.
- [[project-ssbo-phase1-timing]] — `dispatchOffscreenPasses`
  records draws in preDrawCb but reads SSBO state set by
  endFrame's later upload; any Phase 1 push constant that
  coordinates with drawlist positions must live in SCREEN coords.
- [[feedback-smoke-vs-integration-testing]] — substrate smoke
  verifies API surface; integration verifies GPU-pacing reality;
  both needed.
- (Updated [[project-spark-effects-spec]] to mark B.5 visible
  end-to-end; updated [[project-spark-libraryification]] to add
  the 2026-05-19 second compound-app milestone.)

## Verification

- Substrate tests (B.1 — TargetPool lifecycle, key isolation,
  per-Spark isolation): green throughout.
- B.4.b smoke tests (single_source pipeline cache, descriptor
  pool, three-phase dispatch with copy.frag): green.
- B.5 lifecycle test (drop_shadow create → update → deinit,
  inflation correctness, target_size invariant): green.
- `zig build test` end-to-end: exit 0.
- `spark_demo src/effect.md`: 5764 frames in 2000ms smoke run,
  no validation errors, no panics.
- Visible verification: teal box with dark blurred halo at the
  drop_shadow position in spark_demo (Christian's screenshot).
- Matryoshka cooperative-embed validation: drop_shadow on Lab
  heading text in matryoshka HUD (Christian's screenshot).

## What's next

Phase B continues. B.6 (`:::frosted_glass`) is the natural next
piece — same shape as drop_shadow (single_source filter), simpler
shader (single-pass blur + alpha tint, no offset), but the
forcing function for the cache-target-tags proper fix. If both
drop_shadow AND frosted_glass need `disable_cache`, the proper
fix (store target tags in cache entries + replay-with-offset on
blit, mirror of `blitPrivate.rebaseTargets`) earns its place.

Then B.7 (`:::placeholder_scene` HostSlotPass stub) closes the v1
union-arm coverage — wires the `.host_slot` arm reserved-but-
unused since A.2. Test-only registration, not in
installCoreComponents, clear-to-color callback. The lockfile
against Phase D's matryoshka `:::3d-scene` integration.

Then B.8 (acceptance wrap): lock-in migration for at least three
more decisions (D#4 target pool semantics, D#15 nested recursion,
D#7 LDR contract), Phase B journey, memory updates, FPS canary
against the pre-Phase-B baseline (acceptance criterion: within 5%;
drop_shadow is the most expensive single effect, makes the
meaningful measurement).

Matryoshka-side: a `:::card` factory at some point. Drop_shadow +
a card surface gives the natural "elevated card" visual idiom.
5-10 LOC factory in matryoshka's component-registration site,
composes spark's existing primitives. Future-session work.

## What carried forward cleanly

- Substrate-first discipline. B.1 → B.4.b shipped before any
  factory. The substrate APIs survived first contact with the
  consumer (drop_shadow) without API changes.
- Per-Spark instance ownership. Two-Sparks-one-process correctness
  inherited from session 19's `_ref` purge + session 20's
  `two_instances.zig` test. The B.4.b additions (single_source
  pipeline cache, descriptor pool families) all slotted in as
  sibling fields per the [[feedback-spark-sibling-fields]]
  pattern. Zero process-globals.
- Wire format stability. `integration_render.zig`'s hash gate
  caught two would-be silent drift cases during B.2/B.3 and B.4.a
  — the fingerprint changes when the union variant tag changes,
  forcing a deliberate decision rather than a silent breakage.
- Christian's "the spec is the task list" cadence. Seventeen
  commits in one continuous arc, per-phase progress markers, no
  parallel tracking overhead.

## What hurt

- The diagnostic round on the keystone bug took longer than it
  should have. I went through three rounds of speculation before
  I started actually tracing operation order. The
  [[feedback-trust-physical-observation]] reminder is exactly the
  kind of trap that surfaces when "my logs/math say it should
  work" rather than "let me trace the actual lifecycle." Christian
  caught me almost dismissing his "no box" report as a scroll
  position question — second-guessing the report instead of
  diagnosing.
- The cache re-tagging bug was diagnosed correctly but the
  workaround (`disable_cache = true`) was applied without
  recognizing it would unmask the SSBO timing bug. Two bugs were
  cancelling out to produce one observable symptom; fixing one
  without the other made the milestone worse, not better. Worth
  pinning as a category: when a workaround makes things WORSE,
  that's diagnostic information about a second bug being masked.

Phase B.5 lands clean. The substrate proved itself through real
factory consumption and real compound-app integration. The
cooperative-embed contract survived its first substrate-evolution
test. The path forward to B.6 → B.7 → B.8 is now well-scoped.

🪆
