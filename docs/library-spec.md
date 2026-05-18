# spark — library-ification spec

Drafted 2026-05-18. This spec covers the work to convert spark from a
self-contained demo executable into a Zig library that a second
Vulkan host (matryoshka — `~/dev/matryoshka/`) can import via
`build.zig.zon`.

## Context

The architecture doc has documented the cooperative-embed shape from
the start: "the library does not own a Vulkan instance, device,
surface, or swapchain. The host hands the library its `VkDevice` +
per-frame `VkCommandBuffer` and the library records draw work into
them." In practice, `src/lib.zig` is 34 lines and nothing reaches
through it. `src/main.zig` (1378 LOC) owns GLFW, the Vulkan stack,
font init from env vars (`TEXT_ENGINE_FONT=...`), the JobSystem
pair, the IoChannel, the asset cache directory under
`XDG_CACHE_HOME`, persistence under `XDG_STATE_HOME`, and the
per-frame loop. The internal modules reach across each other freely.
Several components carry module-global `_ref` pointers
(`src/components/llm_stream.zig:74-78` is canonical; `box.zig`,
`embedded_document.zig`, `svg_stream.zig`, `image_stream.zig`,
`handle.zig` follow the same pattern).

After this work, a second host (matryoshka, the demo itself,
`examples/minimal_host.zig`) can:

```zig
const spark = @import("spark");

var sp = try spark.Spark.init(allocator, .{
    .device = vk_device,
    .graphics_queue = vk_queue,
    .graphics_queue_family = qf_index,
    .color_format = swap_format,
    .theme = &my_theme,
    .fonts = &my_fonts,
});
defer sp.deinit();

// Host opts in to extras it wants:
try spark.extras.llm_stream.install(&sp);

const doc = try sp.loadDocument(@embedFile("ui.md"));
defer doc.deinit();

// Per frame:
sp.beginFrame(.{
    .extent = swap_extent,
    .zoom = 1.0,
    .target_image = current_swap_image,
    .target_view = current_swap_view,
});
try sp.layoutAndRender(&doc, cmd_buffer);
sp.endFrame();
```

No env vars consulted internally. No GLFW. No swapchain ownership.
No filesystem assumptions.

## In scope

- Cooperative Vulkan handshake: host owns instance/device/queue/
  swapchain; spark owns atlases, pipelines, glyph cache, descriptor
  pools.
- Drop module-global refs in components; thread a `Spark` context
  explicitly.
- Split core (markdown / components / layout / kiwi / state /
  registry / jobs / io_channel) from extras (HTTP-backed
  llm-stream / svg-stream / image-stream / asset cache / dotenv).
- Real public API in `src/lib.zig`.
- `examples/minimal_host.zig` as the smallest possible second
  consumer.
- Integration tests that exercise the library boundary, not
  internals.

## Out of scope

- **Render-pass interop with matryoshka** — separate spec, follows
  this one. We're handing the host a `VkImage` + `VkImageView` and
  recording `vkCmdBeginRendering` with `loadOp=LOAD` inside
  `layoutAndRender`. matryoshka and spark coexisting in one
  command buffer is the *next* thing this unlocks, but landing it
  isn't part of library-ification.
- **Inline 3D / `:::3d-scene` factory** — a later component, after
  the library boundary is real.
- **Rename `text_engine` → `spark`** — mechanical, can land
  concurrent with any phase or separately. Decided in conversation
  but not required by this spec.

## Related precedent — valkyr in matryoshka

The cooperative-embed pattern this spec asks for is **already
shipping** in a sibling Foundation42 library. `valkyr` (LLM inference
+ training, pure Zig + Vulkan, cross-vendor) embeds into matryoshka
through the same shape spark is being asked to grow. Reading the
working integration is more useful than imagining it.

### Key files to read first

- **`~/dev/valkyr/docs/embedding.md`** — the embedding contract,
  three-tier API, build wiring, per-frame protocol. ~950 lines, but
  the first 220 lines cover everything load-bearing.
- **`~/dev/matryoshka/src/games/ai_demo.zig`** (594 lines) — the
  integration. Loads a real Llama / Gemma / Qwen model, runs forward
  passes inside matryoshka's render loop, taps last-layer attention
  via the `on_layer` callback, drives a 16-light strip from the
  scores. The whole per-frame plumbing is ~50 lines in `aiDispatch`
  (lines 393-450).
- **`~/dev/matryoshka/src/games/train_mlp_demo.zig` / `train_classifier_demo.zig`** —
  interactive function fitting. Live MLP training in the render
  loop, click-driven supervision, Adam optimizer, no `waitIdle`,
  locked at refresh rate. Same recorder, same submit.
- **`~/dev/matryoshka/build.zig:14-22, 107`** — the build wiring.
  Three lines to add valkyr as a path dependency. Zero shader
  sharing, zero peer dependencies, zero build coupling. Spark
  should achieve the same.

### Patterns to lift directly

1. **Attach API shape.** valkyr's entry point is
   `vk.Context.attach(instance, physical, device, queue, family, pool)`
   — the library does not init Vulkan, does not own queues, does
   not manage cmd pools. The host hands over six handles, gets a
   Context back. Spark's `Spark.init(opts)` should follow the same
   shape (which it does in this spec — see Phase 1's `InitOptions`).

2. **`Recorder.attachCmd` instead of per-call cmd passing.**
   `Recorder.attachCmd(ctx, host_cmd, max_sets, max_descriptors)`
   attaches the recorder to a cmd buffer **once** and sizes its
   descriptor pool at attach time. Per frame: `rec.reset()`
   (descriptor pool only — cmd buffer untouched) → `rec.begin()`
   (no-op in attached mode) → record dispatches → done. The host
   owns the cmd buffer's reset/begin/end/submit lifecycle; valkyr
   never touches them. **Strongly consider this shape for spark's
   `layoutAndRender`** instead of passing `cmd` every frame —
   descriptor pool sizing is a library concern with stable
   per-attach sizing, not a per-frame parameter. The shape from
   `ai_demo.zig:375-380`:

   ```zig
   state.rec = try vkr.recorder.Recorder.attachCmd(
       &state.ctx,
       @ptrCast(host_cmd),
       512,   // max_sets
       2048,  // max_descriptors
   );
   ```

3. **Three-tier API naming.** valkyr exposes three explicit tiers
   the host picks from:
   - **Tier 1** — cooperative-compute primitives (`vk.Context`,
     `buffer`, `pipeline`, `recorder`, `shaders`). Hosts that want
     to run their own compute alongside graphics without involving
     an LLM at all.
   - **Tier 2** — Session-driven (`session.Session`). Full state
     machine, deferred-sample correctness, per-layer scheduling.
   - **Tier 3** — Runner (`inference.runner.InferenceRunner`).
     Queue-based: submit `Command.chat`, drain `Event`s. **Same
     Runner powers `valkyr --serve`** — embed and HTTP eat from
     one inference abstraction.

   Spark has analogues already in this spec (raw `markdown.parse`
   / `Spark.loadDocument+layoutAndRender` / `Spark + extras`), but
   they're not named as tiers. **Consider naming them
   consistently** so a host integrating both libraries sees
   parallel APIs. Suggested mapping:
   - Tier 1 — element contract + walker (host builds its own
     Element trees, walks them directly)
   - Tier 2 — `Spark.loadDocument` + frame cycle (full live-document
     runtime)
   - Tier 3 — `Spark` + extras (LLM streams, SVG generation, etc.)

4. **`@ptrCast` bridge for cImport handles.** Both libraries
   `@cImport` `<vulkan/vulkan.h>` independently. The handles are
   the same opaque pointers at the C ABI but distinct Zig types
   from the two cImports' perspective. The canonical bridge sits
   at `ai_demo.zig:120-129`:

   ```zig
   fn attachContext(handles: vk.VulkanHandles) vkr.vk.Context {
       return vkr.vk.Context.attach(
           @ptrCast(handles.instance),
           @ptrCast(handles.physical_device),
           @ptrCast(handles.device),
           @ptrCast(handles.queue),
           handles.queue_family,
           @ptrCast(handles.cmd_pool),
       );
   }
   ```

   **Every host integrating spark will need an identical bridge
   function.** Don't try to design it away — it's a Zig type-system
   reality, not a contract problem. Document it in the spark
   embedding doc as "expected ~10 lines of host-side scaffolding."

5. **Event drain on the main thread.** valkyr's `runner.pollEvent()`
   is drained once per frame on the main thread (`ai_demo.zig:151-172`).
   No callbacks. Same shape as spark's `IoChannel.drain()` — keep
   spark's model identical for consistency.

6. **Per-frame submit discipline.** valkyr never submits. `tickWork()`
   records into the host's cmd buffer; the host's render loop owns
   `vkEndCommandBuffer` + `vkQueueSubmit`. **Spark must do the
   same** — `layoutAndRender` records, host submits. The earlier
   decision in this spec to use dynamic rendering with `loadOp=LOAD`
   inside `layoutAndRender` is consistent with this; just confirm
   no `vkQueueSubmit` ever lives inside spark.

### What this changes

The library-ification work isn't speculative — valkyr is the
existence proof. A future matryoshka game importing **all three**
libraries (matryoshka-engine + spark + valkyr) gets:

- One `VkInstance` / `VkDevice` / queue / cmd pool, host-owned
- One `VkCommandBuffer` per frame, host-owned
- Three libraries each recording their own work into it via
  `attach`/`tick`/`drain` shapes
- One `vkQueueSubmit` per frame, host-issued
- Zero cross-library coordination (each library mints its own
  descriptors, its own pipelines, its own SSBOs; the host sizes
  pool caps independently per library)

That's the cooperative-compute payoff: three independent libraries
composed by one host into one frame, with no shared knowledge
between the libraries themselves.

If the spark agent hits any design uncertainty during Phase 1
or Phase 3 about API shape ("does it look like this or like
that?"), the answer is almost always **look at the valkyr
equivalent and match it**. Foundation42 conventions are converging
on this shape; consistency across libraries is high-value.

## Phasing

Each phase ships a usable intermediate state. Order matters; later
phases assume earlier ones have landed.

### Phase 1 — `Spark` context struct + module-global purge

Add `src/spark.zig` with the `Spark` struct:

```zig
pub const Spark = struct {
    allocator: std.mem.Allocator,

    // Vulkan (borrowed from host)
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    graphics_queue_family: u32,
    color_format: c.VkFormat,

    // Owned by spark
    fonts: *FontRegistry,           // borrowed in Phase 1; Spark owns at Phase 3
    glyph_cache: *GlyphCache,
    mono_atlas: *Atlas,
    color_atlas: *Atlas,
    text_pipeline: *TextPipeline,
    quad_pipeline: *QuadPipeline,
    tri_pipeline: *TrianglePipeline,
    image_pipeline: *ImagePipeline,

    theme: *const Theme,            // host-owned; spark borrows
    registry: *Registry,
    state: *State,                  // root document's state
    layout_cache: *BlockCache,
    layout_context: *LayoutContext,

    compute_jobs: *JobSystem,       // cpu_count - 2 workers, parallel layout / tessellation
    io_jobs: *JobSystem,            // 24 workers, blocking HTTP
    io_channel: *IoChannel,

    // Extras hooks (null = extras not installed).
    // Populated via explicit `installDotEnv` / `installAssetCache`
    // calls on the host — never auto-loaded. See decision #9.
    dotenv: ?*DotEnv = null,
    asset_cache: ?*AssetCache = null,

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Spark;
    pub fn deinit(self: *Spark) void;

    /// Mount a DotEnv reader at `env_path`. Required precondition
    /// for any extras factory that reads env vars (llm-stream,
    /// svg-stream, image-stream, embedded_document_http). The host
    /// chooses the path — the library makes no filesystem
    /// assumptions. Calling twice replaces the previous reader.
    pub fn installDotEnv(self: *Spark, env_path: []const u8) !void;

    /// Mount an asset cache at `dir` with a `budget_bytes` ceiling.
    /// Required precondition for svg-stream / image-stream. Same
    /// host-chooses-path discipline as installDotEnv.
    pub fn installAssetCache(
        self: *Spark,
        dir: []const u8,
        budget_bytes: usize,
    ) !void;
};

pub const InitOptions = struct {
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,    // needed for memory type lookup in atlas / image_texture
    graphics_queue: c.VkQueue,
    graphics_queue_family: u32,
    color_format: c.VkFormat,

    theme: *const Theme,
    fonts: *FontRegistry,                    // borrowed in Phase 1, owned at Phase 3

    // Optional knobs
    mono_atlas_size: u32 = 2048,
    color_atlas_size: u32 = 1024,
    max_glyphs: u32 = 16384,
    max_quads: u32 = 2048,
    max_tri_vertices: u32 = 65536,
    max_tri_indices: u32 = 196608,
    max_images: u32 = 32,

    compute_workers: ?u32 = null,            // null = cpu_count - 2
    io_workers: u32 = 24,
};
```

**Module-global purge.** Replace the `_ref` pattern in every
component. Current shape in `src/components/llm_stream.zig:74-78`:

```zig
var registry_ref: ?*component_mod.Registry = null;
var theme_ref: ?*const element.Theme = null;
var parent_state_ref: ?*state_mod.State = null;
var io_channel_ref: ?*io.IoChannel = null;
var env_ref: ?*const dotenv.DotEnv = null;
```

Target shape:

```zig
// In the component's instance struct:
const Component = struct {
    spark: *Spark,
    // ... existing per-instance fields
};

// Factory.create captures *Spark:
pub fn install(spark: *Spark) !void {
    try spark.registry.register("llm-stream", makeFactory(spark));
}
```

`Factory.create` grows a `*Spark` argument:

```zig
pub const Factory = struct {
    create: *const fn (
        spark: *Spark,
        allocator: std.mem.Allocator,
        spec: *const Spec,
    ) anyerror!Instance,
    update: ?*const fn (ctx: *anyopaque, spec: *const Spec) anyerror!void = null,
    deinit: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
    handle_update: ?*const fn (ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void = null,
};
```

`update`/`deinit`/`handle_update` read `*Spark` from the component's
ctx when needed. No closure capture machinery required; the spark
pointer is just a struct field.

Demo (`src/main.zig`) becomes the first consumer of the new shape:
its scattered top-level vars consolidate into one `Spark` instance.
Behavior unchanged.

**Done when:**
- No `_ref` module-global pointers remain in any component
  (`grep -r "var .*_ref:" src/components/` returns empty).
- Demo runs with identical visual output and similar FPS
  (see the FPS canary section below — `src/hello.md` at ~12,800
  fps Release is the current baseline).
- All existing tests pass.

#### Phase 1 outcome — shipped 2026-05-18 (commit `d6f2f4b`)

Phase 1 landed. Three implementation refinements emerged that
later phases must preserve:

1. **Ownership stays borrowed in Phase 1, inverts at Phase 3.**
   The original wording above ("ownership transferred at init") was
   wrong-by-a-phase. Phase 1 shipped as pure refactor: `main.zig`
   still owns every Vulkan / font / pipeline / state resource;
   Spark holds borrowed pointers. Phase 3 (public API) is where
   Spark grows real `init()` and inverts ownership. This split is
   intentional — it lets Phase 1 be a behavior-preserving refactor
   with zero ownership-semantics change, which is much safer to
   land. Comments throughout this spec referring to "ownership
   transferred at init" have been updated to "borrowed in Phase 1,
   owned at Phase 3."

2. **`PendingX` structs carry their own `spark: *Spark` snapshot.**
   The async completion handlers in `IoChannel`-using components
   (embedded-document HTTP fetch, llm-stream SSE, svg-stream
   Recraft envelope, image-stream Gemini envelope) outlive their
   owning Components. Cancellation nulls the Component back-pointer,
   but the completion handler still needs to release the
   io-channel-owned body and bump `host_state.dirty` regardless.
   The spark pointer is process-stable, so every PendingX struct
   gets a snapshot field as the safe handle for the completion
   path. **Don't lose this when relocating these factories to
   `src/extras/` in Phase 2** — the snapshot field travels with
   the struct.

3. **`testStub(allocator)` pattern for component tests.** Tests
   that don't exercise the layout/render path use a stub Spark
   with most fields `undefined`; tests that touch specific surfaces
   (`host_state.dirty`, parallel-tessellator `JobSystem`) patch the
   needed field on the returned struct. Don't try to make a full
   real Spark for every test — `testStub` + per-test patching is
   the established pattern.

The full demo Release FPS dropped to ~5,184 fps after Phase 1 — a
31% drop versus the spec's original 7,600 baseline. **The drop is
demo-content drift, not Phase 1 regression** (the demo grew
between the 7,600 measurement and Phase 1). `hello.md` is the new
regression-detection probe at ~12,965 fps — see the canary section
below.

### Phase 2 — core / extras split

Move HTTP-dependent components and their support code to `src/extras/`:

| from                                       | to                                          |
|--------------------------------------------|---------------------------------------------|
| `src/components/llm_stream.zig`            | `src/extras/llm_stream.zig`                 |
| `src/components/svg_stream.zig`            | `src/extras/svg_stream.zig`                 |
| `src/components/image_stream.zig`          | `src/extras/image_stream.zig`               |
| `src/dotenv.zig`                           | `src/extras/dotenv.zig`                     |
| `src/asset_cache.zig`                      | `src/extras/asset_cache.zig`                |
| (http branch of `embedded_document.zig`)   | `src/extras/embedded_document_http.zig`     |

Core stays at `src/components/`: box, flex, grid, slider, button,
input, badge, kbd, tag, progress, sparkline, status, handle,
chart, svg, embedded_document (file:// only).

Each extras module exposes one install function:

```zig
pub fn install(spark: *Spark) !void {
    // register factories that depend on HTTP / asset cache / dotenv
}
```

Host opts in explicitly. Order matters: any extras factory that
reads env vars needs `installDotEnv` to have happened first; any
that uses the on-disk asset cache needs `installAssetCache`. Each
extras `install` checks its preconditions at install time and
returns a descriptive error (`error.RequiresDotEnv`,
`error.RequiresAssetCache`) rather than failing silently or
auto-loading anything:

```zig
try ui.installDotEnv("/home/chris/.env");
try ui.installAssetCache("/home/chris/.cache/spark", 500 * 1024 * 1024);
try spark.extras.llm_stream.install(&ui);
try spark.extras.svg_stream.install(&ui);
try spark.extras.image_stream.install(&ui);
try spark.extras.embedded_document_http.install(&ui);
```

**Decisions to lock in:**

- `io_channel.zig` stays in core. It's generic submit/drain/
  completion infrastructure, reusable for non-HTTP async (file
  watch, MCP pipes, future LSP). Only the HTTP-using *factories*
  move to extras.
- `embedded-document` for `file://` and bare paths stays in core
  (document composition is foundational to the flywheel). `http://`
  and `https://` move to a separate `embedded_document_http`
  factory in extras that registers itself under the same
  directive name with a URL-scheme check at resolve time, **or**
  intercepts via a separate directive name (`:::embedded-doc-url`,
  TBD). Implementer picks whichever is cleaner. Both work.
- Asset cache (`~/.cache/text_engine/assets`) is extras: only
  svg-stream and image-stream use it; core never touches the
  filesystem cache path.
- **DotEnv and AssetCache are host-opt-in, not auto-loaded.** Add
  explicit methods on `Spark`:
  ```zig
  pub fn installDotEnv(self: *Spark, env_path: []const u8) !void;
  pub fn installAssetCache(self: *Spark, dir: []const u8, budget_bytes: usize) !void;
  ```
  Extras factories that depend on these check at install time and
  return `error.RequiresDotEnv` / `error.RequiresAssetCache` if the
  host hasn't installed them yet. The host's call order is the
  contract:
  ```zig
  try ui.installDotEnv("/home/chris/.env");
  try ui.installAssetCache("/home/chris/.cache/spark", 500 * 1024 * 1024);
  try spark.extras.llm_stream.install(&ui);   // needs dotenv
  try spark.extras.svg_stream.install(&ui);   // needs asset_cache
  ```
  No surprise filesystem reads when an extras install runs.

**Done when:**
- A `--core-only` flag (or build option) in `main.zig` skips
  the extras install calls and produces a working demo with
  markdown + ANSI + the core component set (no LLM streams,
  no svg-stream, no image-stream).
- `zig build` with extras removed from `build.zig`'s file list
  still succeeds and produces a usable library.

### Phase 3 — public API in `src/lib.zig`

`src/lib.zig` becomes the only file external consumers `@import`.
Re-exports:

```zig
// Top-level types
pub const Spark = @import("spark.zig").Spark;
pub const InitOptions = @import("spark.zig").InitOptions;
pub const FrameInfo = @import("spark.zig").FrameInfo;
pub const Document = @import("document.zig").Document;

// Element contract — for components built outside the library
pub const Element = @import("element.zig").Element;
pub const ElementVTable = @import("element.zig").ElementVTable;
pub const Style = @import("element.zig").Style;
pub const Theme = @import("element.zig").Theme;
pub const LayoutCtx = @import("element.zig").LayoutCtx;
pub const DrawList = @import("element.zig").DrawList;
pub const Constraints = @import("element.zig").Constraints;
pub const Box = @import("element.zig").Box;
pub const InputEvent = @import("element.zig").InputEvent;
pub const MouseEvent = @import("element.zig").MouseEvent;
pub const KeyEvent = @import("element.zig").KeyEvent;
pub const Hit = @import("element.zig").Hit;
pub const IntrinsicMetrics = @import("element.zig").IntrinsicMetrics;
pub const BlockMetrics = @import("element.zig").BlockMetrics;

// Registry / state
pub const Registry = @import("component.zig").Registry;
pub const Factory = @import("component.zig").Factory;
pub const Spec = @import("markdown_components.zig").Spec;
pub const Attr = @import("markdown_components.zig").Attr;
pub const State = @import("state.zig").State;
pub const Subscriber = @import("state.zig").Subscriber;

// Fonts
pub const FontRegistry = @import("font/registry.zig").FontRegistry;
pub const FontId = @import("font/registry.zig").FontId;

// Producers — hosts that want raw markdown / ANSI parsing
pub const markdown = @import("markdown.zig");
pub const ansi = @import("ansi.zig");

// Opt-in extras
pub const extras = struct {
    pub const llm_stream = @import("extras/llm_stream.zig");
    pub const svg_stream = @import("extras/svg_stream.zig");
    pub const image_stream = @import("extras/image_stream.zig");
    pub const embedded_document_http = @import("extras/embedded_document_http.zig");
};
```

Add methods on `Spark`:

```zig
// Document lifecycle
pub fn loadDocument(self: *Spark, source: []const u8) !Document;
pub fn loadDocumentFromFile(self: *Spark, path: []const u8) !Document;

// Frame cycle
pub fn beginFrame(self: *Spark, info: FrameInfo) void;
pub fn layoutAndRender(self: *Spark, doc: *Document, cmd: c.VkCommandBuffer) !void;
pub fn endFrame(self: *Spark) void;

// Input dispatch
pub fn dispatchMouseMove(self: *Spark, doc: *Document, pos: [2]f32) !void;
pub fn dispatchMouseButton(self: *Spark, doc: *Document, button: u8, down: bool, pos: [2]f32) !void;
pub fn dispatchKey(self: *Spark, doc: *Document, ev: KeyEvent) !void;
pub fn dispatchChar(self: *Spark, doc: *Document, codepoint: u32) !void;
pub fn dispatchScroll(self: *Spark, doc: *Document, delta: [2]f32) !void;

// LM-driven updates
pub fn applyUpdate(self: *Spark, doc: *Document, update_source: []const u8) !void;

// Async housekeeping — drain io completions, tick state, etc.
// Host calls once per frame, typically right before beginFrame.
pub fn tick(self: *Spark) !void;
```

`FrameInfo`:

```zig
pub const FrameInfo = struct {
    extent: [2]u32,                  // host's swapchain extent
    zoom: f32 = 1.0,
    scroll_offset: [2]f32 = .{0, 0},
    target_image: c.VkImage,         // host's swapchain image
    target_view: c.VkImageView,
    // No depth — spark doesn't use depth testing.
};
```

**Render strategy.** `layoutAndRender` records its own
`vkCmdBeginRendering` / `vkCmdEndRendering` with `loadOp=LOAD`
inside the host's command buffer. Composites onto whatever the
host drew before this call. This matches matryoshka's
dynamic-rendering pattern. The host doesn't need to wrap spark in
its own render pass; spark is self-contained inside one
`vkCmdBegin/EndRendering` pair.

**Demo migration.** `src/main.zig` migrates to consume only
`@import("spark")`. No more direct imports of `element_layout.zig`,
`markdown.zig`, etc. The host-side concerns (GLFW window, swapchain
creation, frame pacing, key dispatch, GLFW → spark event
translation) stay in `main.zig`; everything text-engine-shaped goes
through the lib.zig surface.

If migrating reveals API gaps, surface them as additions to
`lib.zig` rather than reaching back into internals.

**Done when:**
- `grep -rn "@import.*element_layout" src/main.zig` returns empty.
  Same for `markdown`, `component`, `state`, `element` (it's all
  via the lib.zig namespace).
- Demo behaves identically.
- `zig build test` passes.

### Phase 4 — `examples/minimal_host.zig`

~200 LOC: own GLFW window + Vulkan instance/device/swapchain,
minimal Theme + FontRegistry from a single hardcoded font path,
load a tiny embedded markdown doc, run a frame loop, close on ESC.

The point: prove the library boundary against a second consumer
before matryoshka adoption. If `minimal_host.zig` can't be written
using only `@import("spark")`, the API isn't done.

This file is also the canonical reference for matryoshka's
spark-integration code — when matryoshka starts adopting, they
copy the host-side scaffolding from here.

**Done when:**
- `zig build minimal-host` produces a binary that opens a window,
  renders a tiny markdown doc with a `:::box` and a `:::slider`,
  responds to mouse input, closes cleanly.
- The file imports only `@import("spark")` plus GLFW + Vulkan
  headers. No reaching into internals.

### Phase 5 — Integration tests

`src/tests/integration_render.zig`:
- Construct a `Spark` instance (use a stub device or run with VK
  validation in test mode — there's no shortcut here, but a Vulkan
  context for tests can be init'd lazily once).
- Parse a known markdown doc through `Spark.loadDocument`.
- Run a layout pass; capture the resulting DrawList.
- Hash glyphs + quads + tris arrays. Compare against a stored
  hash.

`src/tests/library_lifecycle.zig`:
- Init/deinit a `Spark` instance using `std.testing.allocator`.
- Verify no leaks.
- Spin up two `Spark` instances in one process; verify they don't
  share state (set state.foo on one, check it's not visible on
  the other).

Convert ~5 existing module-internal tests to integration shape:
they should go through `Spark.loadDocument` rather than reaching
into `markdown.parse` directly. The point is to exercise the
library boundary, not just the internals.

**Done when:**
- `zig build test` passes with the new tests.
- `std.testing.allocator` reports no leaks across the lifecycle
  test.
- Two-instances test passes.

## Design decisions (override if wrong)

| # | Decision | Rationale |
|---|---|---|
| 1 | Components store `*Spark` in instance ctx; `Factory.create` takes it as first arg | Single hop to all engine resources; no thread-locals; no closure machinery |
| 2 | Dynamic rendering self-contained inside `layoutAndRender` with `loadOp=LOAD` | Matches matryoshka. Host owns the target image. Composites cleanly. |
| 3 | file:// `embedded-document` in core; http:// in extras | File composition is foundational to the flywheel; network is opt-in |
| 4 | `IoChannel` stays in core | Reusable for non-HTTP async (file watch, MCP pipes, future LSP) |
| 5 | `Theme` + `FontRegistry` constructed by host | Same cooperative-embed pattern as Vulkan resources |
| 6 | No env vars consulted by the library | Library makes no filesystem assumptions; demo's `TEXT_ENGINE_FONT=...` stays in `main.zig` |
| 7 | `Document` is a handle (arena + Element tree + per-doc DrawList) | Multiple docs per `Spark` is natural for HUD overlays, debug panels |
| 8 | Each `Document` gets its own `State` by default | Two docs on one Spark shouldn't fight over `state.*` keys; sharing is opt-in via `loadDocument(.{ .shared_state = ... })` |
| 9 | DotEnv + AssetCache are host-opt-in via explicit `Spark.installDotEnv(path)` / `Spark.installAssetCache(dir, budget)` calls, not auto-loaded by extras | Library makes no filesystem assumptions; host stays in charge of all filesystem paths; no surprise `~/.env` reads when any extras install runs |
| 10 | Vulkan handles in the public API are raw C types (`c.VkDevice`, `c.VkQueue`, `c.VkCommandBuffer`) | Lowest-common-denominator interop — both spark and matryoshka have their own thin Vulkan wrappers; raw handles let both sides keep their internal bindings without coupling |
| 11 | The rename (`text_engine` → `spark`) lands separately from this work | Mechanical; can be done first or last. Asset cache dir, env var prefixes, build module name move together. |

## Risks / things to watch

- **`element_layout.zig` (1793 lines)** has accreted layout-cache +
  parallel-walk + constraint + exclusion logic. The refactor may
  touch it heavily if `Spark` plumbing has to thread through. If
  the file gets unwieldy, consider splitting `layoutInlineFlow`
  and `layoutStackV` into separate files — but only as needed.
  Don't pre-split.
- **`main.zig` (1378 lines)** will need significant reworking in
  Phase 3. The split between "host-owned VK setup" and "library
  consumption" is the proof point — if the boundary cuts cleanly,
  matryoshka adoption will too.
- **Parallel walker mutexes** (`LayoutContext.mutex`,
  `glyph_cache_lock`) currently work because everything's on one
  process-global Spark. Two `Spark` instances in one process must
  not accidentally share state — verify with the two-instances
  test in Phase 5.
- **Stage 15E `inline_object` / `valign`** is the newest contract
  surface (`element.zig:264-288`). Easy to forget during refactor.
  If anything visual breaks, suspect it first.
- **glslc -O for shaders** is already wired (matryoshka pattern,
  per existing README); keep it working through any build.zig
  changes.

## Process notes

- **Spec is living, not gospel.** If any of the design decisions
  turn out wrong during implementation, push back rather than
  working around them — and update the spec file in the same
  commit. The spec captures what we believe today; the code is
  what we ship. When the two disagree, the more recent
  understanding wins, and the spec should follow.
- **FPS canary.** The Phase-1-era baseline is **~12,800 fps
  Release** against `src/hello.md` — a tiny doc (heading + 2
  paragraphs + 1 `:::box` + 1 `::badge`) chosen as a stable
  rendering hot-path probe. Earlier readings of ~7,600 fps were
  taken before the demo grew to ~20 KB with embedded docs, LLM
  streams, and the full inline drawer — apples-to-oranges. To
  re-measure after a change: `./zig-out/bin/text_engine_demo
  src/hello.md` (TEXT_ENGINE_EXIT_AFTER=N for a timed run). If
  the reading drops by more than ~5% against hello.md after a
  refactor, something on the hot path regressed — likely a
  cache-line / pointer-chase issue from added indirection. Fix is
  usually inlining hot fields rather than dereferencing through a
  struct hop.

## Locked-in answers to earlier open questions

- **Per-Document State:** each `Document.init` creates its own root
  `State` by default. Two HUD documents on one matryoshka instance
  don't accidentally share `state.player_health`. Sharing is
  explicit via `loadDocument(.{ .shared_state = &other_doc.state })`.
  Embedded documents continue to do their parent-pointer
  dirty-bubble thing inside that, unchanged.
- **DotEnv / AssetCache:** explicit host-opt-in via
  `Spark.installDotEnv` / `Spark.installAssetCache` (see Phase 2
  decisions block above).
- **Vulkan API shape:** raw C handles (`c.VkDevice` etc.) at the
  public API. Both spark and matryoshka have their own thin
  wrappers internally; raw handles are the interop boundary.

## What this unlocks

After Phase 5 lands, matryoshka can:

```zig
const spark = @import("spark");

var ui = try spark.Spark.init(alloc, .{
    .device = my_vk.device,
    .physical_device = my_vk.physical_device,
    .graphics_queue = my_vk.graphics_queue,
    .graphics_queue_family = my_vk.qf_graphics,
    .color_format = my_vk.swap_format,
    .theme = &hud_theme,
    .fonts = &hud_fonts,
});
defer ui.deinit();

const hud_doc = try ui.loadDocument(@embedFile("hud.md"));
defer hud_doc.deinit();

// In matryoshka's render loop, after the main 3D pass composites
// to the swapchain image:
try ui.tick();
ui.beginFrame(.{
    .extent = swap_extent,
    .target_image = current_swap_image,
    .target_view = current_swap_view,
});
try ui.layoutAndRender(&hud_doc, my_cmd);
ui.endFrame();
```

matryoshka HUDs become markdown files — sliders, charts,
telemetry, debug panels — authored as text, hot-reloadable, the
LM can stream directly into them. No Dear ImGui anywhere in
matryoshka.

The follow-up spec (render-pass interop / inline 3D scenes) builds
on top of this; it can't start until the library boundary is real.
