//! text_engine_demo — Phase 6: SDF lane + per-glyph attention.
//!
//! Adds a new bottom paragraph "ATTENTION" rendered through the SDF
//! lane, with each glyph's `attention` SSBO field animated per frame
//! as a sine wave. The fragment shader thickens the SDF threshold +
//! grows a warm halo for high-attention glyphs, so we see a visible
//! "wave of heat" rolling left-to-right through the word — first
//! piece of the chat.md vision wired up end-to-end.

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

const ATLAS_MONO_SIZE: u32 = 768;
const ATLAS_COLOR_SIZE: u32 = 1024;
const MAX_GLYPHS: u32 = 2048;

const FrameCtx = struct {
    pipeline: *tp.TextPipeline,
    n_glyphs: u32,
    /// All glyph instances, mutated per frame for the attention wave.
    glyphs: []tp.GlyphInstance,
    /// Index range covering the animated SDF span — the wave
    /// rewrites only these entries each frame.
    pulse_start: u32,
    pulse_count: u32,
    /// Frame loop start time so the wave's phase is consistent.
    start_ms: i64,
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
    try stdout.print("text_engine demo — phase 6\n", .{});
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
    const emoji_id = try fonts.load(emoji_path.ptr, 28);
    // SDF lane at 44 px display — large enough that the attention
    // glow + threshold modulation is visible; small enough to share
    // a line with body text without overwhelming it. Source-px is
    // fixed at 64 inside `loadSdf` regardless.
    const sdf_id = try fonts.loadSdf(font_path.ptr, 44);

    var cache = glyph_cache_mod.GlyphCache.init(allocator);
    defer cache.deinit();

    // ── Compose the paragraph ──────────────────────────────────────
    const white: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const grey: [4]f32 = .{ 0.58, 0.62, 0.72, 1.0 };
    const yellow: [4]f32 = .{ 0.99, 0.84, 0.32, 1.0 };
    const orange: [4]f32 = .{ 0.99, 0.55, 0.30, 1.0 };

    const heading_line = layout.Line{ .spans = &.{
        .{ .text = "text_engine", .style = .{ .font_id = heading_id, .color = white } },
    } };
    const subtitle_line = layout.Line{ .spans = &.{
        .{ .text = "Phase 6 — SDF lane + per-glyph attention", .style = .{ .font_id = subtitle_id, .color = grey } },
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
    // The SDF span. Default per-span attention is 0.5; the per-frame
    // update below overwrites the .attention field of every glyph in
    // this span individually so each letter rides a different phase.
    const sdf_line = layout.Line{ .spans = &.{
        .{ .text = "ATTENTION", .style = .{ .font_id = sdf_id, .color = white, .attention = 0.5 } },
    } };

    var glyphs = std.ArrayList(tp.GlyphInstance).init(allocator);
    defer glyphs.deinit();

    // Layout the top part of the paragraph, then capture the index
    // range for the SDF line, then layout the SDF line, then we know
    // exactly which entries to animate per frame.
    const top_paragraph = layout.Paragraph{ .lines = &.{
        heading_line,
        subtitle_line,
        blank_line,
        mixed_line,
        emoji_line,
        blank_line,
    } };
    const sdf_y = try layout.layoutParagraph(
        &glyphs,
        allocator,
        &fonts,
        &cache,
        &atlas_mono,
        &atlas_color,
        top_paragraph,
        40,
        40,
    );

    const pulse_start: u32 = @intCast(glyphs.items.len);
    _ = try layout.layoutParagraph(
        &glyphs,
        allocator,
        &fonts,
        &cache,
        &atlas_mono,
        &atlas_color,
        .{ .lines = &.{sdf_line} },
        40,
        sdf_y,
    );
    const pulse_count: u32 = @intCast(glyphs.items.len - pulse_start);

    try pipeline.writeGlyphs(glyphs.items);
    try stdout.print("  glyphs:                {d} (pulse span: {d} glyphs)\n", .{
        glyphs.items.len,
        pulse_count,
    });
    try stdout.print("  cache:                 {d} miss / {d} hit ({d:.1}% hit rate)\n", .{
        cache.misses,
        cache.hits,
        cache.hitRate() * 100.0,
    });

    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var frame_ctx = FrameCtx{
        .pipeline = &pipeline,
        .n_glyphs = @intCast(glyphs.items.len),
        .glyphs = glyphs.items,
        .pulse_start = pulse_start,
        .pulse_count = pulse_count,
        .start_ms = std.time.milliTimestamp(),
    };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&frame_ctx);

    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "TEXT_ENGINE_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;

    var frame_count: u64 = 0;
    while (!window.shouldClose()) {
        window.pollEvents();

        // ── Per-frame attention wave ────────────────────────────────
        // Each glyph in the pulse span gets a sine-driven attention
        // value, phase-offset by index — a single wave rolls
        // left-to-right through the word. The SSBO is host-coherent,
        // so the memcpy in writeGlyphs becomes visible to the GPU
        // before the next submit without any explicit flush.
        const elapsed: f32 = @floatFromInt(std.time.milliTimestamp() - frame_ctx.start_ms);
        const t_sec: f32 = elapsed * 0.001;
        var i: u32 = 0;
        while (i < pulse_count) : (i += 1) {
            const idx = pulse_start + i;
            const phase = t_sec * 3.0 - @as(f32, @floatFromInt(i)) * 0.6;
            const w = (std.math.sin(phase) + 1.0) * 0.5;
            frame_ctx.glyphs[idx].attention = w;
        }
        try pipeline.writeGlyphs(frame_ctx.glyphs);

        try rdr.drawFrame();
        frame_count += 1;
        if (exit_after_ms) |limit| {
            if (std.time.milliTimestamp() - frame_ctx.start_ms >= limit) break;
        }
    }

    const elapsed_ms = std.time.milliTimestamp() - frame_ctx.start_ms;
    try stdout.print("  frames:                {d} in {d}ms ({d:.1} fps)\n", .{
        frame_count,
        elapsed_ms,
        if (elapsed_ms > 0) @as(f64, @floatFromInt(frame_count)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms)) else 0,
    });
}
