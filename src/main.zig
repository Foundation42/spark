//! text_engine_demo — Phase 2: rasterise one glyph via FreeType,
//! upload to a small atlas, render a textured quad sampling it.

const std = @import("std");
const text_engine = @import("text_engine");
const win = @import("window.zig");
const vk = @import("gpu/vk.zig");
const swap = @import("gpu/swapchain.zig");
const renderer = @import("gpu/renderer.zig");
const atlas_mod = @import("gpu/atlas.zig");
const tp = @import("gpu/text_pipeline.zig");
const face_mod = @import("font/face.zig");

const ATLAS_SIZE: u32 = 256;
const GLYPH_PX_HEIGHT: u32 = 128; // big enough that hinting+AA is obvious

const FrameCtx = struct {
    pipeline: *const tp.TextPipeline,
    glyph_w: u32,
    glyph_h: u32,
};

fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const fc: *const FrameCtx = @ptrCast(@alignCast(ctx.?));
    const gw: f32 = @floatFromInt(fc.glyph_w);
    const gh: f32 = @floatFromInt(fc.glyph_h);
    const vw: f32 = @floatFromInt(extent.width);
    const vh: f32 = @floatFromInt(extent.height);
    const atlas_f: f32 = @floatFromInt(ATLAS_SIZE);
    const pc = tp.TextPushConsts{
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .dst_pos = .{ (vw - gw) * 0.5, (vh - gh) * 0.5 },
        .dst_size = .{ gw, gh },
        .viewport_size = .{ vw, vh },
        .uv_min = .{ 0.0, 0.0 },
        .uv_max = .{ gw / atlas_f, gh / atlas_f },
    };
    fc.pipeline.recordDraw(cmd, extent, pc);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("text_engine demo — phase 2\n", .{});
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

    // ── FreeType: rasterise 'A' at GLYPH_PX_HEIGHT ─────────────────
    // Hardcoded to a path that exists on Christian's Arch box; later
    // phases will route through fontconfig so this isn't load-bearing
    // on distro layout.
    const font_path = std.posix.getenv("TEXT_ENGINE_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans.ttf";

    var ft = try face_mod.Library.init();
    defer ft.deinit();
    var face = try face_mod.Face.init(ft, font_path.ptr, 0);
    defer face.deinit();
    try face.setPixelSize(GLYPH_PX_HEIGHT);
    const glyph = try face.rasterizeChar('A');
    try stdout.print("  glyph 'A':             {d}x{d} (pitch={d}, bearing=({d},{d}), advance={d:.1}px)\n", .{
        glyph.width,
        glyph.height,
        glyph.pitch,
        glyph.bearing_x,
        glyph.bearing_y,
        glyph.advance_px,
    });

    // FreeType may emit rows with pitch != width (alignment padding)
    // or with negative pitch (bottom-up). Re-pack into a tight
    // top-down buffer before handing to the staging upload.
    const tight = try packGlyph(allocator, glyph);
    defer allocator.free(tight);

    // ── Atlas + upload ─────────────────────────────────────────────
    var atlas = try atlas_mod.Atlas.init(&ctx, ATLAS_SIZE, ATLAS_SIZE);
    defer atlas.deinit();
    try atlas.uploadRegion(0, 0, glyph.width, glyph.height, tight);

    // ── Text pipeline targeting the swapchain format ───────────────
    var pipeline = try tp.TextPipeline.init(&ctx, swapchain.format, &atlas);
    defer pipeline.deinit();

    // ── Frame loop ─────────────────────────────────────────────────
    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var frame_ctx = FrameCtx{
        .pipeline = &pipeline,
        .glyph_w = glyph.width,
        .glyph_h = glyph.height,
    };
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

/// Copy a FreeType `GlyphBitmap` into an allocator-owned tight-packed
/// (pitch == width, top-down) buffer. FreeType's `pitch` field is the
/// stride in bytes; negative means bottom-up rows. Flipping here so
/// the atlas uploader can treat the buffer as a plain w*h grayscale.
fn packGlyph(allocator: std.mem.Allocator, g: face_mod.GlyphBitmap) ![]u8 {
    const w = g.width;
    const h = g.height;
    const out = try allocator.alloc(u8, w * h);
    errdefer allocator.free(out);
    if (w == 0 or h == 0) return out;

    const abs_pitch: usize = @intCast(if (g.pitch < 0) -g.pitch else g.pitch);
    const src_top_down = g.pitch >= 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src_row_idx: usize = if (src_top_down) y else h - 1 - y;
        const src = g.buffer + src_row_idx * abs_pitch;
        const dst = out[y * w ..][0..w];
        @memcpy(dst, src[0..w]);
    }
    return out;
}
