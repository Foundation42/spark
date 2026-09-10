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

/// The clip slice for a primitive layer, tolerant of a clip array that
/// has not caught up.
///
/// `sealClips` runs before the draw loop, so in practice the arrays are
/// level — but a layer's range is computed from the PRIMITIVE arrays, and
/// a bug that left the clip array short would otherwise be an
/// out-of-bounds slice at draw time rather than an unclipped draw. The
/// iterator already reads a short array as unclipped; this keeps the
/// slice itself from being the thing that crashes.
fn clipSlice(clips: []const u16, from: usize, to: usize) []const u16 {
    if (from >= clips.len) return &.{};
    return clips[from..@min(to, clips.len)];
}

const element = @import("element.zig");
const state_mod = @import("state.zig");
const component_mod = @import("component.zig");
const layout_context_mod = @import("layout/context.zig");
const layout_cache_mod = @import("layout_cache.zig");
const io_channel_mod = @import("io_channel.zig");
const jobs_mod = @import("common").jobs;
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
const overlay_mod = @import("overlay.zig");
const io = io_channel_mod;

/// Which corner of an overlay document sits at the point it was opened
/// at. Re-exported so a host names it as `spark.Corner` rather than
/// reaching into `overlay.zig`; see that file for why a menu is a
/// document and not a component.
pub const Corner = overlay_mod.Corner;

/// GLFW's escape keycode. `element.KeyEvent.key` is a raw GLFW code by
/// contract (see `KeyEvent`), and spark links no GLFW — so the one
/// number the dispatcher itself has an opinion about is written here,
/// once, with its provenance, rather than appearing bare at the site.
pub const KEY_ESCAPE: i32 = 256;

/// The three modifier bits the context record reports, as GLFW numbers
/// them. `:::textarea` and `:::input` each keep their own copy of these
/// for their own keymaps; this is the dispatcher's, and it is here
/// rather than borrowed from a component because a component is the
/// wrong place for a library-wide fact.
const MOD_SHIFT: u32 = 0x0001; // GLFW_MOD_SHIFT
const MOD_CONTROL: u32 = 0x0002; // GLFW_MOD_CONTROL
const MOD_ALT: u32 = 0x0004; // GLFW_MOD_ALT

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

/// An image the HOST owns, handed to a `.host_named` pass.
///
/// Borrowed for the duration of the frame and nothing more: spark
/// binds the view into a descriptor set and draws. It never
/// transitions the image, never writes it, and never keeps it — the
/// host owns the lifetime and the layout, and must have it in one a
/// fragment shader can sample (`SHADER_READ_ONLY_OPTIMAL`, or
/// `GENERAL`, which many compute-written surfaces are already sitting
/// in) at the moment it calls into spark.
pub const HostSurfaceImage = struct {
    view: vk.c.VkImageView,
    /// **The span: the screen extent this image's full `[0,1]` UV range
    /// covers. NOT the image's resolution.**
    ///
    /// The two coincide for a full-resolution surface on a host
    /// rendering at native scale, which is the only case that existed
    /// when this field was first written, and the coincidence is a
    /// trap. Two ways out of it:
    ///
    /// * A **half-resolution** surface still covers the whole screen,
    ///   with fewer texels. UV is normalised to the image, so the
    ///   fraction a panel wants is unchanged — its span is the screen,
    ///   and reporting `width/2` would window twice as far across.
    /// * A surface **written at a reduced dispatch footprint** (a host
    ///   rendering at 70% into a full-size image) has its content in
    ///   the top-left 70% of its UV range, so the full range spans
    ///   `screen / 0.7` — larger than the screen, not smaller.
    ///
    /// Both fall out of one question, which is the one to answer when
    /// adding a surface: *how much of the screen would I see if I
    /// looked at all of this image?*
    span_w: u32,
    span_h: u32,
    /// Whether the image corresponds to the screen at all. See
    /// `HostSurfaceFit`.
    fit: HostSurfaceFit = .screen,
    /// **The layout the image is actually in, and there is no default.**
    ///
    /// A combined-image-sampler descriptor declares the layout it will
    /// read the image in, and it must be the one the image is in. Both
    /// values here are legal to sample from; declaring the wrong one is
    /// undefined behaviour that a driver may well survive.
    /// `:::gbuffer` shipped declaring `shader_read_only` against images
    /// sitting in `GENERAL`, drew correctly for a whole campaign, and
    /// the validation layers said so to nobody — that path had never
    /// been run with them on.
    ///
    /// Required rather than defaulted, because neither answer is safe
    /// to assume and forgetting to think about it is exactly how it
    /// happened the first time.
    layout: HostSurfaceLayout,
};

/// Which sampleable layout a host surface is sitting in.
///
/// spark never transitions a host image — the host owns the layout — so
/// this is the host stating what it already did, not asking for
/// anything.
pub const HostSurfaceLayout = enum(u8) {
    /// `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL` — a surface the host
    /// deliberately handed to the fragment stage.
    shader_read_only,
    /// `VK_IMAGE_LAYOUT_GENERAL` — where a compute-written surface
    /// already sits, and the reason this field exists.
    general,
    /// `VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_OPTIMAL` — a depth attachment
    /// the host has finished writing and left readable. A shadow map
    /// arrives this way, which is how the third variant was found:
    /// `GENERAL` covered every colour surface and none of the depth
    /// ones.
    depth_read_only,

    pub fn toVk(self: HostSurfaceLayout) c_uint {
        return switch (self) {
            .shader_read_only => vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .general => vk.c.VK_IMAGE_LAYOUT_GENERAL,
            .depth_read_only => vk.c.VK_IMAGE_LAYOUT_DEPTH_READ_ONLY_OPTIMAL,
        };
    }
};

/// Whether a host surface is screen-aligned, which decides what a panel
/// over it is a window ONTO.
pub const HostSurfaceFit = enum(u8) {
    /// The image covers the screen. The panel shows the part of it
    /// under the panel, and keeps doing so when it is dragged. Every
    /// G-buffer, every lighting target, every post buffer.
    screen,
    /// The image is not a view of the screen — a shadow map from a
    /// light's point of view, a texture atlas, a probe grid. There is
    /// no "underneath" to window onto, so the panel shows the whole
    /// image wherever it sits, and dragging it moves the picture
    /// without changing it.
    whole,
};

/// Answers a surface name with an image, or null when the host has
/// nothing by that name. Called once per `.host_named` composite, on
/// the render thread, inside the frame.
pub const HostSurfaceFn = *const fn (ctx: *anyopaque, name: []const u8) ?HostSurfaceImage;

/// Where a `:::button {cmd="..."}` sends its line.
///
/// spark does not parse, validate or interpret the string — it does not
/// know what a command IS. The host owns the vocabulary, and a document
/// that names a verb this host has never heard of gets whatever the
/// host says about that, in the host's own words.
///
/// **The sink must not act immediately.** It is called from inside the
/// button's `on_input`, which is inside the pointer dispatch, which is
/// inside the frame — so a line like `hud unmount debug` would free the
/// very component whose click is still being handled. Queue the line
/// and run it at a point where nothing is mid-walk; matryoshka drains
/// after the pointer block, the same way it drains the mount inbox.
///
/// Takes no error: a button is a person clicking, and there is nothing
/// useful to propagate a failure INTO. The host reports what happened
/// through its own channels (a console log line), where a person will
/// actually see it.
pub const CommandSink = *const fn (ctx: *anyopaque, line: []const u8) void;

/// The system clipboard, as two host-supplied functions.
///
/// **Why this is a seam and not a call.** Components do not reach for
/// GLFW — `:::input` re-declares the eight key codes it needs rather than
/// importing `win.zig`, and matryoshka's HUD is forbidden from touching
/// the window at all (its input is a *declared surface* on the control
/// plane). A clipboard is host property in exactly the way a command
/// sink is, so it arrives by the same door.
///
/// A host that installs none leaves Ctrl+C/X/V inert — visibly a
/// keystroke, inertly a keystroke, which is the shape `cmd=` buttons
/// already set for a document carried between hosts.
///
/// **The borrow, and why it is spelt out.** `ClipboardGet` returns memory
/// the HOST owns, valid only until the next clipboard call. That is not a
/// convenience, it is GLFW's actual contract — `glfwGetClipboardString`
/// hands back a pointer it recycles — and promising anything longer would
/// be a promise the obvious implementation cannot keep. Copy it before
/// doing anything that could call the host again.
pub const ClipboardGet = *const fn (ctx: *anyopaque) ?[]const u8;
pub const ClipboardSet = *const fn (ctx: *anyopaque, text: []const u8) void;

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

    /// **Starting sizes, not budgets — none of these four is a
    /// ceiling.** They say how big the per-frame GPU buffers are on
    /// frame one. A frame that needs more gets more: the finished
    /// drawlist is measured and the buffer grown to fit before anything
    /// is recorded (`Spark.reserveForDrawlist` → `gpu/growable.zig`).
    /// Growth is once per size, logged once, and stops at a hard
    /// ceiling that refuses by name rather than eating GPU memory.
    ///
    /// They were called `max_*` until the growth landed, and every host
    /// that hit one raised it by hand — spark's own demo carried
    /// `max_glyphs = 65536` for exactly that reason (`14aedd9`: the
    /// document outgrew its glyph budget and the whole page went
    /// black). The rename is the point. There is no number to raise.
    ///
    /// Set them only to skip a first-frame reallocation you can
    /// predict — a host that KNOWS its panels are small can lower them
    /// and keep the memory. Leaving them alone is correct.
    initial_glyphs: u32 = 16384,
    initial_quads: u32 = 2048,
    initial_tri_vertices: u32 = 65536,
    initial_tri_indices: u32 = 196608,

    /// **This one IS a maximum**, and stays named like one. Unlike the
    /// four above it sizes a descriptor POOL, not a buffer: one set per
    /// live image texture, allocated when the image loads. A pool
    /// cannot be resized in place the way a buffer can — growing it
    /// means chaining a second pool and re-pointing every set — and its
    /// overflow is local rather than total: the 33rd image fails to
    /// load and does not draw, while the other 32 and all the text
    /// render normally. A different failure from the black page, and
    /// left for the beat that wants a pool chain.
    max_images: u32 = 32,

    /// Compute worker count. Null = cpu_count - 2 (matches demo).
    compute_workers: ?u32 = null,
    /// I/O worker count. 24 worker threads matches the demo; HTTP
    /// streams park on socket reads so this number is concurrency,
    /// not parallelism.
    io_workers: u32 = 24,
};

/// One background pass's place in the containment tree, for Phase 2's
/// pre-pass ordering. See `orderBackgrounds`.
///
/// `index` is the dispatch's own position in `pass_dispatches`, which is
/// also the exclusive END of its subtree range — the walker appends a
/// parent immediately after the children it captured, so the two numbers
/// are the same by construction and only the START has to be carried.
/// One document's slice of the frame — everything a single
/// `layoutAndRender` call appended, in the four drawlist arrays and in
/// `pass_dispatches`.
///
/// **A layer is the unit of paint order.** Without one, spark paints
/// per FRAME: every background composite, then all MAIN geometry
/// globally by primitive type (tri → image → quad → text). That is
/// right for one document and wrong for two, because text is last in
/// the frame — so the LOWER panel's text lands over the UPPER panel's
/// glass and the two weave into each other. Chris dragged the Scene
/// applet over Corners on 2026-08-31 and watched it happen.
///
/// A document's primitives are already contiguous (the host calls
/// `layoutAndRender` once per document, and the walker appends as it
/// goes), so ordering by document costs a pair of marks per call and no
/// GPU resources at all — no per-panel target, no extra bandwidth. The
/// earlier plan reached for one offscreen target per document; that was
/// written when the empty-shadowed-panel bug looked like the same
/// problem, and it is not (see `element.provisionalTag`).
///
/// Ranges are `[start, end)`. Tris are held in INDEX space rather than
/// vertex space, because that is what a draw consumes and what
/// `triRuns` walks — a vertex range would be the wrong slice of the
/// wrong array.
pub const PaintLayer = struct {
    dispatches: [2]u32,
    glyphs: [2]u32,
    quads: [2]u32,
    tri_indices: [2]u32,
    images: [2]u32,
    /// This layer is the OVERLAY's, and `endFrame` paints it after every
    /// other layer whatever order the host called `layoutAndRender` in.
    /// See `orderOverlayLast`.
    overlay: bool = false,

    /// The whole frame as one layer — what a host that never called
    /// `layoutAndRender` gets, and what one call produces anyway. Keeps
    /// every pre-layers call site painting exactly as it did.
    fn whole(dl: *const element.DrawList, pd_len: usize) PaintLayer {
        return .{
            .dispatches = .{ 0, @intCast(pd_len) },
            .glyphs = .{ 0, @intCast(dl.glyph_targets.items.len) },
            .quads = .{ 0, @intCast(dl.quad_targets.items.len) },
            .tri_indices = .{ 0, @intCast(dl.tri_indices.items.len) },
            .images = .{ 0, @intCast(dl.image_targets.items.len) },
        };
    }
};

/// Mark every dispatch that lies inside another dispatch's subtree, so
/// Phase 1's top-level loop can leave it to the parent that owns it.
///
/// `out` must be `dispatches.len` long; it is overwritten in full.
///
/// Pulled out of `dispatchOffscreenPasses` so the rule can be asserted
/// without a GPU. The bug it fixes is invisible in a picture — a pass
/// processed twice draws the same thing twice — so a rendering gate
/// cannot see it, and the only honest gate is on the rule itself.
pub fn markSubtreeOwned(dispatches: []const element.PassDispatch, out: []bool) void {
    std.debug.assert(out.len == dispatches.len);
    @memset(out, false);
    for (dispatches) |d| {
        const range: [2]u32 = switch (d) {
            .single_source => |ss| ss.subtree_dispatch_range,
            .chain => |c| c.subtree_dispatch_range,
            else => continue,
        };
        var k = range[0];
        while (k < range[1]) : (k += 1) out[k] = true;
    }
}

pub const BackgroundSpan = struct {
    index: u32,
    subtree_start: u32,
};

/// Sort background passes **outermost first**, keeping siblings in the
/// order the author wrote them.
///
/// Phase 2 composites every background — a `{backdrop}` chain, a
/// `.host_named` panel — in a pre-pass, because both are backgrounds to
/// their own children and the walker emits post-order (see
/// `PassSource.isBackground`). What that reasoning missed is that the
/// pre-pass inherits the same post-order problem *among the backgrounds
/// themselves*: a background NESTED in another comes out first, and its
/// parent then composites straight over it.
///
/// That is not hypothetical. A `:::gbuffer` inside a
/// `:::frosted_glass {backdrop}` vanished completely — the chrome
/// painted over its own child — which is why `hud/xray.md` and
/// `hud/corners.md` wore a grip and no chrome from 2026-08-31 until this
/// was fixed. `demos/hud-lab/nested-pass-{bare,chrome}.md` are the two
/// arms that caught it.
///
/// **The key is `(subtree_start ascending, index descending)`**, which is
/// pre-order over a containment tree. Given two backgrounds whose ranges
/// nest, the outer one's subtree starts no later and ends strictly later
/// — it sits after everything it contains — so either its start is
/// smaller, or the starts tie and its index is larger. Disjoint siblings
/// never tie, and the earlier one's start is smaller, so document order
/// survives untouched. Both facts are gated below.
/// Put the overlay's paint layer last, keeping every other layer in the
/// order the host rendered it.
///
/// **Above all page content, and not by convention.** A layer paints
/// after every layer before it — background, triangles, images, quads
/// and glyphs together — so "last" IS "on top", and the whole of the
/// overlay's above-ness is this one sort. The alternative was to tell
/// hosts "call `layoutAndRenderOverlay` last": that is a rule that
/// cannot be checked at the call site, and a host that renders two
/// panels in a loop and a menu before the loop would get a menu
/// underneath the second panel, which reads as a rendering bug and is
/// actually a call-order bug three files away.
///
/// `std.sort.insertion` because it is STABLE and the array is tiny (one
/// entry per `layoutAndRender` this frame — one to a handful). Stability
/// is load-bearing, not incidental: two panels that overlap are ordered
/// by the host's call order and that ordering must survive untouched.
///
/// Idempotent, which matters on the `beginFrame(.reset = false)` path
/// where the previous frame's `paint_layers` are replayed and sorted
/// again.
pub fn orderOverlayLast(layers: []PaintLayer) void {
    std.sort.insertion(PaintLayer, layers, {}, struct {
        fn lt(_: void, a: PaintLayer, b: PaintLayer) bool {
            return !a.overlay and b.overlay;
        }
    }.lt);
}

pub fn orderBackgrounds(spans: []BackgroundSpan) void {
    std.mem.sort(BackgroundSpan, spans, {}, struct {
        fn lt(_: void, a: BackgroundSpan, b: BackgroundSpan) bool {
            if (a.subtree_start != b.subtree_start)
                return a.subtree_start < b.subtree_start;
            return a.index > b.index;
        }
    }.lt);
}

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
    /// One entry per `layoutAndRender` call this frame, in call order,
    /// which is paint order. See `PaintLayer`. Clears and carries over
    /// with `drawlist` and `pass_dispatches` — a skip-layout frame
    /// replays last frame's drawlist and needs last frame's layer
    /// boundaries to replay it in the right order.
    paint_layers: std.ArrayList(PaintLayer),
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

    /// Answers a `.host_named` pass's surface name with an image the
    /// host owns. Null until `setHostSurfaceResolver`, and a document
    /// asking for a surface on a host that installed none simply does
    /// not composite — the panel's children still draw, so a
    /// `:::gbuffer` in a document running on a host without G-buffers
    /// is an empty frame with working buttons rather than a crash.
    host_surface_fn: ?HostSurfaceFn = null,
    host_surface_ctx: ?*anyopaque = null,

    /// The system clipboard, or nothing. Null until `setClipboard`; see
    /// `ClipboardGet` for why a text editor asks the host rather than the
    /// window.
    clipboard_get_fn: ?ClipboardGet = null,
    clipboard_set_fn: ?ClipboardSet = null,
    clipboard_ctx: ?*anyopaque = null,

    /// Where `:::button {cmd="..."}` sends its line. Null until
    /// `setCommandSink`, and a `cmd=` button on a host that installed
    /// none does nothing at all — visibly a button, inertly a button,
    /// which is the right shape for a document carried between hosts.
    command_sink_fn: ?CommandSink = null,
    command_sink_ctx: ?*anyopaque = null,

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
    /// True once `dispatchOffscreenPasses` has recorded a draw into
    /// this frame's command buffer. Cleared by `beginFrame`.
    ///
    /// It exists for one guard: after Phase 1 has bound a buffer handle
    /// or a descriptor set into the cmd, spark can no longer replace
    /// those buffers — the recorded binds would point at freed memory
    /// and the host would submit them anyway (spark's own demo swallows
    /// an `endFrame` error and lets `drawFrame` submit). So `endFrame`
    /// asks whether a grow is still NEEDED at that point, and refuses
    /// by name if it is. See `reserveForDrawlist`.
    offscreen_recorded: bool = false,

    // ── Input state (managed by `dispatchMouseButton` etc.) ─────────
    /// Last mouse position dispatched (world coords, pre-zoom).
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// True while ANY button is held. Derived from `buttons_down` and
    /// kept as its own field because the reference host and matryoshka's
    /// bridge both read it; it meant exactly this back when left was the
    /// only button that reached spark at all.
    mouse_down: bool = false,
    /// Which buttons are held, bit N for button N. Left is bit 0, so a
    /// left-only host sees `buttons_down == 1` exactly when
    /// `mouse_down` is true, which is what it saw before this existed.
    buttons_down: u8 = 0,
    /// Which button took `captured`. The capture belongs to the button
    /// that opened the gesture and is released by that same button, so a
    /// right-click during a left-drag cannot end the drag.
    capture_button: u8 = 0,
    /// Modifier keys the host says are held right now, as a raw GLFW
    /// bitmask. Stamped onto every mouse, scroll and hover event this
    /// dispatcher builds — see `setPointerMods` for why it is ambient
    /// rather than a dispatch parameter.
    pointer_mods: u32 = 0,
    /// Pointer-capture: whichever Hit the most recent mouse_down
    /// landed on receives every subsequent move + up until release.
    captured: ?element.Hit = null,
    /// Keyboard focus. Set when a click lands on a focusable hit;
    /// cleared on click-outside or Esc. Compared by ctx pointer.
    focused: ?element.Hit = null,
    /// Whichever Hit currently has the pointer over it with no button
    /// held. Holds the `.enter` it was sent, so the `.leave` can be
    /// aimed at the same component. Compared by ctx pointer.
    hovered: ?element.Hit = null,
    /// Where the pointer was on the last hover dispatch, so a stationary
    /// pointer costs nothing. A polling host calls `dispatchHover` every
    /// frame whether the mouse moved or not.
    hover_x: f32 = 0,
    hover_y: f32 = 0,
    /// The multi-click run in progress. See `ClickRun`.
    click: ClickRun = .{},
    /// Test seam: when non-null, this is "now" for the click run instead
    /// of the wall clock. A gate that has to prove 500ms apart is NOT a
    /// double-click cannot wait 500ms, and one that sleeps is a gate that
    /// costs half a second every suite run forever.
    click_clock_ms: ?i64 = null,

    /// **Does anything need drawing again?** Raised by a dispatch that
    /// actually changed a component's picture; read and cleared by
    /// `takeRedrawRequest`. See that method for the whole argument, and
    /// for why this is a flag rather than a `bool` off each dispatcher.
    redraw_requested: bool = false,

    /// The one open overlay, or nothing. A document drawn over the page
    /// at a point, taking the pointer while it is up — see
    /// `overlay.zig` for why a context menu is a document rather than a
    /// component, and `openOverlay` for the whole contract.
    overlay: ?overlay_mod.Overlay = null,

    /// Where a right-click's context record is written, or nothing.
    /// Owned; duped in `setContextPath`, freed in `deinit`. Null until
    /// the host names a path, and a right-click on a host that named
    /// none emits nothing — the same shape as `command_sink_fn`, and
    /// for the same reason: a document carried between hosts should be
    /// inert about the things its host has not wired, not broken.
    context_path: ?[]u8 = null,

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
            opts.initial_glyphs,
        );
        errdefer text_pipeline.deinit();
        var quad_pipeline = try qp.QuadPipeline.init(opts.vk_ctx, opts.color_format, offscreen_format, opts.initial_quads);
        errdefer quad_pipeline.deinit();
        var tri_pipeline = try tri_pipeline_mod.TrianglePipeline.init(
            opts.vk_ctx,
            opts.color_format,
            offscreen_format,
            opts.initial_tri_vertices,
            opts.initial_tri_indices,
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
        const paint_layers = std.ArrayList(PaintLayer).init(allocator);
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
            .paint_layers = paint_layers,
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

        // 0. The overlay, if one is up. BEFORE `registry.deinit`,
        //    because `closeOverlay` calls `deinitScope` — which destroys
        //    the overlay's Bindings while the State they are subscribed
        //    to is still alive — and only then frees that State. Left to
        //    step 1 the registry would tear the same instances down in a
        //    different order and the document's State would outlive
        //    nothing at all; left to the host, a host that forgot would
        //    leak a whole document with no way to notice.
        self.closeOverlay();
        if (self.context_path) |p| {
            self.allocator.free(p);
            self.context_path = null;
        }

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
        self.paint_layers.deinit();
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

    /// Install the resolver a `.host_named` pass asks for its image.
    ///
    /// Optional, and a host that never calls this simply has no
    /// surfaces: a `:::gbuffer` in one of its documents lays out and
    /// draws its children, and composites nothing. That is the right
    /// failure for a debug panel carried between hosts.
    pub fn setHostSurfaceResolver(self: *Spark, ctx: *anyopaque, f: HostSurfaceFn) void {
        self.host_surface_ctx = ctx;
        self.host_surface_fn = f;
    }

    /// Install the sink a `:::button {cmd="..."}` sends its line to.
    /// See `CommandSink` — in particular, why it must queue.
    pub fn setCommandSink(self: *Spark, ctx: *anyopaque, f: CommandSink) void {
        self.command_sink_ctx = ctx;
        self.command_sink_fn = f;
    }

    /// Name the state path a right-click writes its context record to.
    ///
    /// The record is one `State.set`, in the line-oriented `key=value`
    /// grammar the rest of spark uses:
    ///
    ///     context subject=node:near1 x=412.0 y=233.5 shift=0 ctrl=0 alt=0
    ///
    /// A host subscribes to `path`, reads the subject, decides what the
    /// menu for it contains, and calls `openOverlay`. **spark opens
    /// nothing on right-click**, and that asymmetry is the design: the
    /// same host code serves a right-click on a graph node and one on a
    /// sphere in a 3D viewport where no spark element is under the
    /// cursor at all.
    ///
    /// A right-click that nobody claims writes NOTHING — not an empty
    /// subject, not a record with a blank field. The host has to be able
    /// to tell "the canvas claims this point" from "no element claims
    /// this point", because those route differently: one opens a canvas
    /// menu, the other is the 3D scene's click.
    ///
    /// **A path rather than a callback**, unlike `setCommandSink`,
    /// because the answer is DATA a document may also want to read. A
    /// panel that shows what was last right-clicked is a document
    /// binding `${state.ui.context}` and no host code at all; a callback
    /// would make that impossible and would buy nothing — the host
    /// subscribes to the path and gets its callback back.
    ///
    /// Rejected names: `bindContext` (spark's "binding" vocabulary means
    /// `${…}` attribute templating, and this is not that),
    /// `setContextSink` (a Sink in this file is a function pointer —
    /// `CommandSink` — and calling a path one would lie), `setMenuPath`
    /// (spark does not know what a menu is, and must not learn).
    pub fn setContextPath(self: *Spark, path: []const u8) !void {
        const dup = try self.allocator.dupe(u8, path);
        if (self.context_path) |old| self.allocator.free(old);
        self.context_path = dup;
    }

    /// Install the host's clipboard. Both directions at once, because a
    /// host that can paste and not copy is a bug rather than a policy.
    pub fn setClipboard(self: *Spark, ctx: *anyopaque, get: ClipboardGet, set: ClipboardSet) void {
        self.clipboard_ctx = ctx;
        self.clipboard_get_fn = get;
        self.clipboard_set_fn = set;
    }

    /// What the clipboard holds, borrowed until the next clipboard call —
    /// see `ClipboardGet`. Null when the host installed none.
    pub fn clipboardText(self: *Spark) ?[]const u8 {
        const f = self.clipboard_get_fn orelse return null;
        const ctx = self.clipboard_ctx orelse return null;
        return f(ctx);
    }

    /// Put `text` on the clipboard, if the host has one.
    pub fn setClipboardText(self: *Spark, text: []const u8) void {
        const f = self.clipboard_set_fn orelse return;
        const ctx = self.clipboard_ctx orelse return;
        f(ctx, text);
    }

    /// Hand a command line to the host, if one is listening.
    pub fn sendCommand(self: *Spark, line: []const u8) void {
        if (line.len == 0) return;
        const sink = self.command_sink_fn orelse return;
        const ctx = self.command_sink_ctx orelse return;
        sink(ctx, line);
    }

    /// The host's image for `name`, or null.
    fn hostSurface(self: *Spark, name: []const u8) ?HostSurfaceImage {
        if (name.len == 0) return null;
        const f = self.host_surface_fn orelse return null;
        const ctx = self.host_surface_ctx orelse return null;
        return f(ctx, name);
    }

    /// The window transform for a panel looking at part of a host
    /// surface: `(scale.xy, offset.xy)` such that a compose quad's own
    /// `[0,1]` UV maps onto the region of the surface the panel covers.
    ///
    /// Pure, and separated from the record path so it can be gated
    /// without a device — this is the arithmetic that decides whether
    /// a magnifying glass shows what is under it or something a few
    /// hundred pixels away, and it is not visible in a unit test any
    /// other way.
    ///
    /// **The divisor is the SPAN, and the span is not the image's
    /// resolution.** See `HostSurfaceImage.span_w` — a half-resolution
    /// surface and a full-resolution one covering the same screen have
    /// the same span, and a panel over either must show the same place.
    /// An earlier version of this comment argued for the image's own
    /// dimensions and was wrong in both directions at once.
    ///
    /// `.whole` short-circuits to the identity: an image that is not a
    /// view of the screen has no region under the panel to find, so the
    /// panel shows all of it.
    pub fn hostWindow(
        region: element.PassRegion,
        span_w: u32,
        span_h: u32,
        fit: HostSurfaceFit,
    ) [4]f32 {
        if (fit == .whole) return .{ 1, 1, 0, 0 };
        const sw: f32 = @floatFromInt(@max(1, span_w));
        const sh: f32 = @floatFromInt(@max(1, span_h));
        const rw: f32 = @floatFromInt(region.w);
        const rh: f32 = @floatFromInt(region.h);
        const rx: f32 = @floatFromInt(region.x);
        const ry: f32 = @floatFromInt(region.y);
        return .{ rw / sw, rh / sh, rx / sw, ry / sh };
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

    /// Size every per-frame GPU buffer to the drawlist that is about to
    /// be recorded. Idempotent, and on a settled document it is four
    /// integer compares.
    ///
    /// **Measure, don't fail.** The CPU drawlist is an unbounded
    /// `ArrayList` and it is COMPLETE by the time anything records —
    /// the walk is over, `layoutAndRender` has returned. So the size
    /// this frame needs is a number we can read, not a condition we
    /// have to discover by having `writeGlyphs` refuse a batch and
    /// return `SsboOverflow` out of `endFrame`, which is what used to
    /// happen and which cost the whole page (`14aedd9`; `src/main.zig`
    /// says it cost an afternoon).
    ///
    /// **Where it is safe to call, and why there are two call sites.**
    /// A grow REPLACES `VkBuffer` handles. The tri pipeline binds its
    /// VBO/IBO by handle at record time and the text/quad pipelines
    /// bind a descriptor set whose contents Vulkan is allowed to
    /// consume as early as `vkCmdBindDescriptorSets` is recorded. So
    /// this has to run before ANY draw goes into the frame's command
    /// buffer. Spark records in exactly two places, in this order:
    ///
    ///   1. `dispatchOffscreenPasses` — Phase 1, the offscreen passes.
    ///   2. `endFrame` — Phase 2, the main pass.
    ///
    /// It is called at the top of both. The first call does the work;
    /// the second is the no-op that covers a host with no effects,
    /// which never calls `dispatchOffscreenPasses` at all. A host that
    /// appends to the drawlist BETWEEN them is out of contract, and
    /// `endFrame` refuses that by name rather than freeing buffers its
    /// own command buffer already points at.
    pub fn reserveForDrawlist(self: *Spark) !void {
        const dl = &self.drawlist;
        try self.text_pipeline.reserve(dl.glyphs.items.len);
        try self.quad_pipeline.reserve(dl.quads.items.len);
        try self.tri_pipeline.reserve(dl.tris.items.len, dl.tri_indices.items.len);
    }

    /// Whether `reserveForDrawlist` would actually allocate. Asked
    /// before growing, never after — by the time a grow has run the old
    /// buffer is gone and the question is too late to matter.
    fn needsRoom(self: *const Spark) bool {
        const dl = &self.drawlist;
        return dl.glyphs.items.len > self.text_pipeline.glyphs.capacity or
            dl.quads.items.len > self.quad_pipeline.quads.capacity or
            dl.tris.items.len > self.tri_pipeline.vertices.capacity or
            dl.tri_indices.items.len > self.tri_pipeline.indices.capacity;
    }

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
        // Unconditional, both modes: this is a fact about the command
        // buffer being recorded, and the host rotates that every frame
        // whether or not it asked for a layout reset.
        self.offscreen_recorded = false;
        if (opts.reset) {
            self.drawlist.clearRetainingCapacity();
            // Symmetry with drawlist — both per-frame lists clear
            // together on the reset path, both carry over on the
            // dirty-gate path. Asymmetry here is a class of bug
            // (e.g. stale pass dispatches replayed against a
            // freshly-rebuilt drawlist); the lifecycle test pins it.
            self.pass_dispatches.clearRetainingCapacity();
            self.paint_layers.clearRetainingCapacity();
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
    ///
    /// Each call is also one PAINT LAYER: later calls land wholly on top
    /// of earlier ones, background and geometry together. For a single
    /// document that is the order spark always painted in; for two
    /// overlapping documents it is the difference between one panel
    /// being above the other and the two interleaving. See `PaintLayer`.
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
        // Mark this document's slice of the frame. Everything the walk
        // below appends is one layer, and layers paint in call order.
        const dl = &self.drawlist;
        const first: PaintLayer = .{
            .dispatches = .{ @intCast(self.pass_dispatches.items.len), 0 },
            .glyphs = .{ @intCast(dl.glyph_targets.items.len), 0 },
            .quads = .{ @intCast(dl.quad_targets.items.len), 0 },
            .tri_indices = .{ @intCast(dl.tri_indices.items.len), 0 },
            .images = .{ @intCast(dl.image_targets.items.len), 0 },
        };
        // Reserved BEFORE the walk, because appending after it could
        // fail on allocation, and a document that rendered but has no
        // layer is a document that silently does not paint.
        try self.paint_layers.ensureUnusedCapacity(1);
        const box = try element_layout.layoutAndRenderCached(doc.root, origin, constraints, &lc, dl);
        self.paint_layers.appendAssumeCapacity(.{
            .dispatches = .{ first.dispatches[0], @intCast(self.pass_dispatches.items.len) },
            .glyphs = .{ first.glyphs[0], @intCast(dl.glyph_targets.items.len) },
            .quads = .{ first.quads[0], @intCast(dl.quad_targets.items.len) },
            .tri_indices = .{ first.tri_indices[0], @intCast(dl.tri_indices.items.len) },
            .images = .{ first.images[0], @intCast(dl.image_targets.items.len) },
        });
        return box;
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

    // ── The overlay ─────────────────────────────────────────────────
    //
    // A document drawn over the page at a point. Three properties, and
    // the host gets none of them for free by rendering a second
    // document itself: it is ABOVE everything (`orderOverlayLast`), it
    // takes the pointer FIRST (`hitScope`), and it FLIPS rather than
    // clamping near an edge (`overlay.place`). Everything else about a
    // menu — what is in it, what the items do, whether there is a
    // search box — is the host's document and none of spark's business.
    // See `overlay.zig`.

    /// Open `doc` (markdown source) as the overlay, anchored so that
    /// `corner` of it sits at `at` — flipping to the other side of an
    /// axis if that would run it off the surface.
    ///
    /// `at` is in WORLD coordinates: the same ones `dispatchMouseButton`
    /// takes and the same ones the `context` record reports, so a host
    /// answering a right-click passes the numbers straight back.
    ///
    /// **Nothing here assumes a preceding right-click.** A host that
    /// picked a mesh in its own 3D scene, where no spark element is
    /// under the cursor at all, calls exactly this with a point it
    /// computed itself. That symmetry is the design: the same code path
    /// serves a right-click on a graph node and a right-click on a
    /// sphere in the viewport.
    ///
    /// **A second open replaces the first**, tearing down the previous
    /// document and its components. There is one overlay, not a stack —
    /// see `overlay.zig` for what a stack would change.
    ///
    /// The overlay document gets its own `State` (frontmatter seeds it)
    /// and the fixed registry scope `overlay.SCOPE`. Pass
    /// `LoadOpts.shared_state` through `opts` to have a menu read and
    /// write the host's own state, which is what a menu with a live
    /// `:::checkbox` in it wants.
    ///
    /// Rejected names: `showOverlay` (spark has no show/hide anywhere —
    /// a thing is rendered or it is not), `popup` (see `overlay.zig`),
    /// `openMenu` (the whole design is that spark does not know what a
    /// menu is).
    pub fn openOverlay(
        self: *Spark,
        doc: []const u8,
        at: [2]f32,
        corner: Corner,
        opts: document_mod.LoadOpts,
    ) !void {
        // **Close BEFORE loading, and it is not the obvious order.**
        // Building the replacement first would be the careful-looking
        // version — a parse failure would leave the previous menu up and
        // working. It is wrong here, and the reason is the shared
        // registry scope: both documents resolve their `:::` blocks
        // under `overlay.SCOPE`, so the new parse lands on the OLD
        // document's cached instances (same `#id`, same `auto:N`) and
        // adopts them, and the `deinitScope` in the close that followed
        // would then free components the new document's Element tree
        // points straight at. A dangling vtable pointer beats a lost
        // menu by a distance.
        //
        // So a failed open leaves nothing open. Say so rather than let a
        // host discover it: `openOverlay` returning an error means there
        // is no overlay, not that the old one survived.
        self.closeOverlay();

        var load = opts;
        load.scope = overlay_mod.SCOPE;
        var fresh = try self.loadDocument(doc, load);
        errdefer fresh.deinit();
        var scratch = element.DrawList.init(self.allocator);
        errdefer scratch.deinit();
        var scratch_pd = std.ArrayList(element.PassDispatch).init(self.allocator);
        errdefer scratch_pd.deinit();

        // **An overlay opening takes the pointer AND the keyboard.**
        // `dispatchMouseMove` routes to `captured` without consulting
        // the overlay at all, so a page gesture still holding it would
        // keep being dragged under an open menu; and `dispatchKey`
        // delivers to `focused`, so a text field on the page would
        // swallow everything typed while a menu was up — right-click
        // while editing, and the menu's own keystrokes land in the field
        // behind it. One rule for all three, stated here, rather than a
        // guard in each dispatcher that one of them forgets.
        //
        // The focus clear fires `focus_lost` on the previous holder
        // while it is still alive, which is what `clearFocus` is for.
        self.clearFocus();
        self.captured = null;
        self.hovered = null;

        self.overlay = .{
            .doc = fresh,
            .at = at,
            .corner = corner,
            .scratch = scratch,
            .scratch_pd = scratch_pd,
        };
    }

    /// Dismiss the overlay. A no-op when none is open, so a host can
    /// call it on any "the gesture is over" edge without asking first.
    ///
    /// **Three pointers and a slice of the hit layer have to go with
    /// it.** `captured`, `focused` and `hovered` hold `Hit`s by value,
    /// and a Hit inside the overlay points at a component this call is
    /// about to destroy; so does every entry in the overlay's range of
    /// `drawlist.hits`, which otherwise survives until the next
    /// `beginFrame` and would be hit-tested by any input arriving in
    /// between. A menu item whose handler closes the menu is the
    /// ordinary case, not an exotic one — that is what a menu item DOES
    /// — so this is the path, not the corner.
    ///
    /// The three are cleared unconditionally rather than only when they
    /// point into the overlay. Comparing would mean trusting a pointer
    /// into freed memory to still be comparable, and the blunt version
    /// costs nothing real: `openOverlay` cleared all three on the way
    /// in, so there is no page gesture left for this to interrupt.
    /// **Forget the hit layer, and every pointer into a component.**
    ///
    /// For a host about to tear a `Document` down while a frame's hits still
    /// reference its components. Those hits outlive the teardown — they are
    /// cleared at the next `beginFrame`, and a host that dispatches input
    /// before its next draw is dispatching into freed memory.
    ///
    /// matryoshka found this the hard way: `Panel.close` already cleared
    /// `captured`, with the comment *"a drag in flight was on an element that
    /// no longer exists"* — the right thought, stopped one step short. A
    /// right-click, a menu, a pick, and the panel it rebuilt left the OLD
    /// canvas in `hits`; the next hover walked a freed `Description` and read
    /// `0xAAAAAAAA` out of a poisoned pin.
    ///
    /// **Call it BEFORE the teardown.** Nothing here notifies — a component
    /// about to be destroyed has no use for `focus_lost`, and calling out to
    /// one that is already gone is the bug this exists to prevent. That is the
    /// difference from `closeOverlay`, which owns its document's lifetime and
    /// so can afford to be polite first.
    ///
    /// The overlay's recorded hit range is reset too. It is a pair of INDICES
    /// into the list being emptied, and a later `closeOverlay` would splice at
    /// them; it clamps, so this is belt-and-braces, and a stale range that
    /// clamps to a wrong-but-legal splice is worse than a crash because
    /// nothing says it happened.
    pub fn forgetHits(self: *Spark) void {
        self.drawlist.hits.clearRetainingCapacity();
        if (self.overlay) |*ov| ov.hits = .{ 0, 0 };
        self.captured = null;
        self.hovered = null;
        self.focused = null;
    }

    pub fn closeOverlay(self: *Spark) void {
        var ov = self.overlay orelse return;
        self.overlay = null;

        // `focus_lost` goes out while the component is still alive.
        self.clearFocus();
        self.captured = null;
        self.hovered = null;

        const hits = &self.drawlist.hits;
        const lo: usize = @min(ov.hits[0], hits.items.len);
        const hi: usize = @min(ov.hits[1], hits.items.len);
        if (hi > lo) {
            // `replaceRange` with nothing shifts the tail down; it
            // cannot fail for a shrink, and the tail is page hits that
            // stay perfectly valid at their new indices — nothing
            // anywhere stores a hit INDEX.
            hits.replaceRange(lo, hi - lo, &.{}) catch {};
        }

        // Components before the document, mirroring
        // `:::embedded-document`'s teardown: `deinitScope` destroys each
        // instance's Binding, and a Binding unsubscribes from the State
        // the document is about to free.
        self.registry.deinitScope(overlay_mod.SCOPE);
        ov.scratch.deinit();
        ov.scratch_pd.deinit();
        ov.doc.deinit();
    }

    /// Is an overlay up? A host asks before deciding whether a key or a
    /// click is the document's business.
    pub fn overlayOpen(self: *const Spark) bool {
        return self.overlay != null;
    }

    /// Where the open overlay sits, or null.
    ///
    /// For a host REPLACING one menu with another: a second-level menu is
    /// chosen with the cursor inside the first, so re-anchoring to the pointer
    /// would walk the menu down the screen one level at a time. Asking where
    /// the open one is keeps it put.
    ///
    /// The box is `{0,0,0,0}` until the first `layoutAndRenderOverlay`, so a
    /// host that opens two in one frame gets the origin it asked for rather
    /// than a corner — which is right, and is why this returns the box's
    /// position rather than a promise about it.
    pub fn overlayOrigin(self: *const Spark) ?[2]f32 {
        const ov = self.overlay orelse return null;
        return .{ ov.box.x, ov.box.y };
    }

    /// The width an overlay document is laid out against.
    ///
    /// A menu has a width; prose in spark claims whatever `max_w` it is
    /// offered, so an overlay given the surface width would be a menu as
    /// wide as the screen. This is the number that makes a menu look
    /// like one, and a host wanting another shape says so inside its own
    /// document (a `:::flex` with a fixed width, a `:::box`).
    ///
    /// Recorded, not built: per-open control of it. The trigger is the
    /// first host that wants two overlay shapes in one application — a
    /// narrow context menu and a wide inspector — at which point it
    /// becomes a field on `LoadOpts`-shaped options rather than a
    /// constant.
    pub const OVERLAY_MAX_W: f32 = 260;

    /// Measure the overlay, place it, and walk it into this frame's
    /// DrawList as its own paint layer. No-op when nothing is open.
    ///
    /// **Where in the frame this goes.** After the host's own
    /// `layoutAndRender` calls and BEFORE `dispatchOffscreenPasses` —
    /// not inside `endFrame`, which is the tempting place. By `endFrame`
    /// the offscreen phase may already have recorded descriptor binds
    /// against the pipelines' buffers, and appending to the drawlist
    /// there can demand a grow that `endFrame` is obliged to refuse
    /// (`error.DrawlistGrewAfterDispatch`) — and, because the refusal
    /// happens before `reserveForDrawlist`, the buffers never grow and
    /// the refusal repeats every frame. A menu that opens and
    /// permanently blacks out a document with an effect in it is a much
    /// worse trade than one call the host has to make.
    ///
    /// Calling this out of order does NOT put the menu under the page —
    /// `orderOverlayLast` handles that — and does not misroute input:
    /// the overlay records its own slice of the hit layer rather than
    /// relying on being last in it.
    ///
    /// **Laid out twice, on purpose.** The flip needs the document's
    /// size and spark cannot know it without walking: `measureBlock`
    /// answers zero height for a paragraph (it is a wrap-time question),
    /// so there is no cheap measure for prose. The first walk goes into
    /// a scratch DrawList the overlay owns and keeps — reused frame to
    /// frame, so the cost is a walk and not an allocation — and only its
    /// returned Box is used. The layout cache makes the second walk
    /// mostly a replay of the first. The alternative, placing from last
    /// frame's size, shows as a menu that jumps on its first frame.
    ///
    /// The measure walk is given the overlay's OWN dispatch list
    /// (`Overlay.scratch_pd`), sibling to its own DrawList, so a menu
    /// containing an effect does not emit its dispatches twice — and,
    /// just as importantly, so the block-cache entry that walk mints is
    /// a truthful one. It used to be handed `null`, which cost every
    /// effect in every overlay: see `Overlay.scratch_pd` for the whole
    /// mechanism and `src/tests/overlay_render.zig` for the gates.
    ///
    /// **The second walk being a CACHE HIT is load-bearing, and that is
    /// worth saying out loud.** The note that used to live here said a
    /// document registering kiwi constraints (`:::grid`) would be walked
    /// twice through one `LayoutContext.beginPass`, and that nobody had
    /// put a grid in a menu. Both halves were understated. `:::box` is
    /// the component that registers with the solver
    /// (`box.layoutViaConstraints` — and it is the only one), so every
    /// menu with a box in it is that document; and the reason it does
    /// not fire is that the second walk never reaches the solver,
    /// because `layoutAndRenderCached` answers it out of the entry the
    /// measure walk just snapshotted. Take the cache out of the measure
    /// walk and the very next line is
    /// `error.UnsatisfiableConstraint` from `addConstraint` —
    /// `x_min == 0` from the measure, `x_min == 200` from the placement,
    /// both `required`. Measured 2026-09-10, not reasoned about.
    ///
    /// So the double walk survives on the cache, and any overlay block
    /// that misses on the real walk is a crash waiting for a document.
    /// The honest fix is to stop walking twice: walk ONCE at (0, 0)
    /// into `ov.scratch` + `ov.scratch_pd`, place from the returned box,
    /// then merge into the frame at the placed origin with
    /// `element_layout.blitPrivate` + `mergePrivatePassDispatches` —
    /// the machinery `layoutStackV`'s parallel arm already uses to move
    /// a worker's private drawlist into the frame, translation of hits,
    /// clips and pass regions included. Recorded, not built: it moves a
    /// whole document's input routing and clip replay onto a path only
    /// workers have exercised, which is more than this beat can gate.
    /// **Trigger:** an overlay document whose top-level block is
    /// `disable_cache` (a `:::input` search box, a `:::clip`) and which
    /// also contains a `:::box` — that combination reaches the solver
    /// twice. `src/tests/overlay_render.zig`'s plain-quad gate pins the
    /// invariant it would break, so it goes red here rather than in a
    /// host.
    pub fn layoutAndRenderOverlay(self: *Spark) !void {
        // `&self.overlay.?`, not `&(self.overlay orelse return)` — the
        // latter takes the address of a COPY of the payload, and every
        // write below (`box`, `hits`, the scratch list's capacity) would
        // land on a temporary and vanish. It compiles, and the symptom
        // is a menu that is drawn but that no click can ever reach.
        if (self.overlay == null) return;
        const ov = &self.overlay.?;

        const constraints: element.Constraints = .{ .max_w = OVERLAY_MAX_W };

        // Pass 1 — measure. Scratch drawlist and scratch dispatch list,
        // both discarded except for the box they produce — and except
        // for the block-cache entries they leave behind, which is the
        // part that has to be complete.
        ov.scratch.clearRetainingCapacity();
        ov.scratch_pd.clearRetainingCapacity();
        const effective_theme = ov.doc.theme orelse self.theme;
        const effective_state = ov.doc.state orelse self.host_state;
        var measure_lc = element.LayoutCtx{
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
            .pass_dispatches = &ov.scratch_pd,
        };
        const measured = try element_layout.layoutAndRenderCached(
            ov.doc.root,
            .{ 0, 0 },
            constraints,
            &measure_lc,
            &ov.scratch,
        );

        // Pass 2 — place, then render for real.
        const origin = overlay_mod.place(
            ov.at,
            .{ measured.w, measured.h },
            ov.corner,
            self.surfaceRectWorld(),
        );
        const hits_before: u32 = @intCast(self.drawlist.hits.items.len);
        const box = try self.layoutAndRender(&ov.doc, origin, constraints);
        ov.box = box;
        ov.hits = .{ hits_before, @intCast(self.drawlist.hits.items.len) };
        // The layer this call just appended is the overlay's. Marked
        // here rather than threaded through `layoutAndRender` because
        // that signature is one matryoshka calls and one the whole
        // library's gates call; a parameter on it would have to be
        // written at forty call sites to say "no" at each.
        if (self.paint_layers.items.len > 0) {
            self.paint_layers.items[self.paint_layers.items.len - 1].overlay = true;
        }
    }

    /// The part of the world the host can actually see this frame.
    ///
    /// `screen = (world - scroll) * zoom`, so the visible world rect
    /// starts at `scroll` and is `extent / zoom` across. An overlay
    /// flips against THIS and not against `(0, 0, extent)`: a host that
    /// has scrolled the page 500px down has a menu near the bottom at
    /// world y ≈ 1200, a number that says nothing at all when compared
    /// to a 720px surface height.
    fn surfaceRectWorld(self: *const Spark) element.Box {
        const z = if (self.frame_info.zoom > 0) self.frame_info.zoom else 1.0;
        return .{
            .x = self.frame_info.scroll_offset[0],
            .y = self.frame_info.scroll_offset[1],
            .w = @as(f32, @floatFromInt(self.frame_info.extent.width)) / z,
            .h = @as(f32, @floatFromInt(self.frame_info.extent.height)) / z,
        };
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

    /// A drawlist clip index as a scissor in an OFFSCREEN TARGET's own
    /// pixels — the Phase 1 counterpart of `element.scissorOf` against
    /// `extent` on the main path.
    ///
    /// **Two changes of frame, and neither is optional.**
    ///
    /// 1. *World → screen.* The clip table rides the drawlist's
    ///    world→screen transform, and that transform runs in `endFrame`
    ///    — AFTER Phase 1. A quad's `dst_pos` reaches the GPU already
    ///    transformed because the SSBO is uploaded later (the routing
    ///    block below spells out that timing); a scissor does NOT,
    ///    because `vkCmdSetScissor` bakes its numbers into the command
    ///    buffer the moment it is recorded. So Phase 1 has to do the
    ///    transform itself, with the same scroll and zoom `endFrame`
    ///    will use. `drawlist_needs_transform` is the flag `endFrame`
    ///    keys on, so the two cannot disagree: on a `.reset = false`
    ///    frame the table already holds the previous frame's
    ///    screen-space rects and transforming again would
    ///    double-multiply.
    ///
    /// 2. *Screen → target-local.* `quad.vert` and `text.vert` compute
    ///    `px = dst_pos - world_offset`, so target-local IS screen minus
    ///    the very `world_offset` these draws are being recorded with.
    ///    Taking it from the caller rather than recomputing
    ///    `(compose_region - scroll) * zoom` here is the whole point:
    ///    one derivation, shared with the shader, so the scissor cannot
    ///    drift from the geometry it is cutting.
    ///
    /// Clamped to the TARGET's extent, not the surface's — an offscreen
    /// target is compose-region-sized, and Vulkan refuses a scissor
    /// reaching outside the framebuffer it is set on. A clip entirely
    /// off the target clamps to zero area, which draws nothing: the
    /// right answer, and not a case worth branching for.
    ///
    /// At `zoom != 1` this inherits the limitation the primitives
    /// already have — see the `TODO(zoom)` at the routing block:
    /// `target_size` is world-sized while screen coords are
    /// zoom-scaled, so a zoomed effect's content overruns its target
    /// either way. What has to hold is that the scissor lands in the
    /// SAME space as the geometry, and it does; sizing the target for
    /// zoom fixes both at once.
    fn offscreenScissor(
        self: *const Spark,
        clip: u16,
        world_offset: [2]f32,
        target_extent: vk.c.VkExtent2D,
    ) ?[4]u32 {
        const rect = self.drawlist.clipRect(clip) orelse return null;
        const screen = if (self.drawlist_needs_transform)
            rect.toScreen(self.frame_info.scroll_offset, self.frame_info.zoom)
        else
            rect;
        return element.scissorOf(.{
            .x = screen.x - world_offset[0],
            .y = screen.y - world_offset[1],
            .w = screen.w,
            .h = screen.h,
        }, target_extent.width, target_extent.height);
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
        if (std.posix.getenv("SPARK_DUMP_PASSES") != null) self.dumpPassGraph();
        // **Seal here as well as in `endFrame`.** Phase 1 reads
        // `quad_clips` / `glyph_clips` to scissor its offscreen draws,
        // and the walker only seals at clip boundaries — whatever was
        // emitted after the last one is still uncovered at this point.
        // The run iterator reads a short array as unclipped, which is
        // the same answer, but "the same answer by fallback" is not a
        // thing to lean on when those arrays are about to decide what
        // gets cut. Idempotent, so `endFrame`'s seal stays a no-op.
        try self.drawlist.sealClips(element.NO_CLIP);
        // **First thing, before a single draw is recorded.** Phase 1
        // binds the VBO/IBO by handle and the SSBO descriptor sets; a
        // grow after that point would leave those binds pointing at
        // freed memory. The drawlist is already complete here — the
        // host's `layoutAndRender` calls have all returned — so the
        // size is known and this is the earliest honest place to fix
        // it. See `reserveForDrawlist`.
        try self.reserveForDrawlist();
        // From here on this frame's cmd may carry binds, which is what
        // `endFrame`'s refusal keys on.
        if (self.pass_dispatches.items.len > 0) self.offscreen_recorded = true;
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
        //
        // **A nested dispatch is its parent's to process, not ours.**
        // The advances below skip PAST a subtree once its parent has
        // been handled, which is the right move for pre-order and this
        // walker emits post-order: children come first, so the top-level
        // loop reached every nested dispatch BEFORE the parent that owns
        // it and processed it a second time. Two pool acquisitions, two
        // sets of recorded commands, two descriptor sets, every frame,
        // for every effect nested in another — which is every applet
        // wearing chrome.
        //
        // `owned` is not Phase 2's `is_nested`, and the two must not be
        // merged. Phase 2 asks "was this composited into the parent's
        // target?", which a `{backdrop}` answers no to. Phase 1 asks
        // "will the parent walk this dispatch?", which every parent
        // answers yes to — both `phase1ProcessSingleSource` and
        // `phase1ProcessChain` recurse over their whole subtree before
        // anything source-specific happens. Same-shaped bitmaps, two
        // different questions.
        const owned = try self.allocator.alloc(bool, self.pass_dispatches.items.len);
        defer self.allocator.free(owned);
        markSubtreeOwned(self.pass_dispatches.items, owned);

        var i: u32 = 0;
        while (i < self.pass_dispatches.items.len) {
            if (owned[i]) {
                i += 1;
                continue;
            }
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

    /// Print this frame's pass graph and the drawlist's routing tags.
    /// `SPARK_DUMP_PASSES=1` in the environment turns it on.
    ///
    /// Two tables, and the bugs live in the join between them. The first
    /// is what the walker emitted — each dispatch's index, its source,
    /// and the subtree range it claims. The second is how many drawlist
    /// primitives carry each routing tag. A tag naming a dispatch that
    /// renders nothing (a `.backdrop`, which fills its target by copying
    /// the attachment) means those primitives are drawn by nobody, and
    /// the panel comes out empty. That is exactly how the
    /// `dispatch_start` aliasing was found — see `element.provisionalTag`.
    ///
    /// Glyphs only: they are the primitive whose absence is obvious to a
    /// person looking at the frame, and every routing bug so far has
    /// moved all four arrays together.
    fn dumpPassGraph(self: *Spark) void {
        if (self.pass_dispatches.items.len == 0) return;
        std.debug.print("--- pass_dispatches ({}) ---\n", .{self.pass_dispatches.items.len});
        for (self.pass_dispatches.items, 0..) |d, di| {
            switch (d) {
                .pattern => std.debug.print("  [{}] pattern\n", .{di}),
                .host_slot => std.debug.print("  [{}] host_slot\n", .{di}),
                .single_source => |ss| std.debug.print(
                    "  [{}] single_source src={s} subtree={any}\n",
                    .{ di, @tagName(ss.source), ss.subtree_dispatch_range },
                ),
                .chain => |c| std.debug.print(
                    "  [{}] chain src={s} subtree={any}\n",
                    .{ di, @tagName(c.source), c.subtree_dispatch_range },
                ),
            }
        }
        // Counted by scanning per distinct tag rather than with a map:
        // the tag space is the dispatch list plus one sentinel, so this
        // is a handful of passes over an array, and it needs no
        // allocator — which keeps the dump usable from anywhere.
        var counted: usize = 0;
        for (self.drawlist.glyph_targets.items) |t| {
            if (t == element.MAIN_TARGET) counted += 1;
        }
        if (counted > 0) std.debug.print("  glyphs tagged MAIN: {}\n", .{counted});
        for (0..self.pass_dispatches.items.len) |di| {
            var n: usize = 0;
            for (self.drawlist.glyph_targets.items) |t| {
                if (t == @as(u32, @intCast(di))) n += 1;
            }
            counted += n;
            if (n > 0) std.debug.print("  glyphs tagged [{}]: {}\n", .{ di, n });
        }
        // Anything left over is wearing a tag that is neither MAIN nor a
        // dispatch — an unresolved provisional tag, which means a pass
        // element returned without rewriting its own span.
        if (counted < self.drawlist.glyph_targets.items.len) {
            std.debug.print(
                "  glyphs tagged UNRESOLVED: {} <- a provisional tag escaped the walk\n",
                .{self.drawlist.glyph_targets.items.len - counted},
            );
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

        // A `.host_named` pass owns NO target. Its source is an image
        // the host already holds, bound straight into the compose's
        // sampler — so there is nothing to acquire, nothing to render
        // into, and nothing to release. `dispatch_target_map` stays
        // null at this index and Phase 2 reads the host's view
        // instead. The children were left on MAIN by the walker (the
        // same routing a backdrop gets) and draw over the composite.
        //
        // Returning here rather than acquiring-and-ignoring is the
        // point: a pool target per magnifying glass per frame, never
        // written and never read, is exactly the kind of cost that
        // hides until somebody opens eight panels.
        if (S.source == .host_named) return;

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

        // Fill the target — the subtree, or the attachment behind it.
        //
        // A `.backdrop` single_source copies the region of the host's
        // attachment this element covers instead of rendering its children
        // into it, and the children are left on MAIN to be drawn over the
        // composited result. Same idea and the same helper as a backdrop
        // chain — which is why `PassSource` is not called `ChainSource` any
        // more. For `:::liquid_glass` it is the difference between
        // refracting its own content and refracting the scene behind the
        // panel, the "see-through" look its header used to say needed a
        // second sampler. It does not: the backdrop IS the one sampler.
        if (S.source == .backdrop) {
            try self.fillTargetFromMain(cmd, target_handle, S.compose_region, S.target_size);
        } else {
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
                        // Optional: a `.host_named` nested pass owns no
                        // target — the compose resolves the host's view
                        // itself, and its window is computed from the
                        // SCREEN-space compose_region, so it samples the
                        // right part of the surface even while being
                        // drawn into a parent's offscreen target.
                        const nested_target = self.dispatch_target_map.items[j];
                        const nx: f32 = @floatFromInt(nested.compose_region.x - S.compose_region.x);
                        const ny: f32 = @floatFromInt(nested.compose_region.y - S.compose_region.y);
                        const nw: f32 = @floatFromInt(nested.compose_region.w);
                        const nh: f32 = @floatFromInt(nested.compose_region.h);
                        try self.recordSingleSourceCompose(cmd, nested, nested_target, nx, ny, nw, nh, &last_compose, .offscreen);
                        // `+ 1`, because a dispatch sits AT its own
                        // `subtree_dispatch_range[1]` — the walker captures
                        // `seq` before appending itself. Landing on `[1]`
                        // lands back on THIS entry and the loop never
                        // advances, which is an infinite loop that records a
                        // composite per turn and allocates a descriptor set
                        // per composite: the fan spins up and the frame never
                        // ends. `dispatchOffscreenPasses` says exactly this
                        // and gets it right; these two nested walks did not.
                        j = nested.subtree_dispatch_range[1] + 1;
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
                    // C.1.5 advance is `subtree_dispatch_range[1] + 1`,
                    // the same fencepost every other walk uses. This
                    // comment used to claim the no-+1 shape was fine
                    // because "the inner walk's while-condition handles
                    // the chain's own-index termination" — it does not:
                    // `[1]` IS the chain's own index, so `j` lands back
                    // on itself and spins.
                    .chain => |nested_c| {
                        const inner_base = self.chain_pool_bases.items[j] orelse unreachable;
                        const final_target = self.acquired_targets.items[inner_base + nested_c.final_pool_local];
                        const nx: f32 = @floatFromInt(nested_c.compose_region.x - S.compose_region.x);
                        const ny: f32 = @floatFromInt(nested_c.compose_region.y - S.compose_region.y);
                        const nw: f32 = @floatFromInt(nested_c.compose_region.w);
                        const nh: f32 = @floatFromInt(nested_c.compose_region.h);
                        try self.recordChainFinalComposite(cmd, nested_c, final_target, nx, ny, nw, nh, &last_compose, .offscreen);
                        // `+ 1`, because a dispatch sits AT its own
                        // `subtree_dispatch_range[1]` — the walker captures
                        // `seq` before appending itself. Landing on `[1]`
                        // lands back on THIS entry and the loop never
                        // advances, which is an infinite loop that records a
                        // composite per turn and allocates a descriptor set
                        // per composite: the fan spins up and the frame never
                        // ends. `dispatchOffscreenPasses` says exactly this
                        // and gets it right; these two nested walks did not.
                        j = nested_c.subtree_dispatch_range[1] + 1;
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
            // Clipping reaches INSIDE an effect, and the runs split for
            // it exactly as the main pass's do. A scissor is per-draw
            // dynamic state, so a run has to be uniform in its clip or
            // the last rect set wins over primitives that wanted a
            // different one — and one rect per dispatch is not enough
            // for the shape every real customer has: matryoshka's HUD
            // panel is a title, a clipped `:::nodegraph` canvas, and a
            // footer, all inside one `:::drop_shadow`, so the canvas's
            // rect must apply to the canvas and to nothing else.
            {
                var it = element.clippedRuns(dl_p1.quad_targets.items, dl_p1.quad_clips.items, dispatch_index_u32);
                while (it.next()) |run| {
                    const sc = self.offscreenScissor(run.clip, world_offset_target, target_extent_render);
                    self.quad_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen, sc);
                }
            }
            {
                var it = element.clippedRuns(dl_p1.glyph_targets.items, dl_p1.glyph_clips.items, dispatch_index_u32);
                while (it.next()) |run| {
                    const sc = self.offscreenScissor(run.clip, world_offset_target, target_extent_render);
                    self.text_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen, sc);
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

        // (3) Fill pool[0] — the chain's source image.
        //
        // A `.subtree` chain renders its children into it: the effect
        // filters what it wraps. A `.backdrop` chain COPIES the region of
        // the host's attachment the panel covers, so the effect filters
        // what is BEHIND it, and the children are left on MAIN to be drawn
        // over the result in Phase 2.
        //
        // The copy is legal here and nowhere else: `dispatchOffscreenPasses`
        // runs BEFORE the host opens its rendering scope, so the attachment
        // is not in use and can be transitioned to TRANSFER_SRC and back.
        // It also fixes what a backdrop can see — whatever the host drew
        // before calling spark, and nothing spark itself draws this frame.
        if (C.source == .backdrop) {
            try self.fillTargetFromMain(cmd, pool_zero, C.compose_region, C.target_size);
        } else {
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
                        // Optional: a `.host_named` nested pass owns no
                        // target — the compose resolves the host's view
                        // itself, and its window is computed from the
                        // SCREEN-space compose_region, so it samples the
                        // right part of the surface even while being
                        // drawn into a parent's offscreen target.
                        const nested_target = self.dispatch_target_map.items[j];
                        const nx: f32 = @floatFromInt(nested.compose_region.x - C.compose_region.x);
                        const ny: f32 = @floatFromInt(nested.compose_region.y - C.compose_region.y);
                        const nw: f32 = @floatFromInt(nested.compose_region.w);
                        const nh: f32 = @floatFromInt(nested.compose_region.h);
                        try self.recordSingleSourceCompose(cmd, nested, nested_target, nx, ny, nw, nh, &last_compose, .offscreen);
                        // `+ 1`, because a dispatch sits AT its own
                        // `subtree_dispatch_range[1]` — the walker captures
                        // `seq` before appending itself. Landing on `[1]`
                        // lands back on THIS entry and the loop never
                        // advances, which is an infinite loop that records a
                        // composite per turn and allocates a descriptor set
                        // per composite: the fan spins up and the frame never
                        // ends. `dispatchOffscreenPasses` says exactly this
                        // and gets it right; these two nested walks did not.
                        j = nested.subtree_dispatch_range[1] + 1;
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
                        // `+ 1`, because a dispatch sits AT its own
                        // `subtree_dispatch_range[1]` — the walker captures
                        // `seq` before appending itself. Landing on `[1]`
                        // lands back on THIS entry and the loop never
                        // advances, which is an infinite loop that records a
                        // composite per turn and allocates a descriptor set
                        // per composite: the fan spins up and the frame never
                        // ends. `dispatchOffscreenPasses` says exactly this
                        // and gets it right; these two nested walks did not.
                        j = nested_c.subtree_dispatch_range[1] + 1;
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
            // Clipped runs, same as the single_source arm above and for
            // the same reason — see the note there. This is the arm the
            // HUD panel actually takes: `:::drop_shadow` and a
            // non-backdrop `:::frosted_glass` are chains, and a
            // `{backdrop}` chain nested inside one leaves its children
            // on the ENCLOSING tag, which is this pool[0].
            {
                var it = element.clippedRuns(dl_p1.quad_targets.items, dl_p1.quad_clips.items, dispatch_index_u32);
                while (it.next()) |run| {
                    const sc = self.offscreenScissor(run.clip, world_offset_target, target_extent_render);
                    self.quad_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen, sc);
                }
            }
            {
                var it = element.clippedRuns(dl_p1.glyph_targets.items, dl_p1.glyph_clips.items, dispatch_index_u32);
                while (it.next()) |run| {
                    const sc = self.offscreenScissor(run.clip, world_offset_target, target_extent_render);
                    self.text_pipeline.recordDrawRange(cmd, target_extent_render, world_offset_target, run.first, run.count, display_mod.Push.offscreen, .offscreen, sc);
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
        }

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

    /// Where `element.CornerPush` sits in the head: after the display
    /// transform's two floats, rounded up to the vec4 boundary the shaders
    /// declare as `vec2 display; vec2 _display_pad;`. Named rather than
    /// spelled inline because getting it wrong writes the corner over the
    /// paperwhite value and every effect goes dark on an HDR surface.
    const CORNER_PUSH_OFFSET: u32 = 16;

    comptime {
        if (CORNER_PUSH_OFFSET + @sizeOf(element.CornerPush) != element.PASS_UNIFORM_OFFSET) {
            @compileError("the fixed head and PASS_UNIFORM_OFFSET disagree: an effect's own uniforms would land on top of the corner block");
        }
        if (@sizeOf(display_mod.Push) > CORNER_PUSH_OFFSET) {
            @compileError("display_mod.Push has outgrown its slot in the head");
        }
    }

    /// Push an effect's uniforms plus the fixed head, in the layout
    /// `element.PASS_UNIFORM_OFFSET` describes. Three ranges, one call-site
    /// shape, so no record path can forget the head.
    ///
    /// The head is the display transform and the composite's geometry, and
    /// both belong to the RECORD path: the display is per-frame, and the
    /// corner needs the region in physical pixels. A component snapshotting
    /// its uniforms at layout time has neither.
    fn pushEffectUniforms(
        cmd: vk.c.VkCommandBuffer,
        layout: vk.c.VkPipelineLayout,
        disp: display_mod.Push,
        corner: element.CornerPush,
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
        var cn = corner;
        vk.c.vkCmdPushConstants(
            cmd,
            layout,
            vk.c.VK_SHADER_STAGE_FRAGMENT_BIT,
            CORNER_PUSH_OFFSET,
            @sizeOf(element.CornerPush),
            &cn,
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
            .{ .size_px = .{ vw, vh }, .radius_px = pattern_step.corner_radius },
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
        target_handle: ?pass_mod.TargetHandle,
        vx: f32,
        vy: f32,
        vw: f32,
        vh: f32,
        last_bound: *vk.c.VkPipeline,
        att: vk.Attachment,
    ) !void {
        // Where the one sampler's pixels come from, and — for a
        // `.host_named` pass — the window onto them.
        //
        // `window` is null for every other source, because they sample
        // a target cut to the panel's own size and the quad's `[0,1]`
        // UV already IS the panel. Only a host surface is bigger than
        // what is being shown of it.
        var window: ?[4]f32 = null;
        // Spark's own targets are left in `SHADER_READ_ONLY_OPTIMAL` by
        // the barrier that ended their pass. A host surface is in
        // whatever the host put it in, and the descriptor must declare
        // that layout and not this one — see `HostSurfaceImage.layout`.
        var source_layout: c_uint = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        const source_view: vk.c.VkImageView = blk: {
            if (ss.source == .host_named) {
                // No surface, or a name this host does not answer for:
                // composite NOTHING and let the children draw. A
                // document that asks for `surface=nrmal` shows an
                // empty panel with working buttons, which is a legible
                // wrong rather than a validation error on a null view.
                const img = self.hostSurface(ss.host_surface.slice()) orelse return;
                window = hostWindow(ss.compose_region, img.span_w, img.span_h, img.fit);
                source_layout = img.layout.toVk();
                break :blk img.view;
            }
            break :blk (target_handle orelse return).view();
        };
        const pipeline = self.single_source_pipelines.lookup(ss.filter_shader_id, att) orelse return;
        if (pipeline != last_bound.*) {
            vk.c.vkCmdBindPipeline(cmd, vk.c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            last_bound.* = pipeline;
        }
        const set = try self.single_source_descriptor_pool.acquire(
            source_view,
            self.single_source_pipelines.sampler,
            source_layout,
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
        // A backdrop's pixels were COPIED off the host's attachment and
        // already carry the display transform; encoding again would push a
        // PQ code through the PQ curve twice. Same rule as the chain arm.
        const disp = switch (ss.source) {
            // A host surface holds DATA, not a picture — a world-space
            // normal, a raw albedo, a depth. The filter turns that into
            // a colour it authored, so it encodes like anything else
            // spark draws. Only a backdrop skips the transform, because
            // only a backdrop's pixels arrived already carrying it.
            .subtree, .host_named => self.displayFor(att),
            .backdrop => display_mod.Push.offscreen,
        };
        // The window transform is spark's to write, not the component's:
        // it needs the laid-out box and the host surface's dimensions,
        // and neither exists when `apply_attrs` runs. It overwrites the
        // head of the effect's own block — see `element.HOST_WINDOW_BYTES`,
        // where the contract is stated.
        var uniforms = ss.filter_uniforms;
        var ulen = ss.filter_uniforms_len;
        if (window) |w| {
            ulen = @max(ulen, element.HOST_WINDOW_BYTES);
            @memcpy(uniforms[0..element.HOST_WINDOW_BYTES], std.mem.asBytes(&w));
        }
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            disp,
            .{ .size_px = .{ vw, vh }, .radius_px = ss.corner_radius },
            uniforms[0..ulen],
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
            // Spark's own target: its barrier ended here.
            vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
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
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            self.displayFor(att),
            .{ .size_px = .{ vw, vh }, .radius_px = hs.corner_radius },
            &.{},
        );
        vk.c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    /// Fill a backdrop effect's offscreen target with the region of the
    /// host's attachment that the element covers — what is already on screen
    /// behind the panel. Shared by the chain arm (where the target is
    /// pool[0]) and the single_source arm (where it is the only target).
    ///
    /// **Why a blit and not a shader.** The source and destination differ in
    /// both format (a swapchain 8- or 10-bit UNORM into the pool's RGBA16F)
    /// and size is 1:1, which is exactly what `vkCmdBlitImage` converts. A
    /// shader pass would need the attachment bound as a sampler, and the
    /// host's image was not created SAMPLED.
    ///
    /// **The values copied are DISPLAY-ENCODED, and stay that way.** On a PQ
    /// swapchain these are ST 2084 codes, not linear light. Blurring them
    /// blurs in the display encoding, which is what every 2D compositor
    /// does and is fine for a frosted panel. What matters is that the final
    /// composite must NOT then apply the display transform again — the
    /// pixels already carry it. `recordChainFinalComposite` passes
    /// `Push.offscreen` for a backdrop chain for exactly that reason; PQ
    /// twice is not PQ, and we have paid for that lesson once already.
    fn fillTargetFromMain(
        self: *Spark,
        cmd: vk.c.VkCommandBuffer,
        target: pass_mod.TargetHandle,
        compose_region: element.PassRegion,
        target_size: [2]u32,
    ) !void {
        const src_image = self.frame_info.target_image orelse return error.BackdropNeedsTargetImage;

        // Screen-space region, the same transform Phase 2 composites with —
        // `compose_region` is world coords, and a scrolled or zoomed
        // document would otherwise sample the wrong part of the screen.
        const sx = self.frame_info.scroll_offset[0];
        const sy = self.frame_info.scroll_offset[1];
        const z = self.frame_info.zoom;
        const fx = (@as(f32, @floatFromInt(compose_region.x)) - sx) * z;
        const fy = (@as(f32, @floatFromInt(compose_region.y)) - sy) * z;
        const fw = @as(f32, @floatFromInt(compose_region.w)) * z;
        const fh = @as(f32, @floatFromInt(compose_region.h)) * z;

        // Clamp to the attachment. A panel hanging off the edge would
        // otherwise ask the driver to read outside the image, and the
        // validation layers are right to complain.
        const ext_w: i32 = @intCast(self.frame_info.extent.width);
        const ext_h: i32 = @intCast(self.frame_info.extent.height);
        const x0 = std.math.clamp(@as(i32, @intFromFloat(@round(fx))), 0, ext_w);
        const y0 = std.math.clamp(@as(i32, @intFromFloat(@round(fy))), 0, ext_h);
        const x1 = std.math.clamp(@as(i32, @intFromFloat(@round(fx + fw))), x0, ext_w);
        const y1 = std.math.clamp(@as(i32, @intFromFloat(@round(fy + fh))), y0, ext_h);
        if (x1 <= x0 or y1 <= y0) return; // fully offscreen — the target stays cleared

        barrierImageLayout(cmd, src_image, .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            .src_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = vk.c.VK_ACCESS_2_TRANSFER_READ_BIT,
            // The host owns this image and has already drawn into it; its
            // contents are the whole point, so nothing here may discard.
            .old_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        });
        barrierImageLayout(cmd, target.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            .src_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .dst_access = vk.c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        });

        const sub = vk.c.VkImageSubresourceLayers{
            .aspectMask = vk.c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        var blit = vk.c.VkImageBlit{
            .srcSubresource = sub,
            .srcOffsets = .{
                .{ .x = x0, .y = y0, .z = 0 },
                .{ .x = x1, .y = y1, .z = 1 },
            },
            .dstSubresource = sub,
            .dstOffsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{ .x = @intCast(target_size[0]), .y = @intCast(target_size[1]), .z = 1 },
            },
        };
        vk.c.vkCmdBlitImage(
            cmd,
            src_image,
            vk.c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            target.image(),
            vk.c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &blit,
            vk.c.VK_FILTER_LINEAR,
        );

        // Hand both images back: the attachment to the host, which is about
        // to open its rendering scope on it, and the target to whatever
        // samples it next (a chain's steps, or Phase 2's compose).
        barrierImageLayout(cmd, src_image, .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .src_access = vk.c.VK_ACCESS_2_TRANSFER_READ_BIT,
            .dst_access = vk.c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });
        barrierImageLayout(cmd, target.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            .dst_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .src_access = vk.c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .dst_access = vk.c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .old_layout = vk.c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .new_layout = vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        });
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
        //
        // **Both cases wait on the FRAGMENT SHADER, and that is what makes
        // the pool a ping-pong pool.** The `.clear` arm used to name
        // TOP_OF_PIPE, which waits for nothing: correct while every step
        // wrote a target no earlier step had read, and a write-after-read
        // hazard the moment one writes back into a target it just sampled —
        // which is exactly what ping-ponging between two targets IS. The
        // discard does not save us; UNDEFINED throws away the contents, but
        // the transition itself still races the previous step's reads, and
        // the corruption would be driver-dependent and intermittent. A WAR
        // needs an execution dependency only, so `src_access` stays 0 on the
        // clear path — reads leave nothing to flush — and the cost of the
        // fix is a scoreboard wait the ping-pong could not be correct
        // without. `:::frosted_glass` is the first step sequence to rely on
        // it (pool[0] → pool[1] → pool[0]).
        const keep = step.load == .keep;
        barrierImageLayout(cmd, dest.image(), .{
            .src_stage = vk.c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
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
            // Spark's own target: its barrier ended here.
            vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
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
        // A chain STEP is a full-image filter into a pool target, and the
        // rounding belongs to the final composite that lands on the host's
        // attachment. Rounding here would carve the corner out of an
        // intermediate the next step is about to blur back over.
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            display_mod.Push.offscreen,
            .{},
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
            // Spark's own target: its barrier ended here.
            vk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
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
        // **A backdrop must not be encoded twice.** Every other composite
        // carries spark's own display-referred colour and needs the frame's
        // transform on the way to the host's attachment. A backdrop's pixels
        // were COPIED off that attachment and already carry it — encoding
        // again would push a PQ code through the PQ curve a second time, and
        // `pq(pq(x))` is a searchlight. Passthrough, for the one case where
        // the source is the destination's own encoding.
        const disp = switch (ch.source) {
            // `.host_named` has no chain arm. A chain's pool[0] is
            // FILLED — rendered into, or blitted into — and a host
            // surface is neither: it is bound as a sampler and never
            // copied, which is the whole reason the effect can remap
            // values a blit could not. A chain that wanted one would
            // have to sample the host image in its first step rather
            // than adopt it as pool[0], and nothing has asked. Grouped
            // with `.subtree` rather than left unreachable because if
            // it ever arrives it will be authored colour, like every
            // other filter output, and this is the answer it wants.
            .subtree, .host_named => self.displayFor(att),
            .backdrop => display_mod.Push.offscreen,
        };
        pushEffectUniforms(
            cmd,
            self.single_source_pipelines.layout,
            disp,
            .{ .size_px = .{ vw, vh }, .radius_px = ch.corner_radius },
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
            // The clip table rides the SAME transform, in the same pass,
            // with the same numbers. It has to be here and not at the
            // draw: this whole block is skipped on a frame that reused
            // the previous layout, so a clip transformed independently
            // would be applying this frame's scroll to primitives still
            // holding the last frame's.
            for (dl.clips.items) |*r| r.* = r.toScreen(.{ sx, sy }, z);
            self.drawlist_needs_transform = false;
        }

        // Every primitive emitted after the last clip boundary is
        // unclipped — the tail of the frame, and the whole of a document
        // that never clipped anything. `sealClips` is idempotent, so this
        // costs nothing when the walker already sealed.
        try dl.sealClips(element.NO_CLIP);

        // **Grow before writing, and before recording anything.** The
        // drawlist is final, so the size it needs is a number rather
        // than a failure to discover. On a settled document this is
        // four integer compares; on the frame a document outgrows its
        // starting size it is one reallocation, and the page renders
        // instead of going black.
        //
        // The `needsRoom` question comes FIRST because a grow after
        // Phase 1 has recorded binds would free memory this very
        // command buffer already points at — and the host submits that
        // command buffer whether or not `endFrame` returned an error
        // (spark's own demo prints the error and lets `drawFrame`
        // submit). So a host that appended to the drawlist between
        // `dispatchOffscreenPasses` and here gets a named refusal and
        // an intact frame, not a dangling handle.
        if (self.offscreen_recorded and self.needsRoom()) return error.DrawlistGrewAfterDispatch;
        try self.reserveForDrawlist();

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
        // No `if (pass_dispatches.len > 0)` guard any more: with no
        // dispatches every range below is empty and every loop is a
        // no-op, and the geometry draws — which it must, since a
        // document with no effects at all is the common case.
        {
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
                        // Same rule as the chain arm: a BACKDROP fills its
                        // target from the attachment, so the children were
                        // never routed into it and are ordinary MAIN content.
                        if (!ss.source.isBackground()) {
                            var k = ss.subtree_dispatch_range[0];
                            while (k < ss.subtree_dispatch_range[1]) : (k += 1) {
                                is_nested[k] = true;
                            }
                        }
                    },
                    // Effects-spec C.1.5 — chain joins single_source
                    // as a content-wrapping shape. Its subtree
                    // dispatches were rendered into pool[0] by
                    // Phase 1; Phase 2 must skip them as nested.
                    .chain => |c| {
                        // A BACKDROP chain does not own its subtree: pool[0]
                        // is a copy of the attachment, and the children were
                        // never routed into it. They are ordinary MAIN
                        // content and must be dispatched, not skipped.
                        if (!c.source.isBackground()) {
                            var k = c.subtree_dispatch_range[0];
                            while (k < c.subtree_dispatch_range[1]) : (k += 1) {
                                is_nested[k] = true;
                            }
                        }
                    },
                    else => {},
                }
            }

            const sx = self.frame_info.scroll_offset[0];
            const sy = self.frame_info.scroll_offset[1];
            const z = self.frame_info.zoom;

            // Scratch for the per-layer background sort. Sized once for
            // the whole frame and reused — a layer's list is a subset of
            // it, so one allocation covers every layer.
            const bgs = try self.allocator.alloc(BackgroundSpan, pd_len);
            defer self.allocator.free(bgs);

            // **One layer at a time, in call order.** Everything below —
            // the background pre-pass, the top-level composites, and the
            // MAIN geometry — used to run once for the whole frame, which
            // put every document's text above every document's glass. See
            // `PaintLayer`. A host that renders one document gets exactly
            // one layer and the identical sequence of commands.
            //
            // …with one exception, and it is the only one: the OVERLAY's
            // layer goes last whatever order the host called
            // `layoutAndRender` in. See `orderOverlayLast` for why that
            // is a sort here rather than a rule the host is asked to
            // keep. In place, so the `.reset = false` replay path sees
            // the same order next frame — and idempotent, so seeing it
            // twice costs one pass of an already-sorted insertion sort.
            orderOverlayLast(self.paint_layers.items);
            var only = [_]PaintLayer{PaintLayer.whole(dl, pd_len)};
            const layers: []const PaintLayer = if (self.paint_layers.items.len > 0)
                self.paint_layers.items
            else
                only[0..];

            for (layers) |layer| {
                // Bind cursors are PER LAYER, and must be: geometry is
                // recorded between one layer's composites and the next
                // layer's, so a cursor carried across the boundary would
                // report a pipeline as still bound after the quad and
                // text pipelines have been bound over it — and the next
                // composite would be recorded with no bind at all.
                var last_pattern: vk.c.VkPipeline = null;
                var last_compose: vk.c.VkPipeline = null;

                // **Backgrounds first, outermost first.** A backdrop chain is a
                // background in the same sense `:::pattern` is: its children,
                // and any effect nested in them, belong ON TOP of it. But the
                // walker emits post-order — children come before their parent —
                // so composing in the main loop would lay the panel over the
                // very content it is supposed to sit behind. A pre-pass puts it
                // underneath, and keeps two overlapping backdrops in the order
                // the author wrote them.
                //
                // The pre-pass cannot keep raw dispatch order, though, and for
                // a week it did. Post-order puts a background NESTED inside
                // another before the one containing it, so a `:::gbuffer` in a
                // `:::frosted_glass {backdrop}` composited first and the chrome
                // painted over its own child — the panel vanished. That is the
                // whole reason an applet could have chrome or draw its own
                // passes and not both. `orderBackgrounds` sorts them
                // outermost-first; see its doc for why the key is correct.
                //
                // The consequence, stated rather than discovered: a background
                // still lands under every NON-background pass this frame, not
                // just its own children. Two backdrops stack by document order;
                // a backdrop cannot be composited over a sibling drop shadow.
                var bg_n: usize = 0;
                for (layer.dispatches[0]..layer.dispatches[1]) |bi| {
                    const d = self.pass_dispatches.items[bi];
                    // A background inside a `.subtree` parent was rendered into
                    // THAT parent's pool by Phase 1 and is not ours to put on
                    // MAIN — compositing it here as well would draw it twice,
                    // the second time outside the effect wrapping it.
                    if (is_nested[bi]) continue;
                    const start: u32 = switch (d) {
                        .chain => |c| if (c.source.isBackground()) c.subtree_dispatch_range[0] else continue,
                        .single_source => |ss| if (ss.source.isBackground()) ss.subtree_dispatch_range[0] else continue,
                        else => continue,
                    };
                    bgs[bg_n] = .{ .index = @intCast(bi), .subtree_start = start };
                    bg_n += 1;
                }
                orderBackgrounds(bgs[0..bg_n]);

                for (bgs[0..bg_n]) |bg| {
                    const bi = bg.index;
                    switch (self.pass_dispatches.items[bi]) {
                        .chain => |c| {
                            const pool_base = self.chain_pool_bases.items[bi] orelse unreachable;
                            const final_target = self.acquired_targets.items[pool_base + c.final_pool_local];
                            const bx = (@as(f32, @floatFromInt(c.compose_region.x)) - sx) * z;
                            const by = (@as(f32, @floatFromInt(c.compose_region.y)) - sy) * z;
                            const bw = @as(f32, @floatFromInt(c.compose_region.w)) * z;
                            const bh = @as(f32, @floatFromInt(c.compose_region.h)) * z;
                            try self.recordChainFinalComposite(cmd, c, final_target, bx, by, bw, bh, &last_compose, .main);
                        },
                        .single_source => |ss| {
                            // Backdrops AND host-named surfaces: both are
                            // backgrounds to their own children, and both
                            // need the pre-pass for the same post-order
                            // reason. A host_named pass owns no target —
                            // its sampler is the host's image — so the
                            // handle is legitimately null here and the
                            // compose resolves the view itself.
                            const target = self.dispatch_target_map.items[bi];
                            const bx = (@as(f32, @floatFromInt(ss.compose_region.x)) - sx) * z;
                            const by = (@as(f32, @floatFromInt(ss.compose_region.y)) - sy) * z;
                            const bw = @as(f32, @floatFromInt(ss.compose_region.w)) * z;
                            const bh = @as(f32, @floatFromInt(ss.compose_region.h)) * z;
                            try self.recordSingleSourceCompose(cmd, ss, target, bx, by, bw, bh, &last_compose, .main);
                        },
                        // The list was built from the same two arms above, so
                        // anything else here means the two switches drifted.
                        else => unreachable,
                    }
                }

                var i: usize = layer.dispatches[0];
                while (i < layer.dispatches[1]) {
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
                            // Every background source was composited in the
                            // pre-pass above — compositing again here would
                            // draw the panel twice, the second time over its
                            // own children.
                            if (ss.source.isBackground()) {
                                i = ss.subtree_dispatch_range[1] + 1;
                                continue;
                            }
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
                            // Backgrounds were composited in the pre-pass
                            // above. `isBackground()` rather than
                            // `== .backdrop` so this site and the pre-pass's
                            // filter cannot drift: a source that is a
                            // background to one of them and not to the other
                            // is composited twice or not at all.
                            if (c.source.isBackground()) {
                                i += 1;
                                continue;
                            }
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
                // whole layer, so the cost reduces to one recordDrawRange
                // per pipeline — identical command volume to the pre-B.4.b.4
                // single recordDraw, just with `firstInstance = 0` made
                // explicit. The TriRun iterator's index-space arithmetic
                // means `vkCmdDrawIndexed` receives the same arguments as
                // before in the no-effect case.
                //
                // Paint order: tri → image → quad → text. SVG fills under
                // chrome under glyphs — same as pre-B.4.b.4 and same as the
                // offscreen-target order inside Phase 1. Within a LAYER: the
                // rule orders one document's own primitives, and it is the
                // wrong rule to apply across two, which is what a
                // frame-global sweep did.
                //
                // Each iterator is given the layer's slice, so `run.first` is
                // layer-relative and the layer's start is added back. Tris
                // slice `tri_indices` rather than `tri_targets` because a
                // draw consumes indices and the tag lives in vertex space —
                // slicing the tags would cut the wrong array at the wrong
                // place, and would do it silently.
                //
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
                    const base = layer.tri_indices[0];
                    var it = element.triRuns(
                        dl.tri_targets.items,
                        dl.tri_indices.items[base..layer.tri_indices[1]],
                        element.MAIN_TARGET,
                    );
                    while (it.next()) |run| {
                        self.tri_pipeline.recordDrawIndexedRange(cmd, extent, main_world_offset, base + run.first_index, run.index_count, disp, .main);
                    }
                }
                {
                    const base = layer.images[0];
                    var it = element.runs(dl.image_targets.items[base..layer.images[1]], element.MAIN_TARGET);
                    const all_images = dl.images.items;
                    while (it.next()) |run| {
                        if (run.count == 0) continue;
                        self.image_pipeline.bind(cmd, extent, .main);
                        const subset = all_images[base + run.first .. base + run.first + run.count];
                        for (subset) |im| {
                            self.image_pipeline.recordOne(cmd, extent, main_world_offset, @ptrCast(@alignCast(im.descriptor_set)), im.dst_pos, im.dst_size, disp);
                        }
                    }
                }
                // Clipping on the MAIN attachment. `extent` and
                // `main_world_offset = (0,0)` make this the identity case
                // of the same arithmetic Phase 1 does in
                // `offscreenScissor` — the clip table is already in
                // screen space by the time this runs, and the main
                // attachment IS screen space, so there is nothing to
                // rebase and no clamp target but the surface.
                //
                // This note used to say the two offscreen paths passed
                // null because "nothing clips inside an effect yet". That
                // premise died the day matryoshka's HUD wrapped a
                // `:::nodegraph` canvas in `:::drop_shadow`: the panel's
                // whole subtree routes into the chain's pool[0], the
                // canvas's scissor went with it, and node bodies and
                // labels painted over the panel's own title and footer.
                // Wires clipped throughout, which is the tell — the
                // nodegraph cuts its link segments on the CPU, and only
                // quads and glyphs ever depended on the scissor.
                {
                    const base = layer.quads[0];
                    var it = element.clippedRuns(
                        dl.quad_targets.items[base..layer.quads[1]],
                        clipSlice(dl.quad_clips.items, base, layer.quads[1]),
                        element.MAIN_TARGET,
                    );
                    while (it.next()) |run| {
                        const sc: ?[4]u32 = if (dl.clipRect(run.clip)) |r|
                            element.scissorOf(r, extent.width, extent.height)
                        else
                            null;
                        self.quad_pipeline.recordDrawRange(cmd, extent, main_world_offset, base + run.first, run.count, disp, .main, sc);
                    }
                }
                {
                    const base = layer.glyphs[0];
                    var it = element.clippedRuns(
                        dl.glyph_targets.items[base..layer.glyphs[1]],
                        clipSlice(dl.glyph_clips.items, base, layer.glyphs[1]),
                        element.MAIN_TARGET,
                    );
                    while (it.next()) |run| {
                        const sc: ?[4]u32 = if (dl.clipRect(run.clip)) |r|
                            element.scissorOf(r, extent.width, extent.height)
                        else
                            null;
                        self.text_pipeline.recordDrawRange(cmd, extent, main_world_offset, base + run.first, run.count, disp, .main, sc);
                    }
                }
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

    /// How many mouse buttons the dispatcher tracks. GLFW's
    /// `GLFW_MOUSE_BUTTON_LAST` is 7, so a `u8` mask covers every button
    /// the platform can report and there is nothing to grow into.
    pub const MAX_MOUSE_BUTTONS: u8 = 8;

    /// Which button asks the context question.
    ///
    /// **One, and it is the right button.** Verified rather than
    /// assumed, because the numbering is the host's and not spark's:
    /// this library's reference host builds its `POLLED_BUTTONS` array
    /// as `{GLFW_MOUSE_BUTTON_LEFT, _RIGHT, _MIDDLE}` and dispatches the
    /// array INDEX (`src/main.zig`, `processInput`), so index 1 is
    /// right and index 2 is middle. `:::nodegraph`'s `PAN_BUTTON = 2`
    /// is the middle button and agrees.
    ///
    /// matryoshka does not dispatch this button to spark at all yet —
    /// its `processInput` still sends only button 0, and its own note
    /// beside `.mouse_right` says so — so the host work for this beat
    /// starts by widening that, exactly the way the reference host
    /// already did.
    ///
    /// A named constant rather than a bare `1` at the site: the number
    /// is a fact about somebody else's array, and a bare 1 is a fact
    /// with nowhere to write down where it came from.
    pub const CONTEXT_BUTTON: u8 = 1;

    /// How long a gap still counts as part of the same click run. GLFW
    /// does not report double-clicks, so somebody has to count them;
    /// 400ms is where every toolkit's default lands. It was
    /// `:::textarea`'s private constant until the graph editor wanted
    /// double-click too — two components deriving this separately is two
    /// answers to "what is a double-click" on one screen.
    pub const MULTI_CLICK_MS: i64 = 400;

    /// How far the pointer may travel between clicks of a run, in world
    /// pixels. A double-click that drifted three pixels is still a
    /// double-click; one that moved across the widget is two clicks.
    pub const MULTI_CLICK_SLOP: f32 = 4;

    /// The multi-click run in progress.
    ///
    /// **Measured in world pixels and per button.** Pixels rather than
    /// byte offsets or hit identity because a person aiming a second
    /// click aims at the same spot on the screen — whatever has since
    /// moved under it. Per button because a left click followed by a
    /// right click in the same place is two different intents, and
    /// reporting the second as a double-click would open a context menu
    /// that thinks a word is selected.
    pub const ClickRun = struct {
        /// 1 = single, 2 = double, 3 = triple. Capped at 3.
        run: u8 = 1,
        last_ms: i64 = 0,
        last_x: f32 = 0,
        last_y: f32 = 0,
        /// Which button opened the previous click of the run. 0xFF is
        /// "no previous click" — a real button index would make the very
        /// first click of a session continue a run that never happened.
        last_button: u8 = 0xFF,
    };

    /// The run a press at `(x, y)` with `button` opens, given the run
    /// before it. Pure, so the three ways it can be wrong — too slow,
    /// too far, the other button — are gated without a clock or a
    /// window, which the wall-clock version inside `:::textarea` never
    /// could be.
    pub fn stepClickRun(prev: ClickRun, now_ms: i64, x: f32, y: f32, button: u8) ClickRun {
        const near = button == prev.last_button and
            (now_ms - prev.last_ms) < MULTI_CLICK_MS and
            @abs(x - prev.last_x) < MULTI_CLICK_SLOP and
            @abs(y - prev.last_y) < MULTI_CLICK_SLOP;
        return .{
            // Saturating at 3 rather than wrapping to 1: a fourth click
            // in place means "still that line", not "back to a caret".
            .run = if (!near) 1 else @min(prev.run + 1, 3),
            .last_ms = now_ms,
            .last_x = x,
            .last_y = y,
            .last_button = button,
        };
    }

    fn nowMs(self: *const Spark) i64 {
        return self.click_clock_ms orelse std.time.milliTimestamp();
    }

    /// Tell the dispatcher which modifier keys are held, as a raw GLFW
    /// bitmask (`GLFW_MOD_SHIFT | GLFW_MOD_CONTROL | …`). Every mouse,
    /// scroll and hover event built after this call carries it.
    ///
    /// **Ambient rather than a dispatch parameter, deliberately.** Mods
    /// belong on a move and on the wheel as much as on a click —
    /// Shift-drag constrains an axis, Ctrl+wheel zooms — and
    /// `dispatchMouseMove(x, y)` and `dispatchScroll(x, y, dy, dx)` are
    /// signatures matryoshka calls, so neither could grow a parameter
    /// without breaking the embed. A host that never calls this reports
    /// "nothing held", which is what every event said before this
    /// existed.
    ///
    /// Rejected names: `setModifiers` (which device?), `setMouseMods`
    /// (the wheel is not the mouse buttons), `setInputMods` (keyboard
    /// events carry their own on the event, and this is not those).
    pub fn setPointerMods(self: *Spark, mods: u32) void {
        self.pointer_mods = mods;
    }

    /// Build the `MouseEvent` for `hit`, stamped with the ambient
    /// modifier mask and the current click run. One place, so a channel
    /// added later cannot forget half of it — every hardcoded
    /// `.button = 0` this replaced was a field somebody forgot.
    fn mouseEventFor(self: *const Spark, hit: element.Hit, x: f32, y: f32, button: u8, down: bool) element.MouseEvent {
        return .{
            .local = .{ x - hit.box.x, y - hit.box.y },
            .button = button,
            .button_down = down,
            .mods = self.pointer_mods,
            .click_run = self.click.run,
        };
    }

    /// **Does anything need drawing again?** Read-and-clear. True when a
    /// dispatch since the last call actually changed a component's
    /// picture — a node dragged, a hover moving from one node to the
    /// next, a caret gained or lost, a wheel notch a `:::clip` took.
    ///
    /// This exists because a host has TWO questions and one flag, and
    /// answering both with `State.dirty` gets one of them wrong. "Has
    /// the document's layout changed?" is what `State.dirty` means. "Does
    /// anything need drawing again?" is this — and until it existed, the
    /// only input paths that answered it were the ones that happened to
    /// write state on their way past. A node dragged inside a canvas
    /// writes nothing until the button comes up, so the screen sat still
    /// for the whole gesture and the node teleported on release. Hover
    /// was broken the same way and nobody had noticed.
    ///
    /// **Only what CHANGED.** `dispatchHit` reads the target's
    /// `content_version` either side of the handler, so a pointer moving
    /// across empty canvas, or around inside the node it is already
    /// hovering, raises nothing at all. Dirtying on every move instead
    /// would make a moving mouse cost a document walk a frame, which is
    /// the cure being worse than the disease.
    ///
    /// **A flag, not a `bool` off each dispatcher.** `dispatchScroll`
    /// returns "someone took this" and the obvious symmetry is for
    /// `dispatchMouseMove` and `dispatchHover` to do the same. They
    /// cannot: matryoshka's host calls `dispatchMouseMove(x, y) catch {}`
    /// as a statement, and a `!bool` breaks that embed at the call site.
    /// One flag also covers the channels a bool per dispatcher would
    /// have missed — key, char, focus — for free.
    ///
    /// Rejected names: `dirty` (the collision with `State.dirty` IS the
    /// confusion this is here to end), `needsRedraw` (reads as a pure
    /// query, and this one clears), `invalidate` (Win32/Qt's word for a
    /// region, and there is no region here).
    pub fn takeRedrawRequest(self: *Spark) bool {
        defer self.redraw_requested = false;
        return self.redraw_requested;
    }

    /// Dispatch a mouse move. Position is in world coords (host
    /// un-transforms screen → world if it's applying a zoom/scroll).
    /// Routes to the captured Hit if a drag is in progress; otherwise
    /// does nothing. A pointer with no button held is `dispatchHover`,
    /// a separate channel — see `element.HoverEvent` for why.
    ///
    /// A move that moved something raises `redraw_requested` — see
    /// `takeRedrawRequest`, which is what a host polls instead of
    /// guessing that a held button means a redraw.
    pub fn dispatchMouseMove(self: *Spark, x: f32, y: f32) !void {
        self.mouse_x = x;
        self.mouse_y = y;
        if (self.mouse_down) {
            if (self.captured) |hit| {
                // The button is the one that took the capture, not 0.
                // A move during a middle-drag that claimed to be button 0
                // would defeat the very guards this beat turned on.
                try dispatchHit(self, hit, .{
                    .mouse_move = self.mouseEventFor(hit, x, y, self.capture_button, true),
                }, self.host_state);
            }
        }
    }

    /// Dispatch a pointer that is over the document with **no button
    /// held**. Sends `.enter` / `.move` / `.leave` to components that
    /// declared `on_hover`; components that did not are untouched.
    ///
    /// **Never while a button is held.** Pointer capture owns the
    /// pointer for the length of a gesture — that is what makes a slider
    /// dragged off its own box keep scrubbing — and a hover fired at a
    /// third component mid-drag would put two components in a "the
    /// pointer is mine" state at once. So a held button suppresses hover
    /// entirely, whether or not the press found a target, and the press
    /// itself leaves whatever was hovered.
    ///
    /// **Cost.** One `findHit` per call: a backwards linear scan of the
    /// hit layer, which holds only interactive elements, with a rect test
    /// each. That is the same scan `claimsPointer` already pays once a
    /// frame in matryoshka's host, so hover doubles a cost that was
    /// already noise. What is gated is the DISPATCH, not the scan: a
    /// `.move` only goes out when the pointer actually moved, so a
    /// stationary pointer over a live document costs the scan and
    /// nothing else. The scan is not skipped for a stationary pointer on
    /// purpose — the document can re-lay-out under a still cursor (a
    /// `:::fold` opening), and the enter/leave that follows is real.
    ///
    /// A hover that changed what a component draws raises
    /// `redraw_requested`; one that merely slid around inside the same
    /// node raises nothing. See `takeRedrawRequest`.
    pub fn dispatchHover(self: *Spark, x: f32, y: f32) !void {
        self.mouse_x = x;
        self.mouse_y = y;

        if (self.buttons_down != 0 or self.captured != null) {
            try self.leaveHover(x, y);
            return;
        }

        // `hitScope`, not the whole hit layer: while an overlay is open
        // the page under it must not light up as the pointer crosses it
        // on its way to a menu item. Hover is where that reads worst —
        // a button under an open menu glowing through it.
        const hits = self.hitScope();
        const target: ?element.Hit = blk: {
            const h = findHit(hits, x, y) orelse break :blk null;
            // Deepest-hit-only, no bubbling: see `on_hover`'s contract.
            break :blk if (h.vtable.on_hover != null) h else null;
        };

        if (self.hovered) |old| {
            const same = if (target) |t| t.ctx == old.ctx else false;
            if (same) {
                const t = target.?;
                // Refresh the box: the component may have moved or
                // resized under a still pointer, and a stale box makes
                // `local` drift further every relayout.
                self.hovered = t;
                if (x != self.hover_x or y != self.hover_y) {
                    try dispatchHoverHit(self, t, .move, x, y, self.pointer_mods, self.host_state);
                }
                self.hover_x = x;
                self.hover_y = y;
                return;
            }
            try self.leaveHover(x, y);
        }

        self.hover_x = x;
        self.hover_y = y;
        if (target) |t| {
            self.hovered = t;
            try dispatchHoverHit(self, t, .enter, x, y, self.pointer_mods, self.host_state);
        }
    }

    /// Send `.leave` to whoever holds the hover and forget them.
    ///
    /// `(x, y)` is where the pointer is NOW — outside the box being told
    /// about, which is the point: a component reads which edge it went
    /// out through. Not the last position it was inside at, which would
    /// be a leave event whose position says the pointer is still there.
    ///
    /// **Only if they are still in the hit layer.** `hovered` is a COPY
    /// of a Hit, so its `ctx` outlives the component when a `:::fold`
    /// shuts under the cursor and frees its children. `captured` and
    /// `focused` carry the same hazard and get away with it because they
    /// are only ever set by a press and cleared on release; a hover
    /// persists across every frame the pointer sits still, which is
    /// exactly the window in which a document re-lays out. A component
    /// that no longer exists cannot be left, so it is dropped silently.
    fn leaveHover(self: *Spark, x: f32, y: f32) !void {
        const old = self.hovered orelse return;
        self.hovered = null;
        for (self.drawlist.hits.items) |h| {
            if (h.ctx != old.ctx) continue;
            try dispatchHoverHit(self, old, .leave, x, y, self.pointer_mods, self.host_state);
            return;
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
    /// **Always true while an overlay is open**, wherever the pointer is.
    /// A click outside an open menu is spent dismissing it — spark
    /// consumes it and nothing under it ever sees it — so a host that
    /// answered "not mine" for the area outside the menu would hand that
    /// click to its 3D scene as well, and dismissing a menu would also
    /// re-pick the world behind it.
    ///
    /// Coordinates are world coords, the same ones `dispatchMouseMove` takes.
    pub fn claimsPointer(self: *const Spark, x: f32, y: f32) bool {
        if (self.overlay != null) return true;
        if (self.captured != null) return true;
        return findHit(self.drawlist.hits.items, x, y) != null;
    }

    /// The hits a pointer may reach right now.
    ///
    /// With no overlay open that is the whole hit layer, exactly as it
    /// always was. With one open it is the overlay's own range and
    /// nothing else — **the overlay takes input first**, and it does so
    /// by narrowing what can be hit rather than by being last in the
    /// array. Order would be the tempting mechanism and it is the wrong
    /// one: `layoutAndRenderOverlay` need not be the host's last layout
    /// call (see its note on where in the frame it goes), so a page hit
    /// emitted after the menu's would otherwise win the backwards scan
    /// and a click would go straight through the menu into it.
    ///
    /// The range can be stale for exactly one window — between a
    /// `beginFrame(.reset = true)` that cleared the drawlist and the
    /// `layoutAndRenderOverlay` that refills it — and an input dispatch
    /// in that window would index past the end. Clamped to empty rather
    /// than clamped to "everything": during that window the overlay has
    /// no hits, and answering with the page's would let a click through
    /// the very menu that is meant to be blocking it.
    fn hitScope(self: *const Spark) []const element.Hit {
        const hits = self.drawlist.hits.items;
        const ov = self.overlay orelse return hits;
        if (ov.hits[1] > hits.len or ov.hits[0] > ov.hits[1]) return &.{};
        return hits[ov.hits[0]..ov.hits[1]];
    }

    /// Offer a wheel notch to the components under `(x, y)`, innermost
    /// first. Returns true once one consumes it.
    ///
    /// **Bubbles rather than picking one.** `findHit` answers "which single
    /// element did the pointer land on", which is right for a click and wrong
    /// for the wheel: the pointer is very often over a button inside a
    /// scrolling region, and the button has no opinion about the wheel. So
    /// this walks the hit layer backwards — deepest first, since a container
    /// that declares `emits_own_hits` appends its own box BEFORE walking its
    /// children — and asks each in turn.
    ///
    /// A false from every one of them is the answer the HOST needs: nothing
    /// in the document wanted this notch, so the document itself should
    /// scroll. That is why there is a return value rather than this being
    /// fire-and-forget.
    pub fn dispatchScroll(self: *Spark, x: f32, y: f32, dy: f32, dx: f32) !bool {
        self.mouse_x = x;
        self.mouse_y = y;
        // Scoped to the overlay while one is open — a wheel notch over a
        // menu belongs to the menu (a long operator list scrolls), and a
        // notch outside it must not scroll the page out from under the
        // thing the menu is about.
        const hits = self.hitScope();
        var i = hits.len;
        while (i > 0) {
            i -= 1;
            const hit = hits[i];
            const on_scroll = hit.vtable.on_scroll orelse continue;
            if (x < hit.box.x or x >= hit.box.x + hit.box.w) continue;
            if (y < hit.box.y or y >= hit.box.y + hit.box.h) continue;
            const eff: *anyopaque = hit.state orelse @ptrCast(self.host_state);
            const before = versionOf(hit);
            if (try on_scroll(hit.ctx, .{
                .local = .{ x - hit.box.x, y - hit.box.y },
                .dx = dx,
                .dy = dy,
                .mods = self.pointer_mods,
            }, eff)) {
                // Taking the notch is not the same as having moved: a
                // `:::clip` already at its stop takes it and stays put.
                // The version says which, same as every other channel.
                noteRedraw(self, hit, before);
                return true;
            }
        }
        // Nobody in the menu wanted it — and it still does not fall
        // through. `false` here means "the host should scroll the page",
        // and a page scrolling under an open menu moves the very thing
        // the menu is about out from under it while leaving the menu
        // where it was.
        if (self.overlay != null) return true;
        return false;
    }

    /// Dispatch a **primary**-button transition. `down=true` on press,
    /// `down=false` on release. Manages pointer capture + focus.
    ///
    /// The shorthand, kept at this exact signature because matryoshka's
    /// HUD calls it — and asserts it exists, in `hud.zig`'s embed
    /// contract. `dispatchMouseButtonN` is the same thing with the
    /// button named; this is it with the button assumed, which is what
    /// every caller written before right and middle reached spark meant.
    pub fn dispatchMouseButton(self: *Spark, x: f32, y: f32, down: bool) !void {
        return self.dispatchMouseButtonN(x, y, down, 0);
    }

    /// Dispatch a transition of button **N**. 0 = left, 1 = right,
    /// 2 = middle; the mask is `MAX_MOUSE_BUTTONS` wide.
    ///
    /// Rejected names: `dispatchMouseButtonEx` (a Win32 tell that says
    /// nothing about what was added), `dispatchButton` (reads as
    /// `:::button`), `dispatchMousePress` (it dispatches the release
    /// too). The `N` is the parameter that is new, which is the whole
    /// difference from the three-argument form above.
    ///
    /// **Capture belongs to the button that opened it.** A press while
    /// something is already captured goes straight to the holder — no
    /// re-hit-test, no focus change — and a release only ends the
    /// capture if it is the button that took it. So a right-click during
    /// a left-drag reaches the component being dragged (which can cancel
    /// the gesture, the usual convention) instead of ending it, and
    /// releasing the right button afterwards does not drop the drag.
    ///
    /// **The click run advances on presses that open a gesture**, not on
    /// a second button pressed during one: a modifier-ish press is part
    /// of the gesture, not a click of its own.
    pub fn dispatchMouseButtonN(self: *Spark, x: f32, y: f32, down: bool, button: u8) !void {
        self.mouse_x = x;
        self.mouse_y = y;
        // Loud, not a guess: a button index off the end of the mask
        // would silently alias onto button 0 and a side button would
        // start clicking things.
        if (button >= MAX_MOUSE_BUTTONS) return error.UnknownMouseButton;
        const bit: u8 = @as(u8, 1) << @intCast(button);

        const was_down = (self.buttons_down & bit) != 0;
        if (down == was_down) return; // not a transition; nothing to do
        if (down) self.buttons_down |= bit else self.buttons_down &= ~bit;
        self.mouse_down = self.buttons_down != 0;

        // ── The overlay takes the press first ───────────────────────
        //
        // **A dismissing click is SWALLOWED, not delivered.** Every
        // menu on this machine swallows it — Win32's, NSMenu, GTK and
        // Qt all grab the pointer for the life of the menu, and Bitwig,
        // Blender and Photoshop all behave that way because of it. The
        // web's ad-hoc menus are the odd one out, and they are the ones
        // that feel wrong.
        //
        // The argument, though, is not precedent. The user's intent in
        // a dismissing click is "not this menu"; it is not "not this
        // menu, AND do whatever is at the point I happened to aim at".
        // Delivering it makes one click both close a menu and delete
        // the node under the cursor — an irreversible action nobody
        // chose. The cost of swallowing is one extra click to reach the
        // thing underneath, which is the cheaper of the two errors by a
        // wide margin.
        //
        // **Only a PRESS dismisses.** A right-click that opens a menu
        // is followed by its own release before any frame has drawn, so
        // the overlay's box is still zero at that moment; a release that
        // dismissed would close every menu in the gesture that opened
        // it. Releases outside are swallowed and do nothing.
        if (self.overlay) |ov| {
            if (!ov.contains(x, y)) {
                if (down) self.closeOverlay();
                return;
            }
        }

        if (down) {
            if (self.captured) |hit| {
                try dispatchHit(self, hit, .{
                    .mouse_down = self.mouseEventFor(hit, x, y, button, true),
                }, self.host_state);
                return;
            }
            // The pointer is about to belong to a gesture, so it stops
            // belonging to a hover. Before the hit test, so a component
            // that is both hovered and pressed sees `.leave` then
            // `mouse_down` rather than the two interleaved.
            try self.leaveHover(x, y);

            self.click = stepClickRun(self.click, self.nowMs(), x, y, button);

            const maybe_hit = findHit(self.hitScope(), x, y);
            // Focus management.
            const new_focus_ctx: ?*anyopaque = blk: {
                if (maybe_hit) |h| if (h.focusable) break :blk h.ctx;
                break :blk null;
            };
            const old_focus_ctx: ?*anyopaque = if (self.focused) |f| f.ctx else null;
            if (new_focus_ctx != old_focus_ctx) {
                if (self.focused) |old| dispatchHit(self, old, .focus_lost, self.host_state) catch {};
                self.focused = if (maybe_hit) |h| if (h.focusable) h else null else null;
                if (self.focused) |new| dispatchHit(self, new, .focus_gained, self.host_state) catch {};
            }
            if (maybe_hit) |hit| {
                self.captured = hit;
                self.capture_button = button;
                try dispatchHit(self, hit, .{
                    .mouse_down = self.mouseEventFor(hit, x, y, button, true),
                }, self.host_state);
            }

            // ── The context question ────────────────────────────────
            //
            // LAST in the press path, and deliberately so. `State.set`
            // notifies its subscribers SYNCHRONOUSLY (see spark's
            // CLAUDE.md), so the host's answer to this record — very
            // likely an `openOverlay`, which clears the capture and the
            // focus — re-enters this dispatcher mid-call. Emitting
            // before the press dispatch would mean the component under
            // the cursor received its `mouse_down` after the world had
            // already changed under it. Emitting here means the press is
            // fully settled and there is nothing left for the re-entry
            // to corrupt.
            //
            // The press ALSO went to the component, unchanged: a right
            // press is still an event a component may act on, and
            // `:::nodegraph` reads `mev.button` today. The context
            // record is in addition to that, not instead of it.
            //
            // And note where this is NOT reached: a right press while
            // something already holds the capture returns at the top of
            // this branch, so a right-click during a left-drag asks no
            // context question. That is right — the gesture owns the
            // pointer, and the convention for that press is "cancel the
            // drag", not "and also open a menu".
            if (button == CONTEXT_BUTTON) try self.emitContext(x, y);
        } else {
            if (self.captured) |hit| {
                try dispatchHit(self, hit, .{
                    .mouse_up = self.mouseEventFor(hit, x, y, button, false),
                }, self.host_state);
                if (button == self.capture_button) self.captured = null;
            }
            // The hand let go: whatever is under the pointer is hovered
            // again, now, rather than on whichever later frame the mouse
            // happens to twitch. Releasing a slider and having its thumb
            // stay unlit until you jiggle looks like a dropped event.
            // `hovered` is null here in every path — the press that
            // opened this gesture left it — so this is an `.enter`, not
            // a `.move` that a stale position could suppress.
            if (self.buttons_down == 0) try self.dispatchHover(x, y);
        }
    }

    /// What claims the point `(x, y)`, in whatever words the document or
    /// the component chose — or null when nobody claims it.
    ///
    /// Public because the ANSWER, not just the record, is something a
    /// host router wants: matryoshka's `PointerRouter` has to decide
    /// whether a right-click belongs to the document or to the 3D scene
    /// behind it, and "no element claims this point" is the whole of
    /// that decision. Asking costs one backwards scan of the hit layer,
    /// the same one `claimsPointer` already pays.
    ///
    /// **Innermost-out, first answer wins.** Backwards through the hit
    /// layer, which is deepest-first — the same order `dispatchScroll`
    /// bubbles in and for the same reason: the pointer is very often
    /// over something small inside something large, and the small thing
    /// is the more specific answer.
    ///
    /// **Within one hit, the vtable hook is asked before the author's
    /// attribute.** The hook varies with the point and the attribute is
    /// a constant, so the hook is the more specific of the two; and a
    /// hook that DECLINES falls through to the attribute, which is what
    /// makes `:::nodegraph {context="canvas"}` work exactly as an author
    /// would guess — nodes and pins name themselves, the empty ground
    /// between them takes the attribute.
    pub fn contextSubjectAt(self: *const Spark, x: f32, y: f32) ?[]const u8 {
        const claim = self.contextClaimAt(x, y) orelse return null;
        return claim.subject;
    }

    /// The subject AND the state to report it in. Private because the
    /// state pointer is a routing detail; `contextSubjectAt` is the
    /// question a host asks.
    const ContextClaim = struct { subject: []const u8, state: ?*anyopaque };

    fn contextClaimAt(self: *const Spark, x: f32, y: f32) ?ContextClaim {
        const hits = self.hitScope();
        var i = hits.len;
        while (i > 0) {
            i -= 1;
            const h = hits[i];
            if (x < h.box.x or x >= h.box.x + h.box.w) continue;
            if (y < h.box.y or y >= h.box.y + h.box.h) continue;
            if (h.vtable.context_subject) |ask| {
                if (ask(h.ctx, .{ x - h.box.x, y - h.box.y })) |s| {
                    if (s.len > 0) return .{ .subject = s, .state = h.state };
                }
            }
            if (h.context_subject) |s| {
                if (s.len > 0) return .{ .subject = s, .state = h.state };
            }
        }
        return null;
    }

    /// Write the context record for a right-press at `(x, y)`, if
    /// anything claims the point and the host named a path.
    ///
    /// The grammar, one line, same `kind key=value …` shape as every
    /// other line-oriented payload in this library:
    ///
    ///     context subject=node:near1 x=412.0 y=233.5 shift=0 ctrl=0 alt=0
    ///
    /// `x`/`y` are the WORLD coordinates of the press — the same frame
    /// `openOverlay` takes, so a host passes them straight back with no
    /// conversion of its own. One decimal place, which is finer than a
    /// pointer can aim and coarse enough to read.
    ///
    /// `shift`/`ctrl`/`alt` come from the ambient `pointer_mods` mask.
    /// Super is deliberately absent: three is what a menu ever branches
    /// on, and a fourth field in every record for a modifier no host has
    /// asked for is a field every parser has to skip forever. Recorded,
    /// not built — the trigger is the first host that wants Cmd.
    ///
    /// **Routed to the claiming element's State**, falling back to the
    /// host's root — the same rule `dispatchHit` uses for input, so a
    /// host running one document per panel does not have to learn a
    /// second one. Nothing is emitted for an unclaimed point, so there
    /// is never an ambiguous "which state was that for".
    fn emitContext(self: *Spark, x: f32, y: f32) !void {
        const path = self.context_path orelse return;
        const claim = self.contextClaimAt(x, y) orelse return;

        // Loud, never a guess. The record is whitespace-delimited, so a
        // subject with a space in it does not produce a broken record —
        // it produces a VALID record that means something else, and the
        // host reads `subject=node` and never learns there was more. A
        // quoted form would be the other answer and it is the wrong one
        // here: it would make every host's parser handle quoting to
        // support a subject nobody should be writing.
        //
        // The REFUSAL is the returned error; the log line is the
        // diagnostic that names the offender, and it is `warn` rather
        // than `err` for one reason worth writing down: Zig's test
        // runner counts any `std.log.err` during a test as a failure, so
        // an `err` here would make the gate that proves this refusal
        // fires impossible to write. An untestable refusal is worse than
        // a diagnostic one level quieter — the error still propagates
        // out of `dispatchMouseButtonN`, and no record is written.
        for (claim.subject) |c| {
            if (c <= ' ' or c == '"' or c == 0x7f) {
                std.log.warn(
                    "spark: refusing a context subject that is not one word: \"{s}\" " ++
                        "(no spaces, tabs, newlines, quotes or control bytes — see " ++
                        "ElementVTable.context_subject)",
                    .{claim.subject},
                );
                return error.ContextSubjectNotOneWord;
            }
        }

        const mods = self.pointer_mods;
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try buf.writer().print(
            "context subject={s} x={d:.1} y={d:.1} shift={d} ctrl={d} alt={d}",
            .{
                claim.subject,
                x,
                y,
                @intFromBool(mods & MOD_SHIFT != 0),
                @intFromBool(mods & MOD_CONTROL != 0),
                @intFromBool(mods & MOD_ALT != 0),
            },
        );

        const target: *state_mod.State = if (claim.state) |s|
            @ptrCast(@alignCast(s))
        else
            self.host_state;
        try target.set(path, buf.items);
    }

    /// Dispatch a keyboard event to the focused hit (no-op when no
    /// focus). Host translates platform keysym → element.KeyEvent
    /// (raw GLFW keycode + mods).
    ///
    /// **Escape closes an open overlay and goes no further.** It is the
    /// one key the dispatcher itself has an opinion about, and the
    /// opinion is universal — every menu everywhere closes on Esc — so
    /// making each host wire it would be making each host reimplement
    /// the same three lines and one of them forget. The key is consumed
    /// rather than also delivered, for the same reason a dismissing
    /// click is: the press meant "not this menu", not "not this menu AND
    /// clear the caret in the field behind it".
    pub fn dispatchKey(self: *Spark, ev: element.KeyEvent) !void {
        if (self.overlay != null and ev.key == KEY_ESCAPE) {
            self.closeOverlay();
            self.redraw_requested = true;
            // Belt-and-braces: `closeOverlay` has already cleared the
            // focus, so there is nobody below to deliver to today. The
            // `return` states the contract — the key is CONSUMED —
            // rather than leaving it to be re-derived from that
            // coupling every time someone reads this.
            return;
        }
        if (self.focused) |hit| {
            try dispatchHit(self, hit, .{ .key_down = ev }, self.host_state);
        }
    }

    /// Dispatch a Unicode codepoint to the focused hit (text input
    /// path). No-op when no focus.
    pub fn dispatchChar(self: *Spark, codepoint: u32) !void {
        if (self.focused) |hit| {
            try dispatchHit(self, hit, .{ .char_input = codepoint }, self.host_state);
        }
    }

    /// Clear keyboard focus and fire `focus_lost` on the previous
    /// holder. Use this from an Esc handler or when the host wants
    /// to take focus back (e.g. on click-outside the doc surface).
    pub fn clearFocus(self: *Spark) void {
        if (self.focused) |old| {
            dispatchHit(self, old, .focus_lost, self.host_state) catch {};
            self.focused = null;
        }
    }

    /// Apply an LM-style update directive (the `:::update` wire
    /// format) to the Spark's root State. Re-parses, dispatches
    /// against the registry, returns the number of directives
    /// applied.
    pub fn applyUpdate(self: *Spark, source: []const u8) !usize {
        return self.applyUpdateTo(self.host_state, source);
    }

    /// `applyUpdate`, against a state the caller names.
    ///
    /// A host drawing several Documents in one Spark gives each its
    /// own State — otherwise two panels that both bind `warm` are one
    /// value, the same collision `LoadOpts.scope` fixes for component
    /// instances. `Spark.layoutAndRender` already prefers
    /// `doc.state`, and the walker already stamps it onto every Hit,
    /// so a panel's slider reads and writes its own state on the
    /// input path. This is the ingress side of that: a stream update
    /// aimed at one panel must land in that panel's State rather than
    /// in whichever State the Spark happens to hold as root.
    ///
    /// Pass `doc.state orelse spark.host_state` — the same fallback
    /// layout uses.
    pub fn applyUpdateTo(self: *Spark, state: *state_mod.State, source: []const u8) !usize {
        const update_mod = @import("update.zig");
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        return update_mod.applyAll(arena.allocator(), state, self.registry, source);
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
            .paint_layers = undefined,
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

    // Effects-spec Phase C.2 — the two blur shaders, one axis of a separable
    // Gaussian each. Compiled into the single_source cache because a chain
    // step has exactly the single_source pipeline shape (one
    // combined-image-sampler, one push-constant range, a fullscreen
    // triangle); what makes it a chain step is where its source and
    // destination come from, not how it binds. Standing up a parallel
    // ChainPipelineCache would be two caches with the same contents.
    //
    // `_alpha` is `:::drop_shadow`'s, `_rgba` is `:::frosted_glass`'s. They
    // share `shaders/gaussian.glsl` and differ only in what they do with the
    // blurred value — a coverage times a tint, versus a colour under a wash.
    try resolver.register("gaussian_alpha.frag", &shaders.gaussian_alpha_frag);
    try single_source.compile(pass_mod.shaderIdFromName("gaussian_alpha.frag"), &shaders.gaussian_alpha_frag);
    try resolver.register("gaussian_rgba.frag", &shaders.gaussian_rgba_frag);
    try single_source.compile(pass_mod.shaderIdFromName("gaussian_rgba.frag"), &shaders.gaussian_rgba_frag);

    // The panels campaign's Northstar — `:::gbuffer`, a window onto an
    // image the HOST owns. Same pipeline shape as every other
    // single_source filter (one combined-image-sampler, one push range,
    // a fullscreen triangle); what makes it different is only where the
    // sampler's image comes from, which is a record-time question and
    // not a pipeline one.
    try resolver.register("gbuffer.frag", &shaders.gbuffer_frag);
    try single_source.compile(pass_mod.shaderIdFromName("gbuffer.frag"), &shaders.gbuffer_frag);
}

/// What a component says about its own picture right now, or `null` if
/// it keeps no counter at all. The two calls either side of a handler
/// are what `noteRedraw` compares.
fn versionOf(hit: element.Hit) ?u64 {
    const get = hit.vtable.content_version orelse return null;
    return get(hit.ctx);
}

/// Raise `redraw_requested` iff the handler that just ran changed the
/// component's picture. `before` is `versionOf(hit)` read before it ran.
///
/// **A component that cannot say is believed.** No `content_version`
/// means both reads are null, and this counts that as changed. The other
/// way round — assume unchanged — is a component that silently never
/// redraws, which is the exact bug this whole seam exists to kill, one
/// level further in and much harder to see.
fn noteRedraw(sp: *Spark, hit: element.Hit, before: ?u64) void {
    const after = versionOf(hit);
    if (before == null or after == null or before.? != after.?) {
        sp.redraw_requested = true;
    }
}

fn dispatchHit(sp: *Spark, hit: element.Hit, event: element.InputEvent, default_state: *state_mod.State) !void {
    const on_input = hit.vtable.on_input orelse return;
    // Embedded-doc walks stamp the child state pointer onto the Hit;
    // top-level walks leave it null → fall back to the dispatcher's
    // default (the host's root State).
    const eff: *anyopaque = hit.state orelse @ptrCast(default_state);
    // `defer`, not a line after the call: a handler that mutates and
    // THEN fails has still changed the picture, and a frame that never
    // runs is how the failure would have been hidden.
    const before = versionOf(hit);
    defer noteRedraw(sp, hit, before);
    try on_input(hit.ctx, event, eff);
}

/// Deliver one hover phase to a Hit. Same state-routing rule as
/// `dispatchHit` — an embedded document's components get that doc's
/// state, not the host's root — and the same redraw bookkeeping.
fn dispatchHoverHit(
    sp: *Spark,
    hit: element.Hit,
    phase: element.HoverPhase,
    x: f32,
    y: f32,
    mods: u32,
    default_state: *state_mod.State,
) !void {
    const on_hover = hit.vtable.on_hover orelse return;
    const eff: *anyopaque = hit.state orelse @ptrCast(default_state);
    const before = versionOf(hit);
    defer noteRedraw(sp, hit, before);
    try on_hover(hit.ctx, .{
        .local = .{ x - hit.box.x, y - hit.box.y },
        .phase = phase,
        .mods = mods,
    }, eff);
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

// ── `orderBackgrounds` — Phase 2's pre-pass order ───────────────────
//
// The rule these gate is not "the list changed": it is that a parent
// background composites BEFORE the background nested in it, and that
// nothing else about the author's order moves. Each test poisons in the
// obvious wrong direction — the identity order, or the key with its
// tiebreak flipped — and fails.

fn orderOf(spans: []BackgroundSpan) [8]u32 {
    orderBackgrounds(spans);
    var out: [8]u32 = @splat(0xFFFF_FFFF);
    for (spans, 0..) |s, i| out[i] = s.index;
    return out;
}

test "orderBackgrounds: a nested background composites AFTER the one containing it" {
    // The bug this function exists for, in its smallest form. A
    // `:::gbuffer` (no subtree of its own, so `[0,0)`, sitting at
    // dispatch 0) inside a `:::frosted_glass {backdrop}` whose subtree
    // is `[0,1)` and which therefore sits at dispatch 1.
    //
    // Post-order hands them over as [gbuffer, frosted]. Composited in
    // that order the chrome lands on top and the panel is GONE, which
    // is exactly what `nested-pass-chrome.md` captured.
    var spans = [_]BackgroundSpan{
        .{ .index = 0, .subtree_start = 0 }, // the gbuffer
        .{ .index = 1, .subtree_start = 0 }, // the frosted glass around it
    };
    const got = orderOf(&spans);
    try testing.expectEqual(@as(u32, 1), got[0]); // chrome first — underneath
    try testing.expectEqual(@as(u32, 0), got[1]); // then its child, on top
}

test "orderBackgrounds: sibling backdrops keep the order the author wrote them" {
    // Rule 1 — the fix must not have bought the nesting order by
    // throwing away document order, which is what decides which of two
    // OVERLAPPING panels is on top. Two disjoint backdrops, each with a
    // nested pass of its own.
    //
    //   dispatch: 0 gbufA, 1 panelA, 2 gbufB, 3 panelB
    var spans = [_]BackgroundSpan{
        .{ .index = 0, .subtree_start = 0 },
        .{ .index = 1, .subtree_start = 0 },
        .{ .index = 2, .subtree_start = 2 },
        .{ .index = 3, .subtree_start = 2 },
    };
    const got = orderOf(&spans);
    // A under its own child, then B under its own child — and B's panel
    // still lands over A's child, because B was written second.
    try testing.expectEqualSlices(u32, &.{ 1, 0, 3, 2 }, got[0..4]);
}

test "orderBackgrounds: three deep, outermost first" {
    // Containment is a tree, not a pair, and the key has to be a real
    // pre-order rather than a swap that happens to fix depth 2. A
    // backdrop holding a backdrop holding a gbuffer:
    //
    //   dispatch: 0 gbuf, 1 inner, 2 outer
    var spans = [_]BackgroundSpan{
        .{ .index = 0, .subtree_start = 0 },
        .{ .index = 1, .subtree_start = 0 },
        .{ .index = 2, .subtree_start = 0 },
    };
    const got = orderOf(&spans);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, got[0..3]);
}

test "orderBackgrounds: a later sibling's start beats an earlier parent's tie-break" {
    // The two halves of the key doing different jobs, so a single-key
    // sort cannot pass. `subtree_start` separates siblings; `index`
    // descending separates a parent from a child that starts where it
    // does. Flip the tiebreak to ascending and the first pair inverts;
    // drop the start comparison and the last entry moves to the front.
    var spans = [_]BackgroundSpan{
        .{ .index = 0, .subtree_start = 0 }, // child of 1
        .{ .index = 1, .subtree_start = 0 }, // parent
        .{ .index = 9, .subtree_start = 5 }, // a later, disjoint sibling
    };
    const got = orderOf(&spans);
    try testing.expectEqualSlices(u32, &.{ 1, 0, 9 }, got[0..3]);
}

test "orderBackgrounds: an already-correct list is left alone" {
    // A single background, and two disjoint ones, must come out in
    // dispatch order — the overwhelmingly common case, and the one a
    // clever reordering would be most likely to disturb.
    var one = [_]BackgroundSpan{.{ .index = 4, .subtree_start = 2 }};
    try testing.expectEqual(@as(u32, 4), orderOf(&one)[0]);

    var two = [_]BackgroundSpan{
        .{ .index = 1, .subtree_start = 0 },
        .{ .index = 3, .subtree_start = 2 },
    };
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, orderOf(&two)[0..2]);
}

/// A `.chain` dispatch carrying nothing but the subtree range these
/// tests are about. Every other field is inert here.
fn chainAt(subtree: [2]u32, seq: u32) element.PassDispatch {
    return .{ .chain = .{
        .target_size = .{ 1, 1 },
        .target_format = 0,
        .target_pool_count = 1,
        .steps = &.{},
        .compose_region = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .final_pool_local = 0,
        .subtree_dispatch_range = subtree,
        .final_composite_shader_id = [_]u8{0} ** 16,
        .sequence_index = seq,
    } };
}

test "markSubtreeOwned: a nested pass belongs to its parent, not to the top level" {
    // The walker emits POST-ORDER, so a nested dispatch always sits at a
    // LOWER index than the parent that owns it. Phase 1's top-level loop
    // therefore reached index 0 first and processed it, and then the
    // parent at index 1 recursed into index 0 and processed it again:
    // two pool acquisitions and two sets of recorded commands per frame,
    // for every effect nested inside another.
    //
    // `:::drop_shadow` wrapping `:::frosted_glass {backdrop}` — the
    // shape Chris hit — is exactly this list.
    var out: [2]bool = undefined;
    const nested = [_]element.PassDispatch{
        chainAt(.{ 0, 0 }, 0), // the inner glass: no subtree of its own
        chainAt(.{ 0, 1 }, 1), // the shadow: owns index 0
    };
    markSubtreeOwned(&nested, &out);
    try testing.expectEqualSlices(bool, &.{ true, false }, &out);
}

test "markSubtreeOwned: two effects side by side are both top-level" {
    // Siblings own nothing of each other, so neither is skipped. This is
    // the case a too-eager skip would break — and it would break it
    // SILENTLY, by not drawing an effect at all.
    var out: [2]bool = undefined;
    const siblings = [_]element.PassDispatch{
        chainAt(.{ 0, 0 }, 0),
        chainAt(.{ 1, 1 }, 1),
    };
    markSubtreeOwned(&siblings, &out);
    try testing.expectEqualSlices(bool, &.{ false, false }, &out);
}

test "markSubtreeOwned: three deep, and only the outermost is top-level" {
    // Ownership is not just parent-to-child: the outermost effect's range
    // covers the whole nest, so a middle effect is marked by BOTH its
    // parent and its grandparent. Marking is idempotent, which is why the
    // rule can be a plain sweep rather than a tree walk.
    var out: [3]bool = undefined;
    const deep = [_]element.PassDispatch{
        chainAt(.{ 0, 0 }, 0),
        chainAt(.{ 0, 1 }, 1),
        chainAt(.{ 0, 2 }, 2),
    };
    markSubtreeOwned(&deep, &out);
    try testing.expectEqualSlices(bool, &.{ true, true, false }, &out);
}

test "markSubtreeOwned: a pattern owns nothing and can still be owned" {
    // `.pattern` and `.host_slot` have no subtree, so they never mark
    // anyone — but they sit inside other effects' ranges all the time and
    // must be marked when they do. Phase 1's top-level loop skips
    // patterns anyway; this pins that the bitmap agrees with it rather
    // than relying on two places to stay in step.
    var out: [2]bool = undefined;
    const with_pattern = [_]element.PassDispatch{
        .{ .pattern = .{
            .shader_id = [_]u8{0} ** 16,
            .layout_region = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .sequence_index = 0,
        } },
        chainAt(.{ 0, 1 }, 1),
    };
    markSubtreeOwned(&with_pattern, &out);
    try testing.expectEqualSlices(bool, &.{ true, false }, &out);
}

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

// ── Input dispatch: the button, the mods, the run, and hover ────────
//
// Three holes a `:::graph` span would have had to work around, plus a
// multi-click derivation that was about to be copied out of
// `:::textarea` into the second component that wanted a double-click.
//
// Every gate below names the mutation it was paid for, and each of those
// mutations was executed and watched go red — a gate over a dispatcher
// is very easy to write so that it passes against the old behaviour too,
// because the old behaviour was "deliver something plausible".

/// Records what a component was actually handed. Doubles as the `state`
/// pointer on its own Hit so the gates never reach `host_state`.
const InputProbe = struct {
    const Kind = enum { down, up, move };
    const Rec = struct { kind: Kind, ev: element.MouseEvent };

    recs: [32]Rec = undefined,
    n: usize = 0,
    hovers: [32]element.HoverEvent = undefined,
    hn: usize = 0,
    /// Where this probe writes, when a gate needs two DISTINCT
    /// components (hover identity is by `ctx`, so one probe behind two
    /// Hits is one component) whose events are nevertheless interleaved
    /// in one list. Ordering is the assertion in those gates and two
    /// separate lists cannot express it.
    sink: ?*InputProbe = null,

    /// What every shipped component keeps: a counter that moves when
    /// this component's picture does. Only `probe_versioned` publishes
    /// it — the other two vtables leave `content_version` null, which is
    /// itself a case the redraw gates need.
    version: u64 = 0,
    /// Does an event actually change this probe's picture? The redraw
    /// gates need both answers from the same code: a component that
    /// moved, and one that was merely touched and has nothing new to
    /// draw. A real component decides this per event; a probe is told.
    moves: bool = true,

    /// What this probe answers the context question with, and where.
    /// `subject_zone`, when set, is a rect in the probe's own LOCAL
    /// coordinates: inside it the probe answers, outside it declines.
    /// That is what a component with interior structure does — a node
    /// here, a pin there, nothing on the empty canvas — and declining is
    /// the case that lets the author's `context=` attribute through.
    subject: ?[]const u8 = null,
    subject_zone: ?element.Box = null,

    /// Keys delivered to this probe. A count, because the question the
    /// Escape gate asks is "did this key reach the component at all" and
    /// the version counter cannot answer it — `focus_lost` bumps that
    /// too, and closing an overlay clears the focus.
    keys: [8]element.KeyEvent = undefined,
    kn: usize = 0,

    fn bump(self: *InputProbe) void {
        if (self.moves) self.version +%= 1;
    }

    fn contextSubject(ctx: *anyopaque, local: [2]f32) ?[]const u8 {
        const self: *const InputProbe = @ptrCast(@alignCast(ctx));
        const s = self.subject orelse return null;
        const z = self.subject_zone orelse return s;
        if (local[0] < z.x or local[0] >= z.x + z.w) return null;
        if (local[1] < z.y or local[1] >= z.y + z.h) return null;
        return s;
    }

    fn contentVersion(ctx: *anyopaque) u64 {
        const self: *const InputProbe = @ptrCast(@alignCast(ctx));
        return self.version;
    }

    fn layoutAndRender(
        _: *anyopaque,
        _: [2]f32,
        _: element.Constraints,
        _: *element.LayoutCtx,
        _: *element.DrawList,
    ) anyerror!element.Box {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    fn onInput(ctx: *anyopaque, event: element.InputEvent, _: *anyopaque) anyerror!void {
        const self: *InputProbe = @ptrCast(@alignCast(ctx));
        // On `self`, never on the sink: `content_version` is read
        // through this Hit's own `ctx`, and a probe that bumped its
        // neighbour's counter would report the wrong component redrawn.
        self.bump();
        const p = self.sink orelse self;
        const rec: Rec = switch (event) {
            .mouse_down => |m| .{ .kind = .down, .ev = m },
            .mouse_up => |m| .{ .kind = .up, .ev = m },
            .mouse_move => |m| .{ .kind = .move, .ev = m },
            .key_down => |k| {
                if (p.kn < p.keys.len) {
                    p.keys[p.kn] = k;
                    p.kn += 1;
                }
                return;
            },
            else => return,
        };
        if (p.n >= p.recs.len) return;
        p.recs[p.n] = rec;
        p.n += 1;
    }

    fn onHover(ctx: *anyopaque, event: element.HoverEvent, _: *anyopaque) anyerror!void {
        const self: *InputProbe = @ptrCast(@alignCast(ctx));
        self.bump();
        const p = self.sink orelse self;
        if (p.hn >= p.hovers.len) return;
        p.hovers[p.hn] = event;
        p.hn += 1;
    }

    /// The hover phases seen, as a slice that `expectEqualSlices` can
    /// print — an assertion on a count alone passes for enter/enter.
    fn phases(p: *const InputProbe, buf: []element.HoverPhase) []const element.HoverPhase {
        for (p.hovers[0..p.hn], 0..) |h, i| buf[i] = h.phase;
        return buf[0..p.hn];
    }
};

const probe_input_only = element.ElementVTable{
    .layout_and_render = InputProbe.layoutAndRender,
    .on_input = InputProbe.onInput,
};
const probe_hover_too = element.ElementVTable{
    .layout_and_render = InputProbe.layoutAndRender,
    .on_input = InputProbe.onInput,
    .on_hover = InputProbe.onHover,
};
/// The same probe, publishing a `content_version` the way every shipped
/// component does. The redraw gates want this one; the two above stay
/// version-less because "a component that cannot say" is its own case.
const probe_versioned = element.ElementVTable{
    .layout_and_render = InputProbe.layoutAndRender,
    .on_input = InputProbe.onInput,
    .on_hover = InputProbe.onHover,
    .content_version = InputProbe.contentVersion,
};
/// Versioned, and deaf to the pointer: no `on_hover` at all. A hover
/// over one of these must cost nothing, which is most of the document.
const probe_versioned_no_hover = element.ElementVTable{
    .layout_and_render = InputProbe.layoutAndRender,
    .on_input = InputProbe.onInput,
    .content_version = InputProbe.contentVersion,
};
/// Takes input AND answers the context question — the shape
/// `:::nodegraph` will have.
const probe_context = element.ElementVTable{
    .layout_and_render = InputProbe.layoutAndRender,
    .on_input = InputProbe.onInput,
    .context_subject = InputProbe.contextSubject,
};
/// Answers the context question and NOTHING else: no input, no wheel,
/// no hover. This is the component that only exists on the hit layer
/// because `wantsHitBox` counts the fourth channel, and the gate below
/// that names that mutation is the only thing keeping it there.
const probe_context_only = element.ElementVTable{
    .layout_and_render = InputProbe.layoutAndRender,
    .context_subject = InputProbe.contextSubject,
};

fn probeHit(p: *InputProbe, vt: *const element.ElementVTable, x: f32, y: f32, w: f32, h: f32) element.Hit {
    return .{
        .box = .{ .x = x, .y = y, .w = w, .h = h },
        .vtable = vt,
        .ctx = @ptrCast(p),
        .state = @ptrCast(p), // never dereferenced; keeps `host_state` out of it
    };
}

/// `probeHit` with the state pointer left NULL — "use the dispatcher's
/// default", which is the host's root State.
///
/// The input gates put the probe itself in that slot precisely because
/// it is never dereferenced there. A context gate needs the opposite: a
/// context record IS written through that pointer, so a probe sitting in
/// it is a `*State` that is not a State, and the write lands in the
/// middle of the probe. That is not a hypothetical — it is what the
/// first run of these gates did, and it aborted rather than failing,
/// which is the honest outcome for a bad cast.
fn contextProbeHit(p: *InputProbe, vt: *const element.ElementVTable, x: f32, y: f32, w: f32, h: f32) element.Hit {
    var hit = probeHit(p, vt, x, y, w, h);
    hit.state = null;
    return hit;
}

test "dispatch: the event carries the button that was actually pressed" {
    // The hole: `dispatchMouseButton` hardcoded `.button = 0` on every
    // event it built, so `if (m.button != 0) return` — which eight
    // components in this library write, some of them with a "primary
    // only" comment beside it — could not fire. Dead code that reads
    // like a decision.
    //
    // Mutation: put `.button = 0` back in `mouseEventFor`. Red on the
    // first expectEqual (1 != 0), and red again on the release.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_input_only, 0, 0, 100, 50));

    try sp.dispatchMouseButtonN(10, 10, true, 1); // right
    try sp.dispatchMouseButtonN(10, 10, false, 1);
    try testing.expectEqual(@as(usize, 2), p.n);
    try testing.expectEqual(@as(u8, 1), p.recs[0].ev.button);
    try testing.expectEqual(@as(u8, 1), p.recs[1].ev.button);

    // And the three-argument form still means the primary button, which
    // is what every call site written before this beat meant by it —
    // matryoshka's `hud_bridge` among them.
    p.n = 0;
    try sp.dispatchMouseButton(10, 10, true);
    try testing.expectEqual(@as(u8, 0), p.recs[0].ev.button);
}

test "dispatch: a drag reports the button that took the capture, not 0" {
    // `dispatchMouseMove` hardcoded `.button = 0` too, and a move is
    // where a drag actually happens. A middle-drag that claimed to be
    // button 0 would defeat the very guards this beat turned on —
    // `:::slider` reads `m.button` on the move for exactly this reason.
    //
    // Mutation: `.button = 0` in the `dispatchMouseMove` call to
    // `mouseEventFor`. The move's button is 0, red.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_input_only, 0, 0, 100, 50));

    try sp.dispatchMouseButtonN(10, 10, true, 2); // middle
    try sp.dispatchMouseMove(20, 10);
    try testing.expectEqual(@as(usize, 2), p.n);
    try testing.expectEqual(InputProbe.Kind.move, p.recs[1].kind);
    try testing.expectEqual(@as(u8, 2), p.recs[1].ev.button);
    try testing.expect(p.recs[1].ev.button_down);
}

test "dispatch: a second button during a drag reaches the holder and does not end it" {
    // Capture belongs to the button that opened the gesture. A
    // right-click during a left-drag is the "cancel this" convention, so
    // it has to REACH the component being dragged — and releasing it
    // must not drop the drag, or the gesture dies in the user's hand.
    //
    // Mutation: clear `self.captured` on any release rather than on
    // `button == self.capture_button`. The move after the right-release
    // is never delivered, red on the final count.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_input_only, 0, 0, 100, 50));

    try sp.dispatchMouseButtonN(10, 10, true, 0); // left press: takes capture
    try sp.dispatchMouseButtonN(10, 10, true, 1); // right press during it
    try testing.expectEqual(@as(u8, 1), p.recs[1].ev.button);
    try sp.dispatchMouseButtonN(10, 10, false, 1); // right release
    try testing.expect(sp.captured != null); // the left drag is still live
    try sp.dispatchMouseMove(30, 10);
    try testing.expectEqual(@as(usize, 4), p.n);
    try testing.expectEqual(InputProbe.Kind.move, p.recs[3].kind);
    try testing.expectEqual(@as(u8, 0), p.recs[3].ev.button); // still the left drag

    try sp.dispatchMouseButtonN(30, 10, false, 0);
    try testing.expect(sp.captured == null);
}

test "dispatch: a button index off the end of the mask is refused, not aliased" {
    // Loud, never a guess. `1 << 8` on a `u8` mask is not a bug you find
    // by reading; it is a side button that starts clicking things.
    //
    // Mutation: drop the bounds check and let `@intCast` shift. In Debug
    // the shift traps rather than returning, which is a different red —
    // so the gate asserts the ERROR, not merely "did not work".
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    try testing.expectError(error.UnknownMouseButton, sp.dispatchMouseButtonN(0, 0, true, 8));
}

test "dispatch: the modifier mask the host set reaches every pointer event" {
    // The hole `:::textarea`'s header prescribed the cure for: "there is
    // no honest way to know whether Shift is down at the moment of a
    // click. The cure is a `mods` field on MouseEvent, not a guess in
    // here."
    //
    // Mutation: drop `.mods = self.pointer_mods` from `mouseEventFor`
    // (the field defaults to 0, so it still compiles — which is exactly
    // how a dropped field survives a review). Every assertion below goes
    // red at 0.
    const SHIFT: u32 = 0x0001; // GLFW_MOD_SHIFT
    const CTRL: u32 = 0x0002; // GLFW_MOD_CONTROL

    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 0, 0, 100, 50));

    sp.setPointerMods(SHIFT | CTRL);
    try sp.dispatchHover(10, 10);
    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try sp.dispatchMouseMove(20, 10);
    try sp.dispatchMouseButtonN(20, 10, false, 0);

    try testing.expect(p.hn > 0);
    try testing.expectEqual(SHIFT | CTRL, p.hovers[0].mods);
    try testing.expectEqual(@as(usize, 3), p.n);
    for (p.recs[0..p.n]) |r| try testing.expectEqual(SHIFT | CTRL, r.ev.mods);

    // Rule 1: assert the ZERO before believing the mask — a field wired
    // to a constant would satisfy every assertion above.
    p.n = 0;
    sp.setPointerMods(0);
    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try testing.expectEqual(@as(u32, 0), p.recs[0].ev.mods);
}

test "stepClickRun: too slow, too far, or the other button is not a double-click" {
    // Pure, so the three ways a multi-click derivation goes wrong are
    // gated without a clock or a window. The wall-clock version inside
    // `:::textarea` could not be gated this way at all, which is part of
    // why it moved.
    //
    // Mutations, each executed:
    //  * drop the `MULTI_CLICK_MS` term  → the 500ms pair reports 2, red
    //  * drop the `MULTI_CLICK_SLOP` terms → the 20px pair reports 2, red
    //  * drop the `last_button` term     → the left-then-right pair
    //    reports 2, red
    //  * `.run = prev.run + 1` uncapped  → the fourth click reports 4, red
    const start = Spark.ClickRun{ .run = 1, .last_ms = 1000, .last_x = 50, .last_y = 50, .last_button = 0 };

    // Same place, soon enough, same button: the run continues.
    try testing.expectEqual(@as(u8, 2), Spark.stepClickRun(start, 1100, 50, 50, 0).run);
    // Drifted three pixels — still a double-click, which is the whole
    // reason there is a slop rather than an equality.
    try testing.expectEqual(@as(u8, 2), Spark.stepClickRun(start, 1100, 52, 51, 0).run);

    // 500ms apart: two single clicks.
    try testing.expectEqual(@as(u8, 1), Spark.stepClickRun(start, 1500, 50, 50, 0).run);
    // 20px apart: two single clicks, however fast.
    try testing.expectEqual(@as(u8, 1), Spark.stepClickRun(start, 1001, 70, 50, 0).run);
    try testing.expectEqual(@as(u8, 1), Spark.stepClickRun(start, 1001, 50, 70, 0).run);
    // A left click then a right click in the same place is two intents,
    // not a double-click — a context menu that opens thinking a word is
    // selected is the visible form of getting this wrong.
    try testing.expectEqual(@as(u8, 1), Spark.stepClickRun(start, 1001, 50, 50, 1).run);

    // And the run saturates at 3: a fourth click in place still means
    // "that line", not a wrap back round to a caret.
    var run = start;
    var t: i64 = 1000;
    for (0..4) |_| {
        t += 50;
        run = Spark.stepClickRun(run, t, 50, 50, 0);
    }
    try testing.expectEqual(@as(u8, 3), run.run);

    // The very first click of a session continues nothing. `last_button`
    // starts at 0xFF for this: a plausible 0 would have made it a
    // double-click of a click that never happened.
    const fresh = Spark.ClickRun{};
    try testing.expectEqual(@as(u8, 1), Spark.stepClickRun(fresh, 0, 0, 0, 0).run);
}

test "dispatch: the click run reaches the event, and the gesture after it" {
    // The through-path. `click_clock_ms` drives the clock so the gate
    // costs microseconds instead of half a second of real sleeping.
    //
    // Mutation: drop `.click_run = self.click.run` from `mouseEventFor`
    // (it defaults to 1, so it compiles). The second press reports 1,
    // red — and `:::textarea` would place a caret where a word should
    // have been selected.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_input_only, 0, 0, 100, 50));

    sp.click_clock_ms = 10_000;
    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try sp.dispatchMouseButtonN(10, 10, false, 0);
    sp.click_clock_ms = 10_100; // 100ms later, same place
    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try sp.dispatchMouseMove(11, 10);

    try testing.expectEqual(@as(u8, 1), p.recs[0].ev.click_run);
    try testing.expectEqual(@as(u8, 1), p.recs[1].ev.click_run); // the release of the first
    try testing.expectEqual(@as(u8, 2), p.recs[2].ev.click_run);
    // The drag that follows a double-click carries the run too — that is
    // what lets a word-drag extend by whole words.
    try testing.expectEqual(InputProbe.Kind.move, p.recs[3].kind);
    try testing.expectEqual(@as(u8, 2), p.recs[3].ev.click_run);

    // A press 500ms after the last one starts over.
    sp.click_clock_ms = 10_700;
    try sp.dispatchMouseButtonN(11, 10, false, 0);
    try sp.dispatchMouseButtonN(11, 10, true, 0);
    try testing.expectEqual(@as(u8, 1), p.recs[p.n - 1].ev.click_run);
}

test "hover: an enter is matched by a leave when the pointer exits" {
    // The whole content of the phase. A component that hears only "the
    // pointer is at (x, y)" cannot tell a two-pixel move from the
    // pointer having gone somewhere else, and a node in a graph editor
    // that stays lit after you leave it is the visible form of that.
    //
    // Mutation: delete the `try self.leaveHover()` in `dispatchHover`'s
    // "the target changed" branch. The phases are [enter] and the gate
    // is red on the slice compare.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 0, 0, 100, 50));

    try sp.dispatchHover(10, 10);
    try sp.dispatchHover(20, 10);
    try sp.dispatchHover(400, 400); // gone

    var buf: [8]element.HoverPhase = undefined;
    try testing.expectEqualSlices(
        element.HoverPhase,
        &.{ .enter, .move, .leave },
        p.phases(&buf),
    );
    // The leave carries where the pointer was when it left, which is
    // outside the box. Clamping it back inside would tell the component
    // the pointer is still there on the event that says it is not.
    try testing.expectEqual(@as(f32, 400), p.hovers[2].local[0]);
    try testing.expect(sp.hovered == null);
}

test "hover: crossing between components leaves the first before entering the second" {
    // Two components must never both believe the pointer is theirs. The
    // ordering is the assertion — a leave that arrived AFTER the next
    // component's enter would let a graph editor light two nodes.
    //
    // Mutation: move the `leaveHover()` call to after the `.enter`
    // dispatch. Both probes still see one event each, and both counts
    // still pass — only the interleaving changes, which is why this gate
    // records into one shared list rather than counting per probe.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    // Two DISTINCT components — hover identity is by `ctx`, so one probe
    // behind two boxes would be one component and the crossing would be
    // a `.move`. Both write into `log`, so the list IS the interleaving.
    var log = InputProbe{};
    var first = InputProbe{ .sink = &log };
    var second = InputProbe{ .sink = &log };
    try sp.drawlist.hits.append(probeHit(&first, &probe_hover_too, 0, 0, 50, 50));
    try sp.drawlist.hits.append(probeHit(&second, &probe_hover_too, 60, 0, 50, 50));

    try sp.dispatchHover(10, 10); // in the first
    log.hn = 0;
    try sp.dispatchHover(70, 10); // straight into the second

    var buf: [8]element.HoverPhase = undefined;
    try testing.expectEqualSlices(element.HoverPhase, &.{ .leave, .enter }, log.phases(&buf));
    // `local` is measured against the box being told about, not the box
    // the pointer is in: the leave belongs to the first Hit, at x = 0.
    try testing.expectEqual(@as(f32, 70), log.hovers[0].local[0]); // 70 - 0
    try testing.expectEqual(@as(f32, 10), log.hovers[1].local[0]); // 70 - 60
}

test "hover: a stationary pointer sends nothing, but a relayout under it still counts" {
    // The cost gate. A polling host calls `dispatchHover` every frame
    // whether the mouse moved or not, and a `.move` per frame per
    // hovered component is a component redrawing itself sixty times a
    // second for nothing.
    //
    // Mutation: dispatch `.move` unconditionally instead of on
    // `x != hover_x or y != hover_y`. The second and third calls each
    // add a `.move`, red on the count.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 0, 0, 100, 50));

    try sp.dispatchHover(10, 10);
    try sp.dispatchHover(10, 10);
    try sp.dispatchHover(10, 10);
    var buf: [8]element.HoverPhase = undefined;
    try testing.expectEqualSlices(element.HoverPhase, &.{.enter}, p.phases(&buf));

    // The scan is NOT skipped for a still pointer, on purpose: the
    // document can re-lay-out under a stationary cursor — a `:::fold`
    // opening is the everyday case — and the leave that follows is real.
    //
    // Mutation for this half: early-return from `dispatchHover` when the
    // position is unchanged. No leave arrives, red.
    sp.drawlist.hits.clearRetainingCapacity();
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 200, 200, 10, 10));
    try sp.dispatchHover(10, 10);
    try testing.expectEqualSlices(element.HoverPhase, &.{ .enter, .leave }, p.phases(&buf));
}

test "hover: nothing is dispatched while a drag holds the pointer" {
    // Pointer capture owns the pointer for the length of a gesture —
    // that is what makes a slider dragged off its own box keep scrubbing.
    // A hover fired at a third component mid-drag would put two
    // components in a "the pointer is mine" state at once.
    //
    // Mutation: drop the `buttons_down != 0 or captured != null` guard at
    // the top of `dispatchHover`. The drag across the second component
    // enters it while the first is still captured, red on the phases.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 0, 0, 50, 50));
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 60, 0, 50, 50));

    try sp.dispatchHover(10, 10); // enter the first
    p.hn = 0;
    try sp.dispatchMouseButtonN(10, 10, true, 0);

    // The press itself takes the hover away — the pointer now belongs to
    // the gesture, and it says so rather than going quiet.
    var buf: [8]element.HoverPhase = undefined;
    try testing.expectEqualSlices(element.HoverPhase, &.{.leave}, p.phases(&buf));

    p.hn = 0;
    try sp.dispatchHover(70, 10); // a host that asks anyway
    try sp.dispatchMouseMove(70, 10);
    try sp.dispatchHover(70, 10);
    try testing.expectEqual(@as(usize, 0), p.hn);

    // …and the hand letting go hands the pointer back, in the same call
    // rather than on whichever later frame the mouse happens to twitch.
    // Mutation: drop the `dispatchHover` at the end of the release arm.
    // No enter arrives, red.
    try sp.dispatchMouseButtonN(70, 10, false, 0);
    try testing.expectEqualSlices(element.HoverPhase, &.{.enter}, p.phases(&buf));
}

test "hover: the deepest hit takes it, and a component without on_hover takes it away" {
    // Hover targets one component, the same one a click would — so hover
    // and click can never disagree about who the pointer is on. It does
    // NOT bubble the way the wheel does: two nested components both lit
    // is a state neither can tell it is in.
    //
    // Mutation: fall back to scanning outward for a Hit that HAS an
    // `on_hover` when the deepest one does not. The outer probe stays
    // entered while the pointer is over the inner opaque one, red.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var outer = InputProbe{};
    var inner = InputProbe{};
    // The walker appends a container before its children, and `findHit`
    // scans backwards — so the child is the later entry.
    try sp.drawlist.hits.append(probeHit(&outer, &probe_hover_too, 0, 0, 100, 100));
    try sp.drawlist.hits.append(probeHit(&inner, &probe_input_only, 40, 40, 20, 20));

    try sp.dispatchHover(10, 10);
    try testing.expectEqual(@as(usize, 1), outer.hn);
    try testing.expectEqual(element.HoverPhase.enter, outer.hovers[0].phase);

    try sp.dispatchHover(50, 50); // over the child, which declares no on_hover
    try testing.expectEqual(@as(usize, 2), outer.hn);
    try testing.expectEqual(element.HoverPhase.leave, outer.hovers[1].phase);
    try testing.expectEqual(@as(usize, 0), inner.hn);
    try testing.expect(sp.hovered == null);
}

test "hover: a component that left the hit layer is not sent a leave" {
    // `hovered` is a COPY of a Hit, so its `ctx` outlives the component
    // when a `:::fold` shuts under the cursor and frees its children.
    // `captured` and `focused` carry the same hazard and get away with it
    // because a press sets them and a release clears them; a hover
    // persists across every frame the pointer sits still, which is
    // exactly the window in which a document re-lays out.
    //
    // Mutation: drop the presence scan in `leaveHover` and dispatch
    // straight to `old`. A leave is recorded for a component that is no
    // longer in the layer — red here, a use-after-free in a real
    // document, which is the failure this gate stands in for.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 0, 0, 100, 50));
    try sp.dispatchHover(10, 10);
    try testing.expectEqual(@as(usize, 1), p.hn);

    // The component is gone from this frame's layer.
    sp.drawlist.hits.clearRetainingCapacity();
    try sp.dispatchHover(400, 400);
    try testing.expectEqual(@as(usize, 1), p.hn); // no leave
    try testing.expect(sp.hovered == null);
}

test "hover: a component that never declared on_hover is untouched by any of this" {
    // The governing constraint of the beat, as a gate. An existing
    // component sees the events it always saw and not one more — the
    // whole reason hover is a vtable slot rather than a `mouse_move`
    // with `button_down = false`.
    //
    // Mutation: deliver hover as `.mouse_move` through `on_input` when
    // `on_hover` is null. `:::slider`, which scrubs on any move, would
    // then move to wherever the pointer passed — and here, `p.n` is 3
    // instead of 0, red.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_input_only, 0, 0, 100, 50));

    try sp.dispatchHover(10, 10);
    try sp.dispatchHover(20, 10);
    try sp.dispatchHover(400, 400);
    try testing.expectEqual(@as(usize, 0), p.n);
    try testing.expectEqual(@as(usize, 0), p.hn);
}

// ── The redraw request: "does anything need drawing again?" ─────────
//
// Reported by Christian against `:::nodegraph`: *"dragging nodes doesn't
// update the display until you let go of the mouse."* Hover was broken
// the same way and nobody had noticed yet.
//
// The cause was one flag answering two questions. `processInput` was the
// only input path in the reference host that never set `State.dirty` —
// `keyCb`, `charCb` and `scrollCb` all did — so a drag re-laid nothing
// out, and the `State.set` at `mouse_up` finally dirtied it and the node
// appeared where it had already been for half a second.
//
// The cure is not "dirty on every move". That is the same mistake with
// the sign flipped: a pointer wandering across a document would cost a
// walk a frame forever. So the three gates below come in a set — two
// that the picture updates, and one that a pointer over nothing costs
// NOTHING. Delete the third and the first two are satisfied by
// `redraw_requested = true` at the top of every dispatcher.

test "redraw: a drag asks for a frame mid-gesture, not only at mouse_up" {
    // THE reported bug. The gate is the seam under the host loop rather
    // than the loop itself: `main.zig` can be rewritten around this and
    // the promise still holds.
    //
    // Mutation: delete the `defer noteRedraw(sp, hit, before)` in
    // `dispatchHit`. Every move below reports false and the gate is red
    // three times over — which is exactly the shipped behaviour, so the
    // gate is watching the bug and not a paraphrase of the fix.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&p, &probe_versioned, 0, 0, 100, 50));

    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try testing.expect(sp.takeRedrawRequest()); // the press itself
    // and it CLEARS: a request that stayed raised would make the two
    // assertions below pass against a dispatcher that does nothing.
    try testing.expect(!sp.takeRedrawRequest());

    var step: f32 = 11;
    while (step <= 13) : (step += 1) {
        try sp.dispatchMouseMove(step, 10);
        try testing.expect(sp.takeRedrawRequest());
    }

    try sp.dispatchMouseButtonN(13, 10, false, 0);
    try testing.expect(sp.takeRedrawRequest());
}

test "redraw: a hover that changes target asks for a frame" {
    // The half nobody had noticed. A node in a graph editor lights on
    // enter and unlights on leave, and both were invisible until the
    // mouse happened to do something that wrote state.
    //
    // Mutation: delete the `defer noteRedraw(sp, hit, before)` in
    // `dispatchHoverHit`. Both assertions go red — and the third gate
    // below stays green, which is how you tell the two apart.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var a = InputProbe{};
    var b = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&a, &probe_versioned, 0, 0, 100, 50));
    try sp.drawlist.hits.append(probeHit(&b, &probe_versioned, 100, 0, 100, 50));

    try sp.dispatchHover(10, 10); // enter a
    try testing.expect(sp.takeRedrawRequest());
    try sp.dispatchHover(150, 10); // leave a, enter b
    try testing.expect(sp.takeRedrawRequest());
    try sp.dispatchHover(400, 400); // leave b
    try testing.expect(sp.takeRedrawRequest());
}

test "redraw: a pointer over nothing costs no frames at all" {
    // The cost half, and the reason this is a version comparison rather
    // than "a dispatch happened". Counted rather than asserted one at a
    // time, because the number is the point: this is what a host would
    // have re-laid-out.
    //
    // Mutation: `self.redraw_requested = true` at the top of
    // `dispatchHover` and `dispatchMouseMove` — i.e. dirty
    // unconditionally, the fix everyone reaches for first. The three
    // counts below become 30, 30 and 30, red on all three, while both
    // gates above stay green.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    // Over nothing whatsoever: no hit under the pointer at all.
    var frames: usize = 0;
    for (0..30) |i| {
        const x: f32 = 400 + @as(f32, @floatFromInt(i));
        try sp.dispatchHover(x, 400);
        if (sp.takeRedrawRequest()) frames += 1;
    }
    try testing.expectEqual(@as(usize, 0), frames);

    // Over something that is simply not interested in the pointer, which
    // is most of a document: a paragraph, a heading, a button that only
    // cares about clicks.
    var deaf = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&deaf, &probe_versioned_no_hover, 0, 0, 100, 50));
    frames = 0;
    for (0..30) |i| {
        const x: f32 = 10 + @as(f32, @floatFromInt(i));
        try sp.dispatchHover(x, 10);
        if (sp.takeRedrawRequest()) frames += 1;
    }
    try testing.expectEqual(@as(usize, 0), frames);
    try testing.expectEqual(@as(usize, 0), deaf.hn);

    // And the sharp one: a component that HEARS the move and has nothing
    // new to draw — the pointer wandering around inside the node it is
    // already hovering. `:::nodegraph` is exactly this: its `on_hover`
    // bumps its version only when the pick changes.
    var still = InputProbe{ .moves = false };
    sp.drawlist.hits.clearRetainingCapacity();
    sp.hovered = null;
    try sp.drawlist.hits.append(probeHit(&still, &probe_versioned, 0, 0, 100, 50));
    frames = 0;
    for (0..30) |i| {
        const x: f32 = 10 + @as(f32, @floatFromInt(i));
        try sp.dispatchHover(x, 10);
        if (sp.takeRedrawRequest()) frames += 1;
    }
    try testing.expectEqual(@as(usize, 0), frames);
    // Rule 1: assert it was actually LISTENING. Without this the gate
    // passes just as well against a hover channel that dispatches
    // nothing, which is not what is being claimed.
    try testing.expectEqual(@as(usize, 30), still.hn);
}

test "redraw: a component with no content_version is believed, not assumed still" {
    // The safe direction of the version comparison, made explicit. A
    // component that keeps no counter cannot say whether it changed, and
    // guessing "unchanged" would be this same bug one level in — silent,
    // and per-component instead of global.
    //
    // Mutation: in `noteRedraw`, `if (before != null and after != null
    // and before.? != after.?)`. Red here; green everywhere else in the
    // suite, because every shipped component keeps a version.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{ .moves = false }; // and `probe_hover_too` has no getter
    try sp.drawlist.hits.append(probeHit(&p, &probe_hover_too, 0, 0, 100, 50));

    try sp.dispatchHover(10, 10);
    try testing.expect(sp.takeRedrawRequest());
    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try testing.expect(sp.takeRedrawRequest());
    try sp.dispatchMouseMove(20, 10);
    try testing.expect(sp.takeRedrawRequest());
}

// ── The host window (panels campaign, beat 3) ───────────────────────
// The arithmetic that decides whether a `:::gbuffer` panel shows what
// is genuinely under it or something a few hundred pixels away. Pure,
// so it is gated here rather than by looking at a capture — the
// difference between a correct window and one off by a scale factor is
// a picture that looks plausible either way.

test "hostWindow: a panel maps onto the fraction of the surface it covers" {
    // A 240x160 panel at (576, 115) on a 960x540 span. The window is
    // its rectangle expressed as fractions, and nothing else.
    const w = Spark.hostWindow(.{ .x = 576, .y = 115, .w = 240, .h = 160 }, 960, 540, .screen);
    try testing.expectApproxEqAbs(@as(f32, 0.25), w[0], 1e-6); // 240/960
    try testing.expectApproxEqAbs(@as(f32, 160.0 / 540.0), w[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), w[2], 1e-6); // 576/960
    try testing.expectApproxEqAbs(@as(f32, 115.0 / 540.0), w[3], 1e-6);
}

test "hostWindow: a panel covering the whole surface is the identity" {
    // The case that says the transform has no hidden constant in it. If
    // a full-surface panel is not (1, 1, 0, 0), every other window is
    // wrong by the same factor — and a slightly-wrong window still
    // produces a plausible-looking picture, which is why this is
    // asserted rather than eyeballed.
    const w = Spark.hostWindow(.{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, 1920, 1080, .screen);
    try testing.expectApproxEqAbs(@as(f32, 1), w[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), w[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), w[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), w[3], 1e-6);
}

test "hostWindow: the span and the image's resolution are DIFFERENT numbers" {
    // The trap this beat was written to close, stated where the
    // arithmetic lives.
    //
    // `shadow`, `ao` and `ao_filtered` are created at half the render
    // extent and still cover the whole screen. Their span is therefore
    // the screen, and a panel over the middle of the screen shows the
    // middle of each of them. Passing the image's own dimensions
    // instead lands somewhere else entirely — and it is not a small
    // error that looks like a rounding problem, it is the far edge.
    //
    // `hostWindow` cannot tell the two apart on its own: it divides by
    // whatever it is handed. So what is gated here is that THE CHOICE
    // MATTERS — the two answers differ, by a factor of two, in a way
    // that is visible. The gate that the host reports the right one of
    // them lives in matryoshka's `HudSurfaces` table, which is the code
    // that actually makes the choice.
    const region = element.PassRegion{ .x = 480, .y = 270, .w = 240, .h = 160 };
    const by_span = Spark.hostWindow(region, 960, 540, .screen);
    const by_resolution = Spark.hostWindow(region, 480, 270, .screen);
    try testing.expect(by_resolution[2] != by_span[2]);
    // Concretely: a panel whose left edge sits at the screen's midpoint
    // reads as 0.5 of the screen and 1.0 of a half-size image — the far
    // right edge. The panel would show the bottom-right quadrant while
    // sitting in the middle. Plausible-looking, and wrong.
    try testing.expectApproxEqAbs(@as(f32, 0.5), by_span[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), by_resolution[2], 1e-6);
}

test "hostWindow: a reduced dispatch footprint spans MORE than the screen" {
    // The other direction, and the one the retired comment got backwards.
    //
    // matryoshka allocates every intermediate at full output size and
    // uses `render_scale_pct` to shrink the DISPATCH — so at 70% the
    // content sits in the top-left 70% of the image's UV range, and the
    // full range spans `screen / 0.7`. Dividing by the image's
    // dimensions (which equal the screen's here) leaves the panel
    // looking 1/0.7 too far out, into texels nothing wrote.
    const region = element.PassRegion{ .x = 480, .y = 0, .w = 240, .h = 160 };
    const at_native = Spark.hostWindow(region, 960, 540, .screen);
    // span = screen * screen / render_extent, integer-exact against the
    // host's own `renderW()`.
    const at_70 = Spark.hostWindow(region, 960 * 960 / 672, 540 * 540 / 378, .screen);
    try testing.expect(at_70[2] < at_native[2]);
    try testing.expectApproxEqAbs(@as(f32, 0.5) * 0.7, at_70[2], 1e-3);
}

test "hostWindow: a .whole surface ignores the panel's position entirely" {
    // A shadow map is rendered from the sun's point of view. There is no
    // part of it that is "under" a panel, so windowing it would show a
    // meaningless crop that moved as the panel was dragged — which reads
    // as a bug in the shadow map rather than a category error in the
    // panel. `.whole` shows all of it, from anywhere.
    const a = Spark.hostWindow(.{ .x = 0, .y = 0, .w = 240, .h = 160 }, 960, 540, .whole);
    const b = Spark.hostWindow(.{ .x = 700, .y = 380, .w = 240, .h = 160 }, 960, 540, .whole);
    try testing.expectEqual(a, b);
    try testing.expectEqual([4]f32{ 1, 1, 0, 0 }, a);

    // And the same region under `.screen` is NOT the identity, so this
    // is testing the fit and not the arithmetic being trivial.
    const windowed = Spark.hostWindow(.{ .x = 700, .y = 380, .w = 240, .h = 160 }, 960, 540, .screen);
    try testing.expect(windowed[2] != b[2]);
}

test "hostWindow: a zero-sized span does not divide by zero" {
    // A resize can hand a frame a surface with no extent, and a NaN
    // window samples nothing and paints the panel with whatever the
    // sampler does at NaN — a black box that looks like a missing
    // surface rather than a bad divisor.
    const w = Spark.hostWindow(.{ .x = 10, .y = 10, .w = 100, .h = 100 }, 0, 0, .screen);
    for (w) |v| try testing.expect(!std.math.isNan(v));
}

// ── The overlay, and the context question ───────────────────────────
//
// Three things this beat added, and the gates below are grouped by
// which: the paint order that puts an overlay above the page, the input
// scoping that gives it the pointer, and the right-click that asks the
// host what is under a point without deciding anything itself.
//
// Every gate names the mutation it was paid for, and each of those
// mutations was executed and watched go red. The overlay's PLACEMENT is
// gated in `overlay.zig` — it is pure arithmetic and belongs beside the
// function. Its RENDER is not gated anywhere: walking a document needs
// fonts, an atlas and a device, and none of the decisions this beat made
// live in the walk.

/// A theme whose styles never reach the font registry — enough to parse
/// a document of plain prose, which is what every overlay gate below
/// opens. Same stub `markdown.zig`'s parse tests use, restated here
/// rather than exported: a test fixture that two files share is a third
/// thing to keep in step.
fn stubTheme() element.Theme {
    const s: element.Style = .{ .font_id = 0, .color = .{ 1, 1, 1, 1 } };
    return .{
        .body = s,
        .heading = .{ s, s, s, s, s, s },
        .code_block = s,
        .list_marker = s,
        .emphasis_font_id = 0,
        .strong_font_id = 0,
        .bold_italic_font_id = 0,
        .code_inline_font_id = 0,
    };
}

/// Pretend a frame has drawn the overlay at `box`, claiming the hits in
/// `[first, last)`. `layoutAndRenderOverlay` does this for real and
/// cannot run without a device; what the gates below are about is what
/// the DISPATCHER does once it has been done, so they do it by hand and
/// say so.
fn placeOverlayForTest(sp: *Spark, box: element.Box, first: u32, last: u32) void {
    sp.overlay.?.box = box;
    sp.overlay.?.hits = .{ first, last };
}

test "overlay: the paint layer goes last whatever order it was rendered in" {
    // The whole of "above all page content". A layer paints after every
    // layer before it — ground, triangles, images, quads and glyphs
    // together — so last IS on top, and a menu rendered before a second
    // panel would otherwise be painted underneath it.
    //
    // Mutation: `fn lt(...) bool { return false; }` in
    // `orderOverlayLast`. Compiles, sorts nothing, and the overlay stays
    // where it was emitted — red on the first expectEqual (the overlay's
    // marker is still at index 1).
    const mk = struct {
        fn layer(mark: u32, is_overlay: bool) PaintLayer {
            return .{
                .dispatches = .{ mark, mark },
                .glyphs = .{ mark, mark },
                .quads = .{ mark, mark },
                .tri_indices = .{ mark, mark },
                .images = .{ mark, mark },
                .overlay = is_overlay,
            };
        }
    };

    // Panel A, then the menu, then panel B — a host that renders its
    // menu in the middle of its panel loop.
    var layers = [_]PaintLayer{
        mk.layer(10, false),
        mk.layer(20, true),
        mk.layer(30, false),
    };
    orderOverlayLast(&layers);
    try testing.expectEqual(@as(u32, 10), layers[0].glyphs[0]);
    try testing.expectEqual(@as(u32, 30), layers[1].glyphs[0]);
    try testing.expectEqual(@as(u32, 20), layers[2].glyphs[0]);
    try testing.expect(layers[2].overlay);

    // Stability is load-bearing and not incidental: two overlapping
    // panels are ordered by the host's call order, and a sort that
    // reshuffled them would put the wrong panel on top for reasons
    // nothing in the host explains. `10` still precedes `30`, above.
    //
    // And it is idempotent, which is what the `.reset = false` replay
    // path needs — the same array is sorted again next frame.
    orderOverlayLast(&layers);
    try testing.expectEqual(@as(u32, 10), layers[0].glyphs[0]);
    try testing.expectEqual(@as(u32, 30), layers[1].glyphs[0]);
    try testing.expectEqual(@as(u32, 20), layers[2].glyphs[0]);
}

test "overlay: opens with no input event at all" {
    // The host-initiated door, and the reason the API takes a point
    // rather than reading one off the dispatcher. matryoshka picks a
    // mesh in its own 3D scene, computes a screen point itself, and
    // opens a menu there — with no spark element under the cursor and
    // no right-click anywhere in the story.
    //
    // Note what this gate does NOT do: there is no press, no release, no
    // hit on the layer and no `setPointerMods` anywhere in it. The door
    // is exercised rather than asserted — a dispatcher that had to have
    // seen a right-click would not reach the second line.
    //
    // Mutation: transpose the point — `.at = .{ at[1], at[0] }`. The
    // first draft of `openOverlay` did read `self.mouse_x/mouse_y`
    // instead of the argument, which is the mutation this gate was
    // really written for; that one does not COMPILE (the `at` parameter
    // goes unused, and Zig refuses), and a mutation that does not
    // compile is not a mutation. The transposition is the same slip one
    // step later and it compiles: red on the `at` assertion.
    var theme = stubTheme();
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    sp.theme = &theme;
    sp.registry = &reg;
    defer sp.closeOverlay();

    try testing.expect(!sp.overlayOpen());
    try sp.openOverlay("Rename\n\nDelete\n", .{ 412, 233 }, .top_left, .{});
    try testing.expect(sp.overlayOpen());
    try testing.expectEqual([2]f32{ 412, 233 }, sp.overlay.?.at);

    // A second open replaces the first rather than stacking. If it
    // leaked the previous document the testing allocator says so at
    // teardown, which is the real assertion here.
    try sp.openOverlay("Duplicate\n", .{ 10, 10 }, .bottom_right, .{});
    try testing.expectEqual([2]f32{ 10, 10 }, sp.overlay.?.at);
    try testing.expectEqual(Corner.bottom_right, sp.overlay.?.corner);
}

test "overlay: a press inside it reaches the overlay and never the page" {
    // "It takes input first", and the gate is deliberately built so that
    // being last in the hit array cannot be what makes it work: the
    // OVERLAY's hit is appended first and the page's second, so
    // `findHit`'s backwards scan would pick the page. Only the scoping
    // gets this right.
    //
    // That arrangement is not contrived — `layoutAndRenderOverlay` need
    // not be the host's last layout call (see its note), so a host that
    // renders a menu before its panels produces exactly this array.
    //
    // Mutation: `fn hitScope(self) []const element.Hit { return
    // self.drawlist.hits.items; }`. Compiles, and the press lands on the
    // page probe — red on both counts.
    var theme = stubTheme();
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    sp.theme = &theme;
    sp.registry = &reg;
    defer sp.closeOverlay();

    var menu = InputProbe{};
    var page = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&menu, &probe_input_only, 100, 100, 60, 40));
    try sp.drawlist.hits.append(probeHit(&page, &probe_input_only, 0, 0, 400, 400));

    try sp.openOverlay("Rename\n", .{ 100, 100 }, .top_left, .{});
    placeOverlayForTest(&sp, .{ .x = 100, .y = 100, .w = 60, .h = 40 }, 0, 1);

    try sp.dispatchMouseButtonN(120, 110, true, 0);
    try testing.expectEqual(@as(usize, 1), menu.n);
    try testing.expectEqual(@as(usize, 0), page.n);
}

test "overlay: a press outside dismisses it and is swallowed" {
    // The decision, stated in `dispatchMouseButtonN`: a dismissing click
    // closes the menu and goes no further. Delivering it too would make
    // one click both close a menu and do whatever is under the point it
    // was aimed at — an irreversible action nobody chose. Every native
    // menu on this machine swallows it.
    //
    // Mutation: drop the `return` after `closeOverlay()` so the press
    // falls through to the ordinary path. Compiles. The page probe
    // records one press — red on the second expectEqual, which is the
    // whole of the decision.
    var theme = stubTheme();
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    sp.theme = &theme;
    sp.registry = &reg;
    defer sp.closeOverlay();

    var menu = InputProbe{};
    var page = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&menu, &probe_input_only, 100, 100, 60, 40));
    try sp.drawlist.hits.append(probeHit(&page, &probe_input_only, 0, 0, 400, 400));

    try sp.openOverlay("Rename\n", .{ 100, 100 }, .top_left, .{});
    placeOverlayForTest(&sp, .{ .x = 100, .y = 100, .w = 60, .h = 40 }, 0, 1);

    try sp.dispatchMouseButtonN(10, 10, true, 0);
    try testing.expect(!sp.overlayOpen());
    try testing.expectEqual(@as(usize, 0), page.n);
    try testing.expectEqual(@as(usize, 0), menu.n);

    // And the menu's hits went with it, rather than sitting in the array
    // pointing at a freed component until the next `beginFrame`. A menu
    // item whose handler closes the menu is what a menu item DOES, so
    // this is the path and not the corner.
    try testing.expectEqual(@as(usize, 1), sp.drawlist.hits.items.len);
}

test "overlay: the release of the click that opened it does not dismiss it" {
    // A right-click opens a menu; its own RELEASE arrives before any
    // frame has drawn, so the overlay has no rect yet and `contains`
    // answers false for every point. If a release dismissed, every menu
    // opened by right-click would close in the gesture that opened it —
    // and it would look like the menu never opened at all.
    //
    // Mutation: change the guard to `if (!ov.contains(x, y)) {
    // self.closeOverlay(); return; }` — dismissing on either edge. It
    // compiles and it is the obvious way to write it. Red on the
    // `overlayOpen` assertion.
    var theme = stubTheme();
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    sp.theme = &theme;
    sp.registry = &reg;
    defer sp.closeOverlay();

    var page = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&page, &probe_input_only, 0, 0, 400, 400));

    // The press that opens it. `dispatchMouseButtonN` has to see the
    // press so the button's bit is set and the release is a transition.
    try sp.dispatchMouseButtonN(200, 200, true, Spark.CONTEXT_BUTTON);
    try sp.openOverlay("Rename\n", .{ 200, 200 }, .top_left, .{});

    // …and its release, with the overlay still unplaced.
    try sp.dispatchMouseButtonN(200, 200, false, Spark.CONTEXT_BUTTON);
    try testing.expect(sp.overlayOpen());
}

test "overlay: Escape closes it and does not reach the focused component" {
    // Every menu everywhere closes on Esc, so wiring it per host would
    // be making each host reimplement three lines and one of them
    // forget. Consumed rather than also delivered, for the same reason a
    // dismissing click is: the press meant "not this menu", not "not
    // this menu AND clear the caret in the field behind it".
    //
    // Three mutations, all run. Delete the whole `if (self.overlay …)`
    // arm: Escape stops closing anything and instead reaches the focused
    // probe, red on both halves. Drop the `ev.key == KEY_ESCAPE` half of
    // the condition: every key then dismisses, and typing with a menu up
    // becomes impossible — red on the second half. Or delete the
    // `clearFocus()` from `openOverlay`: the field behind the menu keeps
    // the keyboard, which is the right-click-while-editing bug — red on
    // the `sp.focused == null` assertion.
    //
    // Note what is NOT gated, because it cannot be: the `return` that
    // consumes the key is belt-and-braces today, since `closeOverlay`
    // clears the focus and there is nobody left to deliver to. It stays
    // because "the key is consumed" is the contract and the focus clear
    // is a coupling that could change.
    var theme = stubTheme();
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    sp.theme = &theme;
    sp.registry = &reg;
    defer sp.closeOverlay();

    var field = InputProbe{};
    try sp.drawlist.hits.append(probeHit(&field, &probe_input_only, 0, 0, 400, 400));
    sp.focused = sp.drawlist.hits.items[0];

    // Opening TAKES the keyboard, which is a decision of its own: a
    // right-click while editing must not leave the field behind the menu
    // swallowing everything typed into it.
    try sp.openOverlay("Rename\n", .{ 100, 100 }, .top_left, .{});
    try testing.expect(sp.focused == null);

    // Now give focus to something INSIDE the menu — a focusable item is
    // the ordinary case — so what follows tests the Escape and not the
    // clear above.
    sp.focused = sp.drawlist.hits.items[0];
    try sp.dispatchKey(.{ .key = KEY_ESCAPE, .mods = 0 });
    try testing.expect(!sp.overlayOpen());
    // The KEY count, not the version counter: closing an overlay also
    // clears the focus, and `focus_lost` bumps the version. A gate on
    // the version would have gone green against a dispatcher that
    // delivered the Escape as well.
    try testing.expectEqual(@as(usize, 0), field.kn);

    // Any other key still reaches the focused component with a menu up,
    // so this is one key's exception and not a keyboard blackout.
    try sp.openOverlay("Rename\n", .{ 100, 100 }, .top_left, .{});
    sp.focused = sp.drawlist.hits.items[0];
    try sp.dispatchKey(.{ .key = 65, .mods = 0 });
    try testing.expect(sp.overlayOpen());
    try testing.expectEqual(@as(usize, 1), field.kn);
    try testing.expectEqual(@as(i32, 65), field.keys[0].key);
}

test "overlay: spark claims the pointer everywhere while one is open" {
    // A click outside an open menu is spent dismissing it, and spark
    // consumes it. A host that asked `claimsPointer` and got false for
    // the area outside would hand that same click to its 3D scene, so
    // dismissing a menu would also re-pick the world behind it —
    // matryoshka's `PointerRouter` asks exactly this question.
    //
    // Mutation: delete the `if (self.overlay != null) return true;` line.
    // Compiles, and the point far outside every hit box answers false —
    // red.
    var theme = stubTheme();
    var reg = component_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    sp.theme = &theme;
    sp.registry = &reg;
    defer sp.closeOverlay();

    // Nothing on the hit layer at all, so the only thing that can make
    // this true is the overlay.
    try testing.expect(!sp.claimsPointer(900, 900));
    try sp.openOverlay("Rename\n", .{ 100, 100 }, .top_left, .{});
    placeOverlayForTest(&sp, .{ .x = 100, .y = 100, .w = 60, .h = 40 }, 0, 0);
    try testing.expect(sp.claimsPointer(900, 900));
    try testing.expect(sp.claimsPointer(120, 110));
}

// ── The context question ────────────────────────────────────────────

test "context: a right-press writes one record naming the subject under it" {
    // The grammar, and the fact that spark opens NOTHING — it asks a
    // question and the host answers. `subject`, the world point, and the
    // three modifiers, in one line-oriented record on the bound path.
    //
    // Mutation: emit on every button rather than on `CONTEXT_BUTTON` —
    // delete the `button == CONTEXT_BUTTON` half of the guard. Compiles.
    // The left press at the end then overwrites the record with its own,
    // and the final assertion (that a left press changes nothing) goes
    // red. That is the mutation that matters: a menu that opened on
    // every click would be found in a second, but a record written on
    // every click is invisible until something downstream acts on it.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    defer if (sp.context_path) |p| sp.allocator.free(p);
    try sp.setContextPath("ui.context");

    // The box has to CONTAIN the press — `contextClaimAt` tests the
    // rect before it asks, exactly as every other channel does.
    var p = InputProbe{ .subject = "node:near1" };
    try sp.drawlist.hits.append(contextProbeHit(&p, &probe_context, 0, 0, 600, 600));

    sp.setPointerMods(MOD_CONTROL);
    try sp.dispatchMouseButtonN(412, 233.5, true, Spark.CONTEXT_BUTTON);
    try testing.expectEqualStrings(
        "context subject=node:near1 x=412.0 y=233.5 shift=0 ctrl=1 alt=0",
        st.get("ui.context").?,
    );

    // The press still reached the component. The record is in ADDITION
    // to the ordinary dispatch, not instead of it — `:::nodegraph` reads
    // `mev.button` today and must keep seeing the press.
    try testing.expectEqual(@as(usize, 1), p.n);
    try testing.expectEqual(Spark.CONTEXT_BUTTON, p.recs[0].ev.button);

    // A LEFT press over the same subject writes nothing new.
    try sp.dispatchMouseButtonN(412, 233.5, false, Spark.CONTEXT_BUTTON);
    try sp.dispatchMouseButtonN(1, 1, true, 0);
    try testing.expectEqualStrings(
        "context subject=node:near1 x=412.0 y=233.5 shift=0 ctrl=1 alt=0",
        st.get("ui.context").?,
    );
}

test "context: an unclaimed right-press emits nothing at all" {
    // The distinction matryoshka's router is built on: "the canvas
    // claims this point" and "no element claims this point" have to
    // route differently, because the second one is the 3D scene's click.
    // A record with a blank subject would collapse them.
    //
    // Mutation: in `emitContext`, give the claim a default instead of
    // returning — `orelse ContextClaim{ .subject = "", .state = null }`.
    // Compiles, and it is the plausible design: "always tell the host
    // where the right-click was, and let it decide". A record then
    // appears for both presses below and both `expect(… == null)` go
    // red. Which is the whole argument: with that record written, a host
    // cannot distinguish an unclaimed point from a claimed one without
    // parsing the subject and special-casing the empty string.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    defer if (sp.context_path) |p| sp.allocator.free(p);
    try sp.setContextPath("ui.context");

    // A probe that takes input and DECLINES the context question — the
    // ordinary case for every component in the library today.
    var p = InputProbe{ .subject = null };
    try sp.drawlist.hits.append(contextProbeHit(&p, &probe_context, 0, 0, 400, 400));

    try sp.dispatchMouseButtonN(50, 50, true, Spark.CONTEXT_BUTTON);
    try testing.expect(st.get("ui.context") == null);

    // And a point with nothing under it at all.
    try sp.dispatchMouseButtonN(50, 50, false, Spark.CONTEXT_BUTTON);
    try sp.dispatchMouseButtonN(900, 900, true, Spark.CONTEXT_BUTTON);
    try testing.expect(st.get("ui.context") == null);
}

test "context: innermost wins, and a hook that declines falls to the attribute" {
    // Two rules in one arrangement, because they are the same walk.
    //
    // Innermost-out: the pointer is very often over something small
    // inside something large, and the small thing is the more specific
    // answer. The hit layer is deepest-last, so the scan runs backwards
    // — the same direction `dispatchScroll` bubbles in.
    //
    // Within one hit, the vtable hook is asked before the author's
    // `context=`: the hook varies with the point and the attribute does
    // not, and a hook that DECLINES falling through to the attribute is
    // what makes `:::nodegraph {context="canvas"}` behave the way an
    // author would guess — nodes name themselves, the empty ground
    // between them takes the attribute.
    //
    // Mutation: swap the two arms in `contextClaimAt` so the attribute
    // is tested first. Compiles. The point inside the hook's zone then
    // answers `canvas` instead of `node:near1` — red on the first
    // assertion, and the second (the decline case) still passes, which
    // is exactly why both are here.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    // Outer: a plain element carrying only the author's attribute.
    var outer = InputProbe{};
    var outer_hit = probeHit(&outer, &probe_input_only, 0, 0, 400, 400);
    outer_hit.context_subject = "panel";
    try sp.drawlist.hits.append(outer_hit);

    // Inner: a component whose hook answers inside a 20×20 zone and
    // declines outside it, AND which carries an attribute of its own.
    var inner = InputProbe{
        .subject = "node:near1",
        .subject_zone = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
    };
    var inner_hit = probeHit(&inner, &probe_context, 100, 100, 200, 200);
    inner_hit.context_subject = "canvas";
    try sp.drawlist.hits.append(inner_hit);

    // Inside the hook's zone: the hook wins over both attributes.
    try testing.expectEqualStrings("node:near1", sp.contextSubjectAt(105, 105).?);
    // Inside the inner box but outside the hook's zone: the hook
    // declines and the INNER attribute answers — not the outer one,
    // which would mean a decline had escaped the element entirely.
    try testing.expectEqualStrings("canvas", sp.contextSubjectAt(200, 200).?);
    // Outside the inner box: the outer element's attribute.
    try testing.expectEqualStrings("panel", sp.contextSubjectAt(10, 10).?);
    // Outside everything: nobody claims it.
    try testing.expect(sp.contextSubjectAt(900, 900) == null);
}

test "context: a subject that is not one word is refused, not emitted" {
    // The record is whitespace-delimited, so a subject with a space in
    // it does not produce a BROKEN record — it produces a valid one that
    // means something else, and the host reads `subject=my` and never
    // learns there was more. Loud, and the log line names the offending
    // text so the refusal lands on the component that wrote it.
    //
    // Mutation: delete the validation loop. Compiles, and the record is
    // written as `context subject=my node x=… y=…` — the
    // `expectError` goes red, and so does the assertion that nothing was
    // written.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;
    defer if (sp.context_path) |p| sp.allocator.free(p);
    try sp.setContextPath("ui.context");

    var p = InputProbe{ .subject = "my node" };
    try sp.drawlist.hits.append(contextProbeHit(&p, &probe_context, 0, 0, 400, 400));

    try testing.expectError(
        error.ContextSubjectNotOneWord,
        sp.dispatchMouseButtonN(50, 50, true, Spark.CONTEXT_BUTTON),
    );
    try testing.expect(st.get("ui.context") == null);
}

test "context: a host that named no path is inert, not broken" {
    // Same shape as `command_sink_fn`, and for the same reason: a
    // document carried between hosts should do nothing about the things
    // its host has not wired, rather than fail.
    //
    // Mutation: `const path = self.context_path orelse "context";` — a
    // plausible "sensible default". Compiles, and a host that never
    // asked for context records starts finding one in its root state
    // under a key it never chose. Red on the `count` assertion.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    var p = InputProbe{ .subject = "node:near1" };
    try sp.drawlist.hits.append(contextProbeHit(&p, &probe_context, 0, 0, 400, 400));

    try sp.dispatchMouseButtonN(50, 50, true, Spark.CONTEXT_BUTTON);
    try testing.expectEqual(@as(usize, 0), st.map.count());
}

test "context: a component that answers only the context question still gets a box" {
    // `wantsHitBox` is what puts a component on the hit layer, and a
    // component that is inert to the pointer but answers `context` — a
    // decorative block an author made right-clickable — is never asked
    // if it is not on it. The failure is silence, which is the same
    // failure the inline/block copies of that test used to have.
    //
    // This gate asserts the RULE rather than a walk, because the walk
    // needs a device. The mutation is in `element_layout.wantsHitBox`:
    // drop the `vtable.context_subject != null` clause. Compiles, and
    // `probe_context_only` stops being interactive — red.
    try testing.expect(element_layout.wantsHitBox(&probe_context_only));
    // …and a vtable with none of the four channels is still not.
    const inert = element.ElementVTable{ .layout_and_render = InputProbe.layoutAndRender };
    try testing.expect(!element_layout.wantsHitBox(&inert));
}

test "context: the record lands in the state of the element that claimed it" {
    // Same routing rule `dispatchHit` uses for input: an element inside
    // an `:::embedded-document` — or a panel that is its own Document —
    // carries that document's State on its Hit, and the record follows
    // it. A host running one Document per panel already has to know
    // this rule for input; making the context channel use a second one
    // would be two answers to "whose state is this".
    //
    // Mutation: write to `self.host_state` unconditionally — delete the
    // `if (claim.state)` branch. Compiles, and it is what the first
    // draft of `emitContext` did. The panel's own state stays empty and
    // the root gains a record it should never have seen: red on both
    // assertions.
    var root = state_mod.State.init(testing.allocator);
    defer root.deinit();
    var panel = state_mod.State.init(testing.allocator);
    defer panel.deinit();

    var sp = Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &root;
    defer if (sp.context_path) |p| sp.allocator.free(p);
    try sp.setContextPath("ui.context");

    var p = InputProbe{ .subject = "sphere:12" };
    var hit = probeHit(&p, &probe_context, 0, 0, 400, 400);
    hit.state = @ptrCast(&panel);
    try sp.drawlist.hits.append(hit);

    try sp.dispatchMouseButtonN(50, 50, true, Spark.CONTEXT_BUTTON);
    // Presence first, then content: the mutation below writes to the
    // root instead, and an unwrap of the panel'''s missing value would
    // abort rather than fail — red either way, but only one of those
    // says what went wrong.
    try testing.expect(panel.get("ui.context") != null);
    try testing.expectEqualStrings(
        "context subject=sphere:12 x=50.0 y=50.0 shift=0 ctrl=0 alt=0",
        panel.get("ui.context").?,
    );
    try testing.expect(root.get("ui.context") == null);
}

test "spark: forgetHits drops every pointer a torn-down document left behind" {
    // The contract, field by field. The SCENARIO — dispatch after a teardown —
    // cannot be gated here without performing the use-after-free it prevents,
    // so what is gated is that nothing survives the call, and the host's own
    // `Panel.close` is where it is wired.
    //
    // Mutation: drop the `drawlist.hits.clearRetainingCapacity()`. Red. Same
    // for each of the other three, one line each.
    var sp = Spark.testStub(testing.allocator);
    // `testStub` leaves most of a Spark `undefined` — it exists for gates that
    // only touch a field or two. The drawlist is one this gate touches.
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();

    var dummy: u8 = 0;
    const vt = element.ElementVTable{ .layout_and_render = struct {
        fn f(_: *anyopaque, o: [2]f32, _: element.Constraints, _: *element.LayoutCtx, _: *element.DrawList) anyerror!element.Box {
            return .{ .x = o[0], .y = o[1], .w = 0, .h = 0, .baseline = o[1] };
        }
    }.f };
    const fake = element.Hit{
        .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .vtable = &vt,
        .ctx = @ptrCast(&dummy),
        .state = @ptrCast(&dummy),
    };
    try sp.drawlist.hits.append(fake);
    try sp.drawlist.hits.append(fake);
    sp.captured = fake;
    sp.hovered = fake;
    sp.focused = fake;

    sp.forgetHits();

    try testing.expectEqual(@as(usize, 0), sp.drawlist.hits.items.len);
    try testing.expect(sp.captured == null);
    try testing.expect(sp.hovered == null);
    try testing.expect(sp.focused == null);
}
