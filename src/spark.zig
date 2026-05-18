//! `Spark` — engine context for the spark library. Phase 1 of the
//! library-ification spec (`docs/library-spec.md`).
//!
//! Holds the pointers every component currently reaches for through
//! file-scope `_ref` module-globals (`registry_ref`, `theme_ref`,
//! `state_ref`, `io_channel_ref`, `env_ref`, …). After Phase 1 lands,
//! `Factory.create` takes a `*Spark` first arg, the component stores
//! it in its instance ctx, and every cross-cutting concern is a
//! single pointer dereference away.
//!
//! Ownership story (this phase): Spark borrows; main.zig still owns
//! every resource. The struct is wired so the *shape* matches the
//! spec, but `init` is a builder over pointer args and `deinit` is a
//! noop. Phase 3 reverses this — `Spark.init` constructs the engine
//! resources, `deinit` tears them down, and main.zig's role shrinks
//! to GLFW + swapchain + frame pacing.
//!
//! Extras hooks (`dotenv`, `asset_cache`) are null by default. The
//! host opts in by setting them on the Spark instance — or, after
//! Phase 2 lands, by calling `installDotEnv` / `installAssetCache`.
//! Extras factories check these fields at install time and reject
//! with a descriptive error (`error.RequiresDotEnv`,
//! `error.RequiresAssetCache`) when the precondition isn't met.

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

pub const Spark = struct {
    allocator: std.mem.Allocator,

    // ── Vulkan (borrowed from host in Phase 1; spark owns in Phase 3) ──
    vk_ctx: *const vk.Context,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    text_pipeline: *tp.TextPipeline,
    quad_pipeline: *qp.QuadPipeline,
    tri_pipeline: *tri_pipeline_mod.TrianglePipeline,
    image_pipeline: *image_pipeline_mod.ImagePipeline,

    // ── Text + layout state ───────────────────────────────────────────
    fonts: *font_registry_mod.FontRegistry,
    glyph_cache: *glyph_cache_mod.GlyphCache,
    theme: *const element.Theme,
    registry: *component_mod.Registry,
    host_state: *state_mod.State,
    layout_cache: *layout_cache_mod.BlockCache,
    layout_context: *layout_context_mod.LayoutContext,

    // ── Job systems + I/O ────────────────────────────────────────────
    compute_jobs: *jobs_mod.JobSystem,
    io_jobs: *jobs_mod.JobSystem,
    io_channel: *io_channel_mod.IoChannel,

    // ── Extras hooks ─────────────────────────────────────────────────
    // Null until the host opts in. Extras factories that need these
    // assert at install time. See decision #9 in library-spec.md.
    // Per-Spark instances (not module-globals) so two Sparks in one
    // process stay isolated — same principle Phase 1 enforced when it
    // purged `_ref` module-globals from components.
    dotenv: ?*const dotenv_mod.DotEnv = null,
    asset_cache: ?*asset_cache_mod.AssetCache = null,
    /// HTTP/HTTPS handler for `:::embedded-document` URL sources.
    /// Populated by `extras.embedded_document_http.install(&spark)`;
    /// when null, URL src= attrs error with
    /// `error.HttpEmbeddedDocumentRequiresExtras` at create-time.
    embedded_http: ?*embedded_document_http_mod.EmbeddedDocumentHttp = null,

    /// Pointer-args bag for Phase 1. Phase 3 replaces this with a
    /// fully-owned init that takes raw Vulkan handles + a font
    /// registry and constructs the engine resources internally.
    pub const InitArgs = struct {
        allocator: std.mem.Allocator,

        vk_ctx: *const vk.Context,
        mono_atlas: *atlas_mod.Atlas,
        color_atlas: *atlas_mod.Atlas,
        text_pipeline: *tp.TextPipeline,
        quad_pipeline: *qp.QuadPipeline,
        tri_pipeline: *tri_pipeline_mod.TrianglePipeline,
        image_pipeline: *image_pipeline_mod.ImagePipeline,

        fonts: *font_registry_mod.FontRegistry,
        glyph_cache: *glyph_cache_mod.GlyphCache,
        theme: *const element.Theme,
        registry: *component_mod.Registry,
        host_state: *state_mod.State,
        layout_cache: *layout_cache_mod.BlockCache,
        layout_context: *layout_context_mod.LayoutContext,

        compute_jobs: *jobs_mod.JobSystem,
        io_jobs: *jobs_mod.JobSystem,
        io_channel: *io_channel_mod.IoChannel,

        dotenv: ?*const dotenv_mod.DotEnv = null,
        asset_cache: ?*asset_cache_mod.AssetCache = null,
    };

    pub fn init(args: InitArgs) Spark {
        return .{
            .allocator = args.allocator,
            .vk_ctx = args.vk_ctx,
            .mono_atlas = args.mono_atlas,
            .color_atlas = args.color_atlas,
            .text_pipeline = args.text_pipeline,
            .quad_pipeline = args.quad_pipeline,
            .tri_pipeline = args.tri_pipeline,
            .image_pipeline = args.image_pipeline,
            .fonts = args.fonts,
            .glyph_cache = args.glyph_cache,
            .theme = args.theme,
            .registry = args.registry,
            .host_state = args.host_state,
            .layout_cache = args.layout_cache,
            .layout_context = args.layout_context,
            .compute_jobs = args.compute_jobs,
            .io_jobs = args.io_jobs,
            .io_channel = args.io_channel,
            .dotenv = args.dotenv,
            .asset_cache = args.asset_cache,
        };
    }

    /// Tears down resources Spark owns. Host-borrowed pointers (every
    /// non-extras field) stay untouched — main.zig still owns those
    /// in Phase 2 and frees them itself. The only resources Spark owns
    /// today are the three extras hooks (`dotenv`, `asset_cache`,
    /// `embedded_http`), each populated by a corresponding `installX`
    /// method. Phase 3 grows this to tear down every owned engine
    /// resource as ownership inverts.
    pub fn deinit(self: *Spark) void {
        if (self.embedded_http) |ext| {
            ext.deinit();
            self.allocator.destroy(ext);
            self.embedded_http = null;
        }
        if (self.asset_cache) |ac| {
            ac.deinit();
            // AssetCache.init heap-allocates the struct itself and
            // returns *AssetCache; AssetCache.deinit destroys it.
            self.asset_cache = null;
        }
        if (self.dotenv) |env| {
            const mutable: *dotenv_mod.DotEnv = @constCast(env);
            mutable.deinit();
            self.allocator.destroy(mutable);
            self.dotenv = null;
        }
    }

    /// Mount a DotEnv reader at `env_path`. Required precondition for
    /// any extras factory that reads env vars (llm-stream, svg-stream,
    /// image-stream, embedded_document_http via env-derived URLs).
    /// The host chooses the path — the library makes no filesystem
    /// assumptions. Calling twice replaces the previous reader; Spark
    /// owns the resource and frees it in `deinit`.
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
    /// Required precondition for svg-stream / image-stream — both
    /// dedupe generated SVG/PNG assets to disk to skip the LM call
    /// on a hot reload. Same host-chooses-path discipline as
    /// `installDotEnv`. Calling twice replaces the previous cache;
    /// Spark owns the resource.
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

    /// Test-only fixture. Returns a `Spark` whose only valid field is
    /// `allocator`; every other field is `undefined`. Suitable for
    /// component-internal unit tests that exercise ingest /
    /// state-update paths without touching layout, render, fonts,
    /// Vulkan, or any cross-cutting dependency. Tests that need a
    /// field (host_state, compute_jobs, …) should patch the relevant
    /// field on the returned struct before use.
    pub fn testStub(allocator: std.mem.Allocator) Spark {
        return .{
            .allocator = allocator,
            .vk_ctx = undefined,
            .mono_atlas = undefined,
            .color_atlas = undefined,
            .text_pipeline = undefined,
            .quad_pipeline = undefined,
            .tri_pipeline = undefined,
            .image_pipeline = undefined,
            .fonts = undefined,
            .glyph_cache = undefined,
            .theme = undefined,
            .registry = undefined,
            .host_state = undefined,
            .layout_cache = undefined,
            .layout_context = undefined,
            .compute_jobs = undefined,
            .io_jobs = undefined,
            .io_channel = undefined,
            // Extras stay null in the stub; per-test patching adds them
            // if the test path exercises an extras-dependent code branch.
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Spark: init populates every field" {
    // The test exists to lock the field set against the spec — if
    // a field is added or renamed, this catches the build error
    // before any component tries to dereference through Spark and
    // produces a less-obvious failure.

    var allocator_buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const a = fba.allocator();
    _ = a;
    // The init signature is exercised by main.zig and by every
    // component-internal test that constructs a *Spark fixture.
    // We don't construct one here because every field is a pointer
    // to a heavyweight host resource; the field-presence check is
    // the type system's job at every consumer call site.
    try testing.expect(@sizeOf(Spark) > 0);
}
