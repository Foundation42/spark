# text_engine → spark — session 18 journey
2026-05-18 (same day as 15, 16, 17 — the layout chapter folded into a
library chapter without taking a breath)

Christian's opener:

> Okay, so I was chatting with the agent over in the Matryoshka repo
> regarding starting to align the projects. We wrote up a doc with what
> we think needs to change over here. And btw — text_engine — I thought
> of a name finally — "spark".

Two things land in one message. The project finally has a name. And the
library-ification work — implicit since `chat.md` opened in session 12 —
has a written spec in `docs/library-spec.md`, drafted across two repos
by two agents working with one human.

One commit in:

```
d6f2f4b feat: stage 17 Phase 1 — Spark engine context + module-global purge
```

33 files, +832 / −661. Every component in the registry now reaches the
host's resources through one `*Spark` pointer instead of file-scope
`_ref` globals. The hardcoded SDF "ATTENTION" rainbow paragraph that
opened the demo in session 2 is gone, with notes left at every anchor
point. `text_engine_demo src/hello.md` runs the new FPS canary against
a minimal doc at ~12,965 fps Release.

What follows is the path.

## Naming

"spark" — settled. Short, alive, fits a renderer that's about to be
embedded into matryoshka's HUD layer. The Foundation42 light-and-fire
naming pattern was already audible (valkyr for inference, matryoshka
for the engine). The repo directory and module name still say
`text_engine` — decision #11 in the spec parks that rename as a
mechanical follow-up, not a precondition.

## The spec

`docs/library-spec.md` arrived already drafted — Christian had spent
time with the matryoshka-side agent producing it before this session.
The shape was familiar from a year of cooperative-embed thinking:
host owns Vulkan, library owns atlases/pipelines/cache, per-frame
`layoutAndRender` records into the host's command buffer with
`vkCmdBeginRendering(loadOp=LOAD)`. Five phases — context struct,
core/extras split, public API, minimal_host example, integration
tests. Today's target: Phase 1.

Three questions worth pinning before code:

**DotEnv / asset_cache mounting.** The spec marked these as nullable
fields on `Spark` but didn't say who instantiates them. Two clean
options: (a) lazy on first extras install, (b) explicit
`Spark.installDotEnv(path)` / `installAssetCache(dir, budget)` from the
host. (a) reads `~/.env` the moment any HTTP-using extra installs —
exactly the "library makes filesystem assumptions" pattern the spec
otherwise forbids. (b) keeps the library honest. Christian: "(b),
explicit." Locked in as decision #9.

**Vulkan binding shape at the API boundary.** Both spark and matryoshka
have their own thin Zig wrappers around `@cImport(<vulkan/vulkan.h>)`.
Raw `c.VkDevice` / `c.VkQueue` / `c.VkCommandBuffer` are the same
opaque pointer at the C ABI but distinct Zig types from the two
cImports' perspective — bridging is a one-line `.handle` unwrap at the
call site. Lowest common denominator, no coupling either way. Locked in
as decision #10.

**Per-Document State.** With multiple top-level Documents on one Spark
(matryoshka HUD + debug panel, say), do they share one root State or
each get their own? The recommended answer (each gets its own; sharing
is opt-in via `loadDocument(.{ .shared_state = … })`) matches embedded
documents' existing scope discipline, just lifted one level up. Locked
in as decision #8.

Christian added two process notes that became part of the spec proper:
*the spec is a starting point, not gospel — push back and update the
spec in the same commit if a decision turns out wrong;* and *a Release
FPS canary against `hello.md` is the regression alarm — if it drops by
more than ~5% after a refactor, something's wrong on the hot path.*

## Phase 1 — `Spark` + module-global purge

### `src/spark.zig` — the context struct

The struct holds borrowed pointers to everything the components
currently reach for through file-scope `_ref` globals:

```zig
pub const Spark = struct {
    allocator: std.mem.Allocator,

    // Vulkan (borrowed from host)
    vk_ctx: *const vk.Context,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    text_pipeline: *tp.TextPipeline,
    quad_pipeline: *qp.QuadPipeline,
    tri_pipeline: *tri_pipeline_mod.TrianglePipeline,
    image_pipeline: *image_pipeline_mod.ImagePipeline,

    // Text + layout state
    fonts: *font_registry_mod.FontRegistry,
    glyph_cache: *glyph_cache_mod.GlyphCache,
    theme: *const element.Theme,
    registry: *component_mod.Registry,
    host_state: *state_mod.State,
    layout_cache: *layout_cache_mod.BlockCache,
    layout_context: *layout_context_mod.LayoutContext,

    // Job systems + I/O
    compute_jobs: *jobs_mod.JobSystem,
    io_jobs: *jobs_mod.JobSystem,
    io_channel: *io_channel_mod.IoChannel,

    // Extras hooks (null until installed)
    dotenv: ?*const dotenv_mod.DotEnv = null,
    asset_cache: ?*asset_cache_mod.AssetCache = null,
};
```

`init(.{...})` is a builder over an `InitArgs` struct; `deinit` is a
Phase 1 noop (Spark borrows, doesn't own — Phase 3 inverts this).

A `testStub(allocator)` helper returns a Spark with most fields
`undefined`, suitable for component-internal unit tests that don't
exercise the layout/render path. Tests that need a real field
(`host_state`, `compute_jobs`) patch it on the returned struct before
use. This bit out three times during the session — input tests
needed real state for `.dirty = true`, SVG tests needed a real
`JobSystem` for the parallel tessellator — but the pattern stayed clean:
make the stub minimal, let test sites that need more own that
construction explicitly.

### `Factory.create` grows `*Spark`

The load-bearing change:

```zig
create: *const fn (
    spark: *spark_mod.Spark,    // new
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!Instance,
```

`update` / `deinit` / `handle_update` keep their signatures — they
already have access to the component's ctx, which now carries the
spark pointer it captured in `create`.

`Registry.attachSpark(&spark)` lands the pointer onto the registry
itself; `Registry.resolve` reads it through to `buildEntry`'s
`factory.create(sp, …)` call. The chicken-and-egg is real (Spark
borrows Registry, Registry needs Spark) but solved by separating
construction from attachment — both exist before the first parse runs.

`error.SparkNotAttached` is the loud failure mode if a host forgets the
attach. Every test fixture got two new lines: a `testStub` spark and
the attach call.

### The `_ref` purge

Eleven components carried module-global pointers — the canonical
example was `llm_stream.zig`:

```zig
// Before:
var registry_ref: ?*component_mod.Registry = null;
var theme_ref: ?*const element.Theme = null;
var parent_state_ref: ?*state_mod.State = null;
var io_channel_ref: ?*io.IoChannel = null;
var env_ref: ?*const dotenv.DotEnv = null;

// After:
const Component = struct {
    spark: *spark_mod.Spark,
    // ... existing per-instance fields
};
```

The migration was mostly mechanical but had a non-obvious shape:
async-completion handlers (embedded-document's HTTP fetch,
llm-stream's SSE chunks, svg-stream's Recraft response, image-stream's
Gemini envelope) outlive their Components. Cancellation nulls the
back-pointer; the completion handler still needs to release the
io-channel-owned body and bump `host_state.dirty` even if the
Component is gone. The `PendingFetch` / `PendingStream` /
`PendingSvgStream` / `PendingImageStream` structs each got a
`spark: *Spark` snapshot field — the spark pointer is process-stable
and outlives any Component, so it's a safe handle for the completion
path.

For the simple inline components (the fifteen-deep drawer from
session 17 — `::badge`, `::trend`, `::price`, etc.), none of them
needed `_ref`. The migration was just a signature change plus
`_ = spark;` in the function body. Twelve files via a small Python
script driving `re.sub` over uniform shapes, the gh_ref special case
(`createIssue` + `createPr` sharing a Component) by hand.

### `main.zig` consolidation

The demo went from scattered top-level vars and 25 install call sites
with varying signatures, to:

```zig
var spark = spark_mod.Spark.init(.{
    .allocator = allocator,
    .vk_ctx = &ctx,
    .mono_atlas = &atlas_mono,
    .color_atlas = &atlas_color,
    .text_pipeline = &pipeline,
    .quad_pipeline = &quad_pipeline,
    .tri_pipeline = &tri_pipeline_inst,
    .image_pipeline = &image_pipeline_inst,
    .fonts = &fonts,
    .glyph_cache = &cache,
    .theme = &theme,
    .registry = &registry,
    .host_state = &host_state,
    .layout_cache = &block_cache,
    .layout_context = &layout_context,
    .compute_jobs = job_system,
    .io_jobs = io_pool,
    .io_channel = &io_channel,
    .dotenv = &env,
    .asset_cache = asset_cache,
});
defer spark.deinit();
registry.attachSpark(&spark);

try box_component.install(&spark);
try badge_component.install(&spark);
// ... 25 install calls, every signature now (&spark,)
```

The bridge-state policy from the spec held: main.zig still owns the
resources, Spark borrows. Phase 3 inverts it.

## hello.md + argv

The post-Phase-1 FPS canary against the full demo came in at ~5,184 fps
Release — a 31% drop versus the spec's "~7,600 fps at idle" baseline.
Christian:

> That 7600 number was before we added a ton of stuff to the demo
> document. We should add a more natural hello world document and have
> a way where we can "spark xyz.md"

The 7,600 baseline was apples-to-oranges. The post-Phase-1 demo is
~20 KB of content including embedded HTTP-fetched docs, LLM streams,
the SVG component zoo, ANSI parsing, and the full inline drawer.
Pre-stages-9-through-17 hardware reading vs current full demo.

The fix: `src/hello.md` (heading + two paragraphs + one `:::box`),
`argv[1]` in `main.zig` to load that file, falling back to the embedded
`demo.md`. The result: `text_engine_demo src/hello.md` → **~12,965
fps Release**. Above the old baseline. The spec's canary section grew
a new paragraph pinning hello.md as the regression-detection probe.

A couple of emoji 🌸 🐬 ☕ as a smoke test for the colour-emoji
fallback cascade brought it to **~13,056 fps** with 434 glyphs (vs 371
before).

## Removing "ATTENTION"

> That thing that says ATTENTION — is that hard coded? We should rip it
> out and leave a note about it

The SDF rainbow "ATTENTION" paragraph from session 1 was still wired
into `main.zig`: a hardcoded `paragraph` of one text run with a 44-px
SDF font, a per-frame loop in `drawCb` walking `dl.glyphs.items[idx]`
and mutating `.attention` (via sin wave) and `.hot_color` (via hue
cycle), an `hsvToRgb` helper, `pulse_start` / `pulse_count` /
`sdf_block` fields on `FrameCtx`. None of it driven by anything except
wall-clock time.

The plumbing it exercises — `Style.attention` → `Glyph.attention` SSBO
slot → text fragment shader's rainbow-on-attention branch — is real
infrastructure that wants an LM-side driver (semantic heatmap colouring,
predictive completion glow, intent-buffer visualisation). The visual
demo was a placeholder. Time to delete the placeholder and leave notes
so the substrate doesn't get accidentally torn out next.

Five anchor points got `// removed — see FrameCtx docstring` notes:
top-of-file docstring, the FrameCtx struct doc, the spot where the
per-frame wave used to run, the SDF font load, and where `hsvToRgb`
used to live. Each note says what the surviving plumbing does and how
to bring an animation back when the driver shows up.

## Where this leaves us

Phase 1 closed. The library boundary now has a name, a shape, and one
contract surface (`Factory.create(*Spark, ...)`). Components don't
reach for module-globals anymore. main.zig still owns the resources but
plumbs them through a single struct — the shape Phase 3 will invert
into ownership without touching component code again.

What's left in the library-spec roadmap:
- **Phase 2** — core / extras split. Mostly mechanical file moves
  (`src/extras/llm_stream.zig` etc.) plus `installDotEnv` /
  `installAssetCache` method bodies. Low risk; can ride into the next
  session.
- **Phase 3** — `src/lib.zig` public API. Spark grows real init
  (`loadDocument`, `beginFrame`, `layoutAndRender`, `endFrame`,
  `dispatchMouseMove`, …) and main.zig loses its direct imports of
  `element_layout`, `markdown`, etc. The proof point: if the boundary
  cuts cleanly here, matryoshka adoption will too.
- **Phase 4** — `examples/minimal_host.zig` against the new API.
- **Phase 5** — integration tests + two-instances test for state
  isolation.

The matryoshka-side spec annex landed mid-session pointing at
`~/dev/valkyr/docs/embedding.md` and `~/dev/matryoshka/src/games/ai_demo.zig`
as the working sibling-precedent. Read those before Phase 3 — the
`vk.Context.attach` shape and the `Recorder.attachCmd` pattern are
worth lifting rather than re-deriving.

Christian's signal at session end: *"Awesome stuff!"* — and a journey
doc request. The towel is folded, the tea is drained, and `spark` has
walked from a name into a struct.

🌐🐢🐬🌸☕🚀
