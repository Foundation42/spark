//! Graphics pipeline that draws a textured quad sampling the glyph
//! atlas. Phase 2 issues one quad per `recordDraw` call via push
//! constants; Phase 3 will replace this with an instanced draw
//! consuming a per-glyph SSBO so we can render whole paragraphs in
//! one submit.
//!
//! The pipeline targets vkCmdBeginRendering directly (no VkRenderPass
//! / VkFramebuffer) — it just declares the swapchain colour format
//! via `VkPipelineRenderingCreateInfo`. Viewport + scissor are
//! dynamic so the renderer doesn't have to recreate the pipeline on
//! window resize.

const std = @import("std");
const vk = @import("vk.zig");
const atlas_mod = @import("atlas.zig");
const shaders = @import("shaders");

const c = vk.c;

/// Push-constant block. Layout must match shaders/text.{vert,frag}'s
/// `layout(push_constant) uniform PC { ... }` exactly. extern struct
/// + manual field ordering keeps std430 happy: vec4 first (16-byte
/// align), then six vec2s back-to-back (each 8 bytes, no padding).
pub const TextPushConsts = extern struct {
    color: [4]f32,
    dst_pos: [2]f32,
    dst_size: [2]f32,
    viewport_size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
};

comptime {
    std.debug.assert(@sizeOf(TextPushConsts) == 56);
}

pub const TextPipeline = struct {
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set: c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    device: c.VkDevice, // borrowed

    pub fn init(
        ctx: *const vk.Context,
        color_format: c.VkFormat,
        atlas: *const atlas_mod.Atlas,
    ) !TextPipeline {
        const dev = ctx.device;
        var self: TextPipeline = .{
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .pipeline_layout = null,
            .pipeline = null,
            .device = dev,
        };
        errdefer self.deinit();

        // ── Descriptor set layout: one combined image sampler ───────
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

        // ── Descriptor pool: one set, one sampler binding ───────────
        var ps = std.mem.zeroes(c.VkDescriptorPoolSize);
        ps.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        ps.descriptorCount = 1;
        var dp_ci = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        dp_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dp_ci.poolSizeCount = 1;
        dp_ci.pPoolSizes = &ps;
        dp_ci.maxSets = 1;
        try vk.check(c.vkCreateDescriptorPool(dev, &dp_ci, null, &self.descriptor_pool));

        // ── Allocate + update the descriptor set with the atlas ─────
        var ds_ai = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ds_ai.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds_ai.descriptorPool = self.descriptor_pool;
        ds_ai.descriptorSetCount = 1;
        ds_ai.pSetLayouts = &self.descriptor_set_layout;
        try vk.check(c.vkAllocateDescriptorSets(dev, &ds_ai, &self.descriptor_set));

        var img_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        img_info.sampler = atlas.sampler;
        img_info.imageView = atlas.view;
        img_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.descriptor_set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &img_info;
        c.vkUpdateDescriptorSets(dev, 1, &write, 0, null);

        // ── Pipeline layout: descriptor set + push constants ────────
        var pc_range = std.mem.zeroes(c.VkPushConstantRange);
        pc_range.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        pc_range.offset = 0;
        pc_range.size = @sizeOf(TextPushConsts);
        var pl_ci = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pl_ci.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_ci.setLayoutCount = 1;
        pl_ci.pSetLayouts = &self.descriptor_set_layout;
        pl_ci.pushConstantRangeCount = 1;
        pl_ci.pPushConstantRanges = &pc_range;
        try vk.check(c.vkCreatePipelineLayout(dev, &pl_ci, null, &self.pipeline_layout));

        // ── Shader modules (transient — destroyed after pipeline) ───
        const vert_mod = try createShaderModule(dev, &shaders.text_vert);
        defer c.vkDestroyShaderModule(dev, vert_mod, null);
        const frag_mod = try createShaderModule(dev, &shaders.text_frag);
        defer c.vkDestroyShaderModule(dev, frag_mod, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            stageInfo(c.VK_SHADER_STAGE_VERTEX_BIT, vert_mod),
            stageInfo(c.VK_SHADER_STAGE_FRAGMENT_BIT, frag_mod),
        };

        // No vertex buffer — positions come from gl_VertexIndex.
        var vis = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vis.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        var ias = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        ias.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ias.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        // Viewport + scissor are dynamic; sizes set per-frame.
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

        // Straight-alpha blend: out_rgb = src.rgb * src.a + dst.rgb * (1 - src.a)
        // out_a = src.a + dst.a * (1 - src.a). Fine for opaque
        // backgrounds; Phase 3 may switch to pre-multiplied alpha if
        // we add layered effects (glow / drop shadow) on top.
        var cba = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        cba.blendEnable = c.VK_TRUE;
        cba.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
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

        // Dynamic-rendering attachment formats — substitute for
        // VkRenderPass / VkSubpassDescription.
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
        return self;
    }

    pub fn deinit(self: *TextPipeline) void {
        if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        // Descriptor sets are freed when their pool is destroyed.
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.* = undefined;
    }

    /// Bind the pipeline + descriptor set, set viewport/scissor for
    /// `extent`, push the per-glyph constants, draw 6 verts (one
    /// quad). Must be called inside an active vkCmdBeginRendering
    /// block whose colour format matches the `color_format` passed
    /// to `init`.
    pub fn recordDraw(
        self: *const TextPipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        pc: TextPushConsts,
    ) void {
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        c.vkCmdBindDescriptorSets(
            cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &self.descriptor_set,
            0,
            null,
        );

        var viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .minDepth = 0,
            .maxDepth = 1,
        };
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        var scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);

        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(TextPushConsts),
            &pc,
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
