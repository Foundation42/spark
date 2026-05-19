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
const element_layout = @import("element_layout.zig");
const document_mod = @import("document.zig");
const io = io_channel_mod;

/// Wire-format region for a pass dispatch. i32 fields (not f32) so
/// the determinism hash has no float-equality questions — the
/// pass-graph compiler quantises layout regions to physical pixels
/// before recording a dispatch. Distinct from `element.Box` (layout
/// output, f32) — this type only ever appears in `PassDispatch`.
pub const PassRegion = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// One record of work the pass-graph compiler will eventually emit:
/// a shader bound to a region of the frame, fed by uniform bytes,
/// ordered within the frame by `sequence_index`. Effects-spec Phase
/// A.0 — the type, field, and hashing protocol land before the
/// compiler that populates them, so every Phase A commit (.2, .3,
/// .5, .6) verifies determinism through the same path.
///
/// Wire-format protocol (the hasher in `integration_render.zig`
/// walks fields in this exact order; both ends move together):
///
///   shader_id           — 16 bytes (opaque, provenance-agnostic
///                         per effects-spec Decision #9)
///   layout_region       — PassRegion, 16 bytes (x/y/w/h as i32)
///   uniform_bytes_len   — u32, little-endian
///   uniform_bytes       — raw uniform payload, std140 layout
///   sequence_index      — u32, pass-monotonic within frame
///
/// Order is canonical; the walk iterates the slice in index order.
/// If the protocol changes, this comment is the contract — update
/// it and the hasher together in the same commit.
pub const PassDispatch = struct {
    shader_id: [16]u8,
    layout_region: PassRegion,
    /// Borrowed view into uniform storage owned elsewhere (target
    /// pool / compiler arena once those land). Lifetime is the
    /// current frame; reset at `beginFrame(.{ .reset = true })`.
    uniform_bytes: []const u8,
    sequence_index: u32,
};

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
    /// When A.3 grows real pass-graph state (target pool, barrier
    /// plan, dependency edges), promote into a `PassGraph` struct
    /// on Spark and rename to `pass_graph.dispatches` — one cheap
    /// rename, no protocol churn.
    pass_dispatches: std.ArrayList(PassDispatch),

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
        // ── Atlases ─────────────────────────────────────────────────
        var mono_atlas = try atlas_mod.Atlas.init(opts.vk_ctx, opts.mono_atlas_size, opts.mono_atlas_size, .mono_r8);
        errdefer mono_atlas.deinit();
        var color_atlas = try atlas_mod.Atlas.init(opts.vk_ctx, opts.color_atlas_size, opts.color_atlas_size, .color_rgba8);
        errdefer color_atlas.deinit();

        // ── Pipelines ───────────────────────────────────────────────
        var text_pipeline = try tp.TextPipeline.init(
            opts.vk_ctx,
            opts.color_format,
            &mono_atlas,
            &color_atlas,
            opts.max_glyphs,
        );
        errdefer text_pipeline.deinit();
        var quad_pipeline = try qp.QuadPipeline.init(opts.vk_ctx, opts.color_format, opts.max_quads);
        errdefer quad_pipeline.deinit();
        var tri_pipeline = try tri_pipeline_mod.TrianglePipeline.init(
            opts.vk_ctx,
            opts.color_format,
            opts.max_tri_vertices,
            opts.max_tri_indices,
        );
        errdefer tri_pipeline.deinit();
        const image_pipeline = try allocator.create(image_pipeline_mod.ImagePipeline);
        errdefer allocator.destroy(image_pipeline);
        image_pipeline.* = try image_pipeline_mod.ImagePipeline.init(opts.vk_ctx, opts.color_format, opts.max_images);
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

        // ── DrawList ────────────────────────────────────────────────
        const drawlist = element.DrawList.init(allocator);
        const pass_dispatches = std.ArrayList(PassDispatch).init(allocator);

        return .{
            .allocator = allocator,
            .vk_ctx = opts.vk_ctx,
            .color_format = opts.color_format,
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

        // 5. Per-frame state.
        self.drawlist.deinit();
        self.pass_dispatches.deinit();

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

    /// Apply scroll/zoom transform, upload glyph SSBO, record
    /// tri/image/quad/text draws into the attached cmd. **Must run
    /// inside an active `vkCmdBeginRendering` scope** owned by the
    /// host (host has the swapchain image; spark just records draws).
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

        self.tri_pipeline.recordDraw(cmd, extent, @intCast(dl.tri_indices.items.len));
        if (dl.images.items.len > 0) {
            self.image_pipeline.bind(cmd, extent);
            for (dl.images.items) |im| {
                self.image_pipeline.recordOne(cmd, extent, @ptrCast(@alignCast(im.descriptor_set)), im.dst_pos, im.dst_size);
            }
        }
        self.quad_pipeline.recordDraw(cmd, extent, @intCast(dl.quads.items.len));
        self.text_pipeline.recordDraw(cmd, extent, @intCast(dl.glyphs.items.len));
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
            .compute_jobs = undefined,
            .io_jobs = undefined,
            .fonts = undefined,
            .theme = undefined,
            .host_state = undefined,
        };
    }
};

// ── Helpers ────────────────────────────────────────────────────────

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

test "Spark: testStub produces a usable shell for component tests" {
    // Sanity check that the stub-construction path compiles. The
    // real init path is exercised by main.zig (and Phase 5's
    // integration tests when they land).
    const s = Spark.testStub(testing.allocator);
    try testing.expect(@sizeOf(@TypeOf(s)) > 0);
    // `glyph_cache_lock` is real (Mutex has no resources to free).
}
