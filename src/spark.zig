//! `Spark` — engine context + lifecycle for the spark library.
//! Phase 3 of `docs/library-spec.md` (ownership inversion).
//!
//! Spark constructs the engine resources at `init` time and tears
//! them down in `deinit`. The host gives Spark raw Vulkan handles
//! (device, queue, queue_family, color_format), a Theme, an owned
//! FontRegistry, a borrowed root State, and a small set of sizing
//! knobs. Spark owns the rest: atlases, four GPU pipelines, glyph
//! cache, layout cache, layout context, component registry,
//! compute/io JobSystems, IoChannel.
//!
//! Per-frame surface (Phase 3 frame cycle):
//!
//!   * `attachCmd(cmd, max_sets, max_descriptors)` — cheap per-frame
//!     attach to the host's command buffer. Descriptor pool sizing
//!     happens on the first call; subsequent calls just update the
//!     stored cmd handle. (Phase 3 deliberately doesn't run a
//!     library-owned descriptor pool — atlases + pipelines manage
//!     their own — so the `max_sets`/`max_descriptors` knobs are
//!     reserved for future expansion. Pass 0/0 today.)
//!   * `beginFrame(FrameInfo)` — resets the per-frame DrawList,
//!     caches extent/zoom/scroll/target handles.
//!   * `layoutAndRender(doc, origin, constraints)` — walks `doc.root`
//!     into the shared DrawList at `origin`. Multiple `layoutAndRender`
//!     calls in one frame append to the same DrawList; the host gets
//!     the resulting Box back and can chain layouts vertically.
//!   * `endFrame()` — applies scroll/zoom transform, uploads glyph
//!     SSBO, records tri/image/quad/text draws into the attached cmd.
//!     **Must be called inside an active `vkCmdBeginRendering` scope**
//!     that the host owns (target_image/view live in FrameInfo for
//!     reference but the rendering scope is the host's contract).
//!
//! Extras hooks (`dotenv`, `asset_cache`, `embedded_http`) are null
//! until the host opts in via `installX` methods. Spec decision #9.

const std = @import("std");

const element = @import("element.zig");
const state_mod = @import("state.zig");
const component_mod = @import("component.zig");
const layout_context_mod = @import("layout/context.zig");
const layout_cache_mod = @import("layout_cache.zig");
const io_channel_mod = @import("io_channel.zig");
const jobs_mod = @import("jobs.zig");
const dotenv_mod = @import("extras/dotenv.zig");
const asset_cache_mod = @import("extras/asset_cache.zig");
const embedded_document_http_mod = @import("extras/embedded_document_http.zig");
const vk = @import("gpu/vk.zig");
const atlas_mod = @import("gpu/atlas.zig");
const glyph_cache_mod = @import("text/glyph_cache.zig");
const font_registry_mod = @import("font/registry.zig");
const tp = @import("gpu/text_pipeline.zig");
const qp = @import("gpu/quad_pipeline.zig");
const tri_pipeline_mod = @import("gpu/tri_pipeline.zig");
const image_pipeline_mod = @import("gpu/image_pipeline.zig");
const display_mod = @import("gpu/display.zig");
const element_layout = @import("element_layout.zig");
const document_mod = @import("document.zig");
const pass_mod = @import("pass/root.zig");
const io = io_channel_mod;

/// Per-frame info supplied by the host at `beginFrame`. Stored on
/// the Spark instance until `endFrame`; `layoutAndRender` calls
/// consult these fields for viewport math + zoom/scroll transforms.
pub const FrameInfo = struct {
    extent: vk.c.VkExtent2D,
    zoom: f32 = 1.0,
    /// World-space pixels to subtract during the screen-space
    /// transform. `screen.y = (world.y - scroll_offset[1]) * zoom`.
    scroll_offset: [2]f32 = .{ 0, 0 },
    /// Reference to the host's swapchain image + view this frame is
    /// targeting. Spark doesn't manage the rendering scope itself
    /// (the host wraps `endFrame` in `vkCmdBeginRendering`/
    /// `EndRendering`), but recording the handles here keeps the API
    /// surface aligned with the matryoshka contract.
    target_image: vk.c.VkImage = null,
    target_view: vk.c.VkImageView = null,

    /// What the host's attachment wants out of the fragment stage.
    ///
    /// `.sdr` (the default) is passthrough — spark writes the display-
    /// referred values it always wrote, so a host that never sets this
    /// renders byte-identically to one built before the transform existed.
    /// A host presenting to an HDR10 / ST 2084 swapchain sets `.pq`, and
    /// spark's chrome is mapped to `paperwhite_nits` rather than blazing at
    /// PQ's 10000-nit ceiling.
    ///
    /// Per-frame rather than baked into the pipelines at init: one pipeline
    /// set serves both swapchain families, and a host can change its mind (a
    /// display handoff, a user toggling HDR) without spark rebuilding
    /// anything. Matches how matryoshka pushes `display` to its own overlay
    /// chrome each frame — see `shaders/display.glsl`.
    display: display_mod.Mode = .sdr,

    /// Diffuse-white luminance for the `.pq` arm; ignored under `.sdr`.
    /// BT.2408's reference graphics white by default.
    paperwhite_nits: f32 = display_mod.REFERENCE_PAPERWHITE_NITS,

    /// The pair, as the pipelines take it.
    pub fn displayPush(self: FrameInfo) display_mod.Push {
        return display_mod.Push.from(self.display, self.paperwhite_nits);
    }
};

/// Construction options for `Spark.init`. Raw Vulkan handles +
/// theme + fonts (Spark takes ownership) + borrowed host state +
/// optional sizing knobs. Defaults match the demo's historical
/// values so a thin migration doesn't perturb GPU memory budgets.
pub const InitOptions = struct {
    /// Borrowed Vulkan context. Spark holds the pointer for the
    /// lifetime of the instance; host must keep it alive.
    vk_ctx: *const vk.Context,
    /// Format of the swapchain colour attachment. Pipelines bake
    /// this in at create-time; recreate the Spark on swapchain
    /// re-create if the format changes (rare).
    color_format: vk.c.VkFormat,

    /// Theme. Host-owned; Spark borrows. Built around `font_ids`
    /// the host obtained from the FontRegistry before calling init.
    theme: *const element.Theme,
    /// FontRegistry. Spark TAKES OWNERSHIP — `deinit` will call
    /// `fonts.deinit()`. Host loads its fonts on this registry
    /// before `Spark.init`, then hands the registry over.
    fonts: *font_registry_mod.FontRegistry,
    /// Root host State. Borrowed (host owns lifetime). Used as
    /// `c.spark.host_state` by every component; embedded documents
    /// link their child state's `.parent` to this so dirty bubbles.
    host_state: *state_mod.State,

    // ── Sizing knobs (defaults match the historical demo values) ──
    mono_atlas_size: u32 = 2048,
    color_atlas_size: u32 = 1024,
    max_glyphs: u32 = 16384,
    max_quads: u32 = 2048,
    max_tri_vertices: u32 = 65536,
    max_tri_indices: u32 = 196608,
    max_images: u32 = 32,

    /// Compute worker count. Null = cpu_count - 2 (matches demo).
    compute_workers: ?u32 = null,
    /// I/O worker count. 24 worker threads matches the demo; HTTP
    /// streams park on socket reads so this number is concurrency,
    /// not parallelism.
    io_workers: u32 = 24,
};

pub const Spark = struct {
    allocator: std.mem.Allocator,

    // ── Vulkan (borrowed from host) ──────────────────────────────────
    vk_ctx: *const vk.Context,
    color_format: vk.c.VkFormat,
    /// The format every OFFSCREEN effect target is rendered in, and the
    /// second format every pipeline is built for. Not the host's: an HDR10
    /// swapchain is `A2B10G10R10`, whose alpha is two bits, and coverage —
    /// a glyph's antialiasing, a shadow's falloff — is alpha. See
    /// `vk.pickOffscreenFormat` and `vk.Attachment`.
    offscreen_format: vk.c.VkFormat,

    // ── Owned engine resources ───────────────────────────────────────
    mono_atlas: atlas_mod.Atlas,
    color_atlas: atlas_mod.Atlas,
    text_pipeline: tp.TextPipeline,
    quad_pipeline: qp.QuadPipeline,
    tri_pipeline: tri_pipeline_mod.TrianglePipeline,
    /// Heap-allocated so `:::image-stream` components can alloc/free
    /// descriptors via a stable pointer. Spark frees in deinit.
    image_pipeline: *image_pipeline_mod.ImagePipeline,
    glyph_cache: glyph_cache_mod.GlyphCache,
    glyph_cache_lock: std.Thread.Mutex,
    layout_cache: layout_cache_mod.BlockCache,
    /// Heap-allocated so components can store a stable `*LayoutContext`
    /// pointer through `c.spark.layout_context`. Spark frees in deinit.
    layout_context: *layout_context_mod.LayoutContext,
    /// Heap-allocated for the same reason — components dereference
    /// `c.spark.registry` to register/resolve factory instances.
    registry: *component_mod.Registry,
    /// Heap-allocated so async-using components can capture a stable
    /// `*IoChannel` snapshot at submit time (PendingFetch.spark.io_channel).
    io_channel: *io_channel_mod.IoChannel,
    /// Per-frame DrawList — reset in `beginFrame`, populated by
    /// `layoutAndRender`, drained in `endFrame`.
    drawlist: element.DrawList,
    /// Per-frame pass-graph dispatch list. Sibling to `drawlist`
    /// because pass-graph output is not rasterizer output — the
    /// type-honesty split keeps `DrawList` meaning "things to
    /// rasterize" and `pass_dispatches` meaning "shader passes to
    /// execute." Empty until effects-spec Phase A.6 lands the
    /// pass-graph compiler that populates it. Reset symmetry with
    /// `drawlist` is enforced by `beginFrame` + a lifecycle test.
    /// When the pass-graph compiler grows real co-located state
    /// (target pool, barrier plan, dependency edges), promote into
    /// a `PassGraph` struct on Spark and rename to
    /// `pass_graph.dispatches` — one cheap rename, no protocol
    /// churn. A.3 deliberately did NOT promote: the three new
    /// effects-side fields (this list, `target_pool`,
    /// `shader_resolver`) are loosely coupled at stub-time with no
    /// cross-field state to justify the struct. Revisit at A.6
    /// when the compiler ties them together.
    pass_dispatches: std.ArrayList(element.PassDispatch),
    /// Transient render-target pool — Phase A.3 typed-null stub.
    /// Sibling field per the [[feedback-spark-sibling-fields]]
    /// pattern. Phase B fills with the real ref-counted allocator.
    target_pool: pass_mod.TargetPool,
    /// Shader resolver — `ShaderId` → `ShaderDispatchHandle`.
    /// Phase A.3 empty-cache stub; Phase A.4 populates from the
    /// glslc build step.
    shader_resolver: pass_mod.ShaderResolver,
    /// Pattern-pass pipeline cache (effects-spec Phase A.6.b).
    /// Per-Spark per the [[feedback-spark-sibling-fields]] pattern —
    /// `two_instances.zig` invariant. Eagerly populated from
    /// `registerEmbeddedPassShaders` after each shader registers;
    /// dispatch-time lookup is constant-time. Holds one shared
    /// `VkPipelineLayout` and one `VkPipeline` per pattern shader.
    pattern_pipelines: pass_mod.PatternPipelineCache,
    /// Single-source filter pipeline cache (effects-spec Phase
    /// B.4.b.1). Sibling of `pattern_pipelines`; same lifecycle,
    /// different pipeline-layout shape (one combined-image-sampler
    /// descriptor set + push constants — patterns are push-only).
    /// `registerEmbeddedPassShaders` seeds it with `copy.frag` at
    /// init time as the substrate smoke shader; B.5+ filters
    /// (`drop_shadow`, `frosted_glass`) register here too.
    single_source_pipelines: pass_mod.SingleSourcePipelineCache,
    /// Per-frame descriptor-set pool for single-source compose
    /// dispatches (effects-spec Phase B.4.b.2). Borrows the
    /// descriptor set layout from `single_source_pipelines` —
    /// teardown order in `deinit` destroys the pool before the
    /// cache. Reset cadence symmetric with `target_pool` per
    /// `single_source_descriptor_pool.zig`'s module comment.
    single_source_descriptor_pool: pass_mod.SingleSourceDescriptorPool,
    /// Targets acquired during this frame's Phase 1 (effects-spec
    /// Phase B.4.b.3 dispatch processor). Released wholesale at
    /// end of Phase 3 (end of `endFrame`). Sibling list so any
    /// straggler at frame boundary is caught by
    /// `target_pool.sweepUnreleased` on the next `beginFrame.reset
    /// = true`.
    acquired_targets: std.ArrayList(pass_mod.TargetHandle),
    /// Parallel array indexed by `pass_dispatches` position;
    /// `single_source` entries get their acquired `TargetHandle`
    /// stored here so Phase 1's nested compose lookups and Phase 2's
    /// top-level compose lookups can resolve dispatch_index → target
    /// in O(1) without a hashmap. `null` for `.pattern` entries and
    /// for indices the iteration hasn't visited yet. Sized to
    /// `pass_dispatches.items.len` at the start of
    /// `dispatchOffscreenPasses`; cleared at frame reset alongside
    /// `pass_dispatches`.
    dispatch_target_map: std.ArrayList(?pass_mod.TargetHandle),
    /// Effects-spec C.1 — sibling to `dispatch_target_map` for
    /// `.chain` dispatches. Indexed by `pass_dispatches` position;
    /// `null` for non-chain entries. Holds the `acquired_targets`
    /// index where this chain's ping-pong pool starts — Phase 1's
    /// `phase1ProcessChain` writes it after pool acquire, Phase 2's
    /// `recordChainFinalComposite` reads it to resolve
    /// `final_pool_local` against `acquired_targets[]`.
    ///
    /// **Why sibling array, not field on ChainStep.** Phase-1-transient
    /// state on Spark goes in parallel sibling arrays, never on the
    /// dispatch struct — established pattern from `dispatch_target_map`.
    /// Keeps `ChainStep` structurally immutable like its siblings,
    /// keeps hashFrame's per-arm exclusion list implicit (Phase-1
    /// state on Spark is already excluded from fingerprinting), and
    /// keeps the "did we forget to clear it" lifecycle check a visual
    /// scan rather than a logical trace.
    chain_pool_bases: std.ArrayList(?u32),

    /// Owned via pointer (JobSystem.init returns `*JobSystem`).
    compute_jobs: *jobs_mod.JobSystem,
    io_jobs: *jobs_mod.JobSystem,

    // ── Owned font registry (Phase 3 takes ownership from host) ────
    fonts: *font_registry_mod.FontRegistry,

    // ── Borrowed from host ──────────────────────────────────────────
    theme: *const element.Theme,
    host_state: *state_mod.State,

    // ── Extras hooks (null until host opts in via installX) ─────────
    dotenv: ?*const dotenv_mod.DotEnv = null,
    asset_cache: ?*asset_cache_mod.AssetCache = null,
    embedded_http: ?*embedded_document_http_mod.EmbeddedDocumentHttp = null,

    // ── Per-frame state (set by attachCmd + beginFrame) ─────────────
    /// Bound command buffer for the current frame. Set by `attachCmd`,
    /// consulted by `endFrame` when recording draws.
    attached_cmd: vk.c.VkCommandBuffer = null,
    /// FrameInfo snapshot from the most recent `beginFrame` call.
    /// Default extent zero — `endFrame` is a no-op until set.
    frame_info: FrameInfo = .{ .extent = .{ .width = 0, .height = 0 } },
    /// True when `beginFrame` cleared `drawlist` and a subsequent
    /// `layoutAndRender` is expected to repopulate it in world
    /// coords. `endFrame` consults this flag — if set, apply the
    /// world→screen transform and clear the flag. The host opts out
    /// (`beginFrame(.{ .reset = false })`) on non-dirty frames to
    /// reuse the previous frame's screen-space drawlist verbatim.
    drawlist_needs_transform: bool = false,

    // ── Input state (managed by `dispatchMouseButton` etc.) ─────────
    /// Last mouse position dispatched (world coords, pre-zoom).
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    /// Pointer-capture: whichever Hit the most recent mouse_down
    /// landed on receives every subsequent move + up until release.
    captured: ?element.Hit = null,
    /// Keyboard focus. Set when a click lands on a focusable hit;
    /// cleared on click-outside or Esc. Compared by ctx pointer.
    focused: ?element.Hit = null,


    /// Construct a Spark and all engine resources. The host gives
    /// raw Vulkan handles (via opts.vk_ctx + opts.color_format), an
    /// owned FontRegistry, a borrowed Theme + root State, and
    /// sizing knobs. `deinit` reverses this — every resource Spark
    /// constructed is torn down in reverse order.
    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Spark {
        // The format every offscreen effect target is rendered in, and the
        // second format every pipeline is built for. Chosen once, here,
        // because it has to be the same answer for the pipelines and for
        // the target pool — a mismatch between those two is a validation
        // error at the first effect draw. See `vk.pickOffscreenFormat`.
        const offscreen_format = vk.pickOffscreenFormat(opts.vk_ctx.physical_device, opts.color_format);

        // ── Atlases ─────────────────────────────────────────────────
        var mono_atlas = try atlas_mod.Atlas.init(opts.vk_ctx, opts.mono_atlas_size, opts.mono_atlas_size, .mono_r8);
        errdefer mono_atlas.deinit();
        var color_atlas = try atlas_mod.Atlas.init(opts.vk_ctx, opts.color_atlas_size, opts.color_atlas_size, .color_rgba8);
        errdefer color_atlas.deinit();

        // ── Pipelines ───────────────────────────────────────────────
        var text_pipeline = try tp.TextPipeline.init(
            opts.vk_ctx,
            opts.color_format,
            offscreen_format,
            &mono_atlas,
            &color_atlas,
            opts.max_glyphs,
        );
        errdefer text_pipeline.deinit();
        var quad_pipeline = try qp.QuadPipeline.init(opts.vk_ctx, opts.color_format, offscreen_format, opts.max_quads);
        errdefer quad_pipeline.deinit();
        var tri_pipeline = try tri_pipeline_mod.TrianglePipeline.init(
            opts.vk_ctx,
            opts.color_format,
            offscreen_format,
            opts.max_tri_vertices,
            opts.max_tri_indices,
        );
        errdefer tri_pipeline.deinit();
        const image_pipeline = try allocator.create(image_pipeline_mod.ImagePipeline);
        errdefer allocator.destroy(image_pipeline);
        image_pipeline.* = try image_pipeline_mod.ImagePipeline.init(opts.vk_ctx, opts.color_format, offscreen_format, opts.max_images);
        errdefer image_pipeline.deinit();

        // ── Glyph + layout caches ───────────────────────────────────
        var glyph_cache = glyph_cache_mod.GlyphCache.init(allocator);
        errdefer glyph_cache.deinit();
        var layout_cache = layout_cache_mod.BlockCache.init(allocator);
        errdefer layout_cache.deinit();
        const layout_context = try allocator.create(layout_context_mod.LayoutContext);
        errdefer allocator.destroy(layout_context);
        layout_context.* = try layout_context_mod.LayoutContext.init(allocator);
        errdefer layout_context.deinit();

        // ── Component registry ──────────────────────────────────────
        const registry = try allocator.create(component_mod.Registry);
        errdefer allocator.destroy(registry);
        registry.* = component_mod.Registry.init(allocator);
        errdefer registry.deinit();

        // ── Job systems + IoChannel ─────────────────────────────────
        const compute_jobs = try jobs_mod.JobSystem.init(allocator, opts.compute_workers orelse 0);
        errdefer compute_jobs.deinit();
        const io_jobs = try jobs_mod.JobSystem.init(allocator, opts.io_workers);
        errdefer io_jobs.deinit();
        const io_channel = try allocator.create(io_channel_mod.IoChannel);
        errdefer allocator.destroy(io_channel);
        io_channel.* = io_channel_mod.IoChannel.init(allocator, io_jobs);
        errdefer io_channel.deinit();

        // ── DrawList + effects-side state ───────────────────────────
        const drawlist = element.DrawList.init(allocator);
        const pass_dispatches = std.ArrayList(element.PassDispatch).init(allocator);
        const acquired_targets = std.ArrayList(pass_mod.TargetHandle).init(allocator);
        const dispatch_target_map = std.ArrayList(?pass_mod.TargetHandle).init(allocator);
        const chain_pool_bases = std.ArrayList(?u32).init(allocator);
        const target_pool = pass_mod.TargetPool.init(allocator, opts.vk_ctx);
        var shader_resolver = pass_mod.ShaderResolver.init(allocator);
        errdefer shader_resolver.deinit();
        // Pipeline cache must init before `registerEmbeddedPassShaders`
        // so the per-shader `compile()` calls during seeding land into
        // a live cache. `fullscreen.vert` is shared by every pattern
        // pipeline; the cache holds the cached vert module + layout.
        const shaders = @import("shaders");
        var pattern_pipelines = try pass_mod.PatternPipelineCache.init(
            allocator,
            opts.vk_ctx,
            opts.color_format,
            offscreen_format,
            &shaders.fullscreen_vert,
        );
        errdefer pattern_pipelines.deinit();
        // Single-source filter cache stands up before
        // `registerEmbeddedPassShaders` for the same reason
        // `pattern_pipelines` does — the seeding pass calls
        // `compile()` on each substrate/filter shader and needs both
        // caches live.
        var single_source_pipelines = try pass_mod.SingleSourcePipelineCache.init(
            allocator,
            opts.vk_ctx,
            opts.color_format,
            offscreen_format,
            &shaders.fullscreen_vert,
        );
        errdefer single_source_pipelines.deinit();
        // Descriptor pool borrows the set layout from
        // single_source_pipelines — must init after the cache.
        var single_source_descriptor_pool = try pass_mod.SingleSourceDescriptorPool.init(
            allocator,
            opts.vk_ctx,
            single_source_pipelines.descriptor_set_layout,
        );
        errdefer single_source_descriptor_pool.deinit();
        try registerEmbeddedPassShaders(
            &shader_resolver,
            &pattern_pipelines,
            &single_source_pipelines,
        );

        return .{
            .allocator = allocator,
            .vk_ctx = opts.vk_ctx,
            .color_format = opts.color_format,
            .offscreen_format = offscreen_format,
            .mono_atlas = mono_atlas,
            .color_atlas = color_atlas,
            .text_pipeline = text_pipeline,
            .quad_pipeline = quad_pipeline,
            .tri_pipeline = tri_pipeline,
            .image_pipeline = image_pipeline,
            .glyph_cache = glyph_cache,
            .glyph_cache_lock = .{},
            .layout_cache = layout_cache,
            .layout_context = layout_context,
            .registry = registry,
            .io_channel = io_channel,
            .drawlist = drawlist,
            .pass_dispatches = pass_dispatches,
            .acquired_targets = acquired_targets,
            .dispatch_target_map = dispatch_target_map,
            .chain_pool_bases = chain_pool_bases,
            .target_pool = target_pool,
            .shader_resolver = shader_resolver,
            .pattern_pipelines = pattern_pipelines,
            .single_source_pipelines = single_source_pipelines,
            .single_source_descriptor_pool = single_source_descriptor_pool,
            .compute_jobs = compute_jobs,
            .io_jobs = io_jobs,
            .fonts = opts.fonts,
            .theme = opts.theme,
            .host_state = opts.host_state,
        };
    }

    /// Tear down every Spark-owned resource. Reverse-of-init order
    /// so dependencies (e.g. pipelines reference atlas image views)
    /// are still alive when the dependent is destroyed. The borrowed
    /// fields (vk_ctx, theme, host_state) are NOT freed — host owns
    /// those.
    pub fn deinit(self: *Spark) void {
        // Order of teardown is delicate — get it wrong and ReleaseFast
        // tears straight through the resulting UAF without a panic.
        //
        //   1. Components first (registry.deinit). Each Component's
        //      `deinit_` may dereference `c.spark.layout_context`,
        //      `c.spark.io_channel`, etc., AND embedded-doc components
        //      null out their in-flight `PendingFetch.component` back-
        //      pointer here so the worker / drain path sees the
        //      cancellation. Run while every engine resource is still
        //      live.
        //   2. Workers next (io_jobs + compute_jobs deinit join the
        //      threads). After this point no new completions can land.
        //   3. IoChannel — its own comment forbids destroy-before-
        //      workers-join; reverse-order would leave a window for
        //      late posts to UAF the freed channel.
        //   4. Extras (embedded_http, asset_cache, dotenv) — only
        //      safe to free now that no worker can call
        //      `EmbeddedDocumentHttp.handleCompletion` (which would
        //      read `spark.embedded_http`). Pre-Phase-3 ordering had
        //      these first; the result was a UAF visible in
        //      ReleaseFast but not Debug (Debug's poison-pattern fill
        //      doesn't corrupt the read in time).
        //   5. Remaining engine resources reverse-of-init.

        // 1. Components — must run with full engine alive.
        self.registry.deinit();
        self.allocator.destroy(self.registry);

        // 2. Workers — joins each thread; in-flight HTTP / compute
        //    jobs either complete or get abandoned. After this, no
        //    new completions arrive.
        self.io_jobs.deinit();
        self.compute_jobs.deinit();

        // 3. IoChannel — frees any queued completion bodies (`.ok` /
        //    `.chunk`) that landed but never got drained.
        self.io_channel.deinit();
        self.allocator.destroy(self.io_channel);

        // 4. Extras hooks — now safe; no worker can re-enter.
        if (self.embedded_http) |ext| {
            ext.deinit();
            self.allocator.destroy(ext);
            self.embedded_http = null;
        }
        if (self.asset_cache) |ac| {
            ac.deinit();
            self.asset_cache = null;
        }
        if (self.dotenv) |env| {
            const mutable: *dotenv_mod.DotEnv = @constCast(env);
            mutable.deinit();
            self.allocator.destroy(mutable);
            self.dotenv = null;
        }

        // 5. Per-frame state + effects-side stubs.
        self.drawlist.deinit();
        self.pass_dispatches.deinit();
        self.acquired_targets.deinit();
        self.dispatch_target_map.deinit();
        self.chain_pool_bases.deinit();
        self.target_pool.deinit();
        self.shader_resolver.deinit();
        self.pattern_pipelines.deinit();
        // Descriptor pool borrows single_source_pipelines'
        // descriptor set layout — destroy the pool first so the
        // borrowed handle is alive across its tear-down (Vulkan
        // doesn't require this ordering for descriptor-pool
        // destruction, but the conceptual hierarchy reads cleaner).
        self.single_source_descriptor_pool.deinit();
        self.single_source_pipelines.deinit();

        // 6. Layout state.
        self.layout_context.deinit();
        self.allocator.destroy(self.layout_context);
        self.layout_cache.deinit();
        self.glyph_cache.deinit();

        // 7. Pipelines reverse-of-init.
        self.image_pipeline.deinit();
        self.allocator.destroy(self.image_pipeline);
        self.tri_pipeline.deinit();
        self.quad_pipeline.deinit();
        self.text_pipeline.deinit();

        // 8. Atlases.
        self.color_atlas.deinit();
        self.mono_atlas.deinit();

        // 9. Fonts — Spark took ownership at init.
        self.fonts.deinit();
    }

    /// Wire the Spark pointer into the registry so component
    /// factories can resolve cross-cutting deps. Called once after
    /// `Spark.init` (chicken-and-egg: Registry needs *Spark, Spark
    /// owns Registry; pointer becomes stable once Spark's storage
    /// is committed).
    pub fn attachToRegistry(self: *Spark) void {
        self.registry.attachSpark(self);
    }

    // ── Extras install methods ──────────────────────────────────────

    /// Mount a DotEnv reader at `env_path`. Required precondition for
    /// any extras factory that reads env vars. Spark owns the
    /// resource and frees it in `deinit`. Calling twice replaces.
    pub fn installDotEnv(self: *Spark, env_path: []const u8) !void {
        if (self.dotenv) |old| {
            const old_mut: *dotenv_mod.DotEnv = @constCast(old);
            old_mut.deinit();
            self.allocator.destroy(old_mut);
            self.dotenv = null;
        }
        const env = try self.allocator.create(dotenv_mod.DotEnv);
        errdefer self.allocator.destroy(env);
        env.* = dotenv_mod.DotEnv.init(self.allocator);
        errdefer env.deinit();
        try env.loadFromPath(env_path);
        self.dotenv = env;
    }

    /// Mount an asset cache at `dir` with a `budget_bytes` ceiling.
    /// Required precondition for svg-stream / image-stream.
    pub fn installAssetCache(
        self: *Spark,
        dir: []const u8,
        budget_bytes: u64,
    ) !void {
        if (self.asset_cache) |old| {
            old.deinit();
            self.asset_cache = null;
        }
        const ac = try asset_cache_mod.AssetCache.init(self.allocator, dir, budget_bytes);
        self.asset_cache = ac;
    }

    // ── Frame cycle ─────────────────────────────────────────────────

    /// Attach to the host's command buffer for the upcoming frame.
    /// Cheap (no allocation in Phase 3 — `max_sets`/`max_descriptors`
    /// are reserved for a future library-owned descriptor pool).
    /// Host typically calls this once per frame with the rotated
    /// cmd buffer the swapchain handed out.
    pub fn attachCmd(self: *Spark, cmd: vk.c.VkCommandBuffer, max_sets: u32, max_descriptors: u32) void {
        _ = max_sets;
        _ = max_descriptors;
        self.attached_cmd = cmd;
    }

    /// Optional per-frame knobs supplied at `beginFrame`. The
    /// default does a full layout reset (host plans to call
    /// `layoutAndRender` after); set `.reset = false` on a non-dirty
    /// frame to skip the drawlist reset + prewarm + solver-reset,
    /// and `endFrame` will re-record draws from the existing
    /// (screen-space) DrawList without any walk.
    pub const BeginFrameOpts = struct {
        reset: bool = true,
    };

    /// Begin a frame. With `opts.reset = true` (default): clears the
    /// shared DrawList, resets the layout context's per-pass solver
    /// state, prewarms the font registry, and marks the drawlist as
    /// needing a world→screen transform on `endFrame`. With `opts.reset
    /// = false`: just caches FrameInfo + cmd — the previous frame's
    /// screen-space DrawList is reused verbatim. Host owns the
    /// dirty-tracking discipline that decides which mode to use.
    pub fn beginFrame(self: *Spark, info: FrameInfo, opts: BeginFrameOpts) !void {
        self.frame_info = info;
        if (opts.reset) {
            self.drawlist.clearRetainingCapacity();
            // Symmetry with drawlist — both per-frame lists clear
            // together on the reset path, both carry over on the
            // dirty-gate path. Asymmetry here is a class of bug
            // (e.g. stale pass dispatches replayed against a
            // freshly-rebuilt drawlist); the lifecycle test pins it.
            self.pass_dispatches.clearRetainingCapacity();
            // Effects-spec B.4.b.2: target_pool sweep + descriptor
            // pool reset run together on the reset boundary; both
            // are skipped on `.reset = false` so the dirty-gate
            // path preserves the (target, descriptor-set) pairings
            // from the previous frame and the identical redraw
            // stays valid. Cross-reference comments on both modules'
            // reset paths pin the discipline from each side.
            _ = self.target_pool.sweepUnreleased();
            self.single_source_descriptor_pool.advance();
            try self.fonts.prewarmEffectiveSizesForZoom(info.zoom);
            self.layout_context.beginPass();
            self.drawlist_needs_transform = true;
        }
    }

    /// Walk `doc.root` into the per-frame DrawList. Multiple calls
    /// per frame compose vertically — the host passes successive
    /// origins. Returns the resulting Box for chaining.
    pub fn layoutAndRender(
        self: *Spark,
        doc: *const document_mod.Document,
        origin: [2]f32,
        constraints: element.Constraints,
    ) !element.Box {
        const effective_theme = doc.theme orelse self.theme;
        const effective_state = doc.state orelse self.host_state;
        var lc = element.LayoutCtx{
            .allocator = self.allocator,
            .fonts = self.fonts,
            .cache = &self.glyph_cache,
            .mono_atlas = &self.mono_atlas,
            .color_atlas = &self.color_atlas,
            .theme = effective_theme,
            .state = @ptrCast(effective_state),
            .cache_blocks = &self.layout_cache,
            .job_system = self.compute_jobs,
            .glyph_cache_lock = &self.glyph_cache_lock,
            .zoom = self.frame_info.zoom,
            .layout_context = self.layout_context,
            .pass_dispatches = &self.pass_dispatches,
        };
        return try element_layout.layoutAndRenderCached(doc.root, origin, constraints, &lc, &self.drawlist);
    }

    // ── Document lifecycle ──────────────────────────────────────────

    /// Parse `source` into a Document. The Document owns an arena
    /// + per-doc State by default; pass `LoadOpts.shared_state` to
    /// have multiple docs co-mutate one host-owned State. Host
    /// `deinit`s the Document when done.
    pub fn loadDocument(
        self: *Spark,
        source: []const u8,
        opts: document_mod.LoadOpts,
    ) !document_mod.Document {
        const theme = opts.theme orelse self.theme;
        return try document_mod.buildDocument(self.allocator, source, theme, self.registry, opts);
    }

    /// Convenience: read `path` from cwd and load it.
    pub fn loadDocumentFromFile(
        self: *Spark,
        path: []const u8,
        opts: document_mod.LoadOpts,
    ) !document_mod.Document {
        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, path, 32 * 1024 * 1024);
        defer self.allocator.free(bytes);
        return try self.loadDocument(bytes, opts);
    }

    /// Recovery hook: drop every cached glyph, reset both atlases,
    /// clear the block-layout cache. Host calls this after an
    /// `error.AtlasFull` from `layoutAndRender` — the next frame
    /// retries with a freshly-sized working set. Returns the atlas
    /// reset errors if they happen (rare; out-of-memory on the GPU).
    pub fn invalidateCaches(self: *Spark) !void {
        self.glyph_cache.clear();
        try self.mono_atlas.reset();
        try self.color_atlas.reset();
        self.layout_cache.clear();
    }

    /// Effects-spec Phase B.4.b.3 — Phase 1 of the three-phase
    /// dispatch processor. Records every top-level single-source
    /// effect's offscreen render pass into `cmd`, recursively
    /// descending into nested single-source children before each
    /// parent's pass begins.
    ///
    /// **Three-phase structure** (single command buffer, sequential
    /// dynamic-rendering passes, no nesting — Vulkan forbids nested
    /// render passes):
    ///
    ///   * **Phase 1 (this method)** — offscreen targets. Each
    ///     top-level single_source's processing **includes** any
    ///     nested children's compose dispatches inside that parent's
    ///     render pass; the recursion absorbs nesting so Phase 2
    ///     only ever sees top-level entries. Every offscreen target
    ///     ends in `SHADER_READ_ONLY_OPTIMAL` ready for sampling.
    ///   * **Phase 2 (Spark.endFrame)** — main render pass. Single
    ///     `vkCmdBeginRendering` owned by the host; pattern arms
    ///     render in place, top-level single_source arms compose-
    ///     sample their pre-rendered targets via descriptor sets,
    ///     drawlist primitives with `MAIN_TARGET` sentinel interleave.
    ///   * **Phase 3 (end of Spark.endFrame)** — wholesale release
    ///     of every Phase 1 acquire back to `target_pool`. v1 ships
    ///     release-at-end-of-Phase-2; Decision #4's mid-frame
    ///     release optimisation is deferred to Phase C+ when target
    ///     reuse within a frame matters at bloom-mip scale.
    ///
    /// **Call ordering.** Host calls this BEFORE its
    /// `vkCmdBeginRendering(swapchain)` — Phase 1 needs its own
    /// render-pass scopes against the offscreen targets, and
    /// Vulkan forbids nesting. Until B.5 ships a real
    /// single_source factory, `pass_dispatches` never contains a
    /// single_source entry in production code, so this method is
    /// a no-op for current spark_demo frames; the synthetic
    /// substrate test in `src/tests/single_source_dispatch.zig`
    /// exercises the populated path.
    pub fn dispatchOffscreenPasses(self: *Spark, cmd: vk.c.VkCommandBuffer) !void {
        // Resize the dispatch_target_map to mirror pass_dispatches
        // and start every entry as null. Phase 1 fills in the
        // acquired handles at single_source positions; Phase 2 reads
        // them at the matching indices.
        self.dispatch_target_map.clearRetainingCapacity();
        try self.dispatch_target_map.appendNTimes(null, self.pass_dispatches.items.len);
        // Effects-spec C.1 — chain_pool_bases mirrors lifecycle.
        self.chain_pool_bases.clearRetainingCapacity();
        try self.chain_pool_bases.appendNTimes(null, self.pass_dispatches.items.len);

        // Skip-past-subtree iteration. Pattern arms at the top level
        // are deferred to Phase 2 (`endFrame`); pattern arms inside
        // single_source subtrees are processed during their parent's
        // Phase 1 walk. Single_source arms drive the recursion.
        // `subtree_dispatch_range[1]` is the EXCLUSIVE end of the
        // subtree, but the single_source itself sits AT that index
        // (walker captures `seq = pd.items.len` BEFORE appending
        // the single_source, then appends it at pd[seq]). So to
        // advance past the single_source we use `subtree[1] + 1`,
        // not `subtree[1]` — the latter loops forever on the same
        // entry. Same fix mirrored in phase1ProcessSingleSource's
        // nested loop.
        //
        // B.6.b — patterns inside a single_source's subtree (walker
        // emits them BEFORE the parent in post-order) are handled
        // here by `.pattern => i += 1` skipping them at top-level;
        // they get rendered into the parent's offscreen target by
        // the nested subtree loop in `phase1ProcessSingleSource`.
        // Phase 2's mirror skip uses an `is_nested` bitmap (see
        // there); the asymmetry is intentional — Phase 1's iteration
        // only ever processes single_sources, so the natural skip
        // of `.pattern` is already correct.
        var i: u32 = 0;
        while (i < self.pass_dispatches.items.len) {
            switch (self.pass_dispatches.items[i]) {
                .pattern => i += 1,
                .single_source => |ss| {
                    try self.phase1ProcessSingleSource(cmd, i);
                    i = ss.subtree_dispatch_range[1] + 1;
                },
                // Effects-spec B.7. host_slot has no child subtree —
                // the host owns the rendering wholesale — so advance
                // is just `i += 1`, no skip-past-subtree fencepost.
                .host_slot => {
                    try self.phase1ProcessHostSlot(cmd, i);
                    i += 1;
                },
                // Effects-spec C.1 + C.1.5. chain wraps content
                // via subtree_dispatch_range (C.1.5); same skip-past-
                // subtree shape as single_source. The `+ 1` advances
                // past the chain dispatch's own index (chain sits at
                // subtree_dispatch_range[1] by post-order walker
                // emission — same fencepost as single_source).
                .chain => |c| {
                    try self.phase1ProcessChain(cmd, i);
                    i = c.subtree_dispatch_range[1] + 1;
                },
            }
        }
    }

    /// Recursive Phase 1 step: process nested single_source children
    /// first (depth-first post-order), then acquire `S`'s target,
    /// begin its offscreen render pass, render pattern + nested
    /// composes into it, end the pass, barrier to
    /// `SHADER_READ_ONLY_OPTIMAL`.
    fn phase1ProcessSingleSource(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        dispatch_index: usize,
    ) !void {
        const S = self.pass_dispatches.items[dispatch_index].single_source;

        // Recurse into nested single_sources first (depth-first
        // post-order). Same skip-past-subtree shape as Phase 1's
        // top-level iteration so nested-of-nested still works.
        // See dispatchOffscreenPasses for the fencepost note —
        // same `+ 1` to advance past the nested single_source's own
        // index, not just past its subtree.
        var i: u32 = S.subtree_dispatch_range[0];
        while (i < S.subtree_dispatch_range[1]) {
            switch (self.pass_dispatches.items[i]) {
                .pattern => i += 1,
                .single_source => |nested| {
                    try self.phase1ProcessSingleSource(cmd, i);
                    i = nested.subtree_dispatch_range[1] + 1;
                },
                // host_slot nested inside a single_source subtree
                // (e.g. :::drop_shadow wrapping :::placeholder_scene).
                // Same dispatch as top-level — acquire, transition,
                // invoke, transition — just descended-into here so
                // the parent's compose sees a populated target when
                // it walks its subtree below.
                .host_slot => {
                    try self.phase1ProcessHostSlot(cmd, i);
                    i += 1;
                },
                // chain nested inside a single_source subtree
                // (e.g. :::drop_shadow wrapping :::bloom). Same
                // dispatch as top-level chain — phase1ProcessChain
                // populates the chain's pool, leaving its
                // final_pool_local target in SHADER_READ_ONLY_OPTIMAL
                // for the parent's compose pass to sample. C.1.5
                // advance mirrors single_source nested: `+ 1` past
                // the chain dispatch's own index.
                .chain => |nested_c| {
                    try self.phase1ProcessChain(cmd, i);
                    i = nested_c.subtree_dispatch_range[1] + 1;
                },
            }
        }

        // Acquire S's target. Record it in dispatch_target_map at
        // S's position (Phase 2 reads from there) and in
        // acquired_targets (Phase 3 releases from there).
        const target_key = pass_mod.TargetKey{
            .width = S.target_size[0],
            .height = S.target_size[1],
            .format = self.offscreen_format,
        };
        const target_handle = try self.target_pool.acquire(target_key);
        try self.acquired_targets.append(target_handle);
        self.dispatch_target_map.items[dispatch_index] = target_handle;

        // Transition the freshly-acquired target from UNDEFINED to
        // COLOR_ATTACHMENT_OPTIMAL. The target may have come back
        // from the free list with `SHADER_READ_ONLY_OPTIMAL` from
        // a previous frame's last use; UNDEFINED as `old_layout`
        // is correct in both cases (Vulkan spec — old contents are
        // discarded, which is what we want here since we'll
        // LOAD_OP_CLEAR anyway).
        barrierImageLayout(cmd, target_handle.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .src_access = 0,
            .dst_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });

        // Begin S's offscreen render pass — clear to transparent
        // black so unwritten regions don't poison the compose
        // sample. Render area covers the full target.
        var color_att = std.mem.zeroes(vk.c.VkRenderingAttachmentInfo);
        color_att.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        color_att.imageView = target_handle.view();
        color_att.imageLayout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        color_att.loadOp = vk.c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_att.storeOp = vk.c.VK_ATTACHMENT_STORE_OP_STORE;
        color_att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        const target_extent = vk.c.VkExtent2D{
            .width = S.target_size[0],
            .height = S.target_size[1],
        };
        var ri = std.mem.zeroes(vk.c.VkRenderingInfo);
        ri.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = target_extent };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &color_att;
        vk.c.vkCmdBeginRendering(cmd, &ri);

        // Walk subtree dispatches and record pattern + nested
        // single_source composes target-locally. All viewports
        // here are in target-space coords (origin at S's
        // compose_region top-left, no zoom — target_size ==
        // compose_region.size by construction).
        var last_pattern: vk.c.VkPipeline = null;
        var last_compose: vk.c.VkPipeline = null;
        var j: u32 = S.subtree_dispatch_range[0];
        while (j < S.subtree_dispatch_range[1]) {
            switch (self.pass_dispatches.items[j]) {
                .pattern => |p| {
                    const px: f32 = @floatFromInt(p.layout_region.x - S.compose_region.x);
                    const py: f32 = @floatFromInt(p.layout_region.y - S.compose_region.y);
                    const pw: f32 = @floatFromInt(p.layout_region.w);
                    const ph: f32 = @floatFromInt(p.layout_region.h);
                    self.recordPatternStep(cmd, p, px, py, pw, ph, &last_pattern, .offscreen);
                    j += 1;
                },
                .single_source => |nested| {
                    const nested_target = self.dispatch_target_map.items[j] orelse unreachable;
                    const nx: f32 = @floatFromInt(nested.compose_region.x - S.compose_region.x);
                    const ny: f32 = @floatFromInt(nested.compose_region.y - S.compose_region.y);
                    const nw: f32 = @floatFromInt(nested.compose_region.w);
                    const nh: f32 = @floatFromInt(nested.compose_region.h);
                    try self.recordSingleSourceCompose(cmd, nested, nested_target, nx, ny, nw, nh, &last_compose, .offscreen);
                    j = nested.subtree_dispatch_range[1];
                },
                // host_slot nested inside this single_source's
                // subtree. Same compose shape as top-level host_slot
                // (Phase 2 below); rendered into target-local coords
                // rebased against S.compose_region.
                .host_slot => |nested_hs| {
                    const nested_target = self.dispatch_target_map.items[j] orelse unreachable;
                    const nx: f32 = @floatFromInt(nested_hs.compose_region.x - S.compose_region.x);
                    const ny: f32 = @floatFromInt(nested_hs.compose_region.y - S.compose_region.y);
                    const nw: f32 = @floatFromInt(nested_hs.compose_region.w);
                    const nh: f32 = @floatFromInt(nested_hs.compose_region.h);
                    try self.recordHostSlotCompose(cmd, nested_hs, nested_target, nx, ny, nw, nh, &last_compose, .offscreen);
                    j += 1;
                },
                // Effects-spec C.1 + C.1.5 — chain nested inside
                // this single_source's subtree. Phase 1 already
                // populated the chain's pool; final-composite-into-
                // parent-target is the same compose shape as nested
                // single_source / host_slot, just sourced from
                // `acquired_targets[pool_base + final_pool_local]`.
                // C.1.5 advance mirrors nested single_source's
                // no-+1 shape: `j = nested.subtree_dispatch_range[1]`
                // (the inner walk's while-condition handles the
                // chain's own-index termination).
                .chain => |nested_c| {
                    const inner_base = self.chain_pool_bases.items[j] orelse unreachable;
                    const final_target = self.acquired_targets.items[inner_base + nested_c.final_pool_local];
                    const nx: f32 = @floatFromInt(nested_c.compose_region.x - S.compose_region.x);
                    const ny: f32 = @floatFromInt(nested_c.compose_region.y - S.compose_region.y);
                    const nw: f32 = @floatFromInt(nested_c.compose_region.w);
                    const nh: f32 = @floatFromInt(nested_c.compose_region.h);
                    try self.recordChainFinalComposite(cmd, nested_c, final_target, nx, ny, nw, nh, &last_compose, .offscreen);
                    j = nested_c.subtree_dispatch_range[1];
                },
            }
        }

        // Per-target drawlist routing (Phase B.4.b.4). Render every
        // drawlist primitive whose target_dispatch_index equals
        // this dispatch's index into S's offscreen target. By walker
        // construction every primitive type yields exactly one
        // contiguous run for an offscreen target (push target on
        // enter, primitives append with that tag, pop on exit). The
        // run iterator still tolerates zero or multiple runs as a
        // generality; for offscreen the loop runs at most once per
        // pipeline.
        //
        // The order — tri, image, quad, text — mirrors Phase 2 and
        // the host's main pass so paint order inside an effect's
        // target matches paint order against the main attachment.
        // SVG fills sit behind chrome; backgrounds sit under glyphs.
        const target_extent_render = vk.c.VkExtent2D{
            .width = S.target_size[0],
            .height = S.target_size[1],
        };
        // Screen-space rebase to target-local. **Subtle SSBO timing
        // bit, worth pinning.** Phase 1 RECORDS draws here in
        // preDrawCb, but the actual SSBO upload happens later (in
        // endFrame's `writeQuads/writeMesh/writeGlyphs`, after the
        // world→screen transform on the drawlist). Vulkan executes
        // recorded draws in submission order with the SSBO state at
        // submit time — so by the time Phase 1's draws actually
        // execute on GPU, each instance's `dst_pos` is already in
        // SCREEN coords `(world - scroll) * zoom`, NOT the WORLD
        // coords the walker emitted. `world_offset` must live in the
        // SAME coord space — so it's SCREEN compose too, computed
        // here from world compose + scroll + zoom.
        //
        // TODO(zoom): target_size + per-target viewport are still
        // WORLD-sized. At zoom != 1 the box's screen extent exceeds
        // the offscreen target's framebuffer extent and clips. Wire
        // a zoom-scaled `acquire(target_key)` when zoom-on-effects
        // is exercised; current demo runs at zoom=1.
        const sx = self.frame_info.scroll_offset[0];
        const sy = self.frame_info.scroll_offset[1];
        const z = self.frame_info.zoom;
        const world_offset_target: [2]f32 = .{
            (@as(f32, @floatFromInt(S.compose_region.x)) - sx) * z,
            (@as(f32, @floatFromInt(S.compose_region.y)) - sy) * z,
        };
        const dl_p1 = &self.drawlist;
        const dispatch_index_u32: u32 = @intCast(dispatch_index);
        {
            var it = element.triRuns(dl_p1.tri_targets.items, dl_p1.tri_indices.items, dispatch_index_u32);
            while (it.next()) |run| {
                self.tri_pipeline.recordDrawIndexedRange(cmd, target_extent_render, world_offset_target, run.first_index, run.index_count, display_mod.Push.offscreen, .offscreen);
            }
        }
        {
            var it = element.runs(dl_p1.image_targets.items, dispatch_index_u32);
            const all_images = dl_p1.images.items;
            while (it.next()) |run| {
                if (run.count == 0) continue;
                self.image_pipeline.bind(cmd, target_extent_render, .offscreen);
                const subset = all_images[run.first .. run.first + run.count];
                for (subset) |im| {
                    self.image_pipeline.recordOne(cmd, target_extent_render, world_offset_target, @ptrCast(@alignCast(im.descriptor_set)), im.dst_pos, im.dst_size, display_mod.Push.offscreen);
                }
            }
        }
        {
            var it = element.runs(dl_p1.quad_targets.items, dispatch_index_u32);
            while (it.next()) |run| {
                self.quad_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen);
            }
        }
        {
            var it = element.runs(dl_p1.glyph_targets.items, dispatch_index_u32);
            while (it.next()) |run| {
                self.text_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen);
            }
        }

        vk.c.vkCmdEndRendering(cmd);

        // Barrier target → SHADER_READ_ONLY_OPTIMAL for Phase 2's
        // sampling pass (and any enclosing single_source's compose
        // in this same Phase 1 stack).
        barrierImageLayout(cmd, target_handle.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .src_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });
    }

    /// Effects-spec B.7 — Phase 1 step for a `.host_slot` dispatch.
    /// Acquires the offscreen target, transitions it to
    /// `COLOR_ATTACHMENT_OPTIMAL`, hands the cmd buffer + target
    /// off to the host callback (which opens its own render-pass
    /// scope, draws, and closes it per the HostSlotCtx contract),
    /// then transitions back to `SHADER_READ_ONLY_OPTIMAL` for
    /// Phase 2's compose sample.
    ///
    /// **Substrate-only commit (B.7).** This path runs only when a
    /// host_slot factory is registered on the Spark (B.7's
    /// `:::placeholder_scene` does so in `integration_render.zig`
    /// tests; Phase D's `:::3d-scene` lights it up in production).
    /// `installCoreComponents` does NOT register one — production
    /// frames never enter this method until Phase D.
    fn phase1ProcessHostSlot(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        dispatch_index: usize,
    ) !void {
        const H = self.pass_dispatches.items[dispatch_index].host_slot;

        // Walker contract guarantees a resolved callback by the
        // time a HostSlotStep lands on pass_dispatches; assert
        // belt-and-suspenders so any future path that bypasses the
        // walker (manual PassDispatch construction in tests) trips
        // on the first frame instead of jumping to undefined memory
        // mid-callback.
        std.debug.assert(@intFromPtr(H.invocation.callback) != 0);

        const target_key = pass_mod.TargetKey{
            .width = H.target_size[0],
            .height = H.target_size[1],
            .format = self.offscreen_format,
        };
        const target_handle = try self.target_pool.acquire(target_key);
        try self.acquired_targets.append(target_handle);
        self.dispatch_target_map.items[dispatch_index] = target_handle;

        // UNDEFINED → COLOR_ATTACHMENT_OPTIMAL. The freshly-acquired
        // target may have come back from the free list with
        // SHADER_READ_ONLY_OPTIMAL from a previous frame; UNDEFINED
        // as old_layout discards old contents which is correct
        // because the host opens its own LOAD_OP_CLEAR scope.
        barrierImageLayout(cmd, target_handle.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .src_access = 0,
            .dst_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });

        // Hand off to the host. Per HostSlotCtx contract: host opens
        // its own vkCmdBeginRendering scope, draws, closes the
        // scope, leaves the target in COLOR_ATTACHMENT_OPTIMAL on
        // return. Errors are NOT propagated — failed host renders
        // produce degraded frames, not torn-down render loops.
        const host_ctx = element.HostSlotCtx{
            .cmd = @ptrCast(cmd),
            .target_image = @ptrCast(target_handle.image()),
            .target_view = @ptrCast(target_handle.view()),
            .width = H.target_size[0],
            .height = H.target_size[1],
            .target_format = @intCast(self.color_format),
        };
        H.invocation.callback(H.invocation.user_data, host_ctx);

        // COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL. This
        // layout transition is ALSO the write-after-read barrier
        // between the host's color writes and Phase 2's compose
        // sampler — Vulkan image layout transitions execute a full
        // execution + memory barrier as a side effect. A future
        // "optimisation" that replaces this with a same-layout
        // move would silently remove the barrier and let the
        // compose sample stale data; the WAR sequencing is
        // load-bearing.
        barrierImageLayout(cmd, target_handle.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .src_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });
    }

    /// Effects-spec C.1 + C.1.5 — Phase 1 step for a `.chain` dispatch.
    /// Three-phase shape mirrors `phase1ProcessSingleSource`:
    ///
    ///   (1) Depth-first post-order recurse into nested
    ///       single_source / host_slot / chain children — their
    ///       offscreen targets must be populated before our subtree
    ///       walk samples them via compose.
    ///   (2) Acquire ping-pong pool up front (C.1). Records
    ///       `pool_base` on `chain_pool_bases[dispatch_index]` so
    ///       Phase 2 can resolve `final_pool_local`. Sets
    ///       `dispatch_target_map[dispatch_index] = pool[0]` so the
    ///       subtree's drawlist primitives route into pool[0] via
    ///       the existing per-target rasterizer routing mechanism
    ///       (B.4.b.4) — same dispatch_target_map machinery
    ///       single_source uses, no chain-specific routing path.
    ///   (3) Render subtree content into pool[0] (C.1.5): transition
    ///       pool[0] to COLOR_ATTACHMENT_OPTIMAL, begin a render
    ///       pass with LOAD_OP_CLEAR transparent, walk subtree
    ///       patterns + nested composes target-locally, route this
    ///       dispatch's drawlist primitives, end the render pass,
    ///       transition pool[0] back to SHADER_READ_ONLY_OPTIMAL.
    ///       After (3), pool[0] holds the content image that the
    ///       chain's steps[] will filter/blur/composite through the
    ///       remaining pool targets.
    ///   (4) Walk `steps[]` (Effects-spec C.2). Each step samples its
    ///       source pool target and writes its dest pool target in a
    ///       render-pass scope of its own; the layout transitions
    ///       around each draw are also the read-after-write and
    ///       write-after-read barriers that make the ping-pong safe.
    ///
    /// **Live as of C.2.** `installCoreComponents` registers
    /// `:::drop_shadow` as a chain factory, so production frames enter
    /// this method whenever a document casts a shadow. The first
    /// consumer arrived from the drop shadow rather than from the
    /// `:::bloom` this substrate was drafted for — a separable Gaussian
    /// is two passes and a composite, which is the same shape a bloom
    /// cascade is, one rung down.
    fn phase1ProcessChain(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        dispatch_index: usize,
    ) anyerror!void {
        // Explicit error set breaks the mutual-recursion inference
        // cycle with phase1ProcessSingleSource (which calls back into
        // phase1ProcessChain at its own nested-chain arm).
        const C = self.pass_dispatches.items[dispatch_index].chain;

        // (1) Depth-first post-order recurse into nested children.
        // Same skip-past-subtree shape as phase1ProcessSingleSource;
        // see dispatchOffscreenPasses for the fencepost note —
        // `+ 1` to advance past the nested dispatch's own index,
        // not just past its subtree.
        var i: u32 = C.subtree_dispatch_range[0];
        while (i < C.subtree_dispatch_range[1]) {
            switch (self.pass_dispatches.items[i]) {
                .pattern => i += 1,
                .single_source => |nested| {
                    try self.phase1ProcessSingleSource(cmd, i);
                    i = nested.subtree_dispatch_range[1] + 1;
                },
                .host_slot => {
                    try self.phase1ProcessHostSlot(cmd, i);
                    i += 1;
                },
                .chain => |nested_c| {
                    try self.phase1ProcessChain(cmd, i);
                    i = nested_c.subtree_dispatch_range[1] + 1;
                },
            }
        }

        // (2) Acquire pool. Pool-base capture happens BEFORE the
        // first acquire so the first pool target lands at
        // acquired_targets[pool_base].
        const pool_base: u32 = @intCast(self.acquired_targets.items.len);
        self.chain_pool_bases.items[dispatch_index] = pool_base;

        const target_key = pass_mod.TargetKey{
            .width = C.target_size[0],
            .height = C.target_size[1],
            .format = self.offscreen_format,
        };
        // Effects-spec C.2 — format negotiation landed, and it landed one
        // level up: EVERY offscreen target is `self.offscreen_format`
        // (RGBA16F where the device allows), not just a chain's pool, so a
        // chain does not get to disagree with the single_source target
        // nested inside it. `ChainStep.target_format` is what the component
        // reported and rides the frame fingerprint; the allocation follows
        // Spark, which is the only thing the pipelines were built against.
        var k: u16 = 0;
        while (k < C.target_pool_count) : (k += 1) {
            const target_handle = try self.target_pool.acquire(target_key);
            try self.acquired_targets.append(target_handle);
            // v1 trades one transition per first-written-pool-target
            // for uniform initial state (UNDEFINED → SHADER_READ_ONLY,
            // pool[0]'s subtree-write then transitions UP, steps'
            // dest pool targets transition UP as needed); revisit
            // if profiling shows it.
            barrierImageLayout(cmd, target_handle.image(), .{
                .src_stage = vk.c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .dst_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
                .src_access = 0,
                .dst_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
                .old_layout = vk.c.VK_IMAGE_LAYOUT_UNDEFINED,
                .new_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            });
        }

        // Wire pool[0]'s handle into dispatch_target_map so the
        // subtree's drawlist primitives (tagged with this dispatch's
        // index by the walker's current_target_dispatch_index push)
        // route into pool[0] via the existing per-target rasterizer
        // routing machinery. Symmetric with phase1ProcessSingleSource.
        const pool_zero = self.acquired_targets.items[pool_base];
        self.dispatch_target_map.items[dispatch_index] = pool_zero;

        // (3) Render subtree into pool[0]. SHADER_READ_ONLY →
        // COLOR_ATTACHMENT_OPTIMAL barrier opens write access.
        barrierImageLayout(cmd, pool_zero.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .src_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .dst_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });

        var color_att = std.mem.zeroes(vk.c.VkRenderingAttachmentInfo);
        color_att.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        color_att.imageView = pool_zero.view();
        color_att.imageLayout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        color_att.loadOp = vk.c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_att.storeOp = vk.c.VK_ATTACHMENT_STORE_OP_STORE;
        color_att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        const target_extent = vk.c.VkExtent2D{
            .width = C.target_size[0],
            .height = C.target_size[1],
        };
        var ri = std.mem.zeroes(vk.c.VkRenderingInfo);
        ri.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = target_extent };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &color_att;
        vk.c.vkCmdBeginRendering(cmd, &ri);

        // Walk subtree dispatches and record pattern + nested
        // composes target-locally. All viewports here are in
        // target-space coords (origin at C's compose_region top-left,
        // no zoom — target_size == compose_region.size by
        // construction). Mirrors phase1ProcessSingleSource's
        // subtree-walk loop exactly.
        var last_pattern: vk.c.VkPipeline = null;
        var last_compose: vk.c.VkPipeline = null;
        var j: u32 = C.subtree_dispatch_range[0];
        while (j < C.subtree_dispatch_range[1]) {
            switch (self.pass_dispatches.items[j]) {
                .pattern => |p| {
                    const px: f32 = @floatFromInt(p.layout_region.x - C.compose_region.x);
                    const py: f32 = @floatFromInt(p.layout_region.y - C.compose_region.y);
                    const pw: f32 = @floatFromInt(p.layout_region.w);
                    const ph: f32 = @floatFromInt(p.layout_region.h);
                    self.recordPatternStep(cmd, p, px, py, pw, ph, &last_pattern, .offscreen);
                    j += 1;
                },
                .single_source => |nested| {
                    const nested_target = self.dispatch_target_map.items[j] orelse unreachable;
                    const nx: f32 = @floatFromInt(nested.compose_region.x - C.compose_region.x);
                    const ny: f32 = @floatFromInt(nested.compose_region.y - C.compose_region.y);
                    const nw: f32 = @floatFromInt(nested.compose_region.w);
                    const nh: f32 = @floatFromInt(nested.compose_region.h);
                    try self.recordSingleSourceCompose(cmd, nested, nested_target, nx, ny, nw, nh, &last_compose, .offscreen);
                    j = nested.subtree_dispatch_range[1];
                },
                .host_slot => |nested_hs| {
                    const nested_target = self.dispatch_target_map.items[j] orelse unreachable;
                    const nx: f32 = @floatFromInt(nested_hs.compose_region.x - C.compose_region.x);
                    const ny: f32 = @floatFromInt(nested_hs.compose_region.y - C.compose_region.y);
                    const nw: f32 = @floatFromInt(nested_hs.compose_region.w);
                    const nh: f32 = @floatFromInt(nested_hs.compose_region.h);
                    try self.recordHostSlotCompose(cmd, nested_hs, nested_target, nx, ny, nw, nh, &last_compose, .offscreen);
                    j += 1;
                },
                .chain => |nested_c| {
                    const inner_base = self.chain_pool_bases.items[j] orelse unreachable;
                    const final_target = self.acquired_targets.items[inner_base + nested_c.final_pool_local];
                    const nx: f32 = @floatFromInt(nested_c.compose_region.x - C.compose_region.x);
                    const ny: f32 = @floatFromInt(nested_c.compose_region.y - C.compose_region.y);
                    const nw: f32 = @floatFromInt(nested_c.compose_region.w);
                    const nh: f32 = @floatFromInt(nested_c.compose_region.h);
                    try self.recordChainFinalComposite(cmd, nested_c, final_target, nx, ny, nw, nh, &last_compose, .offscreen);
                    j = nested_c.subtree_dispatch_range[1];
                },
            }
        }

        // Per-target rasterizer routing (B.4.b.4) — render every
        // drawlist primitive whose target_dispatch_index equals this
        // chain's dispatch_index into pool[0]. Same shape as
        // phase1ProcessSingleSource's routing block, just sized to
        // pool[0]'s extent.
        const target_extent_render = vk.c.VkExtent2D{
            .width = C.target_size[0],
            .height = C.target_size[1],
        };
        const sx = self.frame_info.scroll_offset[0];
        const sy = self.frame_info.scroll_offset[1];
        const z = self.frame_info.zoom;
        const world_offset_target: [2]f32 = .{
            (@as(f32, @floatFromInt(C.compose_region.x)) - sx) * z,
            (@as(f32, @floatFromInt(C.compose_region.y)) - sy) * z,
        };
        const dl_p1 = &self.drawlist;
        const dispatch_index_u32: u32 = @intCast(dispatch_index);
        {
            var it = element.triRuns(dl_p1.tri_targets.items, dl_p1.tri_indices.items, dispatch_index_u32);
            while (it.next()) |run| {
                self.tri_pipeline.recordDrawIndexedRange(cmd, target_extent_render, world_offset_target, run.first_index, run.index_count, display_mod.Push.offscreen, .offscreen);
            }
        }
        {
            var it = element.runs(dl_p1.image_targets.items, dispatch_index_u32);
            const all_images = dl_p1.images.items;
            while (it.next()) |run| {
                if (run.count == 0) continue;
                self.image_pipeline.bind(cmd, target_extent_render, .offscreen);
                const subset = all_images[run.first .. run.first + run.count];
                for (subset) |im| {
                    self.image_pipeline.recordOne(cmd, target_extent_render, world_offset_target, @ptrCast(@alignCast(im.descriptor_set)), im.dst_pos, im.dst_size, display_mod.Push.offscreen);
                }
            }
        }
        {
            var it = element.runs(dl_p1.quad_targets.items, dispatch_index_u32);
            while (it.next()) |run| {
                self.quad_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen);
            }
        }
        {
            var it = element.runs(dl_p1.glyph_targets.items, dispatch_index_u32);
            while (it.next()) |run| {
                self.text_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen);
            }
        }

        vk.c.vkCmdEndRendering(cmd);

        // pool[0] COLOR_ATTACHMENT → SHADER_READ_ONLY for steps[]
        // to sample (and Phase 2's final composite if final_pool_local
        // == 0). Mirrors phase1ProcessSingleSource's closing barrier.
        barrierImageLayout(cmd, pool_zero.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .src_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });

        // (4) Walk steps[] — Effects-spec C.2. Sequential by construction:
        // each step's closing layout transition is the barrier the next one
        // reads through, so ping-pong ordering needs no scheduling of its
        // own. Pool-local indices resolve against `pool_base`, which is why
        // the acquire above captured it before the first acquire rather
        // than deriving it after.
        for (C.steps) |step| {
            const source = self.acquired_targets.items[pool_base + step.source_pool_local];
            const dest = self.acquired_targets.items[pool_base + step.dest_pool_local];
            try self.recordChainStep(cmd, step, source, dest, C.target_size);
        }

        // Pool release happens in the same Phase 3 wholesale sweep
        // as single_source / host_slot — no chain-specific release
        // code path. The `defer for ... release` lives at the end of
        // endFrame; chain entries flow through identically.
    }

    /// Bind + draw one `.pattern` dispatch step at a caller-supplied
    /// viewport. Phase 1 supplies target-local coords; Phase 2
    /// supplies world-local coords. `last_bound` is the bind-on-
    /// change cursor — null on entry forces a fresh bind, mutated
    /// in place so successive calls only re-bind on shader change.
    /// The display push a draw into `att` should carry.
    ///
    /// The encode belongs at the composition point and happens exactly once:
    /// a pass writing an intermediate target gets passthrough, and the one
    /// writing the host's attachment gets the frame's real transform. Same
    /// rule the four content pipelines follow, said once here for the effect
    /// path — which did not follow it at all until now, and on an HDR
    /// swapchain composited its content raw into a PQ surface. A mid-grey
    /// card measured 128 outside an effect and 179 inside one.
    fn displayFor(self: *const Spark, att: vk.Attachment) display_mod.Push {
        return switch (att) {
            .main => self.frame_info.displayPush(),
            .offscreen => display_mod.Push.offscreen,
        };
    }

    /// Push an effect's uniforms plus the display head, in the layout
    /// `element.PASS_UNIFORM_OFFSET` describes. Two ranges, one call site
    /// shape, so no record path can forget the head.
    fn pushEffectUniforms(
        cmd: vk.c.VkCommandBuffer,
        layout: vk.c.VkPipelineLayout,
        disp: display_mod.Push,
        bytes: []const u8,
    ) void {
        var d = disp;
        vk.c.vkCmdPushConstants(
            cmd,
            layout,
            vk.c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(display_mod.Push),
            &d,
        );
        if (bytes.len > 0) {
            vk.c.vkCmdPushConstants(
                cmd,
                layout,
                vk.c.VK_SHADER_STAGE_FRAGMENT_BIT,
                element.PASS_UNIFORM_OFFSET,
                @intCast(bytes.len),
                bytes.ptr,
            );
        }
    }

    fn recordPatternStep(
        self: *const Spark,
        cmd: vk.c.VkCommandBuffer,
        pattern_step: element.PatternStep,
        vx: f32,
        vy: f32,
        vw: f32,
        vh: f32,
        last_bound: *vk.c.VkPipeline,
        att: vk.Attachment,
    ) void {
        const pipeline = self.pattern_pipelines.lookup(pattern_step.shader_id, att) orelse return;
        if (pipeline != last_bound.*) {
            vk.c.vkCmdBindPipeline(cmd, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            last_bound.* = pipeline;
        }
        var viewport = vk.c.VkViewport{
            .x = vx,
            .y = vy,
            .width = vw,
            .height = vh,
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        // Scissor offset must be non-negative per Vulkan spec.
        // Clamp to (0, 0) when the region extends above/left of
        // the framebuffer (scroll bringing the top of an effect
        // off-screen); the viewport already positions the
        // rasterizer correctly, scissor only bounds the write.
        var scissor = vk.c.VkRect2D{
            .offset = .{
                .x = @intFromFloat(@max(0, @round(vx))),
                .y = @intFromFloat(@max(0, @round(vy))),
            },
            .extent = .{
                .width = @intFromFloat(@max(0, @round(vw))),
                .height = @intFromFloat(@max(0, @round(vh))),
            },
        };
        vk.c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        pushEffectUniforms(
            cmd,
            self.pattern_pipelines.layout,
            self.displayFor(att),
            pattern_step.uniform_bytes[0..pattern_step.uniform_len],
        );
        vk.c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    /// Bind + draw one single-source compose dispatch — sampling
    /// `target_handle` (which Phase 1 already populated and
    /// barriered to `SHADER_READ_ONLY_OPTIMAL`) through the filter
    /// pipeline keyed by `ss.filter_shader_id`. Acquires a fresh
    /// descriptor set from the per-frame pool, writes the
    /// (view, sampler) binding, binds + draws.
    fn recordSingleSourceCompose(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        ss: element.SingleSourceStep,
        target_handle: pass_mod.TargetHandle,
        vx: f32,
        vy: f32,
        vw: f32,
        vh: f32,
        last_bound: *vk.c.VkPipeline,
        att: vk.Attachment,
    ) !void {
        const pipeline = self.single_source_pipelines.lookup(ss.filter_shader_id, att) orelse return;
        if (pipeline != last_bound.*) {
            vk.c.vkCmdBindPipeline(cmd, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            last_bound.* = pipeline;
        }
        const set = try self.single_source_descriptor_pool.acquire(
            target_handle.view(),
            self.single_source_pipelines.sampler,
        );
        var set_local = set; // pDescriptorSets wants a pointer
        vk.c.vkCmdBindDescriptorSets(
            cmd,
            vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.single_source_pipelines.layout,
            0,
            1,
            &set_local,
            0,
            null,
        );
        var viewport = vk.c.VkViewport{
            .x = vx,
            .y = vy,
            .width = vw,
            .height = vh,
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        // Scissor offset clamp — same as recordPatternStep, for
        // single_source composes scrolled partly above/left of the
        // framebuffer.
        var scissor = vk.c.VkRect2D{
            .offset = .{
                .x = @intFromFloat(@max(0, @round(vx))),
                .y = @intFromFloat(@max(0, @round(vy))),
            },
            .extent = .{
                .width = @intFromFloat(@max(0, @round(vw))),
                .height = @intFromFloat(@max(0, @round(vh))),
            },
        };
        vk.c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            self.displayFor(att),
            ss.filter_uniforms[0..ss.filter_uniforms_len],
        );
        vk.c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    /// Effects-spec B.7 — bind + draw the compose step for one
    /// `.host_slot` dispatch. Mirrors `recordSingleSourceCompose`:
    /// reuses `single_source_pipelines` (same combined-image-sampler
    /// layout) and `single_source_descriptor_pool`. The only
    /// difference is no push-constants — v1's host_slot composite
    /// shader (`copy.frag` for the B.7 stub) is a passthrough
    /// sampler with no uniforms. Phase D may extend HostSlotStep
    /// with a uniforms slot if real composite shaders need
    /// parameters; for now the absence is explicit.
    fn recordHostSlotCompose(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        hs: element.HostSlotStep,
        target_handle: pass_mod.TargetHandle,
        vx: f32,
        vy: f32,
        vw: f32,
        vh: f32,
        last_bound: *vk.c.VkPipeline,
        att: vk.Attachment,
    ) !void {
        const pipeline = self.single_source_pipelines.lookup(hs.composite_shader_id, att) orelse return;
        if (pipeline != last_bound.*) {
            vk.c.vkCmdBindPipeline(cmd, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            last_bound.* = pipeline;
        }
        const set = try self.single_source_descriptor_pool.acquire(
            target_handle.view(),
            self.single_source_pipelines.sampler,
        );
        var set_local = set;
        vk.c.vkCmdBindDescriptorSets(
            cmd,
            vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.single_source_pipelines.layout,
            0,
            1,
            &set_local,
            0,
            null,
        );
        var viewport = vk.c.VkViewport{
            .x = vx,
            .y = vy,
            .width = vw,
            .height = vh,
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        var scissor = vk.c.VkRect2D{
            .offset = .{
                .x = @intFromFloat(@max(0, @round(vx))),
                .y = @intFromFloat(@max(0, @round(vy))),
            },
            .extent = .{
                .width = @intFromFloat(@max(0, @round(vw))),
                .height = @intFromFloat(@max(0, @round(vh))),
            },
        };
        vk.c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        // v1's host_slot composite shader has no uniforms of its own, but it
        // does have the display head — a scene composited raw into a PQ
        // swapchain is the same bug as everything else on this path.
        pushEffectUniforms(cmd, self.single_source_pipelines.layout, self.displayFor(att), &.{});
        vk.c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    /// Effects-spec C.2 — run one `.chain` step: sample `source`, write
    /// `dest`, in a render-pass scope of its own.
    ///
    /// Every step is its own `vkCmdBeginRendering` / `vkCmdEndRendering`
    /// pair, which is not a choice — dynamic rendering does not nest, and
    /// Phase 1 has already closed the subtree's pass by the time steps run.
    /// The two layout transitions around the draw ARE the ping-pong's
    /// read-after-write and write-after-read barriers: a Vulkan image layout
    /// transition executes a full execution + memory barrier as a side
    /// effect, so a later "optimisation" that replaced either with a
    /// same-layout move would silently let step N+1 sample step N's
    /// unfinished writes. Same load-bearing sequencing the single_source and
    /// host_slot paths depend on, said again here because a chain has one
    /// per step rather than one per frame.
    fn recordChainStep(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        step: element.ChainPassStep,
        source: pass_mod.TargetHandle,
        dest: pass_mod.TargetHandle,
        target_size: [2]u32,
    ) !void {
        // Always `.offscreen`: a chain step's destination is a pool
        // target by definition — Phase 2 is the only thing that reaches MAIN.
        const pipeline = self.single_source_pipelines.lookup(step.composite_shader_id, .offscreen) orelse return;

        // A `.keep` step composites over what is already in `dest`, so the
        // old contents must survive the transition — which means naming the
        // real old layout rather than UNDEFINED. A `.clear` step is about to
        // overwrite every pixel, so UNDEFINED is both legal and cheaper (it
        // lets the driver discard rather than preserve).
        const keep = step.load == .keep;
        barrierImageLayout(cmd, dest.image(), .{
            .src_stage = if (keep)
                vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT
            else
                vk.c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .src_access = if (keep) vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT else 0,
            .dst_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .old_layout = if (keep)
                vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            else
                vk.c.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });

        var color_att = std.mem.zeroes(vk.c.VkRenderingAttachmentInfo);
        color_att.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        color_att.imageView = dest.view();
        color_att.imageLayout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        color_att.loadOp = if (keep)
            vk.c.VK_ATTACHMENT_LOAD_OP_LOAD
        else
            vk.c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_att.storeOp = vk.c.VK_ATTACHMENT_STORE_OP_STORE;
        color_att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        const extent = vk.c.VkExtent2D{ .width = target_size[0], .height = target_size[1] };
        var ri = std.mem.zeroes(vk.c.VkRenderingInfo);
        ri.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &color_att;
        vk.c.vkCmdBeginRendering(cmd, &ri);

        vk.c.vkCmdBindPipeline(cmd, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        const set = try self.single_source_descriptor_pool.acquire(
            source.view(),
            self.single_source_pipelines.sampler,
        );
        var set_local = set;
        vk.c.vkCmdBindDescriptorSets(
            cmd,
            vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.single_source_pipelines.layout,
            0,
            1,
            &set_local,
            0,
            null,
        );
        // Whole target: a chain step is a full-image filter, so the viewport
        // is the pool target and not a compose region. Region placement is
        // Phase 2's job, once.
        var viewport = vk.c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(target_size[0]),
            .height = @floatFromInt(target_size[1]),
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        var scissor = vk.c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        vk.c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            display_mod.Push.offscreen,
            step.uniform_bytes[0..step.uniform_len],
        );
        vk.c.vkCmdDraw(cmd, 3, 1, 0, 0);
        vk.c.vkCmdEndRendering(cmd);

        barrierImageLayout(cmd, dest.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .src_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });
    }

    /// Effects-spec C.2 — bind + draw a chain's final composite. Mirrors
    /// `recordSingleSourceCompose` exactly; the only differences are where
    /// the shader id comes from (`final_composite_shader_id`) and that the
    /// sampled target is `pool[final_pool_local]` rather than the chain's
    /// single offscreen target.
    fn recordChainFinalComposite(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        ch: element.ChainStep,
        target_handle: pass_mod.TargetHandle,
        vx: f32,
        vy: f32,
        vw: f32,
        vh: f32,
        last_bound: *vk.c.VkPipeline,
        att: vk.Attachment,
    ) !void {
        const pipeline = self.single_source_pipelines.lookup(ch.final_composite_shader_id, att) orelse return;
        if (pipeline != last_bound.*) {
            vk.c.vkCmdBindPipeline(cmd, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            last_bound.* = pipeline;
        }
        const set = try self.single_source_descriptor_pool.acquire(
            target_handle.view(),
            self.single_source_pipelines.sampler,
        );
        var set_local = set;
        vk.c.vkCmdBindDescriptorSets(
            cmd,
            vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.single_source_pipelines.layout,
            0,
            1,
            &set_local,
            0,
            null,
        );
        var viewport = vk.c.VkViewport{
            .x = vx,
            .y = vy,
            .width = vw,
            .height = vh,
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        var scissor = vk.c.VkRect2D{
            .offset = .{
                .x = @intFromFloat(@max(0, @round(vx))),
                .y = @intFromFloat(@max(0, @round(vy))),
            },
            .extent = .{
                .width = @intFromFloat(@max(0, @round(vw))),
                .height = @intFromFloat(@max(0, @round(vh))),
            },
        };
        vk.c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            self.displayFor(att),
            ch.final_composite_uniforms[0..ch.final_composite_uniforms_len],
        );
        vk.c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    /// Apply scroll/zoom transform, upload glyph SSBO, record
    /// tri/image/quad/text draws into the attached cmd. **Must run
    /// inside an active `vkCmdBeginRendering` scope** owned by the
    /// host (host has the swapchain image; spark just records draws).
    ///
    /// Effects-spec Phase B.4.b.3: pass-dispatch loop now Phase 2 of
    /// the three-phase processor — skip-past-subtree iteration over
    /// `pass_dispatches`, handling top-level `.pattern` arms (render
    /// in place against the main attachment) and top-level
    /// `.single_source` arms (compose-sample their pre-rendered
    /// targets via descriptor sets). Subtrees were already processed
    /// by `dispatchOffscreenPasses` (Phase 1). Phase 3 wholesale-
    /// releases every Phase 1 acquire at the end of this method.
    pub fn endFrame(self: *Spark) !void {
        const cmd = self.attached_cmd orelse return error.NoCmdAttached;
        const extent = self.frame_info.extent;
        const dl = &self.drawlist;

        // World → screen transform — only on frames where
        // `beginFrame.reset=true` cleared the drawlist and
        // `layoutAndRender` repopulated it in world coords. On
        // skip-layout frames the drawlist already holds screen-space
        // data from the previous frame; transforming again would
        // double-multiply. Same idempotence trick `runLayout` used in
        // the pre-Phase-3 demo's drawCb gate.
        if (self.drawlist_needs_transform) {
            const sx = self.frame_info.scroll_offset[0];
            const sy = self.frame_info.scroll_offset[1];
            const z = self.frame_info.zoom;
            for (dl.glyphs.items) |*g| {
                g.dst_pos[0] -= sx;
                g.dst_pos[1] -= sy;
                g.dst_pos[0] *= z;
                g.dst_pos[1] *= z;
                g.dst_size[0] *= z;
                g.dst_size[1] *= z;
            }
            for (dl.quads.items) |*q| {
                q.dst_pos[0] -= sx;
                q.dst_pos[1] -= sy;
                q.dst_pos[0] *= z;
                q.dst_pos[1] *= z;
                q.dst_size[0] *= z;
                q.dst_size[1] *= z;
                q.radius *= z;
            }
            for (dl.tris.items) |*v| {
                v.pos[0] -= sx;
                v.pos[1] -= sy;
                v.pos[0] *= z;
                v.pos[1] *= z;
            }
            for (dl.images.items) |*im| {
                im.dst_pos[0] -= sx;
                im.dst_pos[1] -= sy;
                im.dst_pos[0] *= z;
                im.dst_pos[1] *= z;
                im.dst_size[0] *= z;
                im.dst_size[1] *= z;
            }
            self.drawlist_needs_transform = false;
        }

        // Upload all per-pipeline SSBOs / VBOs. Host-coherent memory
        // makes these plain memcpys — visible to the next submit
        // without an explicit flush. Order doesn't matter for the
        // uploads; the draws below are what fix paint order.
        try self.quad_pipeline.writeQuads(dl.quads.items);
        try self.tri_pipeline.writeMesh(dl.tris.items, dl.tri_indices.items);
        try self.text_pipeline.writeGlyphs(dl.glyphs.items);

        // Phase 2 dispatch loop — skip-past-subtree iteration over
        // pass_dispatches. Top-level `.pattern` arms render in place
        // against the main attachment with world-local coords
        // (existing Decision #12 always-background behaviour); top-
        // level `.single_source` arms compose-sample their pre-
        // rendered targets (populated by Phase 1's
        // `dispatchOffscreenPasses`). Subtrees of single_source
        // arms were processed inside Phase 1 — the iteration
        // advances past them via `subtree_dispatch_range[1]`. Same
        // iteration shape as Phase 1 so adding a new arm variant
        // means changing one switch in two places, not redesigning
        // either loop.
        //
        // Bind-on-change for v1 (per-arm cursors — pattern and
        // single_source pipelines have different layouts so they
        // can't share a cursor); no sort by shader_id since N is
        // small (~1-3 effects/doc). Sort optimisation deferred to
        // Phase C+ chain effects (bloom mips) make per-bind cost
        // matter.
        if (self.pass_dispatches.items.len > 0) {
            // B.6.b — pre-compute is_top_level bitmap. The walker emits
            // patterns BEFORE their parent single_source (post-order),
            // so a naive forward iteration treats nested patterns as
            // top-level and dispatches them on MAIN. Mark every
            // dispatch inside a single_source's subtree_dispatch_range
            // as nested; Phase 2 skips those (Phase 1 already
            // rendered them into the parent's offscreen target).
            const pd_len = self.pass_dispatches.items.len;
            const is_nested = try self.allocator.alloc(bool, pd_len);
            defer self.allocator.free(is_nested);
            @memset(is_nested, false);
            for (self.pass_dispatches.items) |d| {
                switch (d) {
                    .single_source => |ss| {
                        var k = ss.subtree_dispatch_range[0];
                        while (k < ss.subtree_dispatch_range[1]) : (k += 1) {
                            is_nested[k] = true;
                        }
                    },
                    // Effects-spec C.1.5 — chain joins single_source
                    // as a content-wrapping shape. Its subtree
                    // dispatches were rendered into pool[0] by
                    // Phase 1; Phase 2 must skip them as nested.
                    .chain => |c| {
                        var k = c.subtree_dispatch_range[0];
                        while (k < c.subtree_dispatch_range[1]) : (k += 1) {
                            is_nested[k] = true;
                        }
                    },
                    else => {},
                }
            }

            const sx = self.frame_info.scroll_offset[0];
            const sy = self.frame_info.scroll_offset[1];
            const z = self.frame_info.zoom;
            var last_pattern: vk.c.VkPipeline = null;
            var last_compose: vk.c.VkPipeline = null;
            var i: usize = 0;
            while (i < self.pass_dispatches.items.len) {
                if (is_nested[i]) {
                    i += 1;
                    continue;
                }
                switch (self.pass_dispatches.items[i]) {
                    .pattern => |p| {
                        // World-local viewport: (region - scroll) * zoom.
                        // Coord-space assumption — world coords are
                        // top-left-origin pixel space, matching
                        // `VkRect2D`'s expectation directly. Phase C's
                        // multi-resolution chain passes will introduce
                        // per-pass scale; revisit when chain effects
                        // land non-1:1 target ratios.
                        const wx: f32 = @floatFromInt(p.layout_region.x);
                        const wy: f32 = @floatFromInt(p.layout_region.y);
                        const ww: f32 = @floatFromInt(p.layout_region.w);
                        const wh: f32 = @floatFromInt(p.layout_region.h);
                        const sxr = (wx - sx) * z;
                        const syr = (wy - sy) * z;
                        const swr = ww * z;
                        const shr = wh * z;
                        self.recordPatternStep(cmd, p, sxr, syr, swr, shr, &last_pattern, .main);
                        i += 1;
                    },
                    .single_source => |ss| {
                        // Top-level compose. Phase 1 already
                        // populated the target and barriered it to
                        // SHADER_READ_ONLY_OPTIMAL; dispatch_target_map
                        // stores the handle at this dispatch index.
                        // Missing handle here would mean Phase 1
                        // failed silently — unreachable in healthy
                        // code, asserted explicitly.
                        const target = self.dispatch_target_map.items[i] orelse unreachable;
                        const wx: f32 = @floatFromInt(ss.compose_region.x);
                        const wy: f32 = @floatFromInt(ss.compose_region.y);
                        const ww: f32 = @floatFromInt(ss.compose_region.w);
                        const wh: f32 = @floatFromInt(ss.compose_region.h);
                        const sxr = (wx - sx) * z;
                        const syr = (wy - sy) * z;
                        const swr = ww * z;
                        const shr = wh * z;
                        try self.recordSingleSourceCompose(cmd, ss, target, sxr, syr, swr, shr, &last_compose, .main);
                        // +1 advances past the single_source itself
                        // (subtree[1] is exclusive END of subtree,
                        // single_source sits AT that index). Without
                        // the +1 we infinite-loop on this entry.
                        // Same fencepost as Phase 1.
                        i = ss.subtree_dispatch_range[1] + 1;
                    },
                    // Effects-spec B.7. Top-level host_slot compose —
                    // same shape as single_source compose, with the
                    // target filled by the host callback in Phase 1
                    // instead of by spark's walker. No subtree, so
                    // advance is plain `i += 1`.
                    .host_slot => |hs| {
                        const target = self.dispatch_target_map.items[i] orelse unreachable;
                        const wx: f32 = @floatFromInt(hs.compose_region.x);
                        const wy: f32 = @floatFromInt(hs.compose_region.y);
                        const ww: f32 = @floatFromInt(hs.compose_region.w);
                        const wh: f32 = @floatFromInt(hs.compose_region.h);
                        const sxr = (wx - sx) * z;
                        const syr = (wy - sy) * z;
                        const swr = ww * z;
                        const shr = wh * z;
                        try self.recordHostSlotCompose(cmd, hs, target, sxr, syr, swr, shr, &last_compose, .main);
                        i += 1;
                    },
                    // Effects-spec C.1 — top-level chain compose into
                    // MAIN. Mirrors single_source's Phase 2 shape:
                    // Phase 1 already populated the chain's
                    // ping-pong pool and left `pool[final_pool_local]`
                    // in SHADER_READ_ONLY_OPTIMAL; this samples that
                    // target and writes into MAIN at `compose_region`
                    // via `final_composite_shader_id`. No subtree, so
                    // advance is plain `i += 1`.
                    .chain => |c| {
                        const pool_base = self.chain_pool_bases.items[i] orelse unreachable;
                        const final_target = self.acquired_targets.items[pool_base + c.final_pool_local];
                        const wx: f32 = @floatFromInt(c.compose_region.x);
                        const wy: f32 = @floatFromInt(c.compose_region.y);
                        const ww: f32 = @floatFromInt(c.compose_region.w);
                        const wh: f32 = @floatFromInt(c.compose_region.h);
                        const sxr = (wx - sx) * z;
                        const syr = (wy - sy) * z;
                        const swr = ww * z;
                        const shr = wh * z;
                        try self.recordChainFinalComposite(cmd, c, final_target, sxr, syr, swr, shr, &last_compose, .main);
                        i += 1;
                    },
                }
            }
        }

        // Per-target rasterizer routing for the MAIN attachment
        // (Phase B.4.b.4). Interleaved single_source subtrees split
        // the MAIN run into multiple chunks separated by per-target
        // primitives (`text :::drop_shadow{box} text` → two MAIN
        // runs around one TARGET run). The iterator yields each
        // MAIN run as `(first, count)`; recordDrawRange handles
        // each one with vkCmdDraw's `firstInstance` argument (the
        // shaders read `gl_InstanceIndex` which auto-includes it).
        //
        // For non-effect docs there's exactly one run covering the
        // whole array, so the cost reduces to one recordDrawRange
        // per pipeline — identical command volume to the pre-B.4.b.4
        // single recordDraw, just with `firstInstance = 0` made
        // explicit. The TriRun iterator's index-space arithmetic
        // means `vkCmdDrawIndexed` receives the same arguments as
        // before in the no-effect case.
        //
        // Paint order: tri → image → quad → text. SVG fills under
        // chrome under glyphs — same as pre-B.4.b.4 and same as the
        // offscreen-target order inside Phase 1.
        // MAIN attachment world_offset = (0, 0). Drawlist primitives
        // already carry screen-space coords by this point (endFrame's
        // world→screen transform ran above) — no rebase needed. The
        // (0, 0) here is the documented identity case that makes the
        // single-shader-path work for both attachments without
        // branching (Phase B.5 substrate).
        const main_world_offset: [2]f32 = .{ 0, 0 };
        // The display transform applies HERE and nowhere else. This is the
        // composition point — the one place spark writes to the surface the
        // host will present. Phase 1's offscreen target renders pass
        // `.offscreen` because an effect target is an intermediate that gets
        // composited through these same pipelines later; encoding into one
        // would encode twice, and PQ twice is not PQ.
        const disp = self.frame_info.displayPush();
        {
            var it = element.triRuns(dl.tri_targets.items, dl.tri_indices.items, element.MAIN_TARGET);
            while (it.next()) |run| {
                self.tri_pipeline.recordDrawIndexedRange(cmd, extent, main_world_offset, run.first_index, run.index_count, disp, .main);
            }
        }
        {
            var it = element.runs(dl.image_targets.items, element.MAIN_TARGET);
            const all_images = dl.images.items;
            while (it.next()) |run| {
                if (run.count == 0) continue;
                self.image_pipeline.bind(cmd, extent, .main);
                const subset = all_images[run.first .. run.first + run.count];
                for (subset) |im| {
                    self.image_pipeline.recordOne(cmd, extent, main_world_offset, @ptrCast(@alignCast(im.descriptor_set)), im.dst_pos, im.dst_size, disp);
                }
            }
        }
        {
            var it = element.runs(dl.quad_targets.items, element.MAIN_TARGET);
            while (it.next()) |run| {
                self.quad_pipeline.recordDrawRange(cmd, extent, main_world_offset, run.first, run.count, disp, .main);
            }
        }
        {
            var it = element.runs(dl.glyph_targets.items, element.MAIN_TARGET);
            while (it.next()) |run| {
                self.text_pipeline.recordDrawRange(cmd, extent, main_world_offset, run.first, run.count, disp, .main);
            }
        }

        // Phase 3 — wholesale release every Phase 1 acquire back
        // to the target pool. v1: release all at end of Phase 2
        // (the main pass has consumed every offscreen target's
        // compose dispatch by now, so the CPU side is done with
        // every handle). Mid-frame release (Decision #4) deferred
        // to Phase C+ when target reuse within a frame matters at
        // bloom-mip scale; not a v1 cost.
        for (self.acquired_targets.items) |handle| {
            self.target_pool.release(handle);
        }
        self.acquired_targets.clearRetainingCapacity();
    }

    /// Drain pending I/O completions on the main thread. Host calls
    /// once per frame, typically right before `beginFrame`. Each
    /// completion is dispatched via its `PendingHeader.handle_completion`
    /// function pointer; the polymorphic header pattern lets every
    /// async-using component plug in without spark knowing the
    /// specific completion shape.
    pub fn tick(self: *Spark) void {
        _ = self.io_channel.drain(self.io_channel, drainHandler);
    }

    fn drainHandler(channel: *io.IoChannel, completion: io.Completion) void {
        _ = channel;
        // Polymorphic header lives at user_data offset 0.
        const hdr: *io.PendingHeader = @ptrFromInt(completion.user_data);
        hdr.handle_completion(completion);
    }

    // ── Input dispatch ──────────────────────────────────────────────

    /// Dispatch a mouse move. Position is in world coords (host
    /// un-transforms screen → world if it's applying a zoom/scroll).
    /// Routes to captured Hit if a drag is in progress; otherwise
    /// does nothing (hover is not currently dispatched).
    pub fn dispatchMouseMove(self: *Spark, x: f32, y: f32) !void {
        self.mouse_x = x;
        self.mouse_y = y;
        if (self.mouse_down) {
            if (self.captured) |hit| {
                try dispatchHit(hit, .{ .mouse_move = .{
                    .local = .{ x - hit.box.x, y - hit.box.y },
                    .button = 0,
                    .button_down = true,
                } }, self.host_state);
            }
        }
    }

    /// Does the document claim the pointer at `(x, y)`?
    ///
    /// True when some element has registered a hit box under that point —
    /// i.e. when a press there would be routed into the document rather than
    /// falling through to whatever is behind it. Only interactive elements
    /// register hit boxes, so this is spark's own answer to "whose click is
    /// this", and a host arbitrating between the document and a 3D scene
    /// underneath should ask it rather than testing a rectangle of its own:
    /// two region tests are two things that drift.
    ///
    /// Also true while a drag is CAPTURED, wherever the pointer has since
    /// moved to. A slider grabbed at its edge and dragged past the document
    /// is still being dragged, and a host that stopped yielding halfway
    /// through would hand the rest of the gesture to the scene.
    ///
    /// Coordinates are world coords, the same ones `dispatchMouseMove` takes.
    pub fn claimsPointer(self: *const Spark, x: f32, y: f32) bool {
        if (self.captured != null) return true;
        return findHit(self.drawlist.hits.items, x, y) != null;
    }

    /// Dispatch a primary-button transition. `down=true` on press,
    /// `down=false` on release. Manages pointer capture + focus.
    pub fn dispatchMouseButton(self: *Spark, x: f32, y: f32, down: bool) !void {
        self.mouse_x = x;
        self.mouse_y = y;
        const prev_down = self.mouse_down;
        self.mouse_down = down;

        if (down and !prev_down) {
            const maybe_hit = findHit(self.drawlist.hits.items, x, y);
            // Focus management.
            const new_focus_ctx: ?*anyopaque = blk: {
                if (maybe_hit) |h| if (h.focusable) break :blk h.ctx;
                break :blk null;
            };
            const old_focus_ctx: ?*anyopaque = if (self.focused) |f| f.ctx else null;
            if (new_focus_ctx != old_focus_ctx) {
                if (self.focused) |old| dispatchHit(old, .focus_lost, self.host_state) catch {};
                self.focused = if (maybe_hit) |h| if (h.focusable) h else null else null;
                if (self.focused) |new| dispatchHit(new, .focus_gained, self.host_state) catch {};
            }
            if (maybe_hit) |hit| {
                self.captured = hit;
                try dispatchHit(hit, .{ .mouse_down = .{
                    .local = .{ x - hit.box.x, y - hit.box.y },
                    .button = 0,
                    .button_down = true,
                } }, self.host_state);
            }
        } else if (!down and prev_down) {
            if (self.captured) |hit| {
                try dispatchHit(hit, .{ .mouse_up = .{
                    .local = .{ x - hit.box.x, y - hit.box.y },
                    .button = 0,
                    .button_down = false,
                } }, self.host_state);
                self.captured = null;
            }
        }
    }

    /// Dispatch a keyboard event to the focused hit (no-op when no
    /// focus). Host translates platform keysym → element.KeyEvent
    /// (raw GLFW keycode + mods).
    pub fn dispatchKey(self: *Spark, ev: element.KeyEvent) !void {
        if (self.focused) |hit| {
            try dispatchHit(hit, .{ .key_down = ev }, self.host_state);
        }
    }

    /// Dispatch a Unicode codepoint to the focused hit (text input
    /// path). No-op when no focus.
    pub fn dispatchChar(self: *Spark, codepoint: u32) !void {
        if (self.focused) |hit| {
            try dispatchHit(hit, .{ .char_input = codepoint }, self.host_state);
        }
    }

    /// Clear keyboard focus and fire `focus_lost` on the previous
    /// holder. Use this from an Esc handler or when the host wants
    /// to take focus back (e.g. on click-outside the doc surface).
    pub fn clearFocus(self: *Spark) void {
        if (self.focused) |old| {
            dispatchHit(old, .focus_lost, self.host_state) catch {};
            self.focused = null;
        }
    }

    /// Apply an LM-style update directive (the `:::update` wire
    /// format). Re-parses, dispatches against the registry, returns
    /// the number of directives applied.
    pub fn applyUpdate(self: *Spark, source: []const u8) !usize {
        const update_mod = @import("update.zig");
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        return update_mod.applyAll(arena.allocator(), self.host_state, self.registry, source);
    }

    // ── Test stub ───────────────────────────────────────────────────

    /// Test-only fixture. Returns a `Spark` whose `allocator` is the
    /// only valid field; every owned resource is `undefined`.
    /// Suitable for component-internal unit tests that exercise
    /// ingest/state-update paths without touching layout, render,
    /// fonts, Vulkan, or any cross-cutting dependency. Patch
    /// `host_state` / `compute_jobs` / etc. on the returned struct
    /// if the test path needs them.
    pub fn testStub(allocator: std.mem.Allocator) Spark {
        return .{
            .allocator = allocator,
            .vk_ctx = undefined,
            .color_format = undefined,
            .offscreen_format = undefined,
            .mono_atlas = undefined,
            .color_atlas = undefined,
            .text_pipeline = undefined,
            .quad_pipeline = undefined,
            .tri_pipeline = undefined,
            .image_pipeline = undefined,
            .glyph_cache = undefined,
            .glyph_cache_lock = .{},
            .layout_cache = undefined,
            .layout_context = undefined,
            .registry = undefined,
            .io_channel = undefined,
            .drawlist = undefined,
            .pass_dispatches = undefined,
            .target_pool = undefined,
            .shader_resolver = undefined,
            .pattern_pipelines = undefined,
            .single_source_pipelines = undefined,
            .single_source_descriptor_pool = undefined,
            .acquired_targets = undefined,
            .dispatch_target_map = undefined,
            .chain_pool_bases = undefined,
            .compute_jobs = undefined,
            .io_jobs = undefined,
            .fonts = undefined,
            .theme = undefined,
            .host_state = undefined,
        };
    }
};

// ── Helpers ────────────────────────────────────────────────────────

/// Image-layout barrier helper for Phase 1 offscreen target
/// transitions. Same shape as `src/gpu/renderer.zig`'s private
/// `transitionImage` (color aspect, single mip, single layer,
/// queue-family-ignored) — duplicated here rather than threaded
/// through a cross-module dependency because the transition
/// inputs (stages, accesses, layouts) are all the divergence and
/// the boilerplate is short. Phase B.4.b.3.
const ImageBarrier = struct {
    src_stage: vk.c.VkPipelineStageFlags2,
    dst_stage: vk.c.VkPipelineStageFlags2,
    src_access: vk.c.VkAccessFlags2,
    dst_access: vk.c.VkAccessFlags2,
    old_layout: vk.c.VkImageLayout,
    new_layout: vk.c.VkImageLayout,
};

fn barrierImageLayout(cmd: vk.c.VkCommandBuffer, image: vk.c.VkImage, t: ImageBarrier) void {
    var b = std.mem.zeroes(vk.c.VkImageMemoryBarrier2);
    b.sType = vk.c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    b.srcStageMask = t.src_stage;
    b.dstStageMask = t.dst_stage;
    b.srcAccessMask = t.src_access;
    b.dstAccessMask = t.dst_access;
    b.oldLayout = t.old_layout;
    b.newLayout = t.new_layout;
    b.srcQueueFamilyIndex = vk.c.VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = vk.c.VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = .{
        .aspectMask = vk.c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    var dep = std.mem.zeroes(vk.c.VkDependencyInfo);
    dep.sType = vk.c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &b;
    vk.c.vkCmdPipelineBarrier2(cmd, &dep);
}

/// Seed the shader resolver with every built-in pass shader at
/// Spark init time. Effects-spec Phase A.4 + A.5 + B.4.b.1 + B.5:
/// registers `fullscreen.vert` (shared), the three Phase A.5 canary
/// pattern fragments (`gradient`, `pattern`, `noise`), the Phase
/// B.4.b.1 substrate-smoke filter (`copy`), and the Phase B.5
/// first user-facing single_source filter (`drop_shadow`). Phase
/// B.6+ adds `frosted_glass`. When the list grows past comfortable
/// inline size, split into `src/pass/embedded.zig`.
///
/// **Eager-registration scaling caveat.** v1 registers every
/// shader at Spark init — fine while the set is small. Phase C
/// `bloom` will multiply: bloom needs N downsample mip levels, and
/// each might want a distinct shader specialization (separable
/// horizontal/vertical, threshold-aware vs naive). At that point a
/// lazy variant (`resolver.registerLazy(name, fn() spv)` or pull-
/// through compilation on first `resolve()`) is the answer. Today
/// the cost is one HashMap put per shader at startup; Phase C is
/// where this stops being free.
///
/// **Borrowing contract.** The registered slices point into the
/// `shaders` module's `@embedFile`'d data — process-lifetime, no
/// free needed. The resolver holds the borrowed pointers and never
/// owns them. Future asset-cache-loaded shaders (per the resolver's
/// provenance-ladder note) carry their own lifetime via the cache.
///
/// **Pipeline construction is eager** (Phase A.6.b watch-point #3):
/// for each `.frag` shader registered with the resolver, we also
/// call `pattern_pipelines.compile()` so the `VkPipeline` is ready
/// before any `Spark.endFrame` dispatches against it. Eager is
/// cheap and simple for v1 — every shader produces one pipeline at
/// init time. Lazy construction becomes valuable when Phase C bloom
/// targets HDR mips at different formats and the pipeline-per-(id,
/// format) space gets large; v1 doesn't need it.
fn registerEmbeddedPassShaders(
    resolver: *pass_mod.ShaderResolver,
    pipelines: *pass_mod.PatternPipelineCache,
    single_source: *pass_mod.SingleSourcePipelineCache,
) !void {
    const shaders = @import("shaders");
    // Vertex shader is registered in the resolver for symmetry /
    // future lookup paths, but doesn't get its own pattern pipeline
    // (it's the shared vert paired with each frag — built into the
    // cache directly at init time via `fullscreen_vert_module`).
    try resolver.register("fullscreen.vert", &shaders.fullscreen_vert);

    try resolver.register("gradient.frag", &shaders.gradient_frag);
    try pipelines.compile(pass_mod.shaderIdFromName("gradient.frag"), &shaders.gradient_frag);

    try resolver.register("pattern.frag", &shaders.pattern_frag);
    try pipelines.compile(pass_mod.shaderIdFromName("pattern.frag"), &shaders.pattern_frag);

    try resolver.register("noise.frag", &shaders.noise_frag);
    try pipelines.compile(pass_mod.shaderIdFromName("noise.frag"), &shaders.noise_frag);

    // Effects-spec Phase B.4.b.1 substrate-smoke filter. Registered
    // here so the SingleSourcePipelineCache's eager-compile path
    // gets exercised end-to-end at every Spark.init, not just by
    // its own unit tests. No factory ships against `copy.frag` —
    // it's substrate validation, not a user-facing effect.
    try resolver.register("copy.frag", &shaders.copy_frag);
    try single_source.compile(pass_mod.shaderIdFromName("copy.frag"), &shaders.copy_frag);

    // Effects-spec Phase B.6 — second user-facing single_source
    // filter. Frosted-glass factory (`:::frosted_glass`). Ratifies
    // the B.6.a cache substrate (no disable_cache workaround) and
    // shares the drop_shadow descriptor-layout shape — same
    // pipeline cache, same eager-compile discipline.
    try resolver.register("frosted_glass.frag", &shaders.frosted_glass_frag);
    try single_source.compile(pass_mod.shaderIdFromName("frosted_glass.frag"), &shaders.frosted_glass_frag);

    // Effects-spec Phase B.6.d — third single_source filter.
    // Liquid-glass factory (`:::liquid_glass`). Rounded-box SDF
    // refraction + chromatic aberration + rim + tint. First effect
    // authored via the B.6.c SingleSourceFactory generator.
    try resolver.register("liquid_glass.frag", &shaders.liquid_glass_frag);
    try single_source.compile(pass_mod.shaderIdFromName("liquid_glass.frag"), &shaders.liquid_glass_frag);

    // Effects-spec Phase B.7 — default composite shader for the
    // `.host_slot` PassShape arm. Compiled into the single_source
    // pipeline cache (combined-image-sampler layout matches; v1
    // host_slot's composite step reuses the cache rather than
    // standing up a parallel HostSlotPipelineCache). The B.7 stub
    // factory (`:::placeholder_scene`, registered only by
    // `integration_render.zig` tests) drives this shader; Phase D's
    // `:::3d-scene` real-scene composite shaders register alongside.
    try resolver.register("host_slot_passthrough.frag", &shaders.host_slot_passthrough_frag);
    try single_source.compile(pass_mod.shaderIdFromName("host_slot_passthrough.frag"), &shaders.host_slot_passthrough_frag);

    // Effects-spec Phase C.2 — one axis of a separable Gaussian. Compiled
    // into the single_source cache because a chain step has exactly the
    // single_source pipeline shape (one combined-image-sampler, one
    // push-constant range, a fullscreen triangle); what makes it a chain
    // step is where its source and destination come from, not how it binds.
    // Standing up a parallel ChainPipelineCache would be two caches with
    // the same contents.
    try resolver.register("gaussian_alpha.frag", &shaders.gaussian_alpha_frag);
    try single_source.compile(pass_mod.shaderIdFromName("gaussian_alpha.frag"), &shaders.gaussian_alpha_frag);
}

fn dispatchHit(hit: element.Hit, event: element.InputEvent, default_state: *state_mod.State) !void {
    const on_input = hit.vtable.on_input orelse return;
    // Embedded-doc walks stamp the child state pointer onto the Hit;
    // top-level walks leave it null → fall back to the dispatcher's
    // default (the host's root State).
    const eff: *anyopaque = hit.state orelse @ptrCast(default_state);
    try on_input(hit.ctx, event, eff);
}

fn findHit(hits: []const element.Hit, x: f32, y: f32) ?element.Hit {
    var i = hits.len;
    while (i > 0) {
        i -= 1;
        const h = hits[i];
        if (x >= h.box.x and x < h.box.x + h.box.w and
            y >= h.box.y and y < h.box.y + h.box.h)
        {
            return h;
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "claimsPointer: inside a hit box yes, outside no, and captured always" {
    // The host's arbitration question, answered by the same `findHit` the
    // dispatcher uses — which is the point of exposing it rather than letting
    // a host keep its own rectangle.
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.captured = null;

    // A vtable that is never called — `claimsPointer` only reads boxes.
    const vtable = element.ElementVTable{
        .layout_and_render = struct {
            fn f(_: *anyopaque, _: [2]f32, _: element.Constraints, _: *element.LayoutCtx, _: *element.DrawList) anyerror!element.Box {
                return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            }
        }.f,
    };
    var dummy: u8 = 0;
    try sp.drawlist.hits.append(.{
        .box = .{ .x = 10, .y = 20, .w = 100, .h = 40 },
        .vtable = &vtable,
        .ctx = &dummy,
    });

    // Inside, and on the half-open edges the dispatcher itself uses.
    try testing.expect(sp.claimsPointer(50, 40));
    try testing.expect(sp.claimsPointer(10, 20));
    // Rule 1: assert the NO before believing the yes — a predicate stuck at
    // true would satisfy every other assertion in this test.
    try testing.expect(!sp.claimsPointer(9, 40));
    try testing.expect(!sp.claimsPointer(110, 40));
    try testing.expect(!sp.claimsPointer(500, 500));

    // A captured drag claims the pointer wherever it has wandered to. Without
    // this a host yields for the first half of a slider drag and hands the
    // rest to whatever is behind the document.
    sp.captured = sp.drawlist.hits.items[0];
    try testing.expect(sp.claimsPointer(500, 500));
}

test "Spark: testStub produces a usable shell for component tests" {
    // Sanity check that the stub-construction path compiles. The
    // real init path is exercised by main.zig (and Phase 5's
    // integration tests when they land).
    const s = Spark.testStub(testing.allocator);
    try testing.expect(@sizeOf(@TypeOf(s)) > 0);
    // `glyph_cache_lock` is real (Mutex has no resources to free).
}
