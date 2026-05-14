//! text_engine_demo — standalone demo exe that exercises the library
//! through the same module surface a host engine would.
//!
//! Phase 1a: open a glfw window, create a Vulkan 1.3 context (with
//! validation in Debug), create a swapchain. No frame loop yet —
//! Phase 1b adds the clear-color draw + present.

const std = @import("std");
const text_engine = @import("text_engine");
const win = @import("window.zig");
const vk = @import("gpu/vk.zig");
const swap = @import("gpu/swapchain.zig");
const renderer = @import("gpu/renderer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("text_engine demo — phase 1b\n", .{});
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

    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    // TEXT_ENGINE_EXIT_AFTER=<seconds> auto-closes after a delay so
    // automated test runs (and `timeout`-less probes) actually exit
    // through the defer chain — SIGTERM skips deferred destruction,
    // which masks any cleanup-time validation warnings.
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
