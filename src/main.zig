//! text_engine_demo — Stage 1 of session 2:
//!
//! Same visual output as session 1 (heading + subtitle + mixed paragraph
//! + emoji line + rainbow SDF "ATTENTION"), but composed as an
//! `Element` tree and rendered through the new `element_layout` walker.
//! Sole point of the migration this stage: prove the contract holds
//! against session 1's content before adding markdown / ANSI engines on
//! top of it.
//!
//! The pulse-span trick from session 1 survives unchanged: layout the
//! top stack first, capture `glyphs.items.len`, then layout the SDF
//! paragraph — the new glyphs are the ones to animate. Phase B will
//! probably replace this with named ranges on the `DrawList`, but
//! it's not load-bearing for stage 1.

const std = @import("std");
const text_engine = @import("text_engine");
const win = @import("window.zig");
const vk = @import("gpu/vk.zig");
const swap = @import("gpu/swapchain.zig");
const renderer = @import("gpu/renderer.zig");
const atlas_mod = @import("gpu/atlas.zig");
const tp = @import("gpu/text_pipeline.zig");
const qp = @import("gpu/quad_pipeline.zig");
const tri_pipeline_mod = @import("gpu/tri_pipeline.zig");
const image_pipeline_mod = @import("gpu/image_pipeline.zig");
const face_mod = @import("font/face.zig");
const registry_mod = @import("font/registry.zig");
const glyph_cache_mod = @import("text/glyph_cache.zig");
const element = @import("element.zig");
const element_layout = @import("element_layout.zig");
const layout_cache_mod = @import("layout_cache.zig");
const markdown = @import("markdown.zig");
const ansi = @import("ansi.zig");
const component = @import("component.zig");
const box_component = @import("components/box.zig");
const button_component = @import("components/button.zig");
const chart_component = @import("components/chart.zig");
const embedded_document_component = @import("components/embedded_document.zig");
const input_component = @import("components/input.zig");
const llm_stream_component = @import("components/llm_stream.zig");
const slider_component = @import("components/slider.zig");
const svg_component = @import("components/svg.zig");
const svg_stream_component = @import("components/svg_stream.zig");
const image_stream_component = @import("components/image_stream.zig");
const state_mod = @import("state.zig");
const update = @import("update.zig");
const demo_server_mod = @import("demo_server.zig");
const jobs_mod = @import("jobs.zig");
const io_channel_mod = @import("io_channel.zig");
const dotenv_mod = @import("dotenv.zig");
const asset_cache_mod = @import("asset_cache.zig");
const svg_mod = @import("svg.zig");
const svg_tess = @import("svg_tessellate.zig");

/// Demo document — parsed by the vendored cmark + mapper into an
/// Element tree at startup. Same render path as the hand-built
/// torture trees of earlier stages; only the construction changed.
const demo_md = @embedFile("demo.md");

/// Small ANSI fixture rendered by `src/ansi.zig` after the markdown.
/// The `\x1b` escapes resolve at compile time to real ESC bytes
/// (0x1B), so the parser sees authentic terminal output. Exercises
/// 8-colour, 256-colour, truecolor, bold + italic, multi-line.
const ansi_demo =
    "\x1b[1;31m\xE2\x97\x8F\x1b[0m bold red    " ++
    "\x1b[1;32m\xE2\x97\x8F\x1b[0m bold green    " ++
    "\x1b[1;33m\xE2\x97\x8F\x1b[0m bold yellow\n" ++
    "\x1b[34mblue\x1b[0m  " ++
    "\x1b[38;5;202m256: orange\x1b[0m  " ++
    "\x1b[38;2;255;127;80mtrue: coral\x1b[0m  " ++
    "\x1b[3mitalic\x1b[0m\n";

// Mono atlas bumped 768 → 2048 once crisp-zoom landed: each visited
// zoom bucket adds a fresh rasterisation of every visible glyph, so
// the steady-state working set scales with `(# distinct zooms × #
// distinct fonts)`. 768² fit ≈ 4 zoom levels before AtlasFull tripped
// `runLayout`; 2048² (4 MB R8 — trivial on any modern GPU) holds ≈ 30
// zoom levels worth, comfortable for any plausible session. Eviction
// of cold buckets is the long-term answer — captured as a future task.
const ATLAS_MONO_SIZE: u32 = 2048;
const ATLAS_COLOR_SIZE: u32 = 1024;
// Stage 11 bumped MAX_GLYPHS from 2048 → 8192. The original
// session-1 ceiling was sized for the SDF + ANSI fixtures; once
// docs started embedding other docs (and the chart's column-strip
// chrome started co-existing with multi-paragraph prose) we tripped
// the cap, writeGlyphs silently failed, and drawCb early-returned
// every frame — visible as a black window. 8192 is comfortable
// headroom; bump again if/when doc density justifies.
const MAX_GLYPHS: u32 = 8192;
const MAX_QUADS: u32 = 2048;
// Stage 13d.1 caps. Petunias.svg flattens to ~5–10k triangles
// (verts + indices each ≈3× tri count for triangle lists).
// 65k / 196k is comfortable headroom for a few SVGs co-existing on
// screen; bump when document density justifies.
const MAX_TRI_VERTICES: u32 = 65536;
const MAX_TRI_INDICES: u32 = 196608;
/// Stage 14c — cap on concurrent `:::image-stream` components. Each
/// owns one descriptor slot from the ImagePipeline's pool. Bump if
/// the demo grows past this; the cost per slot is one VkDescriptorSet
/// (~16 bytes of GPU state + tracking).
const MAX_IMAGES: u32 = 32;

/// Per-frame context owned by main(), borrowed by `drawCb` through
/// the renderer's `*anyopaque` slot. Carries everything `drawCb`
/// needs to (a) detect viewport changes and re-run the layout pass,
/// (b) animate the SDF "ATTENTION" wave each frame.
///
/// **Resize policy.** Layout is event-driven, not per-frame: we
/// cache `last_extent`, and `drawCb` only re-runs the layout pass
/// when the swapchain's current extent differs. Steady-state at a
/// fixed window size is just animate + upload glyphs + record draw —
/// no HB reshaping, no atlas lookups, no token tree rebuild.
///
/// **Parse tree lifetime.** `top_stack` / `ansi_tree` / `sdf_block`
/// are constructed once at startup and stay valid for the lifetime
/// of the frame loop. The slices they reference live in
/// `doc_arena` which the host's main() owns. layoutAndRender reads
/// them each layout pass without mutating.
const FrameCtx = struct {
    // GPU
    text_pipeline: *tp.TextPipeline,
    quad_pipeline: *qp.QuadPipeline,
    tri_pipeline: *tri_pipeline_mod.TrianglePipeline,
    image_pipeline: *image_pipeline_mod.ImagePipeline,

    // Layout prerequisites (borrowed from main)
    allocator: std.mem.Allocator,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    theme: *const element.Theme,
    ansi_theme: *const element.Theme,

    // Parse trees (constructed once at startup)
    top_stack: element.Element,
    ansi_tree: element.Element,
    sdf_block: element.Element,

    // Mutable scratch — `dl` accumulates this layout pass's draw work
    dl: *element.DrawList,

    // Stage 14a — retained per-block layout cache. Owned by main;
    // cleared on theme swap / full re-parse (neither happens in the
    // current demo after startup). The walker consults this through
    // `LayoutCtx.cache_blocks` for every cacheable child of a stack_v
    // container — hits blit cached glyph/quad/tri/hit ranges with an
    // origin offset, misses fall through to a full walk and snapshot
    // the result back into the cache.
    block_cache: *layout_cache_mod.BlockCache,

    // Stage 14b — parallel cache-miss layout dispatch. JobSystem
    // fan-out plus a single mutex around the glyph cache + atlas
    // staging. Workers walk independent cache-miss blocks at origin
    // (0,0) into private DrawLists; main thread merges in order.
    job_system: *jobs_mod.JobSystem,
    glyph_cache_lock: *std.Thread.Mutex,

    // Cached viewport for resize detection. Starts at {0,0} so the
    // first `drawCb` call sees a mismatch and triggers the initial
    // layout, unifying init and resize paths.
    last_extent: vk.c.VkExtent2D = .{ .width = 0, .height = 0 },

    // Animation state — the SDF wave's index range comes out of
    // runLayout(); the wave function reads these to animate the
    // right glyphs each frame.
    pulse_start: u32 = 0,
    pulse_count: u32 = 0,
    start_ms: i64,

    // 7e: reactive state. The host owns it across the program
    // lifetime (extracted from demo.md's frontmatter at startup).
    // Mutations propagate through the registry's subscribers to
    // the cached component instances; the `dirty` flag triggers
    // re-layout.
    state: *state_mod.State,

    // 7f: input. Polled once per frame to detect button / position
    // transitions. `captured` holds the hit the most recent
    // mouse_down landed on — subsequent mouse_move + mouse_up go to
    // the same target regardless of containment (standard
    // pointer-capture pattern; otherwise drags break the moment the
    // cursor exits the thumb's box).
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    captured: ?element.Hit = null,

    // Stage 13c — keyboard focus. Set when a mouse_down lands on a
    // hit whose `focusable=true`; cleared on click-outside or Esc.
    // While non-null, GLFW key + char callbacks route here instead
    // of the scroll/zoom nav handler. Compared by `ctx` pointer
    // identity across re-layouts (component instances persist).
    focused: ?element.Hit = null,

    // Stage 11 lesson: SSBO overflow used to swallow itself via the
    // `catch return` in drawCb / runLayout, turning a 2048-glyph
    // ceiling into a silent black-screen. These flags log the first
    // failure of each kind to stderr so the next overflow can't
    // hide. A real surface (on-screen banner, telemetry) is the
    // proper long-term fix — TODO captured at the SSBO-emit sites.
    glyph_overflow_logged: bool = false,
    quad_overflow_logged: bool = false,
    tri_overflow_logged: bool = false,

    // Scroll + zoom (stage post-11, ad-hoc — the demo's full doc
    // height now exceeds typical viewport once embedded docs are
    // in). Plain scroll wheel → scroll_y; Ctrl+scroll → zoom.
    // Applied as a post-layout transform on DrawList glyphs + quads
    // (one O(N) pass per re-layout). World-space layout stays
    // unchanged; mouse coords un-transform for hit-test.
    //
    // Trade-off: pre-rasterized text becomes fuzzy at non-1.0 zoom
    // because we stretch bitmap glyphs. SDF text (ATTENTION) stays
    // crisp. Documented as v0 limitation — proper crisp-zoom is a
    // multi-size atlas + re-layout-on-zoom rebuild.
    /// Rendered scroll position — what the transform pass uses.
    /// Eased toward `target_scroll_y` each frame so wheel input
    /// floats to its destination instead of snapping.
    scroll_y: f32 = 0,
    /// Destination the scroll callback writes to. The tween in
    /// drawCb closes the gap toward it.
    target_scroll_y: f32 = 0,
    zoom: f32 = 1.0,
    max_scroll_y: f32 = 0,
    /// Wall-clock of the previous drawCb invocation, for time-
    /// based tween easing.
    last_frame_ms: i64 = 0,

    /// Re-run the layout pass for the current viewport. Clears the
    /// DrawList, lays out all three sub-trees at the new `max_w`,
    /// uploads the quads (static for the lifetime of a layout —
    /// they don't animate so we only push them when the layout
    /// changes), and caches the new pulse range.
    fn runLayout(self: *FrameCtx, extent: vk.c.VkExtent2D) !void {
        self.dl.clearRetainingCapacity();

        // Crisp-zoom prewarm. Worker threads can't safely grow the
        // FontRegistry (ArrayList realloc + HashMap put + shared
        // FT_Library use all race against other workers' reads). One
        // main-thread pass eagerly creates whatever effective entries
        // the upcoming layout will need at this zoom; workers then
        // only do read-only lookups against a frozen entries array.
        try self.fonts.prewarmEffectiveSizesForZoom(self.zoom);

        var lc = element.LayoutCtx{
            .allocator = self.allocator,
            .fonts = self.fonts,
            .cache = self.cache,
            .mono_atlas = self.mono_atlas,
            .color_atlas = self.color_atlas,
            .theme = self.theme,
            // Top-level walks stamp the host state onto every Hit
            // they emit. Embedded-doc layoutAndRender save+swap+
            // restores around its child subtree.
            .state = @ptrCast(self.state),
            .cache_blocks = self.block_cache,
            .job_system = self.job_system,
            .glyph_cache_lock = self.glyph_cache_lock,
            // Crisp-zoom: rasterise glyphs at zoom-scaled sizes so the
            // post-layout `× zoom` multiply samples each bitmap at 1:1.
            .zoom = self.zoom,
        };
        var ansi_lc = lc;
        ansi_lc.theme = self.ansi_theme;

        // 40px gutter on each side (in WORLD coords — gutters scale
        // with zoom alongside everything else, like a browser does);
        // clamp to a sane minimum so an accidentally-zero-width
        // extent (minimised window) doesn't wrap every word to its
        // own line forever. The viewport itself is divided by zoom
        // because layout runs in world coords and the post-pass
        // `× zoom` then takes world → screen — so at zoom=2 the
        // available world width is half the screen extent, and at
        // zoom=0.5 it's double.
        const w: f32 = @floatFromInt(extent.width);
        const viewport_world_w: f32 = w / self.zoom;
        const max_w: f32 = @max(viewport_world_w - 80.0, 200.0);
        const c: element.Constraints = .{ .max_w = max_w };

        // Layout in WORLD coordinates — no scroll/zoom applied here.
        // The transform pass at the bottom of this function maps
        // world → screen.
        const top_box = try element_layout.layoutAndRenderCached(self.top_stack, .{ 40, 40 }, c, &lc, self.dl);
        const ansi_box = try element_layout.layoutAndRenderCached(self.ansi_tree, .{ 40, top_box.y + top_box.h + 8 }, c, &ansi_lc, self.dl);

        self.pulse_start = @intCast(self.dl.glyphs.items.len);
        const sdf_box = try element_layout.layoutAndRenderCached(self.sdf_block, .{ 40, ansi_box.y + ansi_box.h }, c, &lc, self.dl);
        self.pulse_count = @intCast(self.dl.glyphs.items.len - self.pulse_start);

        // Recompute max scrollable distance from world content height
        // vs world-space viewport height (`viewport_h / zoom` because
        // the transform scales positions). Clamp current scroll if
        // it now exceeds the new max (e.g. content shortened).
        const content_bottom_world = sdf_box.y + sdf_box.h;
        const viewport_h_world: f32 = @as(f32, @floatFromInt(extent.height)) / self.zoom;
        const bottom_margin: f32 = 40;
        self.max_scroll_y = @max(@as(f32, 0), content_bottom_world + bottom_margin - viewport_h_world);
        if (self.scroll_y > self.max_scroll_y) self.scroll_y = self.max_scroll_y;
        if (self.scroll_y < 0) self.scroll_y = 0;

        // World → screen transform on DrawList. screen = (world - scroll) * zoom.
        // Single O(N) pass per layout — chart at 60Hz survives this comfortably.
        const sy = self.scroll_y;
        const z = self.zoom;
        for (self.dl.glyphs.items) |*g| {
            g.dst_pos[1] -= sy;
            g.dst_pos[0] *= z;
            g.dst_pos[1] *= z;
            g.dst_size[0] *= z;
            g.dst_size[1] *= z;
        }
        for (self.dl.quads.items) |*q| {
            q.dst_pos[1] -= sy;
            q.dst_pos[0] *= z;
            q.dst_pos[1] *= z;
            q.dst_size[0] *= z;
            q.dst_size[1] *= z;
            q.radius *= z;
        }
        // Same transform on triangle vertices — they live in world
        // space alongside quads + glyphs, and the tri shader expects
        // screen-space pixels just like the others.
        for (self.dl.tris.items) |*v| {
            v.pos[1] -= sy;
            v.pos[0] *= z;
            v.pos[1] *= z;
        }
        // Same transform on image draws — dst_pos/dst_size land at
        // the image pipeline as push constants in display pixels, so
        // we apply the scroll/zoom here for symmetry with quads.
        for (self.dl.images.items) |*im| {
            im.dst_pos[1] -= sy;
            im.dst_pos[0] *= z;
            im.dst_pos[1] *= z;
            im.dst_size[0] *= z;
            im.dst_size[1] *= z;
        }

        // Quads stay frozen between layouts (no animation on them);
        // upload once per layout instead of per frame.
        // TODO: surface SSBO overflow visibly — currently logged
        // once to stderr (in drawCb's writeGlyphs path) and silently
        // dropped here. A proper surface (overlay banner, telemetry)
        // beats hunting "why is the screen black".
        self.quad_pipeline.writeQuads(self.dl.quads.items) catch |err| {
            if (!self.quad_overflow_logged) {
                std.debug.print(
                    "WARN: quad write failed ({s}) — {d} quads (cap {d}). Bump MAX_QUADS or split passes. Logging suppressed for further frames.\n",
                    .{ @errorName(err), self.dl.quads.items.len, MAX_QUADS },
                );
                self.quad_overflow_logged = true;
            }
            return err;
        };

        // Stage 13d.1 — upload triangle mesh once per layout.
        // SVGs are static post-tessellation, so per-layout upload
        // is appropriate; if streamed re-tessellation lands (13d.3)
        // we'll reconsider.
        self.tri_pipeline.writeMesh(self.dl.tris.items, self.dl.tri_indices.items) catch |err| {
            if (!self.tri_overflow_logged) {
                std.debug.print(
                    "WARN: triangle write failed ({s}) — {d} verts / {d} indices (cap {d}/{d}). Bump MAX_TRI_*. Logging suppressed for further frames.\n",
                    .{ @errorName(err), self.dl.tris.items.len, self.dl.tri_indices.items.len, MAX_TRI_VERTICES, MAX_TRI_INDICES },
                );
                self.tri_overflow_logged = true;
            }
            return err;
        };
    }
};

fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const fc: *FrameCtx = @ptrCast(@alignCast(ctx.?));

    // ── Scroll tween ───────────────────────────────────────────────
    // Ease `scroll_y` toward `target_scroll_y` so wheel input floats
    // instead of snapping. Frame-rate-independent (uses wall-clock
    // dt). While the gap is open, mark state dirty so runLayout
    // re-applies the transform with the new offset; snap + stop
    // dirtying once within sub-pixel range.
    const now_ms = std.time.milliTimestamp();
    if (fc.last_frame_ms == 0) fc.last_frame_ms = now_ms;
    const dt_ms: f32 = @floatFromInt(@max(now_ms - fc.last_frame_ms, 0));
    fc.last_frame_ms = now_ms;
    if (@abs(fc.target_scroll_y - fc.scroll_y) > 0.25) {
        // tau = 60ms — about 100ms to converge visually. Decay
        // formula: alpha = 1 - exp(-dt/tau). Clamp dt at one frame
        // worth of decay so a hitched frame doesn't overshoot the
        // visual budget.
        const tau_ms: f32 = 60.0;
        const clamped_dt = @min(dt_ms, 50.0);
        const alpha = 1.0 - std.math.exp(-clamped_dt / tau_ms);
        fc.scroll_y += (fc.target_scroll_y - fc.scroll_y) * alpha;
        fc.state.dirty = true;
    } else if (fc.scroll_y != fc.target_scroll_y) {
        fc.scroll_y = fc.target_scroll_y;
        fc.state.dirty = true;
    }

    // ── Event-driven relayout ──────────────────────────────────────
    // Two triggers: viewport changed (resize), or state mutated
    // (input-driven via the slider component, stage 7f, or by the
    // scroll tween above). First call's last_extent={0,0}
    // guarantees an initial layout before the first draw.
    const extent_changed = extent.width != fc.last_extent.width or extent.height != fc.last_extent.height;
    if (extent_changed or fc.state.dirty) {
        fc.runLayout(extent) catch |err| switch (err) {
            error.AtlasFull => {
                // Coarse LRU: drop every cached glyph + reset both
                // atlases + clear the block-layout cache (its cached
                // GlyphInstance UVs point into the now-stale atlas
                // rects). Next layout re-rasterises only what the
                // current viewport actually needs — the working set
                // shrinks back to "visible glyphs at the current
                // zoom" instead of "every glyph at every zoom bucket
                // ever visited this session". One retry, then give up
                // gracefully if the single frame really doesn't fit.
                std.debug.print("INFO: AtlasFull at zoom={d:.3} — resetting glyph caches and retrying\n", .{fc.zoom});
                fc.cache.clear();
                fc.mono_atlas.reset() catch return;
                fc.color_atlas.reset() catch return;
                fc.block_cache.clear();
                fc.runLayout(extent) catch {
                    std.debug.print("WARN: runLayout still failing after atlas reset — dropping frame\n", .{});
                    return;
                };
            },
            else => {
                if (!fc.glyph_overflow_logged) {
                    std.debug.print("WARN: runLayout failed ({s}) at zoom={d:.3}, extent={d}x{d}\n", .{ @errorName(err), fc.zoom, extent.width, extent.height });
                    fc.glyph_overflow_logged = true;
                }
                return;
            },
        };
        fc.last_extent = extent;
        fc.state.clearDirty();
    }

    // ── Per-frame SDF wave animation ───────────────────────────────
    // Runs every frame; mutates the laid-out glyph slice in place
    // and re-uploads. Cheap — ~9 glyphs writing two fields each.
    const elapsed: f32 = @floatFromInt(std.time.milliTimestamp() - fc.start_ms);
    const t_sec: f32 = elapsed * 0.001;
    var i: u32 = 0;
    while (i < fc.pulse_count) : (i += 1) {
        const idx = fc.pulse_start + i;
        const phase = t_sec * 3.0 - @as(f32, @floatFromInt(i)) * 0.6;
        const w = (std.math.sin(phase) + 1.0) * 0.5;
        fc.dl.glyphs.items[idx].attention = w;

        const hue = @mod(@as(f32, @floatFromInt(i)) * 40.0 + t_sec * 30.0, 360.0);
        const rgb = hsvToRgb(hue, 0.85, 1.0);
        fc.dl.glyphs.items[idx].hot_color = .{ rgb[0], rgb[1], rgb[2], 1.0 };
    }
    // TODO: surface SSBO overflow visibly — currently logged once
    // to stderr and silently dropped. A proper surface (overlay
    // banner, telemetry) beats hunting "why is the screen black"
    // again. See stage-11 journey writeup.
    fc.text_pipeline.writeGlyphs(fc.dl.glyphs.items) catch |err| {
        if (!fc.glyph_overflow_logged) {
            std.debug.print(
                "WARN: glyph write failed ({s}) — {d} glyphs (cap {d}). Bump MAX_GLYPHS. Logging suppressed for further frames.\n",
                .{ @errorName(err), fc.dl.glyphs.items.len, MAX_GLYPHS },
            );
            fc.glyph_overflow_logged = true;
        }
        return;
    };

    // ── Record draws — quads first, glyphs on top ──────────────────
    // Triangles → images → quads → text. SVG fills + raster images
    // sit under quad chrome (panels, underlines) and below glyphs so
    // the document chrome reads on top of generated visuals.
    fc.tri_pipeline.recordDraw(cmd, extent, @intCast(fc.dl.tri_indices.items.len));
    if (fc.dl.images.items.len > 0) {
        fc.image_pipeline.bind(cmd, extent);
        for (fc.dl.images.items) |im| {
            fc.image_pipeline.recordOne(cmd, extent, @ptrCast(@alignCast(im.descriptor_set)), im.dst_pos, im.dst_size);
        }
    }
    fc.quad_pipeline.recordDraw(cmd, extent, @intCast(fc.dl.quads.items.len));
    fc.text_pipeline.recordDraw(cmd, extent, @intCast(fc.dl.glyphs.items.len));
}

// ── Input plumbing (stage 7f) ──────────────────────────────────────
//
// Poll-based: once per frame, ask glfw for the current cursor
// position + primary button state, diff against the previous frame,
// and synthesize InputEvents. Pointer-capture semantics: whichever
// hit the most recent mouse_down landed on receives every
// subsequent mouse_move + mouse_up until release, regardless of
// whether the cursor stays inside its box. Without this drags break
// at the boundary.

fn processInput(window: *win.Window, fc: *FrameCtx) !void {
    var x_raw: f64 = 0;
    var y_raw: f64 = 0;
    win.c.glfwGetCursorPos(window.handle, &x_raw, &y_raw);
    // Un-transform: screen mouse → world coords so hit-test compares
    // against the un-transformed Hit.box stored on the DrawList.
    // Inverse of `screen = (world - scroll) * zoom`:
    //   world = screen / zoom + scroll
    const x: f32 = @as(f32, @floatCast(x_raw)) / fc.zoom;
    const y: f32 = @as(f32, @floatCast(y_raw)) / fc.zoom + fc.scroll_y;
    const button_now = win.c.glfwGetMouseButton(window.handle, win.c.GLFW_MOUSE_BUTTON_LEFT) == win.c.GLFW_PRESS;

    const prev_down = fc.mouse_down;
    const moved = x != fc.mouse_x or y != fc.mouse_y;
    fc.mouse_x = x;
    fc.mouse_y = y;
    fc.mouse_down = button_now;

    if (button_now and !prev_down) {
        // Press transition. Hit-test in reverse so the deepest
        // (last-emitted) element wins; capture for the duration of
        // the press.
        const maybe_hit = findHit(fc.dl.hits.items, x, y);

        // Focus management. A click on a focusable hit grabs focus
        // (firing focus_lost on the prior holder if it changed). A
        // click anywhere else — non-focusable hit OR empty space —
        // clears focus. Identity is compared by ctx pointer because
        // Hit structs are rebuilt every layout but components
        // persist.
        const new_focus_ctx: ?*anyopaque = blk: {
            if (maybe_hit) |h| if (h.focusable) break :blk h.ctx;
            break :blk null;
        };
        const old_focus_ctx: ?*anyopaque = if (fc.focused) |f| f.ctx else null;
        if (new_focus_ctx != old_focus_ctx) {
            if (fc.focused) |old| dispatch(old, .focus_lost, fc.state) catch {};
            fc.focused = if (maybe_hit) |h| if (h.focusable) h else null else null;
            if (fc.focused) |new| dispatch(new, .focus_gained, fc.state) catch {};
        }

        if (maybe_hit) |hit| {
            fc.captured = hit;
            try dispatch(hit, .{ .mouse_down = .{
                .local = .{ x - hit.box.x, y - hit.box.y },
                .button = 0,
                .button_down = true,
            } }, fc.state);
        }
    } else if (button_now and prev_down and moved) {
        // Held + cursor moved → drag. Route to captured.
        if (fc.captured) |hit| {
            try dispatch(hit, .{ .mouse_move = .{
                .local = .{ x - hit.box.x, y - hit.box.y },
                .button = 0,
                .button_down = true,
            } }, fc.state);
        }
    } else if (!button_now and prev_down) {
        // Release transition.
        if (fc.captured) |hit| {
            try dispatch(hit, .{ .mouse_up = .{
                .local = .{ x - hit.box.x, y - hit.box.y },
                .button = 0,
                .button_down = false,
            } }, fc.state);
            fc.captured = null;
        }
    }
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

fn dispatch(hit: element.Hit, event: element.InputEvent, state: *state_mod.State) !void {
    const on_input = hit.vtable.on_input orelse return;
    // If the layout walk stamped a state pointer onto this Hit
    // (top-level → host state; embedded-doc → child state), use it.
    // Otherwise fall back to the dispatcher's default.
    const eff: *anyopaque = hit.state orelse @ptrCast(state);
    try on_input(hit.ctx, event, eff);
}

// GLFW key callback — keyboard equivalents of the mouse-wheel
// scroll / zoom inputs. PgUp/PgDn/Home/End drive scroll; Ctrl+= /
// Ctrl+- / Ctrl+0 drive zoom. Discrete steps, so they tween to the
// new target same as wheel input (drawCb's scroll easing handles
// both paths uniformly).
fn keyCb(window: ?*win.c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.C) void {
    if (action != win.c.GLFW_PRESS and action != win.c.GLFW_REPEAT) return;
    const ud = win.c.glfwGetWindowUserPointer(window);
    if (ud == null) return;
    const fc: *FrameCtx = @ptrCast(@alignCast(ud));

    // Esc always clears focus, regardless of who holds it.
    if (key == win.c.GLFW_KEY_ESCAPE and fc.focused != null) {
        const old = fc.focused.?;
        fc.focused = null;
        dispatch(old, .focus_lost, fc.state) catch {};
        fc.state.dirty = true;
        return;
    }

    // While a component holds focus (input field, etc.), keys go to
    // it. The nav handler (PgUp/PgDn/zoom) is suppressed so typing
    // into a field doesn't also scroll the page.
    if (fc.focused) |hit| {
        dispatch(hit, .{ .key_down = .{
            .key = @intCast(key),
            .mods = @intCast(mods),
        } }, fc.state) catch {};
        fc.state.dirty = true;
        return;
    }

    const ctrl = (mods & win.c.GLFW_MOD_CONTROL) != 0;

    if (ctrl) {
        switch (key) {
            // GLFW_KEY_EQUAL is the unshifted `=` key, which is
            // where `+` sits on US/UK keyboards — accept both forms
            // so Ctrl+= and Ctrl++ feel like the same gesture.
            win.c.GLFW_KEY_EQUAL, win.c.GLFW_KEY_KP_ADD => {
                fc.zoom = std.math.clamp(fc.zoom * 1.10, 0.25, 4.0);
                fc.state.dirty = true;
            },
            win.c.GLFW_KEY_MINUS, win.c.GLFW_KEY_KP_SUBTRACT => {
                fc.zoom = std.math.clamp(fc.zoom / 1.10, 0.25, 4.0);
                fc.state.dirty = true;
            },
            win.c.GLFW_KEY_0, win.c.GLFW_KEY_KP_0 => {
                fc.zoom = 1.0;
                fc.state.dirty = true;
            },
            else => {},
        }
        return;
    }

    // Non-Ctrl navigation: page / home / end. Page step ≈ viewport
    // height (less a slim overlap so the eye keeps continuity).
    const viewport_h: f32 = @as(f32, @floatFromInt(fc.last_extent.height)) / fc.zoom;
    const page: f32 = @max(viewport_h - 80, 100);
    switch (key) {
        win.c.GLFW_KEY_PAGE_DOWN => fc.target_scroll_y = std.math.clamp(fc.target_scroll_y + page, 0, fc.max_scroll_y),
        win.c.GLFW_KEY_PAGE_UP => fc.target_scroll_y = std.math.clamp(fc.target_scroll_y - page, 0, fc.max_scroll_y),
        win.c.GLFW_KEY_HOME => fc.target_scroll_y = 0,
        win.c.GLFW_KEY_END => fc.target_scroll_y = fc.max_scroll_y,
        else => return,
    }
}

// GLFW char callback — fires once per printable character (post-IME,
// post-shift composition). Routes to the focused component as a
// `char_input` event. Non-printable keys (arrows, enter, backspace)
// never reach here; they come through `keyCb` as `.key_down`.
fn charCb(window: ?*win.c.GLFWwindow, codepoint: c_uint) callconv(.C) void {
    const ud = win.c.glfwGetWindowUserPointer(window);
    if (ud == null) return;
    const fc: *FrameCtx = @ptrCast(@alignCast(ud));
    const hit = fc.focused orelse return;
    dispatch(hit, .{ .char_input = @intCast(codepoint) }, fc.state) catch {};
    fc.state.dirty = true;
}

// GLFW scroll callback. Ctrl-held → zoom; plain → vertical scroll.
// Reads FrameCtx from the window user pointer (set in main()).
//
// Sets `state.dirty` so drawCb's next frame triggers runLayout
// (which redoes the world→screen transform pass). Bounds clamped
// here so user input can't push them outside the legal range.
fn scrollCb(window: ?*win.c.GLFWwindow, _: f64, yoffset: f64) callconv(.C) void {
    const ud = win.c.glfwGetWindowUserPointer(window);
    if (ud == null) return;
    const fc: *FrameCtx = @ptrCast(@alignCast(ud));

    const ctrl = win.c.glfwGetKey(window, win.c.GLFW_KEY_LEFT_CONTROL) == win.c.GLFW_PRESS or
        win.c.glfwGetKey(window, win.c.GLFW_KEY_RIGHT_CONTROL) == win.c.GLFW_PRESS;

    if (ctrl) {
        const step: f32 = 1.10;
        const dy: f32 = @floatCast(yoffset);
        if (dy > 0) fc.zoom *= std.math.pow(f32, step, dy);
        if (dy < 0) fc.zoom /= std.math.pow(f32, step, -dy);
        fc.zoom = std.math.clamp(fc.zoom, 0.25, 4.0);
    } else {
        const px_per_notch: f32 = 60.0;
        fc.target_scroll_y -= @as(f32, @floatCast(yoffset)) * px_per_notch;
        // Clamp against the most recent layout's known max; runLayout
        // will clamp again once it has the new content height. The
        // tween in drawCb closes the gap toward target_scroll_y.
        fc.target_scroll_y = std.math.clamp(fc.target_scroll_y, 0, fc.max_scroll_y);
    }

    fc.state.dirty = true;
}

/// `IoChannel.drain` handler. Polymorphic dispatch through the
/// `PendingHeader` that every consumer puts as the first field of
/// its Pending struct (stage 13d.3). `user_data` is
/// `@intFromPtr(&pending)`; we read the first usize there and call
/// it. Adding a new consumer (svg-stream, future audio-stream)
/// doesn't touch this file.
fn drainHandler(_: *io_channel_mod.IoChannel, comp: io_channel_mod.Completion) void {
    const header: *const io_channel_mod.PendingHeader = @ptrFromInt(comp.user_data);
    header.handle_completion(comp);
}

/// HSV → RGB conversion using the standard six-sextant formula. `h`
/// is degrees [0, 360); `s` and `v` are [0, 1]. Used by the demo to
/// paint each animated SDF glyph with its own rainbow hue.
/// Stage 13d.2 — measure tessellation cost serial vs parallel.
/// Runs once at startup on the Petunias.svg fixture so we have a
/// concrete speedup number for the journey doc and a regression
/// signal if the JobSystem ever stops scaling. ~10 ms total; pure
/// startup-time cost, no impact on the render loop.
fn runTessellationBenchmark(
    allocator: std.mem.Allocator,
    source: []const u8,
    job_system: *jobs_mod.JobSystem,
    stdout: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const doc = try svg_mod.parse(arena.allocator(), source);

    const t0 = std.time.nanoTimestamp();
    var serial_mesh = svg_tess.Mesh.init(allocator);
    defer serial_mesh.deinit();
    try svg_tess.tessellateSerial(allocator, doc.paths, &serial_mesh, .{});
    const t1 = std.time.nanoTimestamp();

    var parallel_mesh = svg_tess.Mesh.init(allocator);
    defer parallel_mesh.deinit();
    try svg_tess.tessellateParallel(allocator, doc.paths, &parallel_mesh, job_system, .{});
    const t2 = std.time.nanoTimestamp();

    const serial_us: f64 = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    const parallel_us: f64 = @as(f64, @floatFromInt(t2 - t1)) / 1000.0;
    const speedup: f64 = if (parallel_us > 0) serial_us / parallel_us else 0;
    try stdout.print(
        "  svg tessellate ({d} paths, {d} tris): serial {d:.1} us, parallel {d:.1} us → {d:.2}x\n",
        .{
            doc.paths.len,
            serial_mesh.indices.items.len / 3,
            serial_us,
            parallel_us,
            speedup,
        },
    );
}

fn hsvToRgb(h_deg: f32, s: f32, v: f32) [3]f32 {
    const c = v * s;
    const h_prime = @mod(h_deg / 60.0, 6.0);
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m = v - c;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (h_prime < 1.0) {
        r = c;
        g = x;
    } else if (h_prime < 2.0) {
        r = x;
        g = c;
    } else if (h_prime < 3.0) {
        g = c;
        b = x;
    } else if (h_prime < 4.0) {
        g = x;
        b = c;
    } else if (h_prime < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{ r + m, g + m, b + m };
}

/// XDG-style cache directory for persistent assets. Honours
/// `$XDG_CACHE_HOME` if set; otherwise falls back to `$HOME/.cache`.
/// Returns an owned path; caller frees via `allocator.free`.
fn computeAssetCacheDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg| {
        defer allocator.free(xdg);
        return try std.fs.path.join(allocator, &.{ xdg, "text_engine", "assets" });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".cache", "text_engine", "assets" });
}

/// XDG-style state file for persistent reactive-state values. Honours
/// `$XDG_STATE_HOME` if set; otherwise falls back to
/// `$HOME/.local/state`. State (slider positions, input contents) is
/// user data, not regenerable cache — XDG conventions put it under a
/// different root so `rm -rf ~/.cache` doesn't lose it.
fn computeStateFilePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg| {
        defer allocator.free(xdg);
        return try std.fs.path.join(allocator, &.{ xdg, "text_engine", "state.json" });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".local", "state", "text_engine", "state.json" });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("text_engine demo — session 9 / stage 14f (cost-aware parallel-walk classification)\n", .{});
    try stdout.print("  vertex SPIR-V bytes:   {d}\n", .{text_engine.shaders.text_vert.len});
    try stdout.print("  fragment SPIR-V bytes: {d}\n", .{text_engine.shaders.text_frag.len});
    try stdout.print("  demo.md bytes:         {d}\n", .{demo_md.len});

    var window = try win.Window.init(1280, 720, "text_engine_demo");
    defer window.deinit();

    var ctx = try vk.Context.init(allocator, &window, "text_engine_demo");
    defer ctx.deinit();
    try stdout.print("  vulkan device:         {s}\n", .{std.mem.sliceTo(ctx.deviceName(), 0)});

    var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
    defer swapchain.deinit();

    var atlas_mono = try atlas_mod.Atlas.init(&ctx, ATLAS_MONO_SIZE, ATLAS_MONO_SIZE, .mono_r8);
    defer atlas_mono.deinit();
    var atlas_color = try atlas_mod.Atlas.init(&ctx, ATLAS_COLOR_SIZE, ATLAS_COLOR_SIZE, .color_rgba8);
    defer atlas_color.deinit();

    var pipeline = try tp.TextPipeline.init(&ctx, swapchain.format, &atlas_mono, &atlas_color, MAX_GLYPHS);
    defer pipeline.deinit();

    var quad_pipeline = try qp.QuadPipeline.init(&ctx, swapchain.format, MAX_QUADS);
    defer quad_pipeline.deinit();

    var tri_pipeline_inst = try tri_pipeline_mod.TrianglePipeline.init(
        &ctx,
        swapchain.format,
        MAX_TRI_VERTICES,
        MAX_TRI_INDICES,
    );
    defer tri_pipeline_inst.deinit();

    // Stage 14c — image pipeline for `:::image-stream`. Owns the
    // descriptor pool sized to MAX_IMAGES; each component allocates
    // one slot.
    var image_pipeline_inst = try image_pipeline_mod.ImagePipeline.init(
        &ctx,
        swapchain.format,
        MAX_IMAGES,
    );
    defer image_pipeline_inst.deinit();

    const font_path = std.posix.getenv("TEXT_ENGINE_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans.ttf";
    const italic_path = std.posix.getenv("TEXT_ENGINE_ITALIC_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf";
    const bold_path = std.posix.getenv("TEXT_ENGINE_BOLD_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf";
    const bold_italic_path = std.posix.getenv("TEXT_ENGINE_BOLD_ITALIC_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans-BoldOblique.ttf";
    const mono_path = std.posix.getenv("TEXT_ENGINE_MONO_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf";
    const emoji_path = std.posix.getenv("TEXT_ENGINE_EMOJI_FONT") orelse
        "/usr/share/fonts/noto/NotoColorEmoji.ttf";

    var ft = try face_mod.Library.init();
    defer ft.deinit();

    var fonts = registry_mod.FontRegistry.init(allocator, ft);
    defer fonts.deinit();

    const h1_id = try fonts.load(font_path.ptr, 48);
    const h2_id = try fonts.load(font_path.ptr, 32);
    const h3_id = try fonts.load(font_path.ptr, 24);
    const body_id = try fonts.load(font_path.ptr, 20);
    const italic_id = try fonts.load(italic_path.ptr, 20);
    const bold_id = try fonts.load(bold_path.ptr, 20);
    const bold_italic_id = try fonts.load(bold_italic_path.ptr, 20);
    const code_inline_id = try fonts.load(mono_path.ptr, 20);
    const code_block_id = try fonts.load(mono_path.ptr, 18);
    const emoji_id = try fonts.load(emoji_path.ptr, 28);
    const sdf_id = try fonts.loadSdf(font_path.ptr, 44);

    var cache = glyph_cache_mod.GlyphCache.init(allocator);
    defer cache.deinit();

    // ── Build the Theme ────────────────────────────────────────────
    // Single visual policy the rest of the demo cascades from. Stage
    // 3's markdown parser will look the same — load fonts, build a
    // Theme, hand it to LayoutCtx, parser uses `theme.apply*` to
    // resolve inline cascade onto text leaves.
    const white: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const heading_color: [4]f32 = .{ 0.95, 0.96, 0.99, 1.0 };
    const heading_dim: [4]f32 = .{ 0.78, 0.83, 0.92, 1.0 };
    const marker_color: [4]f32 = .{ 0.65, 0.72, 0.85, 1.0 };

    const theme: element.Theme = .{
        .body = .{ .font_id = body_id, .color = white },
        .heading = .{
            .{ .font_id = h1_id, .color = heading_color }, // h1
            .{ .font_id = h2_id, .color = heading_color }, // h2
            .{ .font_id = h3_id, .color = heading_dim }, // h3
            .{ .font_id = h3_id, .color = heading_dim }, // h4
            .{ .font_id = h3_id, .color = heading_dim }, // h5
            .{ .font_id = h3_id, .color = heading_dim }, // h6
        },
        .code_block = .{ .font_id = code_block_id, .color = .{ 0.72, 0.88, 1.0, 1.0 } },
        .list_marker = .{ .font_id = body_id, .color = marker_color },
        .emphasis_font_id = italic_id,
        .strong_font_id = bold_id,
        .bold_italic_font_id = bold_italic_id,
        .code_inline_font_id = code_inline_id,
        // Emoji fallback (stage 5c). The markdown parser scans every
        // text leaf and splits on coverage: Latin + symbols stay with
        // the primary cascade font; pictographic codepoints route to
        // this colour-emoji entry. The inline-flow walker treats the
        // resulting mixed-font runs the same as emphasis / strong.
        .fallback_font_id = emoji_id,
        .font_registry = &fonts,
    };

    // ── Component registry (stage 7b) ──────────────────────────────
    // Owned by the host across the entire program lifetime so cached
    // component instances persist over re-parses. Box factory
    // registered at 7c; 3d-scene and chart factories still missing
    // (their `:::` blocks render as red placeholders).
    var registry = component.Registry.init(allocator);
    defer registry.deinit();
    try registry.register("box", box_component.factory);
    try registry.register("chart", chart_component.factory);
    try registry.register("slider", slider_component.factory);
    try button_component.install(&registry);
    defer button_component.deinitGlobals();
    // input_component install needs parent_state — we know
    // host_state lives long enough (declared just below this block)
    // so we move the install to after host_state init. See below.
    // Embedded-document factory needs theme + registry + parent
    // state captured at install time — see embedded_document.zig's
    // "module-globals smell" note for why.

    // ── Host-owned reactive state (stage 7e) ───────────────────────
    // Frontmatter parses once at startup; the State persists across
    // the program's lifetime. drawCb mutates it on a timer and the
    // registry's subscriber wiring propagates changes into the
    // cached component instances.
    var host_state = (try state_mod.fromSource(allocator, demo_md)) orelse state_mod.State.init(allocator);
    defer host_state.deinit();

    // ── Stage 13b.2 — persistent state ─────────────────────────────
    // Load previous session's state values (slider positions, button
    // bodies, input contents) on top of the frontmatter defaults so a
    // restart picks up where the user left off. Throttled save runs
    // from the main loop every PERSIST_INTERVAL_FRAMES if dirty.
    const state_path = try computeStateFilePath(allocator);
    defer allocator.free(state_path);
    host_state.loadFromFile(state_path) catch |e| switch (e) {
        error.FileNotFound => {
            try stdout.print("  state file:           (none yet) — first run\n", .{});
        },
        else => try stdout.print("  state file:           {s} (load failed: {s})\n", .{ state_path, @errorName(e) }),
    };

    // ── Stage 12 — async I/O channel ───────────────────────────────
    // Work-stealing thread pool + fire-and-forget IoChannel sit
    // between the renderer and any blocking I/O (HTTP fetches today;
    // LLM streams + file watcher + MCP pipes soon). Owned by main
    // so worker threads outlive the renderer; deinit order is
    // strictly reverse-of-init to make sure workers join before the
    // channel's completion queue is freed.
    //
    // ── Stage 14d — split compute and I/O pools ────────────────────
    // The compute `job_system` sizes itself to `cpu_count - 2` and
    // hosts parallel layout / SVG tessellation / future work. Blocking
    // HTTP streams (5-15s on the wire each) get their own pool sized
    // for *concurrency* — workers parked on `req.read` cost nothing,
    // so we can afford 24 slots without contending with compute. This
    // unparks stage 14b: with the parallel walker no longer fighting
    // 5 stream workers for the same 6 deque slots, dispatch becomes
    // safe again.
    const job_system = try jobs_mod.JobSystem.init(allocator, 0);
    defer job_system.deinit();
    const io_pool = try jobs_mod.JobSystem.init(allocator, 24);
    defer io_pool.deinit();
    var io_channel = io_channel_mod.IoChannel.init(allocator, io_pool);
    defer io_channel.deinit();

    // Stage 9 — install the embedded-document factory now that theme
    // + registry + parent state + io_channel all exist. Has to
    // happen before any parse runs.
    // ── Stage 13a.5 — env loader ───────────────────────────────────
    // `~/.env`'s KEY=VALUE pairs land in `env`, which the llm-stream
    // factory pulls API keys from at create-time. Missing file is
    // silent — the factory just rejects an `api_key_env=` attr it
    // can't resolve.
    var env = dotenv_mod.DotEnv.init(allocator);
    defer env.deinit();
    env.loadDefault() catch |e| {
        try stdout.print("  ~/.env load:          {s} (continuing)\n", .{@errorName(e)});
    };

    // ── Stage 14e — persistent asset cache ─────────────────────────
    // Browser-style content-addressable cache for expensive remote
    // assets (Recraft SVG envelopes, Gemini image envelopes). Keyed
    // on sha256(provider | model | prompt) by each consumer; cache
    // hits skip the network entirely. Default budget 500 MB; LRU
    // eviction on overflow.
    const asset_cache_dir = try computeAssetCacheDir(allocator);
    defer allocator.free(asset_cache_dir);
    const asset_cache = try asset_cache_mod.AssetCache.init(allocator, asset_cache_dir, 500 * 1024 * 1024);
    defer asset_cache.deinit();
    {
        const s = asset_cache.stats();
        try stdout.print(
            "  asset cache:          {d} entries / {d:.1} MB / {d:.0} MB budget @ {s}\n",
            .{
                s.entry_count,
                @as(f64, @floatFromInt(s.total_bytes)) / (1024.0 * 1024.0),
                @as(f64, @floatFromInt(s.budget_bytes)) / (1024.0 * 1024.0),
                asset_cache_dir,
            },
        );
    }

    try embedded_document_component.install(&registry, &theme, &host_state, &io_channel);
    defer embedded_document_component.deinitGlobals();
    try llm_stream_component.install(&registry, &theme, &host_state, &io_channel, &env);
    defer llm_stream_component.deinitGlobals();
    try input_component.install(&registry, &host_state);
    defer input_component.deinitGlobals();
    try svg_component.install(&registry, job_system);
    defer svg_component.deinitGlobals();
    try svg_stream_component.install(&registry, &host_state, &io_channel, &env, job_system, asset_cache);
    defer svg_stream_component.deinitGlobals();
    try image_stream_component.install(&registry, &host_state, &io_channel, &env, &ctx, &image_pipeline_inst, asset_cache);
    defer image_stream_component.deinitGlobals();

    // Stage 13d.2 — micro-benchmark serial vs parallel tessellation
    // on Petunias.svg before the markdown parse begins. Runs once at
    // startup so the journey doc has a concrete speedup number; cost
    // is ~10 ms total which is invisible in the startup banner.
    // (Skip if the file isn't there — keeps the demo bootable when
    // a host strips test_data.)
    if (std.fs.cwd().readFileAlloc(allocator, "src/test_data/Petunias.svg", 4 * 1024 * 1024)) |source| {
        defer allocator.free(source);
        runTessellationBenchmark(allocator, source, job_system, stdout) catch |e| {
            try stdout.print("  svg bench skipped: {s}\n", .{@errorName(e)});
        };
    } else |_| {}

    // Stage 11 — spin up the local demo HTTP server BEFORE the parse
    // so the remote :::embedded-document fetch succeeds. Listens on
    // 127.0.0.1:8080 serving src/widgets/. Stopped at scope exit
    // (which joins the worker thread cleanly via socket close).
    const demo_server = try demo_server_mod.Server.start(allocator, "src/widgets", 8080);
    defer demo_server.stop();

    // ── Parse demo.md into an Element tree ─────────────────────────
    // All slices + strings the tree references live in `doc_arena`;
    // freed in one shot at scope exit. The parser also frees the
    // cmark AST internally before returning — only Zig-managed
    // memory survives the call.
    var doc_arena = std.heap.ArenaAllocator.init(allocator);
    defer doc_arena.deinit();
    const top_stack = try markdown.parseWithState(doc_arena.allocator(), demo_md, &theme, &registry, &host_state);

    // SDF "ATTENTION" paragraph — separate from the top stack so we
    // can capture the glyph index range for per-frame animation.
    // Default per-span `attention = 0.5`; the frame loop overwrites
    // each glyph's `.attention` individually for the wave.
    const sdf_children = [_]element.Element{
        .{ .text = .{ .content = "ATTENTION", .style = .{
            .font_id = sdf_id,
            .color = white,
            .attention = 0.5,
        } } },
    };
    const sdf_block = element.Element{ .paragraph = &sdf_children };

    // ── Parse-time content (constructed once, re-laid each resize) ─
    var dl = element.DrawList.init(allocator);
    defer dl.deinit();

    // Stage 14a — retained per-block layout cache. Reused across every
    // re-layout pass; lives for the program lifetime. See
    // `layout_cache.zig` for the cacheability rules — built-in
    // paragraph/heading/code_block/thematic_break participate
    // automatically; custom components opt in via vtable.content_version
    // and out via vtable.disable_cache.
    var block_cache = layout_cache_mod.BlockCache.init(allocator);
    defer block_cache.deinit();

    // Stage 14b — mutex around the (FreeType glyph slot + GlyphCache
    // hashmap + Atlas packing) write surface. Worker threads doing
    // parallel cache-miss layouts acquire it inside
    // `text_layout.appendShapedRun` around each `getOrRasterize` call.
    // Lives next to block_cache so its lifetime matches the layout
    // pipeline; uncontested cost is a single atomic compare-exchange.
    var glyph_cache_lock = std.Thread.Mutex{};

    // ANSI uses a mono-bodied derivation of the theme so spacing is
    // terminal-like. Bold + italic still fall back to the proportional
    // variants of the main theme — mono bold / italic font loads are
    // a future refinement.
    var ansi_theme = theme;
    ansi_theme.body = .{ .font_id = code_inline_id, .color = .{ 0.92, 0.94, 0.98, 1.0 } };
    const ansi_tree = try ansi.parse(doc_arena.allocator(), ansi_demo, &ansi_theme);

    // Tree swap is complete — no live Element references the old
    // (non-existent, this is the first parse) cached instances. Any
    // future re-parse would do the same gc() right after replacing
    // the tree pointer.
    registry.gc();

    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    const start_ms = std.time.milliTimestamp();
    var frame_ctx = FrameCtx{
        .text_pipeline = &pipeline,
        .quad_pipeline = &quad_pipeline,
        .tri_pipeline = &tri_pipeline_inst,
        .image_pipeline = &image_pipeline_inst,
        .allocator = allocator,
        .fonts = &fonts,
        .cache = &cache,
        .mono_atlas = &atlas_mono,
        .color_atlas = &atlas_color,
        .theme = &theme,
        .ansi_theme = &ansi_theme,
        .top_stack = top_stack,
        .ansi_tree = ansi_tree,
        .sdf_block = sdf_block,
        .dl = &dl,
        .block_cache = &block_cache,
        .job_system = job_system,
        .glyph_cache_lock = &glyph_cache_lock,
        .start_ms = start_ms,
        .state = &host_state,
    };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&frame_ctx);

    // Scroll + ctrl-scroll-zoom + keyboard navigation: register
    // both glfw callbacks and stash the FrameCtx on the window's
    // user-pointer so they can find it without a global.
    win.c.glfwSetWindowUserPointer(window.handle, @ptrCast(&frame_ctx));
    _ = win.c.glfwSetScrollCallback(window.handle, scrollCb);
    _ = win.c.glfwSetKeyCallback(window.handle, keyCb);
    _ = win.c.glfwSetCharCallback(window.handle, charCb);

    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "TEXT_ENGINE_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;

    // ── Stage 8a — update micro-stream demo ────────────────────────
    // Every UPDATE_CYCLE_MS, build a synthetic `:::update {...}` byte
    // stream and pipe it through `update.applyAll`. The directive
    // targets the box's `state.box_color` (state-target path), which
    // walks the existing reactive plumbing from 7e: state.set fires
    // the registry's Binding subscriber, which re-substitutes the
    // cached :::box instance's templated `${state.box_color}` attr
    // and calls factory.update with a fresh color.
    //
    // Reusing a single arena across cycles + resetting `retain_capacity`
    // means steady-state allocation is zero after the first cycle —
    // the parse + dispatch path stays inside the cached pages.
    //
    // (Component-target dispatch is covered by unit tests; visible
    // demo uses state-target because the box's color attr is
    // templated, so a component-target `set-color` would get stomped
    // by the next Binding.refire. Non-templated components are the
    // natural home for direct component-target updates — and the
    // upcoming `:::chart` will be the showcase.)
    var update_arena = std.heap.ArenaAllocator.init(allocator);
    defer update_arena.deinit();
    const UPDATE_CYCLE_MS: i64 = 1500;
    const cycle_colors = [_][]const u8{ "blue", "purple", "cyan", "green", "orange" };
    var color_idx: usize = 0;
    var last_update_ms = std.time.milliTimestamp();

    // Stage 8b — :::chart synthetic feed. 60 Hz tick rate (sample
    // ~every 16ms); each tick emits a `:::update {#telemetry
    // action=append}` directive through the same `update.applyAll`
    // hot path the colour cycle uses. The chart's `handle_update`
    // pushes the sample onto its ring buffer; `state.dirty` flips,
    // re-layout fires, the new column shows up next frame.
    //
    // The data signal layers three sines at different frequencies
    // plus low-amplitude noise to make the trace visually rich. A
    // pure constant or a single sine would look like a steady line
    // — not a useful demo of "live streaming data".
    const CHART_TICK_MS: i64 = 16;
    var last_chart_ms = std.time.milliTimestamp();
    var chart_phase: f32 = 0;
    var chart_rng = std.Random.DefaultPrng.init(0xC04EE);

    // Steady-state loop: poll glfw + present. All layout +
    // animation + upload + record work lives in `drawCb` now,
    // keyed off the swapchain's current `extent` so it auto-reflows
    // when the user resizes the window.
    var frame_count: u64 = 0;
    var update_count: u64 = 0;
    while (!window.shouldClose()) {
        window.pollEvents();
        processInput(&window, &frame_ctx) catch {};

        // Stage 12 — drain async I/O completions. Each completion is
        // routed to its originating component (today: only
        // embedded-document fetches); the handler may mark state
        // dirty, which the renderer picks up below.
        _ = io_channel.drain(&io_channel, drainHandler);

        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_update_ms >= UPDATE_CYCLE_MS) {
            color_idx = (color_idx + 1) % cycle_colors.len;
            var buf: [256]u8 = undefined;
            const directive = std.fmt.bufPrint(&buf,
                \\:::update {{target=state.box_color}}
                \\{s}
                \\:::
                \\
            , .{cycle_colors[color_idx]}) catch unreachable;
            const n = update.applyAll(update_arena.allocator(), &host_state, &registry, directive) catch 0;
            update_count += n;
            _ = update_arena.reset(.retain_capacity);
            last_update_ms = now_ms;
        }

        if (now_ms - last_chart_ms >= CHART_TICK_MS) {
            chart_phase += 0.06;
            const base = std.math.sin(chart_phase);
            const harmonic = 0.40 * std.math.sin(chart_phase * 3.1);
            const detail = 0.18 * std.math.sin(chart_phase * 7.7);
            const noise = (chart_rng.random().float(f32) - 0.5) * 0.15;
            const sample = std.math.clamp(base * 0.6 + harmonic + detail + noise, -1.0, 1.0);

            var buf: [128]u8 = undefined;
            const directive = std.fmt.bufPrint(&buf,
                \\:::update {{#telemetry action=append}}
                \\{d:.4}
                \\:::
                \\
            , .{sample}) catch unreachable;
            const n = update.applyAll(update_arena.allocator(), &host_state, &registry, directive) catch 0;
            update_count += n;
            _ = update_arena.reset(.retain_capacity);
            last_chart_ms = now_ms;
        }

        try rdr.drawFrame();
        frame_count += 1;

        // Stage 13b.2 — throttled state flush. Slider drags fire
        // state.set at ~60 Hz; we don't want a file write per drag
        // event. Coalesce by checking every PERSIST_INTERVAL_FRAMES
        // (~1s at 60 fps; faster at high refresh) and flush if
        // anything changed since the last write. The final flush at
        // shutdown catches the tail.
        const PERSIST_INTERVAL_FRAMES: u64 = 60;
        if (frame_count % PERSIST_INTERVAL_FRAMES == 0 and host_state.persist_dirty) {
            host_state.saveToFile(state_path) catch |e| {
                std.log.warn("state save failed: {s}", .{@errorName(e)});
            };
            host_state.clearPersistDirty();
        }

        if (exit_after_ms) |limit| {
            if (std.time.milliTimestamp() - frame_ctx.start_ms >= limit) break;
        }
    }

    // Final flush on graceful exit so the last <1s of mutations land.
    if (host_state.persist_dirty) {
        host_state.saveToFile(state_path) catch |e| {
            std.log.warn("state final flush failed: {s}", .{@errorName(e)});
        };
        host_state.clearPersistDirty();
    }

    const elapsed_ms = std.time.milliTimestamp() - frame_ctx.start_ms;
    try stdout.print("  glyphs:                {d} (pulse span: {d} glyphs)\n", .{
        frame_ctx.dl.glyphs.items.len,
        frame_ctx.pulse_count,
    });
    try stdout.print("  quads:                 {d}\n", .{frame_ctx.dl.quads.items.len});
    try stdout.print("  glyph cache:           {d} miss / {d} hit ({d:.1}% hit rate)\n", .{
        cache.misses,
        cache.hits,
        cache.hitRate() * 100.0,
    });
    try stdout.print("  layout cache:          {d} hit / {d} miss / {d} skip ({d:.1}% hit rate, {d} entries)\n", .{
        block_cache.hits,
        block_cache.misses,
        block_cache.skipped,
        block_cache.hitRate() * 100.0,
        block_cache.entries.count(),
    });
    try stdout.print("  frames:                {d} in {d}ms ({d:.1} fps)\n", .{
        frame_count,
        elapsed_ms,
        if (elapsed_ms > 0) @as(f64, @floatFromInt(frame_count)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms)) else 0,
    });
    try stdout.print("  updates applied:       {d} via :::update wire format\n", .{update_count});
}
