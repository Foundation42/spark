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
const face_mod = @import("font/face.zig");
const registry_mod = @import("font/registry.zig");
const glyph_cache_mod = @import("text/glyph_cache.zig");
const element = @import("element.zig");
const element_layout = @import("element_layout.zig");
const markdown = @import("markdown.zig");
const ansi = @import("ansi.zig");
const component = @import("component.zig");

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

const ATLAS_MONO_SIZE: u32 = 768;
const ATLAS_COLOR_SIZE: u32 = 1024;
const MAX_GLYPHS: u32 = 2048;
const MAX_QUADS: u32 = 2048;

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

    /// Re-run the layout pass for the current viewport. Clears the
    /// DrawList, lays out all three sub-trees at the new `max_w`,
    /// uploads the quads (static for the lifetime of a layout —
    /// they don't animate so we only push them when the layout
    /// changes), and caches the new pulse range.
    fn runLayout(self: *FrameCtx, extent: vk.c.VkExtent2D) !void {
        self.dl.clearRetainingCapacity();

        var lc = element.LayoutCtx{
            .allocator = self.allocator,
            .fonts = self.fonts,
            .cache = self.cache,
            .mono_atlas = self.mono_atlas,
            .color_atlas = self.color_atlas,
            .theme = self.theme,
        };
        var ansi_lc = lc;
        ansi_lc.theme = self.ansi_theme;

        // 40px gutter on each side; clamp to a sane minimum so an
        // accidentally-zero-width extent (minimised window) doesn't
        // wrap every word to its own line forever.
        const w: f32 = @floatFromInt(extent.width);
        const max_w: f32 = @max(w - 80.0, 200.0);
        const c: element.Constraints = .{ .max_w = max_w };

        const top_box = try element_layout.layoutAndRender(self.top_stack, .{ 40, 40 }, c, &lc, self.dl);
        const ansi_box = try element_layout.layoutAndRender(self.ansi_tree, .{ 40, top_box.y + top_box.h + 8 }, c, &ansi_lc, self.dl);

        self.pulse_start = @intCast(self.dl.glyphs.items.len);
        _ = try element_layout.layoutAndRender(self.sdf_block, .{ 40, ansi_box.y + ansi_box.h }, c, &lc, self.dl);
        self.pulse_count = @intCast(self.dl.glyphs.items.len - self.pulse_start);

        // Quads stay frozen between layouts (no animation on them);
        // upload once per layout instead of per frame.
        try self.quad_pipeline.writeQuads(self.dl.quads.items);
    }
};

fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const fc: *FrameCtx = @ptrCast(@alignCast(ctx.?));

    // ── Event-driven relayout ──────────────────────────────────────
    // Compare against cached extent; relayout only when the viewport
    // actually changed. First call's last_extent={0,0} guarantees
    // an initial layout before the first draw.
    if (extent.width != fc.last_extent.width or extent.height != fc.last_extent.height) {
        fc.runLayout(extent) catch {
            // SsboOverflow / AtlasFull etc. — drop this frame quietly.
            // A production path would surface this; for the demo we
            // never approach the caps so it shouldn't fire.
            return;
        };
        fc.last_extent = extent;
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
    fc.text_pipeline.writeGlyphs(fc.dl.glyphs.items) catch return;

    // ── Record draws — quads first, glyphs on top ──────────────────
    fc.quad_pipeline.recordDraw(cmd, extent, @intCast(fc.dl.quads.items.len));
    fc.text_pipeline.recordDraw(cmd, extent, @intCast(fc.dl.glyphs.items.len));
}

/// HSV → RGB conversion using the standard six-sextant formula. `h`
/// is degrees [0, 360); `s` and `v` are [0, 1]. Used by the demo to
/// paint each animated SDF glyph with its own rainbow hue.
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("text_engine demo — session 3 / stage 6a (resize-aware layout)\n", .{});
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
    _ = try fonts.load(emoji_path.ptr, 28); // emoji_id; markdown doesn't reach it without font fallback (parked)
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
    };

    // ── Component registry (stage 7b) ──────────────────────────────
    // Owned by the host across the entire program lifetime so cached
    // component instances persist over re-parses. No factories
    // registered yet — every `:::` block falls through to the 7a
    // missing-component placeholder. Stage 7c registers `:::box` as
    // the first real factory; visible change lands then.
    var registry = component.Registry.init(allocator);
    defer registry.deinit();

    // ── Parse demo.md into an Element tree ─────────────────────────
    // All slices + strings the tree references live in `doc_arena`;
    // freed in one shot at scope exit. The parser also frees the
    // cmark AST internally before returning — only Zig-managed
    // memory survives the call.
    var doc_arena = std.heap.ArenaAllocator.init(allocator);
    defer doc_arena.deinit();
    const top_stack = try markdown.parse(doc_arena.allocator(), demo_md, &theme, &registry);

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

    var frame_ctx = FrameCtx{
        .text_pipeline = &pipeline,
        .quad_pipeline = &quad_pipeline,
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
        .start_ms = std.time.milliTimestamp(),
    };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&frame_ctx);

    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "TEXT_ENGINE_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;

    // Steady-state loop: poll glfw + present. All layout +
    // animation + upload + record work lives in `drawCb` now,
    // keyed off the swapchain's current `extent` so it auto-reflows
    // when the user resizes the window.
    var frame_count: u64 = 0;
    while (!window.shouldClose()) {
        window.pollEvents();
        try rdr.drawFrame();
        frame_count += 1;
        if (exit_after_ms) |limit| {
            if (std.time.milliTimestamp() - frame_ctx.start_ms >= limit) break;
        }
    }

    const elapsed_ms = std.time.milliTimestamp() - frame_ctx.start_ms;
    try stdout.print("  glyphs:                {d} (pulse span: {d} glyphs)\n", .{
        frame_ctx.dl.glyphs.items.len,
        frame_ctx.pulse_count,
    });
    try stdout.print("  quads:                 {d}\n", .{frame_ctx.dl.quads.items.len});
    try stdout.print("  cache:                 {d} miss / {d} hit ({d:.1}% hit rate)\n", .{
        cache.misses,
        cache.hits,
        cache.hitRate() * 100.0,
    });
    try stdout.print("  frames:                {d} in {d}ms ({d:.1} fps)\n", .{
        frame_count,
        elapsed_ms,
        if (elapsed_ms > 0) @as(f64, @floatFromInt(frame_count)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms)) else 0,
    });
}
