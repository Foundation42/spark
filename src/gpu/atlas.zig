//! Glyph atlas: a single R8_UNORM image backed by device-local memory,
//! sampled with linear filtering. The text pipeline binds this as a
//! combined-image-sampler at descriptor set 0, binding 0.
//!
//! Phase 2 ships the simplest possible variant — fixed-size image,
//! manual `uploadRegion` to plant a glyph bitmap into a known XY,
//! one-shot command buffer per upload. Phase 3 layers a rectangle
//! packer + a key→{u, v, w, h} map on top so the renderer can fetch
//! "where is glyph G of font F at size S in this atlas" without
//! callers tracking layout themselves.
//!
//! Layout transitions:
//!   * After `init`: the image lives in SHADER_READ_ONLY_OPTIMAL,
//!     ready to be sampled even before any upload (it's just zeros).
//!   * `uploadRegion` transitions to TRANSFER_DST → copies →
//!     transitions back to SHADER_READ_ONLY_OPTIMAL. Uses a one-shot
//!     command buffer on the graphics queue with a fence wait, so
//!     callers don't have to worry about ordering vs the frame loop.

const std = @import("std");
const vk = @import("vk.zig");

const c = vk.c;

pub const Atlas = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    extent: c.VkExtent2D,

    // Borrowed Vulkan handles — Atlas does not own these.
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    queue: c.VkQueue,
    queue_family: u32,

    pub fn init(
        ctx: *const vk.Context,
        width: u32,
        height: u32,
    ) !Atlas {
        const dev = ctx.device;
        const pd = ctx.physical_device;

        var self: Atlas = .{
            .image = null,
            .memory = null,
            .view = null,
            .sampler = null,
            .extent = .{ .width = width, .height = height },
            .device = dev,
            .physical_device = pd,
            .queue = ctx.queue,
            .queue_family = ctx.queue_family,
        };
        errdefer self.deinit();

        // ── Image ───────────────────────────────────────────────────
        var ici = std.mem.zeroes(c.VkImageCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = c.VK_IMAGE_TYPE_2D;
        ici.format = c.VK_FORMAT_R8_UNORM;
        ici.extent = .{ .width = width, .height = height, .depth = 1 };
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ici.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        ici.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try vk.check(c.vkCreateImage(dev, &ici, null, &self.image));

        // ── Memory ──────────────────────────────────────────────────
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, self.image, &req);
        const mem_type = try findMemoryType(pd, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = mem_type;
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.memory));
        try vk.check(c.vkBindImageMemory(dev, self.image, self.memory, 0));

        // ── View ────────────────────────────────────────────────────
        var ivci = std.mem.zeroes(c.VkImageViewCreateInfo);
        ivci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ivci.image = self.image;
        ivci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = c.VK_FORMAT_R8_UNORM;
        ivci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        try vk.check(c.vkCreateImageView(dev, &ivci, null, &self.view));

        // ── Sampler ─────────────────────────────────────────────────
        // Linear min/mag for body text — bilinear interpolation of the
        // coverage values. Phase 6 will revisit when we add MSDF (the
        // distance-field sampler stays linear; the texel→threshold
        // math happens in the fragment shader regardless).
        var sci = std.mem.zeroes(c.VkSamplerCreateInfo);
        sci.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sci.magFilter = c.VK_FILTER_LINEAR;
        sci.minFilter = c.VK_FILTER_LINEAR;
        sci.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sci.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.borderColor = c.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
        sci.maxLod = 0.0;
        sci.minLod = 0.0;
        sci.maxAnisotropy = 1.0;
        try vk.check(c.vkCreateSampler(dev, &sci, null, &self.sampler));

        // Pre-transition the (zero-filled) image to SHADER_READ_ONLY_OPTIMAL
        // so it's immediately sampleable. Without this the first frame
        // would sample an UNDEFINED-layout image and the validation
        // layer would complain.
        try self.transitionToShaderRead();

        return self;
    }

    pub fn deinit(self: *Atlas) void {
        if (self.sampler != null) c.vkDestroySampler(self.device, self.sampler, null);
        if (self.view != null) c.vkDestroyImageView(self.device, self.view, null);
        if (self.image != null) c.vkDestroyImage(self.device, self.image, null);
        if (self.memory != null) c.vkFreeMemory(self.device, self.memory, null);
        self.* = undefined;
    }

    /// Upload an 8-bit grayscale `pixels` buffer of size `w*h` (row
    /// pitch == w) into the atlas at `(dst_x, dst_y)`. Synchronous —
    /// returns after the copy is done and the image is back in
    /// SHADER_READ_ONLY_OPTIMAL.
    pub fn uploadRegion(
        self: *Atlas,
        dst_x: u32,
        dst_y: u32,
        w: u32,
        h: u32,
        pixels: []const u8,
    ) !void {
        std.debug.assert(pixels.len == w * h);
        if (w == 0 or h == 0) return;

        // ── Staging buffer (host-visible, host-coherent) ────────────
        var staging = try Staging.init(self.physical_device, self.device, w * h);
        defer staging.deinit(self.device);
        @memcpy(staging.mapped[0..pixels.len], pixels);

        // ── One-shot command buffer on the graphics queue ───────────
        // We borrow the graphics queue for transfer because Vulkan
        // guarantees a graphics-capable family also supports transfer;
        // creates one less queue/family to plumb around for Phase 2.
        var pool: c.VkCommandPool = null;
        var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        cpci.queueFamilyIndex = self.queue_family;
        try vk.check(c.vkCreateCommandPool(self.device, &cpci, null, &pool));
        defer c.vkDestroyCommandPool(self.device, pool, null);

        var cmd: c.VkCommandBuffer = null;
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        try vk.check(c.vkAllocateCommandBuffers(self.device, &ai, &cmd));

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        // SHADER_READ_ONLY → TRANSFER_DST_OPTIMAL
        cmdImageBarrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            c.VK_PIPELINE_STAGE_2_COPY_BIT,
            c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        );

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.bufferOffset = 0;
        region.bufferRowLength = 0; // tightly packed
        region.bufferImageHeight = 0;
        region.imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        region.imageOffset = .{ .x = @intCast(dst_x), .y = @intCast(dst_y), .z = 0 };
        region.imageExtent = .{ .width = w, .height = h, .depth = 1 };
        c.vkCmdCopyBufferToImage(
            cmd,
            staging.buffer,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        // TRANSFER_DST_OPTIMAL → SHADER_READ_ONLY_OPTIMAL
        cmdImageBarrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            c.VK_PIPELINE_STAGE_2_COPY_BIT,
            c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        );

        try vk.check(c.vkEndCommandBuffer(cmd));

        // Submit + fence-wait. Could be unified with the frame loop
        // via a transfer queue + semaphore handshake, but for one-time
        // upload at startup the synchronous path is simpler and the
        // few-millisecond stall is invisible to the user.
        var ci = std.mem.zeroes(c.VkFenceCreateInfo);
        ci.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        var fence: c.VkFence = null;
        try vk.check(c.vkCreateFence(self.device, &ci, null, &fence));
        defer c.vkDestroyFence(self.device, fence, null);

        var cmd_info = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
        cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
        cmd_info.commandBuffer = cmd;
        var si = std.mem.zeroes(c.VkSubmitInfo2);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
        si.commandBufferInfoCount = 1;
        si.pCommandBufferInfos = &cmd_info;
        try vk.check(c.vkQueueSubmit2(self.queue, 1, &si, fence));
        try vk.check(c.vkWaitForFences(self.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));
    }

    fn transitionToShaderRead(self: *Atlas) !void {
        var pool: c.VkCommandPool = null;
        var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        cpci.queueFamilyIndex = self.queue_family;
        try vk.check(c.vkCreateCommandPool(self.device, &cpci, null, &pool));
        defer c.vkDestroyCommandPool(self.device, pool, null);

        var cmd: c.VkCommandBuffer = null;
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        try vk.check(c.vkAllocateCommandBuffers(self.device, &ai, &cmd));

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));
        cmdImageBarrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            0,
            c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        );
        try vk.check(c.vkEndCommandBuffer(cmd));

        var fci = std.mem.zeroes(c.VkFenceCreateInfo);
        fci.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        var fence: c.VkFence = null;
        try vk.check(c.vkCreateFence(self.device, &fci, null, &fence));
        defer c.vkDestroyFence(self.device, fence, null);

        var cmd_info = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
        cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
        cmd_info.commandBuffer = cmd;
        var si = std.mem.zeroes(c.VkSubmitInfo2);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
        si.commandBufferInfoCount = 1;
        si.pCommandBufferInfos = &cmd_info;
        try vk.check(c.vkQueueSubmit2(self.queue, 1, &si, fence));
        try vk.check(c.vkWaitForFences(self.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));
    }
};

const Staging = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    mapped: [*]u8,

    fn init(pd: c.VkPhysicalDevice, dev: c.VkDevice, size: u64) !Staging {
        var bci = std.mem.zeroes(c.VkBufferCreateInfo);
        bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = size;
        bci.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        var buf: c.VkBuffer = null;
        try vk.check(c.vkCreateBuffer(dev, &bci, null, &buf));
        errdefer c.vkDestroyBuffer(dev, buf, null);

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(dev, buf, &req);
        const mt = try findMemoryType(
            pd,
            req.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = mt;
        var mem: c.VkDeviceMemory = null;
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &mem));
        errdefer c.vkFreeMemory(dev, mem, null);
        try vk.check(c.vkBindBufferMemory(dev, buf, mem, 0));

        var raw: ?*anyopaque = null;
        try vk.check(c.vkMapMemory(dev, mem, 0, size, 0, &raw));
        return .{
            .buffer = buf,
            .memory = mem,
            .mapped = @ptrCast(raw.?),
        };
    }

    fn deinit(self: *Staging, dev: c.VkDevice) void {
        c.vkUnmapMemory(dev, self.memory);
        c.vkDestroyBuffer(dev, self.buffer, null);
        c.vkFreeMemory(dev, self.memory, null);
        self.* = undefined;
    }
};

fn findMemoryType(
    pd: c.VkPhysicalDevice,
    type_bits: u32,
    required: c.VkMemoryPropertyFlags,
) !u32 {
    var props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(pd, &props);
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if ((type_bits & bit) == 0) continue;
        if ((props.memoryTypes[i].propertyFlags & required) == required) return i;
    }
    return error.NoSuitableMemoryType;
}

fn cmdImageBarrier(
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
    src_stage: c.VkPipelineStageFlags2,
    dst_stage: c.VkPipelineStageFlags2,
    src_access: c.VkAccessFlags2,
    dst_access: c.VkAccessFlags2,
) void {
    var b = std.mem.zeroes(c.VkImageMemoryBarrier2);
    b.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    b.srcStageMask = src_stage;
    b.dstStageMask = dst_stage;
    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    b.oldLayout = old_layout;
    b.newLayout = new_layout;
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
