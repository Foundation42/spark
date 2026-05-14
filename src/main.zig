//! text_engine_demo — Phase 3: HarfBuzz-shaped paragraph, per-glyph
//! SSBO, single instanced draw. The v1 "rich text on screen"
//! milestone — proves the full pipeline end to end with crisp body
//! text on the hinted-grayscale path.

const std = @import("std");
const text_engine = @import("text_engine");
const win = @import("window.zig");
const vk = @import("gpu/vk.zig");
const swap = @import("gpu/swapchain.zig");
const renderer = @import("gpu/renderer.zig");
const atlas_mod = @import("gpu/atlas.zig");
const tp = @import("gpu/text_pipeline.zig");
const face_mod = @import("font/face.zig");
const shape = @import("font/shape.zig");
const layout = @import("text/layout.zig");

// 512x512 grayscale atlas — comfortably fits the demo's pangram at
// 22px body size with room to spare. Phase 4 grows / paginates the
// atlas when the cache spills.
const ATLAS_SIZE: u32 = 512;
const BODY_PX: u32 = 22;
const HEADING_PX: u32 = 56;
const MAX_GLYPHS: u32 = 1024;

const DEMO_TEXT_HEADING = "text_engine";
const DEMO_TEXT_BODY =
    "The quick brown fox jumps over the lazy dog.\n" ++
    "Sphinx of black quartz, judge my vow.\n" ++
    "0123456789  !@#$%&*()  fi fl ff ffi  -> != <=";

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
    try stdout.print("text_engine demo — phase 3\n", .{});
    try stdout.print("  vertex SPIR-V bytes:   {d}\n", .{text_engine.shaders.text_vert.len});
    try stdout.print("  fragment SPIR-V bytes: {d}\n", .{text_engine.shaders.text_frag.len});

    var window = try win.Window.init(1280, 720, "text_engine_demo");
    defer window.deinit();

    var ctx = try vk.Context.init(allocator, &window, "text_engine_demo");
    defer ctx.deinit();
    try stdout.print("  vulkan device:         {s}\n", .{std.mem.sliceTo(ctx.deviceName(), 0)});

    var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
    defer swapchain.deinit();
    try stdout.print("  swapchain:             {d}x{d}, {d} images\n", .{
        swapchain.extent.width,
        swapchain.extent.height,
        swapchain.images.len,
    });

    const font_path = std.posix.getenv("TEXT_ENGINE_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans.ttf";

    var ft = try face_mod.Library.init();
    defer ft.deinit();

    var atlas = try atlas_mod.Atlas.init(&ctx, ATLAS_SIZE, ATLAS_SIZE);
    defer atlas.deinit();

    var pipeline = try tp.TextPipeline.init(&ctx, swapchain.format, &atlas, MAX_GLYPHS);
    defer pipeline.deinit();

    // ── Shape + layout the heading and the body, sharing the atlas ─
    // Two separate FT faces (one per pixel size) because FT mutates
    // the face's pixel size globally — calling setPixelSize again
    // would invalidate the heading's metrics partway through layout.
    // Each face gets its own HB font wrapping it.
    const heading_glyphs = try layoutLine(
        allocator,
        ft,
        &atlas,
        font_path.ptr,
        HEADING_PX,
        DEMO_TEXT_HEADING,
        40,
        @as(f32, @floatFromInt(HEADING_PX)) + 40,
        .{ 0.96, 0.96, 1.0, 1.0 },
    );
    defer allocator.free(heading_glyphs);

    var body_face = try face_mod.Face.init(ft, font_path.ptr, 0);
    defer body_face.deinit();
    try body_face.setPixelSize(BODY_PX);
    const body_metrics = body_face.metrics();
    var body_hb = try shape.Font.fromFreetypeFace(body_face);
    defer body_hb.deinit();

    var body_glyphs = std.ArrayList(tp.GlyphInstance).init(allocator);
    defer body_glyphs.deinit();

    // Three lines separated by '\n' in DEMO_TEXT_BODY. HarfBuzz
    // doesn't break lines — that's the layout pass's job. We split
    // on '\n' and shape each fragment as its own run, advancing the
    // pen vertically by the face's recommended line height.
    var line_no: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, DEMO_TEXT_BODY, '\n');
    const body_top: f32 = @floatFromInt(HEADING_PX + 120);
    while (line_iter.next()) |line| : (line_no += 1) {
        var run = try shape.shapeUtf8(allocator, body_hb, line);
        defer run.deinit();
        const baseline_y = body_top + body_metrics.ascender +
            @as(f32, @floatFromInt(line_no)) * body_metrics.line_height;
        var line_layout = try layout.layoutRun(
            allocator,
            &body_face,
            &atlas,
            run,
            40,
            baseline_y,
            .{ 0.92, 0.94, 0.98, 1.0 },
        );
        defer line_layout.deinit();
        try body_glyphs.appendSlice(line_layout.glyphs);
    }

    // ── Concatenate heading + body into one SSBO write ─────────────
    var all_glyphs = try allocator.alloc(tp.GlyphInstance, heading_glyphs.len + body_glyphs.items.len);
    defer allocator.free(all_glyphs);
    @memcpy(all_glyphs[0..heading_glyphs.len], heading_glyphs);
    @memcpy(all_glyphs[heading_glyphs.len..], body_glyphs.items);
    try pipeline.writeGlyphs(all_glyphs);
    try stdout.print("  glyphs:                {d} ({d} heading + {d} body)\n", .{
        all_glyphs.len,
        heading_glyphs.len,
        body_glyphs.items.len,
    });

    // ── Frame loop ─────────────────────────────────────────────────
    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var frame_ctx = FrameCtx{ .pipeline = &pipeline, .n_glyphs = @intCast(all_glyphs.len) };
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

/// Shape + lay out a single line at a given pixel size, returning a
/// caller-owned slice of glyph instances. Creates its own FT face +
/// HB font, scoped to this call — fine for the one-shot heading
/// path; the body uses long-lived face+font and the layout function
/// directly.
fn layoutLine(
    allocator: std.mem.Allocator,
    ft: face_mod.Library,
    atlas: *atlas_mod.Atlas,
    font_path: [*:0]const u8,
    px_size: u32,
    text: []const u8,
    pen_x: f32,
    baseline_y: f32,
    color: [4]f32,
) ![]tp.GlyphInstance {
    var face = try face_mod.Face.init(ft, font_path, 0);
    defer face.deinit();
    try face.setPixelSize(px_size);
    var hb = try shape.Font.fromFreetypeFace(face);
    defer hb.deinit();
    var run = try shape.shapeUtf8(allocator, hb, text);
    defer run.deinit();
    const line = try layout.layoutRun(allocator, &face, atlas, run, pen_x, baseline_y, color);
    return line.glyphs;
}
