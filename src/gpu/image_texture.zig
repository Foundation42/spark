//! Per-image RGBA8 GPU texture (stage 14c).
//!
//! Each `:::image-stream` component owns one of these — a VkImage +
//! view + sampler dedicated to its decoded pixels. Size matches the
//! decoded image; the pipeline samples the full texture into the
//! component's render rect.
//!
//! Distinct from `Atlas` because images aren't packed: each one is
//! its own little texture allocation. For a handful of generated
//! images per document this is wasteful in bytes but simple — when
//! we have hundreds of small images the right move is an image atlas
//! (same packing primitive Atlas already implements; the shape would
//! be `ImageAtlas` adopting `Shelf` instead of one allocation per
//! image).
//!
//! Reuses `Atlas`'s `Staging` + `findMemoryType` + `cmdImageBarrier`
//! helpers (pub-promoted on its behalf) so the staged-copy + barrier
//! discipline lives in one place. The first upload transitions
//! UNDEFINED → SHADER_READ_ONLY_OPTIMAL; subsequent re-uploads bounce
//! through TRANSFER_DST and back.

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;
const atlas_mod = @import("atlas.zig");

pub const ImageTexture = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    extent: c.VkExtent2D,
    /// True once at least one upload has transitioned us to
    /// SHADER_READ_ONLY_OPTIMAL. Subsequent uploads need a
    /// READ_ONLY → TRANSFER_DST barrier instead of UNDEFINED →
    /// TRANSFER_DST.
    ready: bool = false,

    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    queue: c.VkQueue,
    queue_family: u32,

    pub fn init(
        ctx: *const vk.Context,
        width: u32,
        height: u32,
    ) !ImageTexture {
        const dev = ctx.device;
        const pd = ctx.physical_device;

        var self: ImageTexture = .{
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

        // ── Image ──
        // Always RGBA8 (UNORM) — stb_image decodes to that with
        // `desired_channels=4`. SRGB output is the eventual right
        // call but matches Atlas's mono/color UNORM choice for
        // visual consistency on the demo.
        var ici = std.mem.zeroes(c.VkImageCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = c.VK_IMAGE_TYPE_2D;
        ici.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        ici.extent = .{ .width = width, .height = height, .depth = 1 };
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ici.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        ici.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try vk.check(c.vkCreateImage(dev, &ici, null, &self.image));

        // ── Memory ──
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, self.image, &req);
        const mt = try atlas_mod.findMemoryType(pd, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = mt;
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.memory));
        try vk.check(c.vkBindImageMemory(dev, self.image, self.memory, 0));

        // ── View ──
        var ivci = std.mem.zeroes(c.VkImageViewCreateInfo);
        ivci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ivci.image = self.image;
        ivci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        ivci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        try vk.check(c.vkCreateImageView(dev, &ivci, null, &self.view));

        // ── Sampler ──
        // Linear filter for photographic content (the LLM output is
        // usually rasterised art / photo). CLAMP_TO_EDGE so a UV
        // that walks slightly outside [0..1] (sub-pixel scaling
        // ringing) doesn't sample the wrap side.
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

        return self;
    }

    pub fn deinit(self: *ImageTexture) void {
        const dev = self.device;
        if (self.sampler) |s| c.vkDestroySampler(dev, s, null);
        if (self.view) |v| c.vkDestroyImageView(dev, v, null);
        if (self.image) |im| c.vkDestroyImage(dev, im, null);
        if (self.memory) |m| c.vkFreeMemory(dev, m, null);
        self.* = undefined;
    }

    /// Upload `pixels` (RGBA8, `extent.width * extent.height * 4`
    /// bytes) into the texture. Synchronous — returns after the copy
    /// completes and the image is in SHADER_READ_ONLY_OPTIMAL.
    ///
    /// First call transitions UNDEFINED → TRANSFER_DST → READ_ONLY.
    /// Subsequent calls (re-firing the stream with a fresh prompt)
    /// bounce READ_ONLY → TRANSFER_DST → READ_ONLY. Caller is
    /// responsible for matching `pixels.len` to `extent`.
    pub fn upload(self: *ImageTexture, pixels: []const u8) !void {
        const w = self.extent.width;
        const h = self.extent.height;
        const expected = @as(usize, w) * @as(usize, h) * 4;
        std.debug.assert(pixels.len == expected);
        if (w == 0 or h == 0) return;

        var staging = try atlas_mod.Staging.init(self.physical_device, self.device, expected);
        defer staging.deinit(self.device);
        @memcpy(staging.mapped[0..pixels.len], pixels);

        // One-shot command buffer on the graphics queue — same
        // pattern as Atlas.uploadRegion.
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

        // ?layout → TRANSFER_DST. First upload comes from UNDEFINED;
        // re-uploads from SHADER_READ_ONLY_OPTIMAL.
        const src_layout: c.VkImageLayout = if (self.ready)
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        else
            c.VK_IMAGE_LAYOUT_UNDEFINED;
        const src_stage: c.VkPipelineStageFlags2 = if (self.ready)
            c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT
        else
            c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        const src_access: c.VkAccessFlags2 = if (self.ready)
            c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT
        else
            0;
        atlas_mod.cmdImageBarrier(
            cmd,
            self.image,
            src_layout,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            src_stage,
            c.VK_PIPELINE_STAGE_2_COPY_BIT,
            src_access,
            c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        );

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.bufferOffset = 0;
        region.bufferRowLength = 0;
        region.bufferImageHeight = 0;
        region.imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        region.imageOffset = .{ .x = 0, .y = 0, .z = 0 };
        region.imageExtent = .{ .width = w, .height = h, .depth = 1 };
        c.vkCmdCopyBufferToImage(
            cmd,
            staging.buffer,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        atlas_mod.cmdImageBarrier(
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

        self.ready = true;
    }
};
