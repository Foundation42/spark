//! text_engine_demo — Phase 5: colour emoji via dual-atlas
//! (R8 grayscale + RGBA8 premultiplied) routed by per-glyph
//! `tex_select`. Noto Color Emoji is a strike-only CBDT font, so
//! the registry tracks an actual-vs-display scale factor and the
//! layout pass shrinks the 136-px native bitmaps inline.

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

const ATLAS_MONO_SIZE: u32 = 512;
const ATLAS_COLOR_SIZE: u32 = 1024; // emoji bitmaps are 136 px native, give them room
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
    try stdout.print("text_engine demo — phase 5\n", .{});
    try stdout.print("  vertex SPIR-V bytes:   {d}\n", .{text_engine.shaders.text_vert.len});
    try stdout.print("  fragment SPIR-V bytes: {d}\n", .{text_engine.shaders.text_frag.len});

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

    const font_path = std.posix.getenv("TEXT_ENGINE_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans.ttf";
    const emoji_path = std.posix.getenv("TEXT_ENGINE_EMOJI_FONT") orelse
        "/usr/share/fonts/noto/NotoColorEmoji.ttf";

    var ft = try face_mod.Library.init();
    defer ft.deinit();

    var fonts = registry_mod.FontRegistry.init(allocator, ft);
    defer fonts.deinit();

    const heading_id = try fonts.load(font_path.ptr, 56);
    const subtitle_id = try fonts.load(font_path.ptr, 18);
    const body_id = try fonts.load(font_path.ptr, 22);
    const accent_id = try fonts.load(font_path.ptr, 28);
    // Asking for 28-px emoji from a 136-px-strike CBDT font: the
    // registry stores actual=136, display=28, scale≈0.206. Layout
    // shrinks the bitmaps inline with the surrounding 22-px body.
    const emoji_id = try fonts.load(emoji_path.ptr, 28);
    try stdout.print("  emoji font:            actual {d}px, display {d}px, scale {d:.3}\n", .{
        fonts.entries.items[emoji_id].actual_px,
        fonts.entries.items[emoji_id].display_px,
        fonts.scale(emoji_id),
    });

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
        .{ .text = "Phase 5 — colour emoji via dual atlas", .style = .{ .font_id = subtitle_id, .color = grey } },
    } };
    const blank_line = layout.Line{ .spans = &.{} };
    const mixed_line = layout.Line{ .spans = &.{
        .{ .text = "Mix ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "fonts", .style = .{ .font_id = body_id, .color = yellow } },
        .{ .text = ", ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "sizes", .style = .{ .font_id = accent_id, .color = orange } },
        .{ .text = ", and colours inline.", .style = .{ .font_id = body_id, .color = white } },
    } };
    const emoji_line = layout.Line{ .spans = &.{
        .{ .text = "Inline emoji: ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "🎉🦊🚀❤️🎨🌍", .style = .{ .font_id = emoji_id, .color = white } },
        .{ .text = "  in body text.", .style = .{ .font_id = body_id, .color = white } },
    } };
    const ligature_line = layout.Line{ .spans = &.{
        .{ .text = "Ligatures still: fi fl ff ffi  •  Cache hits keep ", .style = .{ .font_id = body_id, .color = white } },
        .{ .text = "warm", .style = .{ .font_id = body_id, .color = green } },
        .{ .text = " across the paragraph.", .style = .{ .font_id = body_id, .color = white } },
    } };

    const paragraph = layout.Paragraph{ .lines = &.{
        heading_line,
        subtitle_line,
        blank_line,
        mixed_line,
        emoji_line,
        ligature_line,
    } };

    var glyphs = std.ArrayList(tp.GlyphInstance).init(allocator);
    defer glyphs.deinit();

    _ = try layout.layoutParagraph(
        &glyphs,
        allocator,
        &fonts,
        &cache,
        &atlas_mono,
        &atlas_color,
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
