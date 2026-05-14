//! text_engine_demo — Phase 4: multi-font glyph cache + styled
//! spans. Demonstrates per-line baseline resolution over mixed
//! font sizes (Makepad-style row finish), and proves the
//! `(font_id, glyph_id)` cache pulls repeat glyphs straight from
//! the atlas instead of going back to FreeType.

const std = @import("std");
const text_engine = @import("text_engine");
const win = @import("window.zig");
const vk = @import("gpu/vk.zig");
const swap = @import("gpu/swapchain.zig");
const renderer = @import("gpu/renderer.zig");
const atlas_mod = @import("gpu/atlas.zig");
const tp = @import("gpu/text_pipeline.zig");
const face_mod = @import("font/face.zig");
const registry_mod = @import("font/registry.zig");
const glyph_cache_mod = @import("text/glyph_cache.zig");
const layout = @import("text/layout.zig");

const ATLAS_SIZE: u32 = 512;
const MAX_GLYPHS: u32 = 2048;

const FrameCtx = struct {
    pipeline: *const tp.TextPipeline,
    n_glyphs: u32,
};

fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const fc: *const FrameCtx = @ptrCast(@alignCast(ctx.?));
    fc.pipeline.recordDraw(cmd, extent, fc.n_glyphs);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("text_engine demo — phase 4\n", .{});
    try stdout.print("  vertex SPIR-V bytes:   {d}\n", .{text_engine.shaders.text_vert.len});
    try stdout.print("  fragment SPIR-V bytes: {d}\n", .{text_engine.shaders.text_frag.len});

    var window = try win.Window.init(1280, 720, "text_engine_demo");
    defer window.deinit();

    var ctx = try vk.Context.init(allocator, &window, "text_engine_demo");
    defer ctx.deinit();
    try stdout.print("  vulkan device:         {s}\n", .{std.mem.sliceTo(ctx.deviceName(), 0)});

    var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
    defer swapchain.deinit();

    var atlas = try atlas_mod.Atlas.init(&ctx, ATLAS_SIZE, ATLAS_SIZE);
    defer atlas.deinit();

    var pipeline = try tp.TextPipeline.init(&ctx, swapchain.format, &atlas, MAX_GLYPHS);
    defer pipeline.deinit();

    // ── Font registry: one entry per (file, px) ─────────────────────
    // Loading the same file at four sizes is the common path while
    // we don't yet have weight/italic variants — Phase ≥5 will pull
    // those in via fontconfig.
    const font_path = std.posix.getenv("TEXT_ENGINE_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans.ttf";

    var ft = try face_mod.Library.init();
    defer ft.deinit();

    var fonts = registry_mod.FontRegistry.init(allocator, ft);
    defer fonts.deinit();

    const heading_id = try fonts.load(font_path.ptr, 56);
    const subtitle_id = try fonts.load(font_path.ptr, 18);
    const body_id = try fonts.load(font_path.ptr, 22);
    const accent_id = try fonts.load(font_path.ptr, 28);

    var cache = glyph_cache_mod.GlyphCache.init(allocator);
    defer cache.deinit();

    // ── Compose the paragraph ──────────────────────────────────────
    const white: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const grey: [4]f32 = .{ 0.58, 0.62, 0.72, 1.0 };
    const yellow: [4]f32 = .{ 0.99, 0.84, 0.32, 1.0 };
    const orange: [4]f32 = .{ 0.99, 0.55, 0.30, 1.0 };
    const green: [4]f32 = .{ 0.55, 0.85, 0.50, 1.0 };

    const heading_line = layout.Line{ .spans = &.{
        .{ .text = "text_engine", .style = .{ .font_id = heading_id, .color = white } },
    } };
    const subtitle_line = layout.Line{ .spans = &.{
        .{ .text = "Phase 4 — styled spans + glyph cache", .style = .{ .font_id = subtitle_id, .color = grey } },
    } };
    const blank_line = layout.Line{ .spans = &.{} };
    // Mixed-size line — accent span lifts the baseline so the
    // surrounding 22 px body still sits cleanly underneath.
    const mixed_line = layout.Line{ .spans = &.{
        .{ .text = "Mix ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "fonts", .style = .{ .font_id = body_id, .color = yellow } },
        .{ .text = ", ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "sizes", .style = .{ .font_id = accent_id, .color = orange } },
        .{ .text = " and colours inline.", .style = .{ .font_id = body_id, .color = white } },
    } };
    const repeat_line = layout.Line{ .spans = &.{
        .{ .text = "Same glyph, same atlas slot — cache turns ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "warm", .style = .{ .font_id = body_id, .color = green } },
        .{ .text = " after the first sighting.", .style = .{ .font_id = body_id, .color = white } },
    } };
    const ligature_line = layout.Line{ .spans = &.{
        .{ .text = "Ligatures: fi fl ff ffi  •  Pangram: ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "Sphinx of black quartz, judge my vow.", .style = .{ .font_id = body_id, .color = grey } },
    } };

    const paragraph = layout.Paragraph{ .lines = &.{
        heading_line,
        subtitle_line,
        blank_line,
        mixed_line,
        repeat_line,
        ligature_line,
    } };

    // ── Lay out into a caller-owned ArrayList ──────────────────────
    // One allocation grows to hold every glyph in the paragraph;
    // appendLineFromSpans / appendShapedRun never allocate a glyph
    // slice of their own.
    var glyphs = std.ArrayList(tp.GlyphInstance).init(allocator);
    defer glyphs.deinit();

    _ = try layout.layoutParagraph(
        &glyphs,
        allocator,
        &fonts,
        &cache,
        &atlas,
        paragraph,
        40,
        40,
    );

    try pipeline.writeGlyphs(glyphs.items);
    try stdout.print("  glyphs:                {d}\n", .{glyphs.items.len});
    try stdout.print("  cache:                 {d} miss / {d} hit ({d:.1}% hit rate)\n", .{
        cache.misses,
        cache.hits,
        cache.hitRate() * 100.0,
    });

    // ── Frame loop ─────────────────────────────────────────────────
    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var frame_ctx = FrameCtx{ .pipeline = &pipeline, .n_glyphs = @intCast(glyphs.items.len) };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&frame_ctx);

    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "TEXT_ENGINE_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;

    const start_ms = std.time.milliTimestamp();
    var frame_count: u64 = 0;
    while (!window.shouldClose()) {
        window.pollEvents();
        try rdr.drawFrame();
        frame_count += 1;
        if (exit_after_ms) |limit| {
            if (std.time.milliTimestamp() - start_ms >= limit) break;
        }
    }

    const elapsed_ms = std.time.milliTimestamp() - start_ms;
    try stdout.print("  frames:                {d} in {d}ms ({d:.1} fps)\n", .{
        frame_count,
        elapsed_ms,
        if (elapsed_ms > 0) @as(f64, @floatFromInt(frame_count)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms)) else 0,
    });
}
