//! Swapchain + per-image views for the demo's window.
//!
//! Owns the VkSwapchainKHR and the image views; the swapchain images
//! themselves are owned by the swapchain and destroyed implicitly with
//! it. Format and extent are picked here and exposed so the render
//! pipeline (Phase 1b) can match them up with vkCmdBeginRendering
//! attachment info.
//!
//! Recreation on out-of-date / window resize is Phase 1b — for now we
//! create once at startup and tear down at exit.

const std = @import("std");
const vk = @import("vk.zig");
const win = @import("../window.zig");

pub const Swapchain = struct {
    handle: c.VkSwapchainKHR,
    format: c.VkFormat,
    color_space: c.VkColorSpaceKHR,
    extent: c.VkExtent2D,
    images: []c.VkImage,
    image_views: []c.VkImageView,
    device: c.VkDevice, // borrowed
    allocator: std.mem.Allocator,

    const c = vk.c;

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *const vk.Context,
        window: *const win.Window,
    ) !Swapchain {
        const surface = ctx.surface;
        const pd = ctx.physical_device;
        const device = ctx.device;

        // ── Capabilities, formats, present modes ────────────────────
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try vk.check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface, &caps));

        var fmt_count: u32 = 0;
        try vk.check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &fmt_count, null));
        if (fmt_count == 0) return error.NoSurfaceFormats;
        const formats = try allocator.alloc(c.VkSurfaceFormatKHR, fmt_count);
        defer allocator.free(formats);
        try vk.check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &fmt_count, formats.ptr));

        var pm_count: u32 = 0;
        try vk.check(c.vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface, &pm_count, null));
        if (pm_count == 0) return error.NoPresentModes;
        const present_modes = try allocator.alloc(c.VkPresentModeKHR, pm_count);
        defer allocator.free(present_modes);
        try vk.check(c.vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface, &pm_count, present_modes.ptr));

        // Pick B8G8R8A8_UNORM with SRGB_NONLINEAR colour space. UNORM
        // (not _SRGB) keeps the swapchain in linear; we'll apply gamma
        // in the fragment shader once we have actual text rendering.
        // Doing gamma in-shader gives correct coverage blending — sRGB
        // swapchain formats sample correctly but write *after* alpha
        // blend, which causes the well-known greyscale-text muddiness.
        const picked_fmt = pickFormat(formats);
        const picked_present = pickPresentMode(present_modes);
        const fb = window.framebufferSize();
        const extent = pickExtent(caps, fb.w, fb.h);

        // minImageCount + 1 saves a frame of latency over the strict
        // minimum, capped by maxImageCount when the driver specifies
        // one (0 means "no cap").
        var image_count: u32 = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) {
            image_count = caps.maxImageCount;
        }

        var sci = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        sci.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        sci.surface = surface;
        sci.minImageCount = image_count;
        sci.imageFormat = picked_fmt.format;
        sci.imageColorSpace = picked_fmt.colorSpace;
        sci.imageExtent = extent;
        sci.imageArrayLayers = 1;
        // TRANSFER_SRC as well as COLOR_ATTACHMENT: a `.backdrop` chain
        // copies the region of the presented image that its panel covers
        // into pool[0], which is what lets frosted glass blur what is
        // BEHIND it rather than its own children. Universally supported
        // alongside COLOR_ATTACHMENT, and free when nothing asks for it.
        // matryoshka's swapchain already carried it, for `shot ui`.
        sci.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        sci.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        sci.preTransform = caps.currentTransform;
        sci.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        sci.presentMode = picked_present;
        sci.clipped = c.VK_TRUE;
        sci.oldSwapchain = null;

        var handle: c.VkSwapchainKHR = null;
        try vk.check(c.vkCreateSwapchainKHR(device, &sci, null, &handle));
        errdefer c.vkDestroySwapchainKHR(device, handle, null);

        // ── Retrieve the actual swapchain images (count may differ
        // from the minImageCount we asked for) ──────────────────────
        var got_count: u32 = 0;
        try vk.check(c.vkGetSwapchainImagesKHR(device, handle, &got_count, null));
        const images = try allocator.alloc(c.VkImage, got_count);
        errdefer allocator.free(images);
        try vk.check(c.vkGetSwapchainImagesKHR(device, handle, &got_count, images.ptr));

        // ── One view per swapchain image for dynamic-rendering ──────
        const image_views = try allocator.alloc(c.VkImageView, got_count);
        errdefer allocator.free(image_views);
        @memset(image_views, null);
        errdefer for (image_views) |iv| if (iv != null) c.vkDestroyImageView(device, iv, null);

        for (images, image_views) |img, *iv| {
            var ivci = std.mem.zeroes(c.VkImageViewCreateInfo);
            ivci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            ivci.image = img;
            ivci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            ivci.format = picked_fmt.format;
            ivci.components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            };
            ivci.subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            };
            try vk.check(c.vkCreateImageView(device, &ivci, null, iv));
        }

        return .{
            .handle = handle,
            .format = picked_fmt.format,
            .color_space = picked_fmt.colorSpace,
            .extent = extent,
            .images = images,
            .image_views = image_views,
            .device = device,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Swapchain) void {
        for (self.image_views) |iv| if (iv != null) c.vkDestroyImageView(self.device, iv, null);
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);
        if (self.handle != null) c.vkDestroySwapchainKHR(self.device, self.handle, null);
        self.* = undefined;
    }
};

fn pickFormat(formats: []const vk.c.VkSurfaceFormatKHR) vk.c.VkSurfaceFormatKHR {
    const want_fmt = vk.c.VK_FORMAT_B8G8R8A8_UNORM;
    const want_cs = vk.c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    for (formats) |f| {
        if (f.format == want_fmt and f.colorSpace == want_cs) return f;
    }
    return formats[0];
}

fn pickPresentMode(modes: []const vk.c.VkPresentModeKHR) vk.c.VkPresentModeKHR {
    // MAILBOX = lowest latency without tearing when available; FIFO is
    // the spec-guaranteed fallback. For a text editor / terminal,
    // either is fine — we never need to outrun the display.
    for (modes) |m| {
        if (m == vk.c.VK_PRESENT_MODE_MAILBOX_KHR) return m;
    }
    return vk.c.VK_PRESENT_MODE_FIFO_KHR;
}

fn pickExtent(caps: vk.c.VkSurfaceCapabilitiesKHR, fb_w: u32, fb_h: u32) vk.c.VkExtent2D {
    // The spec uses 0xFFFFFFFF in currentExtent to mean "the surface
    // size is determined by the swapchain extent we choose". Otherwise
    // we must match currentExtent exactly.
    if (caps.currentExtent.width != 0xFFFFFFFF) return caps.currentExtent;
    return .{
        .width = std.math.clamp(fb_w, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = std.math.clamp(fb_h, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
}
