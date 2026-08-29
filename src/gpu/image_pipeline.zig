//! Textured-quad pipeline (stage 14c).
//!
//! Renders raster images returned by `:::image-stream` components.
//! Unlike the SSBO-instanced text + quad pipelines (one giant buffer
//! covers every primitive in the frame), each image has its own
//! VkImage + descriptor set — there's no atlas packing across images.
//! The pipeline binds a descriptor per `recordOne` call and draws six
//! verts to make the quad.
//!
//! Push constants:
//!   * `viewport_size` — screen extent for the NDC conversion
//!   * `dst_pos` / `dst_size` — destination rect in display pixels
//!
//! Per-image descriptor sets are allocated from a pool sized for
//! `MAX_IMAGES`; the component owns one slot for its lifetime and
//! writes its (view, sampler) into it after the first upload. Resize
//! invalidates the slot — the descriptor write needs to be re-issued.
//!
//! Render order from `main.zig`: tris → images → quads → glyphs.
//! Images sit between SVG fills and quad chrome so a `:::image-stream`
//! photo doesn't punch a hole through code-block backgrounds, and
//! glyphs sit on top so labels remain legible above any image.

const std = @import("std");
const vk = @import("vk.zig");
const display_mod = @import("display.zig");
const c = vk.c;
const shaders = @import("shaders");

/// Push-constant block mirrors image.vert's `PC`. Field ORDER must
/// match the GLSL layout exactly — adding `world_offset` after
/// `viewport_size` (and before `dst_pos`) keeps the std430 offset
/// table aligned with the shader. `world_offset` matches the
/// quad/text/tri pipelines — (0, 0) for the main attachment,
/// `compose_region.xy` for a single_source offscreen target
/// (Phase B.5 substrate).
pub const ImagePushConsts = extern struct {
    viewport_size: [2]f32,
    world_offset: [2]f32 = .{ 0, 0 },
    dst_pos: [2]f32,
    dst_size: [2]f32,
    /// Output display transform for THIS draw. Read by the fragment
    /// stage — see shaders/display.glsl. No default on purpose: every
    /// record call states whether it is painting the host's attachment
    /// (which carries the host's mode) or an offscreen effect target
    /// (which is always `.offscreen`, because encoding into an
    /// intermediate would encode twice).
    display: display_mod.Push,
};

comptime {
    // Lock the std430 push-constant block size — mirrors the GLSL
    // `PC` in image.vert.
    std.debug.assert(@sizeOf(ImagePushConsts) == 40);
    // `display` is the tail of the block in the GLSL too. A drift here
    // is silent GPU garbage, which is why it is pinned by offset and
    // not only by total size.
    std.debug.assert(@offsetOf(ImagePushConsts, "display") == 32);
    std.debug.assert(@offsetOf(ImagePushConsts, "world_offset") == 8);
    std.debug.assert(@offsetOf(ImagePushConsts, "dst_pos") == 16);
    std.debug.assert(@offsetOf(ImagePushConsts, "dst_size") == 24);
}

pub const ImagePipeline = struct {
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    /// The same pipeline, built for the offscreen effect-target format.
    /// `null` when the two formats are the same and one pipeline serves
    /// both — which keeps `deinit` from ever destroying an alias twice.
    pipeline_offscreen: c.VkPipeline = null,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    /// Cap on how many simultaneous images can exist. Each image
    /// owns one slot from the descriptor pool.
    max_images: u32,

    device: c.VkDevice,

    pub fn init(
        ctx: *const vk.Context,
        color_format: c.VkFormat,
        offscreen_format: c.VkFormat,
        max_images: u32,
    ) !ImagePipeline {
        const dev = ctx.device;
        var self: ImagePipeline = .{
            .pipeline_layout = null,
            .pipeline = null,
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .max_images = max_images,
            .device = dev,
        };
        errdefer self.deinit();

        // ── Descriptor set layout (1 combined image sampler) ──
        var binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        binding.binding = 0;
        binding.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        binding.descriptorCount = 1;
        binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var dsl_ci = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        dsl_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dsl_ci.bindingCount = 1;
        dsl_ci.pBindings = &binding;
        try vk.check(c.vkCreateDescriptorSetLayout(dev, &dsl_ci, null, &self.descriptor_set_layout));

        // ── Descriptor pool sized for max_images slots ──
        var pool_size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = max_images,
        };
        var dp_ci = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        dp_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        // FREE_DESCRIPTOR_SET so components can release their slot
        // on resize / re-fire (`vkFreeDescriptorSets`).
        dp_ci.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        dp_ci.maxSets = max_images;
        dp_ci.poolSizeCount = 1;
        dp_ci.pPoolSizes = &pool_size;
        try vk.check(c.vkCreateDescriptorPool(dev, &dp_ci, null, &self.descriptor_pool));

        // ── Pipeline layout: 1 descriptor set + push constants ──
        var pc_range = c.VkPushConstantRange{
            // Both stages: the vertex stage reads viewport/offset, the
            // fragment stage reads `display`. One range, one push.
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(ImagePushConsts),
        };
        var pl_ci = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pl_ci.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_ci.setLayoutCount = 1;
        pl_ci.pSetLayouts = &self.descriptor_set_layout;
        pl_ci.pushConstantRangeCount = 1;
        pl_ci.pPushConstantRanges = &pc_range;
        try vk.check(c.vkCreatePipelineLayout(dev, &pl_ci, null, &self.pipeline_layout));

        // ── Shader modules ──
        const vert_mod = try createShaderModule(dev, &shaders.image_vert);
        defer c.vkDestroyShaderModule(dev, vert_mod, null);
        const frag_mod = try createShaderModule(dev, &shaders.image_frag);
        defer c.vkDestroyShaderModule(dev, frag_mod, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            stageInfo(c.VK_SHADER_STAGE_VERTEX_BIT, vert_mod),
            stageInfo(c.VK_SHADER_STAGE_FRAGMENT_BIT, frag_mod),
        };

        // No vertex inputs — gl_VertexIndex drives the quad corners.
        var vis = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vis.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        var ias = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        ias.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ias.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var vps = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        vps.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vps.viewportCount = 1;
        vps.scissorCount = 1;

        var rs = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rs.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = c.VK_POLYGON_MODE_FILL;
        rs.cullMode = c.VK_CULL_MODE_NONE;
        rs.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.lineWidth = 1.0;

        var ms = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        ms.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        // Premultiplied alpha — fragment outputs `c.rgb * c.a` and
        // composites with srcFactor = ONE. Matches the rest of the
        // spark pipelines so layered output is consistent.
        var cba = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        cba.blendEnable = c.VK_TRUE;
        cba.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
        cba.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        cba.colorBlendOp = c.VK_BLEND_OP_ADD;
        cba.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        cba.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        cba.alphaBlendOp = c.VK_BLEND_OP_ADD;
        cba.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        var cbs = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        cbs.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cbs.attachmentCount = 1;
        cbs.pAttachments = &cba;

        var dyn_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };
        var dys = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dys.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dys.dynamicStateCount = dyn_states.len;
        dys.pDynamicStates = &dyn_states;

        var rendering_info = std.mem.zeroes(c.VkPipelineRenderingCreateInfo);
        rendering_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
        rendering_info.colorAttachmentCount = 1;
        rendering_info.pColorAttachmentFormats = &color_format;

        var gpci = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        gpci.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        gpci.pNext = &rendering_info;
        gpci.stageCount = stages.len;
        gpci.pStages = &stages;
        gpci.pVertexInputState = &vis;
        gpci.pInputAssemblyState = &ias;
        gpci.pViewportState = &vps;
        gpci.pRasterizationState = &rs;
        gpci.pMultisampleState = &ms;
        gpci.pColorBlendState = &cbs;
        gpci.pDynamicState = &dys;
        gpci.layout = self.pipeline_layout;
        try vk.check(c.vkCreateGraphicsPipelines(dev, null, 1, &gpci, null, &self.pipeline));
        // The offscreen twin. Only the attachment format differs — same
        // layout, same blend, same shaders — so it is the identical
        // create-info with one pointer swapped. Skipped entirely when the
        // host's format already is the offscreen one.
        if (offscreen_format != color_format) {
            var off_fmt = offscreen_format;
            rendering_info.pColorAttachmentFormats = &off_fmt;
            var off_pipeline: c.VkPipeline = null;
            try vk.check(c.vkCreateGraphicsPipelines(dev, null, 1, &gpci, null, &off_pipeline));
            self.pipeline_offscreen = off_pipeline;
        }

        return self;
    }

    /// The pipeline to bind for a draw into `att`. An offscreen draw falls
    /// back to the main pipeline when the two formats coincide, which is the
    /// SDR case and every device that cannot colour-attach RGBA16F.
    pub fn pipelineFor(self: *const @This(), att: vk.Attachment) c.VkPipeline {
        return switch (att) {
            .main => self.pipeline,
            .offscreen => self.pipeline_offscreen orelse self.pipeline,
        };
    }

    pub fn deinit(self: *ImagePipeline) void {
        const dev = self.device;
        if (self.pipeline_offscreen) |p| c.vkDestroyPipeline(dev, p, null);
        if (self.pipeline) |p| c.vkDestroyPipeline(dev, p, null);
        if (self.pipeline_layout) |l| c.vkDestroyPipelineLayout(dev, l, null);
        if (self.descriptor_pool) |p| c.vkDestroyDescriptorPool(dev, p, null);
        if (self.descriptor_set_layout) |l| c.vkDestroyDescriptorSetLayout(dev, l, null);
        self.* = undefined;
    }

    /// Allocate one descriptor set for a new image. Caller must
    /// `freeDescriptor` it before destroying the underlying texture.
    pub fn allocDescriptor(self: *ImagePipeline) !c.VkDescriptorSet {
        var ai = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ai.descriptorPool = self.descriptor_pool;
        ai.descriptorSetCount = 1;
        ai.pSetLayouts = &self.descriptor_set_layout;
        var ds: c.VkDescriptorSet = null;
        try vk.check(c.vkAllocateDescriptorSets(self.device, &ai, &ds));
        return ds;
    }

    pub fn freeDescriptor(self: *ImagePipeline, ds: c.VkDescriptorSet) void {
        var local = ds;
        _ = c.vkFreeDescriptorSets(self.device, self.descriptor_pool, 1, &local);
    }

    /// Bind a (view, sampler) pair into the given descriptor set.
    /// Called after the first upload and after every re-upload that
    /// changes the underlying texture.
    pub fn writeDescriptor(self: *ImagePipeline, ds: c.VkDescriptorSet, view: c.VkImageView, sampler: c.VkSampler) void {
        var info = c.VkDescriptorImageInfo{
            .sampler = sampler,
            .imageView = view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var w = std.mem.zeroes(c.VkWriteDescriptorSet);
        w.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        w.dstSet = ds;
        w.dstBinding = 0;
        w.descriptorCount = 1;
        w.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        w.pImageInfo = &info;
        c.vkUpdateDescriptorSets(self.device, 1, &w, 0, null);
    }

    /// Bind pipeline + viewport/scissor once per frame. Call once
    /// before issuing any `recordOne` calls inside the same frame.
    pub fn bind(self: *const ImagePipeline, cmd: c.VkCommandBuffer, extent: c.VkExtent2D, att: vk.Attachment) void {
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipelineFor(att));
        var viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .minDepth = 0,
            .maxDepth = 1,
        };
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);
    }

    /// Record one image draw. Caller must have already called `bind`
    /// this frame. Position + size are in display pixels (the same
    /// world-space units the rest of the layout uses); the world →
    /// screen transform is the host's post-layout pass on DrawList
    /// (handled there to keep the pipeline simple).
    ///
    /// `world_offset`: see `quad_pipeline.recordDrawRange` —
    /// (0, 0) for MAIN, `compose_region.xy` for an offscreen target.
    pub fn recordOne(
        self: *const ImagePipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        world_offset: [2]f32,
        ds: c.VkDescriptorSet,
        dst_pos: [2]f32,
        dst_size: [2]f32,
        disp: display_mod.Push,
    ) void {
        const pc = ImagePushConsts{
            .viewport_size = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
            .world_offset = world_offset,
            .dst_pos = dst_pos,
            .dst_size = dst_size,
            .display = disp,
        };
        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(ImagePushConsts),
            &pc,
        );
        var local = ds;
        c.vkCmdBindDescriptorSets(
            cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &local,
            0,
            null,
        );
        c.vkCmdDraw(cmd, 6, 1, 0, 0);
    }
};

fn createShaderModule(dev: c.VkDevice, blob: []align(4) const u8) !c.VkShaderModule {
    var ci = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    ci.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = blob.len;
    ci.pCode = @ptrCast(@alignCast(blob.ptr));
    var mod: c.VkShaderModule = null;
    try vk.check(c.vkCreateShaderModule(dev, &ci, null, &mod));
    return mod;
}

fn stageInfo(stage: c.VkShaderStageFlagBits, module: c.VkShaderModule) c.VkPipelineShaderStageCreateInfo {
    var s = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    s.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    s.stage = stage;
    s.module = module;
    s.pName = "main";
    return s;
}
