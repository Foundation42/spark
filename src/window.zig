//! GLFW window wrapper for the standalone demo.
//!
//! The library itself does not own a window — the cooperative-embed
//! surface assumes the host engine already has one. This wrapper
//! exists only so `spark_demo` has a place to draw. When/if a
//! second host appears, this file does not move into the library;
//! the host brings its own.

const std = @import("std");

pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
});

pub const Window = struct {
    handle: *c.GLFWwindow,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32, title: [*:0]const u8) !Window {
        if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
        errdefer c.glfwTerminate();

        // No OpenGL context — Vulkan will own the surface. GLFW_RESIZABLE
        // stays true even though we don't handle resize yet, so the
        // window manager won't lock us to one size; Phase 1b will add
        // swapchain recreate on out-of-date.
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

        const handle = c.glfwCreateWindow(
            @intCast(width),
            @intCast(height),
            title,
            null,
            null,
        ) orelse return error.GlfwCreateWindowFailed;

        return .{ .handle = handle, .width = width, .height = height };
    }

    pub fn deinit(self: *Window) void {
        c.glfwDestroyWindow(self.handle);
        c.glfwTerminate();
        self.* = undefined;
    }

    pub fn shouldClose(self: *const Window) bool {
        return c.glfwWindowShouldClose(self.handle) != 0;
    }

    pub fn pollEvents(_: *const Window) void {
        c.glfwPollEvents();
    }

    /// Returns the framebuffer pixel size, which may differ from the
    /// window's logical size on hi-DPI displays. The swapchain extent
    /// must match this, not the logical size, or text comes out blurry.
    pub fn framebufferSize(self: *const Window) struct { w: u32, h: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        c.glfwGetFramebufferSize(self.handle, &w, &h);
        return .{ .w = @intCast(w), .h = @intCast(h) };
    }

    /// Returns the list of Vulkan instance extensions GLFW needs in order
    /// for `glfwCreateWindowSurface` to succeed on this platform
    /// (VK_KHR_surface + a platform-specific child like VK_KHR_xcb_surface
    /// / VK_KHR_wayland_surface / VK_KHR_win32_surface). Caller appends
    /// any additional extensions it wants (e.g. VK_EXT_debug_utils).
    pub fn requiredInstanceExtensions() []const [*:0]const u8 {
        var count: u32 = 0;
        const ptr = c.glfwGetRequiredInstanceExtensions(&count);
        if (ptr == null or count == 0) return &.{};
        return @as([*]const [*:0]const u8, @ptrCast(ptr))[0..count];
    }
};
