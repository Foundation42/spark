//! The display transform, rendered both ways on a real device and read back.
//!
//! `src/gpu/display.zig` holds a CPU mirror of `shaders/display.glsl`. Neither
//! copy is the authority: the property this file gates is that **they agree**,
//! measured against pixels a GPU actually produced. A transcription slip in
//! either one — a swapped ST 2084 constant, a dropped matrix row, the encode
//! landing on the wrong side of the premultiply — shows up here as a pixel
//! that is not the colour the mirror predicted.
//!
//! Why pixels and not a shader-source assertion: the interesting failures in
//! this change are all invisible to source inspection. `pq(rgb * a)` compiles
//! exactly as well as `pq(rgb) * a` and differs only in the anti-aliased
//! fraction of every glyph edge in the document.
//!
//! The target is `R8G8B8A8_UNORM` on purpose. An `_SRGB` format would apply
//! its own EOTF on write and the readback would be measuring two transforms
//! stacked; UNORM makes the byte that comes back the value the shader wrote,
//! give or take 8-bit quantisation.
const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const vk = spark.vk;
const display = spark.display;
const qp = @import("../gpu/quad_pipeline.zig");
const fixture = @import("fixture.zig");

const c = vk.c;

const TARGET_W: u32 = 8;
const TARGET_H: u32 = 8;
const TARGET_FORMAT = c.VK_FORMAT_R8G8B8A8_UNORM;

/// 8-bit UNORM quantisation is 1/255. Two codes of slack absorbs that plus
/// the difference between the GPU's `pow` and libm's — tight enough that a
/// wrong constant (which moves things by tenths) cannot hide inside it.
const TOL: f32 = 2.5 / 255.0;

/// One offscreen colour attachment plus the host-visible buffer its pixels
/// are copied into. Local to this file: spark has no readback path of its own
/// because nothing but a gate has ever needed one.
const Readback = struct {
    ctx: *const vk.Context,
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    buffer: c.VkBuffer = null,
    buffer_memory: c.VkDeviceMemory = null,
    pool: c.VkCommandPool = null,

    fn init(ctx: *const vk.Context) !Readback {
        var self = Readback{ .ctx = ctx };
        errdefer self.deinit();
        const dev = ctx.device;

        var ici = std.mem.zeroes(c.VkImageCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = c.VK_IMAGE_TYPE_2D;
        ici.format = TARGET_FORMAT;
        ici.extent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ici.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        ici.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try vk.check(c.vkCreateImage(dev, &ici, null, &self.image));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, self.image, &req);
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(ctx, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.memory));
        try vk.check(c.vkBindImageMemory(dev, self.image, self.memory, 0));

        var vci = std.mem.zeroes(c.VkImageViewCreateInfo);
        vci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vci.image = self.image;
        vci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        vci.format = TARGET_FORMAT;
        vci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        try vk.check(c.vkCreateImageView(dev, &vci, null, &self.view));

        var bci = std.mem.zeroes(c.VkBufferCreateInfo);
        bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = TARGET_W * TARGET_H * 4;
        bci.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try vk.check(c.vkCreateBuffer(dev, &bci, null, &self.buffer));

        c.vkGetBufferMemoryRequirements(dev, self.buffer, &req);
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(
            ctx,
            req.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.buffer_memory));
        try vk.check(c.vkBindBufferMemory(dev, self.buffer, self.buffer_memory, 0));

        var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        cpci.queueFamilyIndex = ctx.queue_family;
        try vk.check(c.vkCreateCommandPool(dev, &cpci, null, &self.pool));

        return self;
    }

    fn deinit(self: *Readback) void {
        const dev = self.ctx.device;
        if (self.pool != null) c.vkDestroyCommandPool(dev, self.pool, null);
        if (self.buffer != null) c.vkDestroyBuffer(dev, self.buffer, null);
        if (self.buffer_memory != null) c.vkFreeMemory(dev, self.buffer_memory, null);
        if (self.view != null) c.vkDestroyImageView(dev, self.view, null);
        if (self.image != null) c.vkDestroyImage(dev, self.image, null);
        if (self.memory != null) c.vkFreeMemory(dev, self.memory, null);
        self.* = undefined;
    }

    /// Draw one full-target quad through the real quad pipeline with `disp`
    /// pushed, then copy the attachment back and return the centre texel as
    /// four floats in 0..1.
    fn drawQuad(
        self: *Readback,
        pipeline: *qp.QuadPipeline,
        color: [4]f32,
        disp: display.Push,
    ) ![4]f32 {
        const dev = self.ctx.device;
        try pipeline.writeQuads(&.{.{
            .dst_pos = .{ 0, 0 },
            .dst_size = .{ @floatFromInt(TARGET_W), @floatFromInt(TARGET_H) },
            .color = color,
            .radius = 0,
        }});

        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = self.pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try vk.check(c.vkAllocateCommandBuffers(dev, &ai, &cmd));
        defer c.vkFreeCommandBuffers(dev, self.pool, 1, &cmd);

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        );

        var att = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        att.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        att.imageView = self.view;
        att.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        att.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        att.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        // Clear to transparent black so a premultiplied source blends onto
        // nothing — the readback is then the shader's own output, undiluted.
        att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        var ri = std.mem.zeroes(c.VkRenderingInfo);
        ri.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = TARGET_W, .height = TARGET_H } };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &att;
        c.vkCmdBeginRendering(cmd, &ri);
        pipeline.recordDrawRange(
            cmd,
            .{ .width = TARGET_W, .height = TARGET_H },
            .{ 0, 0 },
            0,
            1,
            disp,
        
            .main, // the harness renders straight into its readback target
            null, // unclipped: this harness reads back the whole target
        );
        c.vkCmdEndRendering(cmd);

        return try self.finishAndRead(cmd);
    }

    /// Close the command buffer, copy the attachment into the host-visible
    /// buffer, submit, wait, and read the centre pixel. Shared by both draw
    /// paths so they cannot differ in anything but the draw.
    fn finishAndRead(self: *Readback, cmd: c.VkCommandBuffer) ![4]f32 {
        const dev = self.ctx.device;
        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_ACCESS_TRANSFER_READ_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        region.imageExtent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        c.vkCmdCopyImageToBuffer(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.buffer,
            1,
            &region,
        );
        try vk.check(c.vkEndCommandBuffer(cmd));

        var si = std.mem.zeroes(c.VkSubmitInfo);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        try vk.check(c.vkQueueSubmit(self.ctx.queue, 1, &si, null));
        try vk.check(c.vkQueueWaitIdle(self.ctx.queue));

        var raw: ?*anyopaque = null;
        try vk.check(c.vkMapMemory(dev, self.buffer_memory, 0, TARGET_W * TARGET_H * 4, 0, &raw));
        defer c.vkUnmapMemory(dev, self.buffer_memory);
        const px: [*]const u8 = @ptrCast(raw.?);
        const centre = ((TARGET_H / 2) * TARGET_W + (TARGET_W / 2)) * 4;
        var out: [4]f32 = undefined;
        for (0..4) |i| out[i] = @as(f32, @floatFromInt(px[centre + i])) / 255.0;
        return out;
    }

    /// The composite half of the harness: bind a single_source pipeline,
    /// sample `src_view`, draw the fullscreen triangle into the readback
    /// target. Mirrors `Spark.recordSingleSourceCompose`'s push layout
    /// exactly — display at 0, the effect's own uniforms at
    /// `element.PASS_UNIFORM_OFFSET` — because that layout is the thing
    /// under test.
    fn drawComposite(
        self: *Readback,
        cache: *spark.pass.SingleSourcePipelineCache,
        dpool: *spark.pass.SingleSourceDescriptorPool,
        shader_id: [16]u8,
        src_view: c.VkImageView,
        disp: display.Push,
    ) ![4]f32 {
        const dev = self.ctx.device;
        const pipeline = cache.lookup(shader_id, .main) orelse return error.NoPipeline;

        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = self.pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try vk.check(c.vkAllocateCommandBuffers(dev, &ai, &cmd));
        defer c.vkFreeCommandBuffers(dev, self.pool, 1, &cmd);

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        );

        var att = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        att.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        att.imageView = self.view;
        att.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        att.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        att.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        var ri = std.mem.zeroes(c.VkRenderingInfo);
        ri.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = TARGET_W, .height = TARGET_H } };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &att;
        c.vkCmdBeginRendering(cmd, &ri);

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        var set = try dpool.acquire(src_view, cache.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, cache.layout, 0, 1, &set, 0, null);
        var viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(TARGET_W),
            .height = @floatFromInt(TARGET_H),
            .minDepth = 0,
            .maxDepth = 1,
        };
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = TARGET_W, .height = TARGET_H } };
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        var d = disp;
        c.vkCmdPushConstants(cmd, cache.layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(display.Push), &d);
        // The rest of the fixed head. This harness mirrors the record path
        // by hand, so it has to write everything `pushEffectUniforms`
        // writes — a block left unpushed is not zero, it is whatever the
        // command buffer's push memory happened to hold, and a garbage
        // corner radius cuts the composite's alpha and fails the colour
        // comparison below. Which is how this gate caught the head growing
        // under it.
        var corner = spark.element.CornerPush{};
        c.vkCmdPushConstants(
            cmd,
            cache.layout,
            c.VK_SHADER_STAGE_FRAGMENT_BIT,
            @sizeOf(display.Push) + 8,
            @sizeOf(spark.element.CornerPush),
            &corner,
        );
        var alpha: f32 = 1.0;
        c.vkCmdPushConstants(
            cmd,
            cache.layout,
            c.VK_SHADER_STAGE_FRAGMENT_BIT,
            spark.element.PASS_UNIFORM_OFFSET,
            @sizeOf(f32),
            &alpha,
        );
        c.vkCmdDraw(cmd, 3, 1, 0, 0);
        c.vkCmdEndRendering(cmd);

        return try self.finishAndRead(cmd);
    }
};

fn barrier(
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    old: c.VkImageLayout,
    new: c.VkImageLayout,
    src_access: c.VkAccessFlags,
    dst_access: c.VkAccessFlags,
    src_stage: c.VkPipelineStageFlags,
    dst_stage: c.VkPipelineStageFlags,
) void {
    var b = std.mem.zeroes(c.VkImageMemoryBarrier);
    b.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    b.oldLayout = old;
    b.newLayout = new;
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
    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
}

fn findMemoryType(ctx: *const vk.Context, type_bits: u32, props: c.VkMemoryPropertyFlags) !u32 {
    var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props);
    var i: u32 = 0;
    while (i < mem_props.memoryTypeCount) : (i += 1) {
        const bit = @as(u32, 1) << @intCast(i);
        if ((type_bits & bit) != 0 and
            (mem_props.memoryTypes[i].propertyFlags & props) == props) return i;
    }
    return error.NoSuitableMemoryType;
}

/// Stand up a fixture, a readback target, and a quad pipeline against it.
///
/// Initialised THROUGH A POINTER, not returned by value. Both the Readback
/// and the QuadPipeline borrow `&self.fx.ctx` for their lifetime, and a
/// by-value return copies the fixture out of the frame those borrows point
/// into — the queue handle then reads as garbage and `vkQueueSubmit` refuses
/// it. Caught by this file's own first run, which is a fair advertisement for
/// gating with a real device.
const Harness = struct {
    fx: fixture.Fixture,
    rb: Readback,
    pipeline: qp.QuadPipeline,

    fn init(self: *Harness, allocator: std.mem.Allocator) !void {
        self.fx = try fixture.Fixture.init(allocator);
        errdefer self.fx.deinit();
        self.rb = try Readback.init(&self.fx.ctx);
        errdefer self.rb.deinit();
        self.pipeline = try qp.QuadPipeline.init(&self.fx.ctx, TARGET_FORMAT, TARGET_FORMAT, 16);
    }

    fn deinit(self: *Harness) void {
        self.pipeline.deinit();
        self.rb.deinit();
        self.fx.deinit();
    }
};

test "gate: SDR renders the authored colour, unchanged" {
    // The identity half. A host that never mentions display gets what spark
    // has always drawn — this is the claim that makes the transform safe to
    // land under every existing embedder.
    var h: Harness = undefined;
    try h.init(testing.allocator);
    defer h.deinit();

    const color = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    const got = try h.rb.drawQuad(&h.pipeline, color, .{});
    for (0..3) |i| try testing.expectApproxEqAbs(color[i], got[i], TOL);
    try testing.expectApproxEqAbs(@as(f32, 1.0), got[3], TOL);
}

test "gate: PQ renders what the CPU mirror predicts, and it is NOT the SDR pixel" {
    // The whole beat in one assertion pair. Rule 1 first: PQ must differ from
    // SDR, or every check here passes against a shader that ignores the push
    // constant entirely. Then the encoded pixel must match `display.pq` — the
    // agreement between GLSL and Zig that neither file can assert alone.
    var h: Harness = undefined;
    try h.init(testing.allocator);
    defer h.deinit();

    const color = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    const push = display.Push.from(.pq, display.REFERENCE_PAPERWHITE_NITS);
    const sdr = try h.rb.drawQuad(&h.pipeline, color, .{});
    const got = try h.rb.drawQuad(&h.pipeline, color, push);

    var differs = false;
    for (0..3) |i| {
        if (@abs(sdr[i] - got[i]) > 4.0 * TOL) differs = true;
    }
    try testing.expect(differs);

    const want = display.pq(.{ color[0], color[1], color[2] }, display.REFERENCE_PAPERWHITE_NITS);
    for (0..3) |i| try testing.expectApproxEqAbs(want[i], got[i], TOL);
}

test "gate: the encode lands BEFORE the premultiply" {
    // The subtle one, and the reason this file renders instead of reading
    // source. Spark blends with `srcFactor = ONE`, so every shader writes
    // `rgb * a`. PQ is non-linear: `pq(rgb) * a` and `pq(rgb * a)` are
    // different pixels, and the wrong one tints every anti-aliased glyph edge
    // and rounded corner by its own coverage — a bug that looks like bad
    // font rendering, not like a colour-space error.
    //
    // At a = 0.5 the two candidates are far apart, so the gate simply asks
    // which one the GPU produced.
    var h: Harness = undefined;
    try h.init(testing.allocator);
    defer h.deinit();

    const rgb = [3]f32{ 0.25, 0.5, 0.75 };
    const a: f32 = 0.5;
    const push = display.Push.from(.pq, display.REFERENCE_PAPERWHITE_NITS);
    const got = try h.rb.drawQuad(&h.pipeline, .{ rgb[0], rgb[1], rgb[2], a }, push);

    const correct = display.pq(rgb, display.REFERENCE_PAPERWHITE_NITS);
    const wrong = display.pq(.{ rgb[0] * a, rgb[1] * a, rgb[2] * a }, display.REFERENCE_PAPERWHITE_NITS);

    // Assert the two candidates are actually distinguishable before believing
    // the answer — otherwise this passes on a target where they coincide.
    var separated = false;
    for (0..3) |i| {
        if (@abs(correct[i] * a - wrong[i] * a) > 4.0 * TOL) separated = true;
    }
    try testing.expect(separated);

    for (0..3) |i| try testing.expectApproxEqAbs(correct[i] * a, got[i], TOL);
}

test "gate: paperwhite reaches the shader — a brighter page renders brighter" {
    // The push constant carries two floats and the mode alone would satisfy
    // every test above. This one fails if `display.y` never arrives.
    var h: Harness = undefined;
    try h.init(testing.allocator);
    defer h.deinit();

    const color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    const dim = try h.rb.drawQuad(&h.pipeline, color, display.Push.from(.pq, 100.0));
    const bright = try h.rb.drawQuad(&h.pipeline, color, display.Push.from(.pq, 400.0));
    try testing.expect(bright[0] > dim[0] + 0.05);
}

// ── The offscreen attachment format ──────────────────────────────────

/// `A2B10G10R10` is the HDR10 swapchain format, and the whole reason
/// `pickOffscreenFormat` exists: ten bits of colour and **two bits of
/// alpha**. Coverage is alpha, so anything that round-trips through an
/// effect target on that format — a glyph's antialiasing, a drop shadow's
/// falloff — comes back quantised to four levels.
const HDR10_FORMAT: c.VkFormat = c.VK_FORMAT_A2B10G10R10_UNORM_PACK32;

test "gate: an offscreen target never inherits a two-bit alpha" {
    // The bug, in one assertion. matryoshka's HUD on an HDR10 swapchain
    // rendered blocky text with hard dark blobs around it and a drop shadow
    // that vanished entirely past blur≈16 — while the identical document on
    // the SDR swapchain was perfect. Everything OUTSIDE the effect block was
    // crisp on both, because it never left the main attachment.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const picked = spark.vk.pickOffscreenFormat(fx.ctx.physical_device, HDR10_FORMAT);
    if (picked == HDR10_FORMAT) {
        // The honest degradation: a device that cannot colour-attach,
        // blend and linearly sample RGBA16F gets the old behaviour rather
        // than a start-up failure. No desktop GPU is in this bucket, so if
        // this fires on a machine that has one, the query is wrong.
        std.debug.print("\n  device declined RGBA16F for offscreen targets — falling back\n", .{});
        return error.SkipZigTest;
    }
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_R16G16B16A16_SFLOAT), picked);
}

test "gate: the two formats produce two pipelines, and one format produces one" {
    // Rule 1 for the twin. `Variants.forAttachment` falling back to `main`
    // is correct ONLY when the formats coincide; if it fell back always,
    // every offscreen draw would bind a pipeline built for the host's
    // format — undefined behaviour that the validation layers catch and a
    // release build does not.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const shaders = @import("shaders");
    const copy_id = spark.pass.shaderIdFromName("copy.frag");

    // Two different formats: the twin is built, and the two attachments
    // resolve to different pipelines.
    var two = try spark.pass.SingleSourcePipelineCache.init(
        allocator,
        &fx.ctx,
        fx.swapchain.format,
        spark.vk.pickOffscreenFormat(fx.ctx.physical_device, fx.swapchain.format),
        &shaders.fullscreen_vert,
    );
    defer two.deinit();
    try two.compile(copy_id, &shaders.copy_frag);
    const main_pipe = two.lookup(copy_id, .main) orelse return error.NoMainPipeline;
    const off_pipe = two.lookup(copy_id, .offscreen) orelse return error.NoOffscreenPipeline;
    try testing.expect(main_pipe != off_pipe);

    // The same format twice: one pipeline serves both, and nothing is built
    // or destroyed for nothing. (`deinit` destroying an alias twice is the
    // failure this shape rules out by construction — `offscreen` is null,
    // not a copy of `main`.)
    var one = try spark.pass.SingleSourcePipelineCache.init(
        allocator,
        &fx.ctx,
        fx.swapchain.format,
        fx.swapchain.format,
        &shaders.fullscreen_vert,
    );
    defer one.deinit();
    try one.compile(copy_id, &shaders.copy_frag);
    try testing.expectEqual(
        one.lookup(copy_id, .main).?,
        one.lookup(copy_id, .offscreen).?,
    );
}

test "gate: a Spark renders its effect targets in the offscreen format" {
    // The wiring, end to end: the format the pipelines were built for and
    // the format the target pool allocates MUST be the same answer, or the
    // first effect draw is a validation error. One field, read by both.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    try testing.expectEqual(
        spark.vk.pickOffscreenFormat(fx.ctx.physical_device, fx.swapchain.format),
        sp.offscreen_format,
    );
    try testing.expectEqual(sp.offscreen_format, sp.single_source_pipelines.offscreen_format);
    try testing.expectEqual(sp.offscreen_format, sp.pattern_pipelines.offscreen_format);
}

// ── The composite path takes the transform too ───────────────────────

/// A small image the composite gate samples: cleared to a known
/// PREMULTIPLIED colour and left in `SHADER_READ_ONLY_OPTIMAL`, which is
/// exactly the state an effect's offscreen target is in when Phase 2 reaches
/// it. Cleared rather than rendered so this fixture has no opinion about the
/// pipeline that would have filled it.
const Source = struct {
    ctx: *const vk.Context,
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,

    fn init(ctx: *const vk.Context, pool: c.VkCommandPool, premul: [4]f32) !Source {
        var self = Source{ .ctx = ctx };
        errdefer self.deinit();
        const dev = ctx.device;

        var ici = std.mem.zeroes(c.VkImageCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = c.VK_IMAGE_TYPE_2D;
        ici.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
        ici.extent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ici.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        ici.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try vk.check(c.vkCreateImage(dev, &ici, null, &self.image));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, self.image, &req);
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(ctx, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.memory));
        try vk.check(c.vkBindImageMemory(dev, self.image, self.memory, 0));

        var vci = std.mem.zeroes(c.VkImageViewCreateInfo);
        vci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vci.image = self.image;
        vci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        vci.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
        vci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        try vk.check(c.vkCreateImageView(dev, &vci, null, &self.view));

        // Clear + settle into the layout a compose samples from.
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try vk.check(c.vkAllocateCommandBuffers(dev, &ai, &cmd));
        defer c.vkFreeCommandBuffers(dev, pool, 1, &cmd);

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));
        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );
        var cv = c.VkClearColorValue{ .float32 = premul };
        var range = c.VkImageSubresourceRange{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        c.vkCmdClearColorImage(cmd, self.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cv, 1, &range);
        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_ACCESS_SHADER_READ_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        );
        try vk.check(c.vkEndCommandBuffer(cmd));

        var si = std.mem.zeroes(c.VkSubmitInfo);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        try vk.check(c.vkQueueSubmit(ctx.queue, 1, &si, null));
        try vk.check(c.vkQueueWaitIdle(ctx.queue));
        return self;
    }

    fn deinit(self: *Source) void {
        const dev = self.ctx.device;
        if (self.view != null) c.vkDestroyImageView(dev, self.view, null);
        if (self.image != null) c.vkDestroyImage(dev, self.image, null);
        if (self.memory != null) c.vkFreeMemory(dev, self.memory, null);
        self.* = undefined;
    }
};

test "gate: a colour composited through an effect matches the same colour drawn directly" {
    // The property in one sentence, and the one the HDR bench found broken:
    // **content that goes through an effect must look like content that does
    // not.** The composite path skipped the display transform entirely, so a
    // mid-grey card measured 128 outside an effect and 179 inside one on a PQ
    // surface — the same document, six pixels apart.
    //
    // Both halves render the same authored colour with the same push, one
    // through the quad rasterizer and one through `copy.frag` sampling an
    // offscreen target. Neither is the authority; the gate is that they
    // AGREE, which is the shape the rest of this file already uses.
    const allocator = testing.allocator;
    var h: Harness = undefined;
    try h.init(allocator);
    defer h.deinit();

    const authored = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    const pq = display.Push.from(.pq, display.REFERENCE_PAPERWHITE_NITS);

    const shaders = @import("shaders");
    var cache = try spark.pass.SingleSourcePipelineCache.init(
        allocator,
        &h.fx.ctx,
        TARGET_FORMAT,
        TARGET_FORMAT,
        &shaders.fullscreen_vert,
    );
    defer cache.deinit();
    const copy_id = spark.pass.shaderIdFromName("copy.frag");
    try cache.compile(copy_id, &shaders.copy_frag);

    var dpool = try spark.pass.SingleSourceDescriptorPool.init(allocator, &h.fx.ctx, cache.descriptor_set_layout);
    defer dpool.deinit();

    // Alpha 1, so premultiplied and authored are the same numbers and the
    // gate is about the transform rather than about premultiplication.
    var src = try Source.init(&h.fx.ctx, h.rb.pool, authored);
    defer src.deinit();

    const direct = try h.rb.drawQuad(&h.pipeline, authored, pq);
    const through = try h.rb.drawComposite(&cache, &dpool, copy_id, src.view, pq);
    for (0..4) |i| try testing.expectApproxEqAbs(direct[i], through[i], TOL);

    // Rule 1: the PQ pixel is not the authored one, so the agreement above
    // is two encodes agreeing rather than two passthroughs agreeing. Without
    // this, a composite that ignored `display` entirely would pass whenever
    // the quad did too.
    try testing.expect(@abs(direct[0] - authored[0]) > TOL * 4);

    // And on SDR both are the authored colour — the identity that makes this
    // safe under every existing embedder.
    const direct_sdr = try h.rb.drawQuad(&h.pipeline, authored, .{});
    const through_sdr = try h.rb.drawComposite(&cache, &dpool, copy_id, src.view, .{});
    for (0..3) |i| {
        try testing.expectApproxEqAbs(authored[i], direct_sdr[i], TOL);
        try testing.expectApproxEqAbs(authored[i], through_sdr[i], TOL);
    }
}
