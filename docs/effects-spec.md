# spark — effects-spec (Factory-shaped shader effects)

Locked 2026-05-19. This spec covers the work to extend spark's
`Factory` contract so shader-driven visual effects (gradients, drop
shadows, frosted glass, and — in the called-out roadmap — bloom,
tone-mapping, and `:::3d-scene`) become first-class components,
declared in markdown alongside `:::box` and `:::chart`, scoped
structurally by the document tree, and resolved through the same
provenance ladder.

## Context

`Factory` is provenance-agnostic. `Factory.create(*Spark, allocator,
spec) -> Component` doesn't care where the implementation came from
or what kind of work the resulting component does on render. Every
component shipped so far has been *content* — emitting glyph quads,
triangles, and image draws into the renderer's draw lists. Nothing in
the contract requires that. A component whose rendering is a fragment
shader pass over a region, or a single-source filter applied to its
child's render, fits the same shape.

The composition story is the unlock. The matryoshka-side agent put it
plainly in the jam: matryoshka's post chain (composite → bloom_down/up
→ TAA → post) is a fixed, hand-wired pipeline today — fast,
opinionated, integrated. Decompose those passes into Factory-shaped
components and the same vocabulary that author HUD elements
(`:::box`, `:::chart`, `:::slider`) spans 2D *and* 3D effects
identically. Drop-shadow on a HUD panel and bloom on a 3D scene
become the same kind of declaration. The compositor stops being a
monolith and joins the LEGO bucket.

After this spec lands, an author can write:

```markdown
:::drop_shadow blur=8 offset_y=4 alpha=0.4
  :::box style="card"
    ## Lab
    *Spark + matryoshka, one VkDevice, one cmd buffer per frame.*
  :::end
:::end

:::gradient from=#1a1a2e to=#16213e direction=vertical
:::end

:::frosted_glass blur=12 tint=#ffffff10
  :::box style="overlay"
    Tools panel
  :::end
:::end
```

And the spark pass-graph compiler reads the tree, allocates transient
offscreen targets where needed, dispatches the shaders, and composites
back — all inside the host's existing render-pass scope, no library-
owned scope wrapping. Same cooperative-embed shape library-spec
already locked.

This spec is the **architectural sibling** to `library-spec.md`. That
one made spark a library cooperative-embedded into hosts. This one
makes shader effects first-class inside spark — and lays the path for
matryoshka's post chain to decompose into the same vocabulary later,
when matryoshka library-ifies.

## In scope (v1 — Phases A and B)

- `Factory.pass_shape: PassShape` extension. Existing components default to `.content` and behave unchanged.
- **Pattern-pass components** (Phase A): fragment shader, no input texture, drawn into a layout region. Canary set: `:::gradient`, `:::pattern`, `:::noise`.
- **Single-source-pass components** (Phase B): child renders to an offscreen target, shader filters that target, result composites back. Canary set: `:::drop_shadow`, `:::frosted_glass`, `:::blur`.
- Pass-graph compiler — walks the document tree, produces an ordered render plan for effect components.
- Transient render-target pool keyed by `(width, height, format)`, ref-counted, **mid-frame release on dispatch-complete + frame-end sanity sweep** (see Decision #4).
- Layout-bounds inflation hook so `:::drop_shadow blur=8` makes its parent reserve +8px so the shadow doesn't clip.
- Built-in SPIR-V binaries for the canary shader set, embedded in spark.
- Effect components register via `installCoreComponents` — core surface, not extras.
- Tests: extend `library_lifecycle.zig`, `two_instances.zig`, `integration_render.zig` to cover effect components.
- The Lab card in `examples/minimal_host.zig` gets `:::drop_shadow` — the visible Phase B deliverable.

## Out of scope (called-out roadmap, not in v1)

- **Phase C — chain effects.** `:::bloom`, `:::tone_map`, multi-pass sequences with intermediate downsampled targets, HDR format negotiation across the chain. Architecture admits the `ChainPass` variant; v1 doesn't ship it.
- **Phase D — `:::3d-scene` host slot.** `HostSlotPass` variant. Factory accepts a host-provided render callback that fills a target. Matryoshka's adoption path. Spark-only default is a clear-to-color or "scene unavailable" placeholder. v1 doesn't ship the variant.
- Compute dispatch for effects. Fragment-only in v1.
- Global HDR pipeline. Per-target opt-in via factory metadata only.
- Hot-reload of shader source from disk.
- Remote / WASM / inference shader provenance rungs. `ShaderId` indirection reserves the door; v1 implements built-in embedded SPIR-V only.
- Animation curves and time-based parameters beyond a simple `time` global if a canary shader needs one.
- Layered effects on one element via flat decoration (use nesting in v1).
- User-defined custom shaders from markdown (`:::shader src="..."`). Future when the provenance ladder is built out.
- Cross-document effects (applying an effect across an `:::embedded-document` boundary).

## Related precedent — library-spec and the cooperative-embed shape

This spec leans heavily on what library-spec already locked:

- **`Factory.create(*Spark, allocator, spec)`** stays the same first argument. Effect factories get the same Spark context; their `create` body builds whatever pipelines or descriptor sets they need from `spark.vk_ctx` + `spark.color_format`. No new factory entry point.
- **Cooperative-embed scope.** Spark records into the host's `vkCmdBeginRendering` scope (library-spec decision #2 revision, session 19). Effect dispatches record into the same scope. No library-wrapped scope. Same applies inside whatever scope matryoshka (Phase D) ends up handing for the 3D-scene target.
- **Per-Spark instance ownership.** Transient target pool, pass-graph compiler state, uniform buffer pool — all live on `*Spark` per the `_ref` purge from Phase 1. Two Sparks in one process stay isolated for effects too. `two_instances.zig` extends naturally.
- **Document-tree as composition.** Effects scope structurally — `:::drop_shadow` applies to its child block. No global flags. The pass-graph compiler walks the tree the same way layout already does, and produces the render plan as a side effect.
- **Update wire format.** `:::update {#id action=set-X value=Y}` lands in `handle_update`, which memcpys into the effect's uniform buffer. Same path the slider uses today for state writeback. `${state.X}` binding rebinds via the existing resolver.

The matryoshka HUD that ships today (yesterday's screenshot) is the
direct beneficiary of Phase B — the Lab card gets a drop-shadow and
the win is visible same-session it lands.

## Phasing

### Phase A — pattern shaders

**Goal:** Prove the `Factory.pass_shape` extension end-to-end with the smallest possible effect category.

**Deliverables (ordered — A.0 and A.1 land before any effect factory):**

- **A.0 — Determinism hasher extension.** First commit of Phase A. `integration_render.zig`'s Wyhash hasher extends to cover effect-dispatch state: shader id bytes, layout region, uniform bytes, sequence index. Baseline determinism tool for every subsequent effect commit. No effect factory is written before this lands — tool first, feature second.
- **A.1 — Param resolver audit + extension.** Audit the existing param resolver for `vec2` / `vec4` / typed-enum support. Extend as needed — `vec4` is required by `:::gradient` color params, `vec2` by `:::drop_shadow` offset (Phase B), enum direction by `:::gradient`. Lock the resolver's typed-marshalling shape **before** writing the first factory; otherwise every effect inherits ad-hoc marshalling.
- **A.2 — `Factory.pass_shape` field + `PassShape` union.** `.content` default, `.pattern` and `.single_source` variants implemented, `.chain` and `.host_slot` reserved in the type, unimplemented.
- **A.3 — `src/pass/` module skeleton.** Pass-graph compiler, `ShaderId` opaque resolver, transient target pool **stubbed** (Phase A's pattern passes don't allocate offscreen targets).
- **A.4 — glslc build step.** `src/pass/shaders/*.glsl` → `glslc -O` → `zig-out/shaders/*.spv` → `@embedFile` into the binary. See Decision #14.
- **A.5 — Canary factories.** Three pattern shaders with deliberately distinct param-shape sets, exercising the A.1 resolver extension: `:::gradient from to direction` (vec4 colors + enum direction), `:::pattern type seed` (enum + integer), `:::noise seed scale octaves` (integer + f32s). Three factories beats two for resolver coverage at trivial code cost — `:::noise` is a pure-fragment-shader pattern with no new architectural surface.
- **A.6 — Pattern-pass dispatch in pass-graph compiler.** Walks tree, emits fragment-shader dispatches scissored to layout region, ordered always-background per Decision #12. Top-level pattern-pass covers full available canvas.
- **A.7 — Tests.** `library_lifecycle.zig` gains gradient lifecycle. `integration_render.zig` verifies determinism using the A.0 hasher extension.

**Acceptance:**

- `:::gradient from=#1a1a2e to=#16213e direction=vertical` renders a visible gradient in both `spark_demo` and `minimal_host`.
- No regression in existing `two_instances.zig`.
- FPS canary (`SPARK_EXIT_AFTER` instrumented run) within 5% of pre-Phase-A baseline on the standard demo doc.

### Phase B — single-source effects

**Goal:** Drop-shadow on the Lab card in yesterday's screenshot. The visible win.

**Color-space contract.** All Phase B targets are **LDR sRGB**. `hdr_target` is present on `SingleSourcePass` but every Phase B canary factory sets it `false`; the pass-graph compiler asserts `hdr_target == false` in v1. HDR per-target opt-in is deferred to Phase C and explicitly does not regress this LDR path. See Decision #7.

**Deliverables:**

- `SingleSourcePass` variant of `PassShape` implemented (the union arm was reserved in Phase A.2; now active).
- Transient target pool implementation (`src/pass/target_pool.zig`): ref-counted with **mid-frame release on last-consumer dispatch-complete**, frame-end pass as sanity sweep. See Decision #4.
- Layout-bounds inflation hook integrated with `LayoutContext`. Inflation computed **once at `create()` from the Spec** (fixed `Edges` or `from_params` evaluated at create time, never re-evaluated). Dynamic shader-uniform changes animate within the reserved edge. See Decision #8.
- Pass-graph compiler extension: for each single-source component, allocate offscreen → render child subtree into target → dispatch effect shader sampling target → composite into main target at child-region + inflation.
- Built-in SPIR-V for `:::drop_shadow` (separable Gaussian blur + offset composite) and `:::frosted_glass` (single-pass blur + tint).
- **`:::placeholder_scene` — test-only stub factory shaped as `HostSlotPass`.** Forces the `.host_slot` union arm to compile and dispatch end-to-end during v1 with a clear-to-color callback (no actual scene content). Registered only by `integration_render.zig` tests, not by `installCoreComponents`. Prevents the union arm from bitrotting before Phase D lights it up — if you reserve a type variant, you build a call site for it.
- Tests:
  - `integration_render.zig`: a doc with `:::drop_shadow` renders deterministically across two consecutive Sparks. A separate doc exercises `:::placeholder_scene` for `HostSlotPass` compile + dispatch coverage.
  - `two_instances.zig`: target pool is per-Spark (not shared), no leaks under effect-using docs in both instances simultaneously.

**Acceptance:**

- `:::drop_shadow blur=8 offset_y=4 alpha=0.4` around `:::box style="card"` in `minimal_host` produces a visible, correctly-inset shadow with no clipping at parent bounds. **Discoverability:** the `minimal_host` markdown source includes a brief comment block explaining Decision #12's always-background pattern-pass rule — the canonical example is where authors learn the rule.
- The matryoshka HUD demo (the screenshot doc) gets a drop-shadow on the Lab card and the title-bar perf numbers stay within 5% of current.
- Two Sparks each rendering effect-using docs in one process: no leaks, determinism holds.

### Phase C (roadmap — not in v1)

`ChainPass` variant. Multi-pass sequences with intermediate downsampled targets. HDR format negotiation across the chain (bloom needs HDR upstream of tone_map). Built-in chains: `:::bloom threshold intensity radius`, `:::tone_map curve exposure`. Stress-tests the pass-graph compiler at matryoshka-scale.

### Phase D (roadmap — not in v1)

`HostSlotPass` variant. Factory accepts a host-provided render callback that fills an offscreen target with arbitrary content. Spark-only default: clear-to-color or "scene unavailable" placeholder. Matryoshka adoption path: matryoshka registers a `:::3d-scene` factory that calls into its own renderer. Unlocks Phase C effects nested inside `:::3d-scene` applying to the 3D scene's target. The full LEGO bucket.

## Design decisions (override if wrong)

| # | Decision | Rationale |
|---|---|---|
| 1 | `Factory.pass_shape: PassShape` extension, default `.content`. Existing components compile unchanged. | New surface area is opt-in per factory. Zero migration cost for existing code. |
| 2 | `PassShape` is a tagged union: `content` / `pattern` / `single_source` / `chain` / `host_slot`. v1 implements first three (content + pattern + single_source); chain and host_slot variants reserved in the type but unimplemented. | Future phases land as compiler arms, no type churn. |
| 3 | Effects scope structurally by document tree. No global flags. Pass-graph compiler walks the tree. | Falls out of the existing layout walk. Composition is what the tree already encodes. |
| 4 | Transient target pool keyed by `(w, h, format)`. Targets are ref-counted; a target returns to the pool when its **last consumer's dispatch completes** (mid-frame, promptly). The frame-end pass is a **sanity sweep** for any stragglers, not the primary release mechanism. | Mid-frame release is what keeps adversarial nesting (recursive single-source, deep effect trees) from blowing the pool to depth × frame. Frame-end-only release would be unbounded under recursion; ref-count-on-dispatch-complete is bounded by peak concurrent effect siblings. |
| 5 | Flat `:::name` grammar — `:::drop_shadow`, not `:::effect type=drop_shadow`. | Matches existing `:::box` / `:::chart` ergonomics. Same registry shape. |
| 6 | v1 is fragment-only. No compute dispatch. `PassShape` variants don't carry a dispatch-mode field. | Compute deferred to its own arc. Smaller surface for v1. |
| 7 | All v1 targets are **LDR sRGB**. The `hdr_target: bool` field is present on `PatternPass` and `SingleSourcePass` for forward-compat with Phase C, but every v1 canary factory sets it `false`, and the pass-graph compiler **asserts `hdr_target == false`** in Phase B. Phase C lights up the HDR path without type churn. | Avoids landing a half-implemented HDR pathway before the chain story (Phase C) exists. Forward-compat field reserved so Phase C is additive, not a refactor. v1 does not regress the LDR fast path. |
| 8 | `SingleSourcePass.layout_inflation: ?LayoutInflationSpec` — optional, **computed once at `create()` from the Spec** (fixed `Edges` or `from_params: fn (*const Spec) Edges` evaluated at create time, never re-evaluated). Dynamic shader-uniform changes (e.g., `${state.shadow_blur}`) animate **within** the reserved edge but do not re-inflate. Author who needs dynamic-edge inflation recreates the component. | Locks v1 to predictable layout behavior — no state → inflation → layout → constraint-solver cascade. Dynamic blur clamped to reserved edge is a fair trade for v1; dynamic-inflation pathway deferred to a post-Phase-B arc when the cascade cost is properly understood. |
| 9 | `ShaderId` is opaque indirection. v1 implements only the built-in embedded SPIR-V resolver. | Architecture reserves the door for remote / WASM / inference / raw rungs without touching component code. |
| 10 | Effect uniforms are `extern struct` types declared per factory (std140-compatible). `handle_update` memcpys field slots. | Existing update wire-format reuses unchanged. No parallel state plumbing. |
| 11 | Effects register via `installCoreComponents`. They are core surface, not optional or extras. | Effects are vocabulary, not plugins. Authoring expects them present. |
| 12 | Pattern-pass components are **always background** of their parent's region — render *before* the parent's content draw list, **regardless of document order** among siblings. Top-level pattern-pass (`:::gradient` at document root with no parent) covers the **document's full available layout region**. | One predictable rule beats two. CSS-style "last child renders on top" would surprise authors who use `:::gradient` as a backdrop. Pick always-background for v1; document explicitly in the canary tutorial so the rule is discoverable. Re-evaluate post-Phase-B if real authors trip on it. |
| 13 | Pass-graph compiler lives in `src/pass/`, parallel to `src/components/` and `src/extras/`. | Keeps `Spark` struct lean. Mirrors existing module split. |
| 14 | Shader source is **GLSL**, compiled via **`glslc -O`** at build time. Sources live in `src/pass/shaders/*.glsl`; SPIR-V binaries land at `zig-out/shaders/*.spv` and are `@embedFile`'d into the binary. No runtime compilation in v1. | Matches matryoshka's daily-driver toolchain (the "reflection cost effectively zero" win from its post-chain work). Cross-library shader tooling stays consistent into Phase D, when matryoshka registers a `HostSlotPass` factory — both sides compile shaders the same way. |
| 15 | Recursive single-source (`:::drop_shadow` containing `:::drop_shadow`): no recursion cap. Trust the author. | Cap is artificial. Target pool handles the storage cost. Adversarial docs are not v1's problem. |

## Risks / things to watch

1. **Sync barriers between passes.** A single-source pass reads from the offscreen target it just wrote. Color-attachment → shader-read barrier needs to land in the right place. Spark's existing `image_pipeline` handles barriers for image components — pass-graph compiler should emit equivalent barriers, not invent a parallel pattern. **Reference implementation:** matryoshka's `src/vk_renderer.zig` post chain (`post_composite → bloom_down/up → post`) already does color-attachment ↔ shader-read transitions across the dual-filter Bjørge chain. Crib those patterns directly when the compiler lands.

2. **Two-instances correctness.** Per library-spec's headline guarantee. Two Sparks in one process must own their own target pools, their own pass-graph compiler state, their own uniform buffer pools. The `two_instances.zig` test extends naturally — add an effect-using doc to each Spark and verify isolation. Catch any module-global re-introduction the same way the original `_ref` purge was guarded.

3. **HDR mixing across nested effects.** A `:::drop_shadow` with `hdr_target=false` containing a child that itself contains `:::bloom` (Phase C, HDR-requiring). Format negotiation across nested effects. v1 sidesteps via the LDR-only assertion in Decision #7, but the *design* must anticipate Phase C cleanly. **Reference implementation:** matryoshka's post chain runs `post_composite` as RGBA16F, bloom mips inherit the float format, tone-map at `post` collapses to sRGB on present. That's the format-negotiation story Phase C inherits — front-load reviewing its shape against the Phase C `ChainPass` design.

**Resolved by design-decisions table** (pointer for reviewers; migrates to "Locked-in answers" at lock time):

- ~~Pool release timing~~ — resolved by Decision #4 (mid-frame ref-count release + frame-end sanity sweep).
- ~~Layout inflation feedback loops~~ — resolved by Decision #8 (inflation computed once at create-time; dynamic uniforms animate within reserved edge).
- ~~Z-order edge cases~~ — resolved by Decision #12 (always-background, document-order-independent).
- ~~Param-type system for uniforms~~ — promoted to Phase A.1 deliverable (audit + extend resolver before writing the first effect factory).
- ~~Pass-graph determinism~~ — promoted to Phase A.0 deliverable (hasher extension lands first; every Phase A commit verifies determinism through the new path).

## Process notes

1. ~~Matryoshka-side compatibility review~~ — done 2026-05-19. Nine redlines applied: target-pool release timing (D#4), param-type audit promoted to Phase A.1, z-order strengthened (D#12), inflation locked to create-time (D#8), color-space contract added to Phase B, glslc pinned (D#14), top-level pattern-pass region specified (D#12), `HostSlotPass` stub factory added to Phase B, determinism hasher promoted to Phase A.0. Reference-implementation cross-refs to matryoshka's `src/vk_renderer.zig` post chain added to Risks #1 and #3.
2. Christian redlines this updated draft.
3. Iterate on §"Design decisions" if anything still doesn't sit right. Mark anything that doesn't converge as a deferred decision noted in the next session's journey doc.
4. When the table is stable, mark this spec **locked** in its header (change `Drafted` to `Locked`), commit, and start Phase A in the next session.
5. Per-phase rhythm matches library-spec: each phase is a commit chain, journey doc at session close, memory updates kept current.

## Locked-in answers to earlier open questions

Empty until redline + matryoshka review. Decisions migrate from §"Design decisions" here as they survive scrutiny.

## What this unlocks

Immediate (Phase B closes):

- HUD panels with proper drop-shadows. The Lab card gets depth.
- Gradient and pattern backgrounds in markdown. No more solid-color-only HUDs.
- Frosted-glass overlays. Tools panels with the modern OS look — declared in one line.
- A pass-graph compiler proven against the easy cases. Phase C inherits a tested skeleton.

When Phase C lands:

- Bloom and tone-mapping inside HUDs (e.g., a bloomed text card). Spark-side win before matryoshka does anything.
- The pass-graph compiler validated against multi-pass chains at HUD scale. Matryoshka's port is then "register your existing passes," not "redesign your renderer."

When Phase D lands:

- `:::3d-scene` factories. Matryoshka adoption — register a real factory that drives matryoshka's renderer into the spark-allocated target.
- Phase C effects nested inside `:::3d-scene` apply to the 3D scene's render. The same `:::bloom` works on HUDs and on the scene. The compositor decomposes; the LEGO bucket is full.

The bigger arc:

Framer ships shaders as drag-and-drop tools in their Insert Panel.
That's one rung of the component provenance ladder — the built-in
SPIR-V rung. Spark, after this spec, has the *same vocabulary* — and
the architecture path open to remote, WASM-generated, and
LLM-emitted shaders via the `ShaderId` indirection. Effects are
components. Same shape as everything else. Same registry. Same wire
updates. Same authoring grammar. Same provenance flexibility. Drop
shadows on HUD panels, bloom on 3D scenes, animated gradients,
frosted glass, CRT scanlines — all declared in markdown, all
swappable, all reorderable by editing one line.

The compositor decomposes. The graph composes. The author writes a
document.
