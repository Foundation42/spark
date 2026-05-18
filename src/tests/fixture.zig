//! Shared test fixture for the Phase 5 library-boundary tests.
//! Stands up the minimum Vulkan + GLFW host scaffolding a `Spark`
//! needs to init, then tears it down. Hidden GLFW window (1×1, never
//! mapped) so the test suite runs without flashing windows or
//! requiring a display server's compositor cooperation.
//!
//! Each test gets its own `Fixture` — sharing across tests would
//! couple test ordering, and Vulkan instance creation is ~50ms which
//! is fine for the handful of integration tests in this suite.

const std = @import("std");
const text_engine = @import("../lib.zig");

const win = text_engine.window;
const vk = text_engine.vk;
const swap = text_engine.swapchain;

pub const Fixture = struct {
    window: win.Window,
    ctx: vk.Context,
    swapchain: swap.Swapchain,
    ft: text_engine.font.Library,

    pub fn init(allocator: std.mem.Allocator) !Fixture {
        win.c.glfwWindowHint(win.c.GLFW_VISIBLE, win.c.GLFW_FALSE);
        var window = try win.Window.init(64, 64, "spark-test");
        errdefer window.deinit();

        var ctx = try vk.Context.init(allocator, &window, "spark-test");
        errdefer ctx.deinit();

        var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
        errdefer swapchain.deinit();

        const ft = try text_engine.font.Library.init();
        return .{
            .window = window,
            .ctx = ctx,
            .swapchain = swapchain,
            .ft = ft,
        };
    }

    pub fn deinit(self: *Fixture) void {
        _ = vk.c.vkDeviceWaitIdle(self.ctx.device);
        self.ft.deinit();
        self.swapchain.deinit();
        self.ctx.deinit();
        self.window.deinit();
        self.* = undefined;
    }
};

const sans_path = "/usr/share/fonts/TTF/DejaVuSans.ttf";
const mono_path = "/usr/share/fonts/TTF/DejaVuSansMono.ttf";

pub const Fonts = struct {
    registry: *text_engine.FontRegistry,
    heading_id: text_engine.FontId,
    body_id: text_engine.FontId,
    code_id: text_engine.FontId,
};

/// Build a heap-allocated `FontRegistry` populated with three sizes
/// of DejaVu (heading/body/mono-code), the way `Spark.init` expects.
/// Caller transfers ownership of `registry` to Spark; on teardown,
/// call `spark.deinit()` THEN `allocator.destroy(fonts.registry)`.
pub fn makeFonts(allocator: std.mem.Allocator, ft: text_engine.font.Library) !Fonts {
    const registry = try allocator.create(text_engine.FontRegistry);
    errdefer allocator.destroy(registry);
    registry.* = text_engine.FontRegistry.init(allocator, ft);
    const heading_id = try registry.load(sans_path, 24);
    const body_id = try registry.load(sans_path, 20);
    const code_id = try registry.load(mono_path, 18);
    return .{
        .registry = registry,
        .heading_id = heading_id,
        .body_id = body_id,
        .code_id = code_id,
    };
}

/// Build a minimal Theme referencing the three sizes from `makeFonts`.
/// Returned by value — keep on the stack alongside the Spark it's
/// passed to (Spark borrows `*const Theme`).
pub fn makeTheme(fonts: Fonts) text_engine.Theme {
    const fg: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const heading: text_engine.Style = .{ .font_id = fonts.heading_id, .color = fg };
    const body: text_engine.Style = .{ .font_id = fonts.body_id, .color = fg };
    const code: text_engine.Style = .{ .font_id = fonts.code_id, .color = fg };
    return .{
        .body = body,
        .heading = .{ heading, heading, body, body, body, body },
        .code_block = code,
        .list_marker = body,
        .emphasis_font_id = fonts.body_id,
        .strong_font_id = fonts.body_id,
        .bold_italic_font_id = fonts.body_id,
        .code_inline_font_id = fonts.code_id,
        .fallback_font_id = fonts.body_id,
        .font_registry = fonts.registry,
    };
}
