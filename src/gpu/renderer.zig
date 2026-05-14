//! Frame-in-flight renderer for the demo.
//!
//! Owns per-frame command buffers + sync primitives and drives the
//! acquire / record / submit / present loop. The actual draw work is
//! a clear-color via `vkCmdBeginRendering` for Phase 1b — Phase 2
//! and later replace `recordFrame` with text-engine library calls.
//!
//! Sync model:
//!   * `image_acquired[MAX_FRAMES]` — binary, signaled by
//!     vkAcquireNextImageKHR, waited on by the queue submit.
//!   * `render_finished[swapchain.images.len]` — binary, signaled by
//!     the queue submit, waited on by vkQueuePresentKHR. Per-image
//!     (not per-frame) because vkAcquireNextImageKHR can hand back
//!     any image index — pairing this semaphore with the *image*
//!     avoids the well-known race where two frames in flight target
//!     the same swapchain image.
//!   * `in_flight[MAX_FRAMES]` — fence, host waits before reusing a
//!     frame's command buffer + acquire semaphore.
//!
//! Swapchain recreation on VK_ERROR_OUT_OF_DATE_KHR / VK_SUBOPTIMAL_KHR
//! is handled by destroying and re-creating the Swapchain in place
//! (and re-creating render_finished semaphores when image count
//! changes). The window framebuffer size drives the new extent; if
//! it's zero (minimised) the loop just yields until it isn't.

const std = @import("std");
const vk = @import("vk.zig");
const swap = @import("swapchain.zig");
const win = @import("../window.zig");

const c = vk.c;

pub const MAX_FRAMES_IN_FLIGHT: u32 = 2;

pub const Renderer = struct {
    ctx: *vk.Context, // borrowed
    swapchain: *swap.Swapchain, // borrowed (we recreate in place)
    window: *const win.Window, // borrowed

    command_pools: [MAX_FRAMES_IN_FLIGHT]c.VkCommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
    image_acquired: [MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    in_flight: [MAX_FRAMES_IN_FLIGHT]c.VkFence,

    render_finished: []c.VkSemaphore,
    allocator: std.mem.Allocator,

    frame_index: u32 = 0,
    clear_color: [4]f32 = .{ 0.04, 0.04, 0.07, 1.0 },

    /// Optional hook called inside vkCmdBeginRendering. Use this to
    /// record draw work for the frame (e.g. text pipeline `recordDraw`
    /// calls). `ctx` is whatever opaque pointer the host passed in
    /// alongside the callback.
    draw_fn: ?*const fn (ctx: ?*anyopaque, cmd: c.VkCommandBuffer, extent: c.VkExtent2D) void = null,
    draw_ctx: ?*anyopaque = null,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *vk.Context,
        swapchain: *swap.Swapchain,
        window: *const win.Window,
    ) !Renderer {
        var self: Renderer = .{
            .ctx = ctx,
            .swapchain = swapchain,
            .window = window,
            .command_pools = [_]c.VkCommandPool{null} ** MAX_FRAMES_IN_FLIGHT,
            .command_buffers = [_]c.VkCommandBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
            .image_acquired = [_]c.VkSemaphore{null} ** MAX_FRAMES_IN_FLIGHT,
            .in_flight = [_]c.VkFence{null} ** MAX_FRAMES_IN_FLIGHT,
            .render_finished = &.{},
            .allocator = allocator,
        };
        errdefer self.deinit();

        // Per-frame command pool + primary command buffer. One pool
        // per frame so we can wholesale-reset the pool each frame
        // rather than reset individual buffers — saves a syscall per
        // frame and is the pattern matryoshka uses.
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
            cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            cpci.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
            cpci.queueFamilyIndex = ctx.queue_family;
            try vk.check(c.vkCreateCommandPool(ctx.device, &cpci, null, &self.command_pools[i]));

            var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
            ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            ai.commandPool = self.command_pools[i];
            ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            ai.commandBufferCount = 1;
            try vk.check(c.vkAllocateCommandBuffers(ctx.device, &ai, &self.command_buffers[i]));
        }

        // Per-frame acquire semaphores + in-flight fences. Fences are
        // created signaled so the first frame doesn't wait on a fence
        // that no one has signaled yet.
        var sci = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sci.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        var fci = std.mem.zeroes(c.VkFenceCreateInfo);
        fci.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fci.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            try vk.check(c.vkCreateSemaphore(ctx.device, &sci, null, &self.image_acquired[i]));
            try vk.check(c.vkCreateFence(ctx.device, &fci, null, &self.in_flight[i]));
        }

        try self.createImageSemaphores();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        // We must idle the device before destroying anything still in
        // flight — fences only sync host vs submit-completion, not
        // semaphore signal/wait pairs that may be queued.
        _ = c.vkDeviceWaitIdle(self.ctx.device);

        for (self.render_finished) |s| if (s != null) c.vkDestroySemaphore(self.ctx.device, s, null);
        if (self.render_finished.len > 0) self.allocator.free(self.render_finished);
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.in_flight[i] != null) c.vkDestroyFence(self.ctx.device, self.in_flight[i], null);
            if (self.image_acquired[i] != null) c.vkDestroySemaphore(self.ctx.device, self.image_acquired[i], null);
            if (self.command_pools[i] != null) c.vkDestroyCommandPool(self.ctx.device, self.command_pools[i], null);
        }
        self.* = undefined;
    }

    /// Drive one frame: acquire → record → submit → present. Returns
    /// when the GPU work is queued; the caller can use this as the
    /// loop body. Handles swapchain recreation transparently on
    /// VK_ERROR_OUT_OF_DATE_KHR / SUBOPTIMAL, and also on framebuffer
    /// size drift (the Wayland-friendly belt-and-braces detection —
    /// some compositors don't reliably signal OUT_OF_DATE through
    /// vkAcquireNextImage / vkQueuePresent on resize, so we poll the
    /// window's reported framebuffer size each frame too).
    pub fn drawFrame(self: *Renderer) !void {
        const device = self.ctx.device;

        // Poll-based resize detection. If GLFW reports a different
        // framebuffer size than what the swapchain was created for,
        // force a recreate before we acquire — otherwise we'd render
        // for the old extent against a surface that's already moved on.
        {
            const fb = self.window.framebufferSize();
            if (fb.w != 0 and fb.h != 0 and
                (fb.w != self.swapchain.extent.width or fb.h != self.swapchain.extent.height))
            {
                try self.recreateSwapchain();
            }
        }

        const frame = self.frame_index;

        try vk.check(c.vkWaitForFences(device, 1, &self.in_flight[frame], c.VK_TRUE, std.math.maxInt(u64)));

        // Acquire. Out-of-date here means the window was resized
        // *between* the last present and now; recreate and skip the
        // frame (don't try to record against a stale swapchain).
        var image_index: u32 = 0;
        const acquire_res = c.vkAcquireNextImageKHR(
            device,
            self.swapchain.handle,
            std.math.maxInt(u64),
            self.image_acquired[frame],
            null,
            &image_index,
        );
        if (acquire_res == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return;
        } else if (acquire_res != c.VK_SUCCESS and acquire_res != c.VK_SUBOPTIMAL_KHR) {
            return error.AcquireFailed;
        }

        // Only reset the fence *after* a successful acquire — otherwise
        // an out-of-date acquire leaves us with an unsignaled fence and
        // no submit will happen, deadlocking the next frame's wait.
        try vk.check(c.vkResetFences(device, 1, &self.in_flight[frame]));

        // Wholesale-reset the pool, then re-record from scratch.
        try vk.check(c.vkResetCommandPool(device, self.command_pools[frame], 0));
        const cmd = self.command_buffers[frame];

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        const sc_image = self.swapchain.images[image_index];
        const sc_view = self.swapchain.image_views[image_index];

        // UNDEFINED → COLOR_ATTACHMENT_OPTIMAL. We don't care about the
        // previous contents — every frame is a full clear right now,
        // so the layout transition can discard the old pixels.
        transitionImage(cmd, sc_image, .{
            .src_stage = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            .dst_stage = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .src_access = 0,
            .dst_access = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .old_layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });

        // ── vkCmdBeginRendering: clear-color only, no draws yet ─────
        var color_att = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        color_att.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        color_att.imageView = sc_view;
        color_att.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        color_att.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_att.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_att.clearValue = .{ .color = .{ .float32 = self.clear_color } };

        var ri = std.mem.zeroes(c.VkRenderingInfo);
        ri.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &color_att;

        c.vkCmdBeginRendering(cmd, &ri);
        if (self.draw_fn) |fnp| fnp(self.draw_ctx, cmd, self.swapchain.extent);
        c.vkCmdEndRendering(cmd);

        // COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR for the present op.
        transitionImage(cmd, sc_image, .{
            .src_stage = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dst_stage = c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            .src_access = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = 0,
            .old_layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .new_layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        });

        try vk.check(c.vkEndCommandBuffer(cmd));

        // ── Submit2 ────────────────────────────────────────────────
        var wait_info = std.mem.zeroes(c.VkSemaphoreSubmitInfo);
        wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
        wait_info.semaphore = self.image_acquired[frame];
        wait_info.stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;

        var signal_info = std.mem.zeroes(c.VkSemaphoreSubmitInfo);
        signal_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
        signal_info.semaphore = self.render_finished[image_index];
        signal_info.stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;

        var cmd_info = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
        cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
        cmd_info.commandBuffer = cmd;

        var si = std.mem.zeroes(c.VkSubmitInfo2);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
        si.waitSemaphoreInfoCount = 1;
        si.pWaitSemaphoreInfos = &wait_info;
        si.commandBufferInfoCount = 1;
        si.pCommandBufferInfos = &cmd_info;
        si.signalSemaphoreInfoCount = 1;
        si.pSignalSemaphoreInfos = &signal_info;
        try vk.check(c.vkQueueSubmit2(self.ctx.queue, 1, &si, self.in_flight[frame]));

        // ── Present ────────────────────────────────────────────────
        var pi = std.mem.zeroes(c.VkPresentInfoKHR);
        pi.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        pi.waitSemaphoreCount = 1;
        pi.pWaitSemaphores = &self.render_finished[image_index];
        pi.swapchainCount = 1;
        pi.pSwapchains = &self.swapchain.handle;
        pi.pImageIndices = &image_index;
        const present_res = c.vkQueuePresentKHR(self.ctx.queue, &pi);
        if (present_res == c.VK_ERROR_OUT_OF_DATE_KHR or present_res == c.VK_SUBOPTIMAL_KHR) {
            try self.recreateSwapchain();
        } else if (present_res != c.VK_SUCCESS) {
            return error.PresentFailed;
        }

        self.frame_index = (frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    fn createImageSemaphores(self: *Renderer) !void {
        var sci = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sci.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        const sems = try self.allocator.alloc(c.VkSemaphore, self.swapchain.images.len);
        @memset(sems, null);
        errdefer {
            for (sems) |s| if (s != null) c.vkDestroySemaphore(self.ctx.device, s, null);
            self.allocator.free(sems);
        }
        for (sems) |*s| try vk.check(c.vkCreateSemaphore(self.ctx.device, &sci, null, s));
        self.render_finished = sems;
    }

    fn recreateSwapchain(self: *Renderer) !void {
        // Wait for any minimisation to end — Wayland reports framebuffer
        // size = (0, 0) for a minimised window, and Vulkan refuses to
        // create a swapchain at zero extent.
        while (true) {
            const fb = self.window.framebufferSize();
            if (fb.w != 0 and fb.h != 0) break;
            win.c.glfwWaitEvents();
        }

        _ = c.vkDeviceWaitIdle(self.ctx.device);

        // Free image-bound semaphores first (image count may change on
        // recreate, e.g. compositor swap from MAILBOX to FIFO).
        for (self.render_finished) |s| if (s != null) c.vkDestroySemaphore(self.ctx.device, s, null);
        self.allocator.free(self.render_finished);
        self.render_finished = &.{};

        self.swapchain.deinit();
        self.swapchain.* = try swap.Swapchain.init(self.allocator, self.ctx, self.window);

        try self.createImageSemaphores();
    }
};

const ImageTransition = struct {
    src_stage: c.VkPipelineStageFlags2,
    dst_stage: c.VkPipelineStageFlags2,
    src_access: c.VkAccessFlags2,
    dst_access: c.VkAccessFlags2,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
};

fn transitionImage(cmd: c.VkCommandBuffer, image: c.VkImage, t: ImageTransition) void {
    var b = std.mem.zeroes(c.VkImageMemoryBarrier2);
    b.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    b.srcStageMask = t.src_stage;
    b.dstStageMask = t.dst_stage;
    b.srcAccessMask = t.src_access;
    b.dstAccessMask = t.dst_access;
    b.oldLayout = t.old_layout;
    b.newLayout = t.new_layout;
    b.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };

    var dep = std.mem.zeroes(c.VkDependencyInfo);
    dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &b;
    c.vkCmdPipelineBarrier2(cmd, &dep);
}
