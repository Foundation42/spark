//! Public Zig-module surface for embedding the spark library
//! (rich-text + reactive markdown rendering over Vulkan) in a host
//! engine — matryoshka HUD, the future terminal app, in-game UI,
//! editors.
//!
//! This is the only file external consumers should `@import`. Host
//! code never reaches into `src/markdown.zig`, `src/element.zig`,
//! `src/component.zig` etc. directly — everything is re-exported
//! through this namespace. If something you need is missing, add a
//! re-export here rather than reaching into internals.
//!
//! Cooperative-embed contract:
//!   * Host owns the Vulkan instance, device, queue, surface,
//!     swapchain, and per-frame command buffers.
//!   * Host owns the GLFW window (or whichever platform layer).
//!   * Host constructs a Theme + FontRegistry (loading fonts on
//!     paths it picks) and hands ownership of FontRegistry to Spark.
//!   * Host calls `Spark.init` with raw Vulkan handles + the theme +
//!     fonts + a root State, then `Spark.attachToRegistry` to wire
//!     the registry's back-pointer.
//!   * Host calls `installCoreComponents` (this file) to register
//!     the core component set.
//!   * Optional: host calls `Spark.installDotEnv` +
//!     `Spark.installAssetCache` + `extras.X.install` for each
//!     extras module it wants.
//!   * Per frame: `Spark.tick()` → `Spark.attachCmd(cmd, 0, 0)` →
//!     `Spark.beginFrame(FrameInfo)` → one or more
//!     `Spark.layoutAndRender(doc, origin, constraints)` →
//!     `Spark.endFrame()`, called inside the host's
//!     `vkCmdBeginRendering` scope.

const std = @import("std");

// ── Spark + Document lifecycle ─────────────────────────────────────
/// The shared job system, re-exported so a host can name the SAME type
/// spark uses. This is what makes `SparkOptions.compute_jobs: ?*JobSystem`
/// expressible: before `common`, spark and its host each compiled their own
/// copy of `jobs.zig` and the two `*JobSystem` types did not unify, so the
/// argument could not typecheck no matter how the API was written.
pub const jobs = @import("common").jobs;

pub const Spark = @import("spark.zig").Spark;
pub const InitOptions = @import("spark.zig").InitOptions;
pub const FrameInfo = @import("spark.zig").FrameInfo;
/// A host image offered to a `:::gbuffer` panel, and the resolver that
/// answers for one. See `element.PassSource.host_named`.
pub const HostSurfaceImage = @import("spark.zig").HostSurfaceImage;
pub const HostSurfaceFit = @import("spark.zig").HostSurfaceFit;
pub const HostSurfaceLayout = @import("spark.zig").HostSurfaceLayout;
pub const HostSurfaceFn = @import("spark.zig").HostSurfaceFn;
pub const document = @import("document.zig");
pub const Document = document.Document;
pub const LoadOpts = document.LoadOpts;
pub const wrapElement = document.wrapElement;

// ── Element contract — for components built outside the library ───
pub const element = @import("element.zig");
pub const Element = element.Element;
pub const ElementVTable = element.ElementVTable;
pub const Style = element.Style;
pub const Theme = element.Theme;
pub const LayoutCtx = element.LayoutCtx;
pub const DrawList = element.DrawList;
pub const Constraints = element.Constraints;
pub const Box = element.Box;
pub const InputEvent = element.InputEvent;
pub const MouseEvent = element.MouseEvent;
pub const KeyEvent = element.KeyEvent;
pub const Hit = element.Hit;
pub const IntrinsicMetrics = element.IntrinsicMetrics;
pub const BlockMetrics = element.BlockMetrics;

// ── Registry / state ───────────────────────────────────────────────
pub const Registry = @import("component.zig").Registry;
pub const Factory = @import("component.zig").Factory;
pub const Instance = @import("component.zig").Instance;
// Effects-spec Phase A.2 — pass-shape types factories opt into.
pub const PassShape = @import("component.zig").PassShape;
pub const PatternPass = @import("component.zig").PatternPass;
pub const SingleSourcePass = @import("component.zig").SingleSourcePass;
pub const ChainPass = @import("component.zig").ChainPass;
pub const HostSlotPass = @import("component.zig").HostSlotPass;
// Effects-spec Phase B.7 — host-slot dispatch contract surfaces.
// HostSlotCtx is the contract spark hands to the host callback at
// dispatch time; HostSlotInvocation is the (callback, user_data)
// pair the per-instance vtable hook returns to the layout walker.
pub const HostSlotCtx = @import("element.zig").HostSlotCtx;
pub const HostSlotInvocation = @import("element.zig").HostSlotInvocation;
pub const ShaderId = @import("component.zig").ShaderId;
pub const Edges = @import("component.zig").Edges;
pub const LayoutInflationSpec = @import("component.zig").LayoutInflationSpec;
// Effects-spec Phase A.3+ — pass-graph compiler module.
pub const pass = @import("pass/root.zig");
pub const Spec = @import("markdown_components.zig").Spec;
/// The registry namespace and the document State a body-parsing factory
/// should hand its children — see their doc comments for the two bugs
/// they exist for. Exported because a HOST component that parses a body
/// needs both, and getting either wrong is silent.
pub const specScope = @import("component.zig").specScope;
pub const specState = @import("component.zig").specState;
pub const Attr = @import("markdown_components.zig").Attr;
pub const params = @import("params.zig");
pub const display = @import("gpu/display.zig");
pub const state = @import("state.zig");
pub const State = state.State;
pub const Subscriber = state.Subscriber;
pub const stateFromSource = state.fromSource;

// ── Fonts ──────────────────────────────────────────────────────────
pub const font = struct {
    pub const Library = @import("font/face.zig").Library;
    pub const FontRegistry = @import("font/registry.zig").FontRegistry;
    pub const FontId = @import("font/registry.zig").FontId;
};
pub const FontRegistry = font.FontRegistry;
pub const FontId = font.FontId;

// ── Vulkan thin wrapper (host needs this for raw handle types) ─────
pub const vk = @import("gpu/vk.zig");

// ── Host-side scaffolding the demo uses ────────────────────────────
// Real production hosts (matryoshka HUD, terminal app) will write
// their own window + swapchain + renderer; these are re-exported so
// the demo can use them via `spark.X` without files ending up
// in multiple modules at build time. Treat as demo-supporting code,
// not part of the stable public API.
pub const window = @import("window.zig");
pub const swapchain = @import("gpu/swapchain.zig");
pub const renderer = @import("gpu/renderer.zig");

// ── Producers — hosts that want raw markdown / ANSI parsing ────────
pub const markdown = @import("markdown.zig");
/// The block walker, for a HOST component that composes a parsed subtree
/// of its own — matryoshka's `:::intents` generates dock markdown, parses
/// it, and delegates layout here. Core components reach it directly; a
/// host has only this namespace, and the alternative is a second copy of
/// the walk that ages separately.
pub const element_layout = @import("element_layout.zig");
/// What a HOST-written container needs from the retained layout cache.
///
/// One function, and it is the one every container gets wrong once:
/// `aggregateChildVersions`. A component that owns a parsed subtree must
/// fold its children's content versions into its OWN, or a child that
/// changes shape — a fold opening, a chart appending — moves nothing the
/// cache can see and the whole block replays as it was. `:::fold` learned
/// it, and then `:::intents` in matryoshka learned it again by the same
/// door, which is what made this an export rather than an internal.
pub const layout_cache = @import("layout_cache.zig");
pub const aggregateChildVersions = layout_cache.aggregateChildVersions;
pub const ansi = @import("ansi.zig");

// ── Wire-format update applier ─────────────────────────────────────
pub const update = @import("update.zig");

// ── Opt-in extras ──────────────────────────────────────────────────
pub const extras = struct {
    pub const llm_stream = @import("extras/llm_stream.zig");
    pub const svg_stream = @import("extras/svg_stream.zig");
    pub const image_stream = @import("extras/image_stream.zig");
    pub const embedded_document_http = @import("extras/embedded_document_http.zig");
    pub const dotenv = @import("extras/dotenv.zig");
    pub const asset_cache = @import("extras/asset_cache.zig");
};

// ── Core component installers ──────────────────────────────────────
// Each module here exposes `pub fn install(spark: *Spark) !void`
// that registers the factory under its directive name. Internal
// implementation detail of `installCoreComponents` below; rarely
// needed directly, but exposed for hosts that want a custom subset.
pub const components = struct {
    pub const ago = @import("components/ago.zig");
    pub const badge = @import("components/badge.zig");
    pub const box = @import("components/box.zig");
    pub const button = @import("components/button.zig");
    pub const chart = @import("components/chart.zig");
    pub const checkbox = @import("components/checkbox.zig");
    /// Shared grading maths — HSV, and the balance the two colour
    /// widgets are two pictures of. No directive of its own.
    pub const color = @import("components/color.zig");
    pub const color_bars = @import("components/color_bars.zig");
    pub const color_wheel = @import("components/color_wheel.zig");
    pub const commit = @import("components/commit.zig");
    pub const curve = @import("components/curve.zig");
    pub const diff = @import("components/diff.zig");
    pub const dot = @import("components/dot.zig");
    pub const embedded_document = @import("components/embedded_document.zig");
    pub const flex = @import("components/flex.zig");
    pub const fold = @import("components/fold.zig");
    pub const clip = @import("components/clip.zig");
    pub const gh_ref = @import("components/gh_ref.zig");
    pub const grid = @import("components/grid.zig");
    pub const grip = @import("components/grip.zig");
    pub const handle = @import("components/handle.zig");
    pub const input = @import("components/input.zig");
    pub const kbd = @import("components/kbd.zig");
    pub const meter = @import("components/meter.zig");
    pub const price = @import("components/price.zig");
    pub const progress = @import("components/progress.zig");
    pub const rating = @import("components/rating.zig");
    pub const slider = @import("components/slider.zig");
    pub const sparkline = @import("components/sparkline.zig");
    pub const stack = @import("components/stack.zig");
    pub const status = @import("components/status.zig");
    pub const trackball = @import("components/trackball.zig");
    pub const svg = @import("components/svg.zig");
    pub const tag = @import("components/tag.zig");
    pub const trend = @import("components/trend.zig");
    pub const value = @import("components/value.zig");
    // Effects-spec Phase A.5 — three canary pattern factories.
    // Same `installCoreComponents` rung as the rasterizer-shaped
    // components per Decision #11 ("core vocabulary, not extras").
    pub const effects = struct {
        pub const gradient = @import("components/effects/gradient.zig");
        pub const pattern = @import("components/effects/pattern.zig");
        pub const noise = @import("components/effects/noise.zig");
        pub const drop_shadow = @import("components/effects/drop_shadow.zig");
        pub const frosted_glass = @import("components/effects/frosted_glass.zig");
        pub const liquid_glass = @import("components/effects/liquid_glass.zig");
        pub const gbuffer = @import("components/effects/gbuffer.zig");
    };
};

/// Register all core component factories on `spark`. Idempotent at
/// the host level: call once after `Spark.init` +
/// `Spark.attachToRegistry`. Extras (llm-stream, svg-stream,
/// image-stream, embedded_document_http) are NOT installed here —
/// the host opts into each via `extras.X.install(&spark)` after
/// mounting any prerequisites (DotEnv, AssetCache).
pub fn installCoreComponents(spark: *Spark) !void {
    try components.box.install(spark);
    try spark.registry.register("chart", components.chart.factory);
    try spark.registry.register("slider", components.slider.factory);
    // The grading pair. Same attribute grammar, two views of it — a
    // document swaps the directive name to swap the picture.
    try components.trackball.install(spark);
    try components.curve.install(spark);
    try components.color_bars.install(spark);
    try components.color_wheel.install(spark);
    try components.badge.install(spark);
    try components.sparkline.install(spark);
    try components.value.install(spark);
    try components.kbd.install(spark);
    try components.meter.install(spark);
    try components.stack.install(spark);
    try components.progress.install(spark);
    try components.status.install(spark);
    try components.tag.install(spark);
    try components.trend.install(spark);
    try components.rating.install(spark);
    try components.dot.install(spark);
    try components.commit.install(spark);
    try components.price.install(spark);
    try components.diff.install(spark);
    try components.gh_ref.install(spark);
    try components.ago.install(spark);
    try components.button.install(spark);
    // Shares `button.isTruthy` and the flip's `"1"`/`"0"` spelling, so
    // it registers next to it.
    try components.checkbox.install(spark);
    try components.handle.install(spark);
    try components.grip.install(spark);
    try components.embedded_document.install(spark);
    try components.flex.install(spark);
    try components.fold.install(spark);
    try components.clip.install(spark);
    try components.grid.install(spark);
    try components.input.install(spark);
    try components.svg.install(spark);
    // Effects-spec Phase A.5 — Phase A pattern canaries.
    try components.effects.gradient.install(spark);
    try components.effects.pattern.install(spark);
    try components.effects.noise.install(spark);
    // Effects-spec Phase B.5 — first single_source filter.
    try components.effects.drop_shadow.install(spark);
    // Effects-spec Phase B.6 — second single_source filter.
    try components.effects.frosted_glass.install(spark);
    // Effects-spec Phase B.6.d — third single_source filter.
    try components.effects.liquid_glass.install(spark);
    try components.effects.gbuffer.install(spark);
}

/// Compiled SPIR-V blobs. Anonymous module wired in by `build.zig`;
/// each field is an `align(4) []const u8`-shaped @embedFile of one
/// shader stage. Host doesn't usually touch this — pipelines pull
/// the bytes they need internally.
pub const shaders = @import("shaders");
