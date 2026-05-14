//! Quad pipeline — instanced filled rectangles with optional rounded
//! corners. Lives alongside `text_pipeline` and drives the same
//! `vkCmdBeginRendering` block: the demo records quads first
//! (backgrounds) then glyphs (text on top) in one render pass.
//!
//! Same shape as `text_pipeline`:
//!   * One `vkCmdDraw(6, n_quads, 0, 0)` per frame.
//!   * Host-visible host-coherent SSBO sized at init, mapped, written
//!     via `writeQuads(slice)` with no explicit flush.
//!   * Dynamic rendering, dynamic viewport / scissor, viewport size
//!     in a push constant.
//!   * Premultiplied-alpha blend (the fragment shader premultiplies
//!     at output, so `srcFactor = ONE` works for both pipelines).
//!
//! The Quad SSBO entry has its own descriptor set (one binding at
//! slot 0) — separate from text_pipeline's, so the two can be bound
//! independently without conflicting layouts.

const std = @import("std");
const vk = @import("vk.zig");
const shaders = @import("shaders");

const c = vk.c;

/// Per-quad SSBO entry. Layout must match the GLSL `QuadInstance`
/// struct in `shaders/quad.vert` under std430.
///
///   * `color` is NOT premultiplied here — fragment premultiplies at
///     output so theme authors can think in straight RGBA when
///     declaring `quote_bar_color = .{ R, G, B, A }`.
///   * `radius` is corner radius in display pixels; 0 = sharp.
///   * std430 pads the struct to a multiple of 16 (the vec4
///     alignment). Total stride: 48 bytes (16 + 16 + 16).
pub const QuadInstance = extern struct {
    dst_pos: [2]f32,
    dst_size: [2]f32,
    color: [4]f32,
    radius: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(QuadInstance) == 48);
}

pub const QuadPushConsts = extern struct {
    viewport_size: [2]f32,
};

pub const QuadPipeline = struct {
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set: c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,

    quad_buffer: c.VkBuffer,
    quad_memory: c.VkDeviceMemory,
    quad_mapped: [*]QuadInstance,
    quad_capacity: u32,

    device: c.VkDevice, // borrowed

    pub fn init(
        ctx: *const vk.Context,
        color_format: c.VkFormat,
        max_quads: u32,
    ) !QuadPipeline {
        const dev = ctx.device;
        var self: QuadPipeline = .{
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .pipeline_layout = null,
            .pipeline = null,
            .quad_buffer = null,
            .quad_memory = null,
            .quad_mapped = undefined,
            .quad_capacity = max_quads,
            .device = dev,
        };
        errdefer self.deinit();

        // ── SSBO: host-visible, host-coherent ──────────────────────
        const bytes: u64 = @as(u64, max_quads) * @sizeOf(QuadInstance);
        var bci = std.mem.zeroes(c.VkBufferCreateInfo);
        bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = bytes;
        bci.usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try vk.check(c.vkCreateBuffer(dev, &bci, null, &self.quad_buffer));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(dev, self.quad_buffer, &req);
        const mt = try findMemoryType(
            ctx.physical_device,
            req.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = mt;
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.quad_memory));
        try vk.check(c.vkBindBufferMemory(dev, self.quad_buffer, self.quad_memory, 0));

        var raw: ?*anyopaque = null;
        try vk.check(c.vkMapMemory(dev, self.quad_memory, 0, bytes, 0, &raw));
        self.quad_mapped = @ptrCast(@alignCast(raw.?));

        // ── Descriptor set layout — one SSBO binding ───────────────
        var binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        binding.binding = 0;
        binding.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        binding.descriptorCount = 1;
        binding.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;

        var dsl_ci = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        dsl_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dsl_ci.bindingCount = 1;
        dsl_ci.pBindings = &binding;
        try vk.check(c.vkCreateDescriptorSetLayout(dev, &dsl_ci, null, &self.descriptor_set_layout));

        // ── Descriptor pool ────────────────────────────────────────
        var pool_size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
        };
        var dp_ci = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        dp_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dp_ci.poolSizeCount = 1;
        dp_ci.pPoolSizes = &pool_size;
        dp_ci.maxSets = 1;
        try vk.check(c.vkCreateDescriptorPool(dev, &dp_ci, null, &self.descriptor_pool));

        var ds_ai = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ds_ai.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds_ai.descriptorPool = self.descriptor_pool;
        ds_ai.descriptorSetCount = 1;
        ds_ai.pSetLayouts = &self.descriptor_set_layout;
        try vk.check(c.vkAllocateDescriptorSets(dev, &ds_ai, &self.descriptor_set));

        var buf_info = c.VkDescriptorBufferInfo{
            .buffer = self.quad_buffer,
            .offset = 0,
            .range = bytes,
        };
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.descriptor_set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &buf_info;
        c.vkUpdateDescriptorSets(dev, 1, &write, 0, null);

        // ── Pipeline layout ────────────────────────────────────────
        var pc_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = @sizeOf(QuadPushConsts),
        };
        var pl_ci = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pl_ci.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_ci.setLayoutCount = 1;
        pl_ci.pSetLayouts = &self.descriptor_set_layout;
        pl_ci.pushConstantRangeCount = 1;
        pl_ci.pPushConstantRanges = &pc_range;
        try vk.check(c.vkCreatePipelineLayout(dev, &pl_ci, null, &self.pipeline_layout));

        // ── Shader modules ─────────────────────────────────────────
        const vert_mod = try createShaderModule(dev, &shaders.quad_vert);
        defer c.vkDestroyShaderModule(dev, vert_mod, null);
        const frag_mod = try createShaderModule(dev, &shaders.quad_frag);
        defer c.vkDestroyShaderModule(dev, frag_mod, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            stageInfo(c.VK_SHADER_STAGE_VERTEX_BIT, vert_mod),
            stageInfo(c.VK_SHADER_STAGE_FRAGMENT_BIT, frag_mod),
        };

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

        // Premultiplied-alpha blend, same as text pipeline.
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
        return self;
    }

    pub fn deinit(self: *QuadPipeline) void {
        if (self.quad_memory != null) {
            c.vkUnmapMemory(self.device, self.quad_memory);
            c.vkFreeMemory(self.device, self.quad_memory, null);
        }
        if (self.quad_buffer != null) c.vkDestroyBuffer(self.device, self.quad_buffer, null);
        if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.* = undefined;
    }

    /// Copy `quads` into the mapped SSBO. Memory is host-coherent so
    /// the write is visible to the next submit without explicit
    /// flush. Returns `error.SsboOverflow` if the slice doesn't fit.
    pub fn writeQuads(self: *QuadPipeline, quads: []const QuadInstance) !void {
        if (quads.len > self.quad_capacity) return error.SsboOverflow;
        @memcpy(self.quad_mapped[0..quads.len], quads);
    }

    /// Bind + draw. Must run inside an active vkCmdBeginRendering
    /// block whose colour format matches `init`'s `color_format`.
    /// Records before text_pipeline.recordDraw in the same block so
    /// backgrounds land under glyphs.
    pub fn recordDraw(
        self: *const QuadPipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        n_quads: u32,
    ) void {
        if (n_quads == 0) return;
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
        var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);

        const pc = QuadPushConsts{ .viewport_size = .{
            @floatFromInt(extent.width),
            @floatFromInt(extent.height),
        } };
        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(QuadPushConsts),
            &pc,
        );
        c.vkCmdDraw(cmd, 6, n_quads, 0, 0);
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
