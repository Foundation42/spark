//! Graphics pipeline that draws a paragraph as one instanced quad
//! draw, indexing into a per-glyph SSBO. One `vkCmdDraw(6, n, 0, 0)`
//! issues `n` glyphs in one submit — the right shape for body text
//! where a screenful is hundreds-to-thousands of glyphs.
//!
//! Phase 3 ships a single SSBO sized at `init` time and host-visible
//! so callers can `writeGlyphs(slice)` straight into mapped memory.
//! Phase 4 will add a ring of double-buffered SSBOs so dynamic text
//! (typing, cursor blink, log streams) doesn't sync with the GPU on
//! every update.
//!
//! Targets `vkCmdBeginRendering` directly — no VkRenderPass / no
//! VkFramebuffer. Viewport + scissor are dynamic state. Push
//! constants carry just the viewport pixel size for the NDC
//! conversion in the vertex stage; per-glyph colour, atlas UV, and
//! pixel rect all travel in the SSBO.

const std = @import("std");
const vk = @import("vk.zig");
const atlas_mod = @import("atlas.zig");
const shaders = @import("shaders");

const c = vk.c;

/// Per-glyph SSBO entry. Layout must match the GLSL `GlyphInstance`
/// struct in `shaders/text.vert` under std430:
///   * each `vec2` is 8-byte aligned (8 bytes wide → no padding)
///   * the `vec4` is 16-byte aligned; four preceding vec2s have
///     already landed it at offset 32 so it's natural.
///   * `tex_select` (uint, 4 bytes) at offset 48.
///   * Struct stride aligns to the struct's max-member alignment
///     (16, from the vec4) — so std430 pads to 64 bytes total. We
///     declare the padding explicitly to keep Zig's `extern struct`
///     size matching the GLSL stride.
pub const GlyphInstance = extern struct {
    dst_pos: [2]f32,
    dst_size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
    /// 0 = mono atlas (R8 coverage), 1 = color atlas (RGBA8). See
    /// `glyph_cache.AtlasKind` — the int values are kept in sync.
    tex_select: u32,
    _pad: [3]u32,
};

comptime {
    std.debug.assert(@sizeOf(GlyphInstance) == 64);
}

pub const TextPushConsts = extern struct {
    viewport_size: [2]f32,
};

pub const TextPipeline = struct {
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set: c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,

    glyph_buffer: c.VkBuffer,
    glyph_memory: c.VkDeviceMemory,
    glyph_mapped: [*]GlyphInstance,
    glyph_capacity: u32,

    device: c.VkDevice, // borrowed

    pub fn init(
        ctx: *const vk.Context,
        color_format: c.VkFormat,
        mono_atlas: *const atlas_mod.Atlas,
        color_atlas: *const atlas_mod.Atlas,
        max_glyphs: u32,
    ) !TextPipeline {
        const dev = ctx.device;
        var self: TextPipeline = .{
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .pipeline_layout = null,
            .pipeline = null,
            .glyph_buffer = null,
            .glyph_memory = null,
            .glyph_mapped = undefined,
            .glyph_capacity = max_glyphs,
            .device = dev,
        };
        errdefer self.deinit();

        // ── SSBO: host-visible, host-coherent so writes from the CPU
        // are immediately visible to subsequent submits without
        // explicit flush. Sized for `max_glyphs` entries up-front. ─
        const bytes: u64 = @as(u64, max_glyphs) * @sizeOf(GlyphInstance);
        var bci = std.mem.zeroes(c.VkBufferCreateInfo);
        bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = bytes;
        bci.usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try vk.check(c.vkCreateBuffer(dev, &bci, null, &self.glyph_buffer));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(dev, self.glyph_buffer, &req);
        const mt = try findMemoryType(
            ctx.physical_device,
            req.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = mt;
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.glyph_memory));
        try vk.check(c.vkBindBufferMemory(dev, self.glyph_buffer, self.glyph_memory, 0));

        var raw: ?*anyopaque = null;
        try vk.check(c.vkMapMemory(dev, self.glyph_memory, 0, bytes, 0, &raw));
        self.glyph_mapped = @ptrCast(@alignCast(raw.?));

        // ── Descriptor set layout ───────────────────────────────────
        // binding 0: mono atlas (R8) — fragment
        // binding 1: glyph SSBO            — vertex
        // binding 2: color atlas (RGBA8)   — fragment
        // Phase 5 reuses the same set across the mono + color lanes
        // so a single bind covers both samplers; the per-glyph
        // `tex_select` in the SSBO picks which one the shader reads.
        var bindings = [_]c.VkDescriptorSetLayoutBinding{
            std.mem.zeroes(c.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(c.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(c.VkDescriptorSetLayoutBinding),
        };
        bindings[0].binding = 0;
        bindings[0].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        bindings[1].binding = 1;
        bindings[1].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;
        bindings[2].binding = 2;
        bindings[2].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[2].descriptorCount = 1;
        bindings[2].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var dsl_ci = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        dsl_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dsl_ci.bindingCount = bindings.len;
        dsl_ci.pBindings = &bindings;
        try vk.check(c.vkCreateDescriptorSetLayout(dev, &dsl_ci, null, &self.descriptor_set_layout));

        // ── Descriptor pool: one set with three bindings ────────────
        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 2 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
        };
        var dp_ci = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        dp_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dp_ci.poolSizeCount = pool_sizes.len;
        dp_ci.pPoolSizes = &pool_sizes;
        dp_ci.maxSets = 1;
        try vk.check(c.vkCreateDescriptorPool(dev, &dp_ci, null, &self.descriptor_pool));

        var ds_ai = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ds_ai.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds_ai.descriptorPool = self.descriptor_pool;
        ds_ai.descriptorSetCount = 1;
        ds_ai.pSetLayouts = &self.descriptor_set_layout;
        try vk.check(c.vkAllocateDescriptorSets(dev, &ds_ai, &self.descriptor_set));

        var mono_info = c.VkDescriptorImageInfo{
            .sampler = mono_atlas.sampler,
            .imageView = mono_atlas.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var color_info = c.VkDescriptorImageInfo{
            .sampler = color_atlas.sampler,
            .imageView = color_atlas.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var buf_info = c.VkDescriptorBufferInfo{
            .buffer = self.glyph_buffer,
            .offset = 0,
            .range = bytes,
        };
        var writes = [_]c.VkWriteDescriptorSet{
            std.mem.zeroes(c.VkWriteDescriptorSet),
            std.mem.zeroes(c.VkWriteDescriptorSet),
            std.mem.zeroes(c.VkWriteDescriptorSet),
        };
        writes[0].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = self.descriptor_set;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[0].pImageInfo = &mono_info;
        writes[1].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = self.descriptor_set;
        writes[1].dstBinding = 1;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[1].pBufferInfo = &buf_info;
        writes[2].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[2].dstSet = self.descriptor_set;
        writes[2].dstBinding = 2;
        writes[2].descriptorCount = 1;
        writes[2].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[2].pImageInfo = &color_info;
        c.vkUpdateDescriptorSets(dev, writes.len, &writes, 0, null);

        // ── Pipeline layout: descriptor set + viewport push consts ──
        var pc_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = @sizeOf(TextPushConsts),
        };
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

        // Premultiplied-alpha blend. Both lanes feed the same blend
        // hardware: mono fragments output `(color.rgb * coverage *
        // color.a, color.a * coverage)` (premultiplied at output);
        // color fragments sample CBDT bitmaps which FT delivers
        // already premultiplied. Using `srcFactor = ONE` (not
        // SRC_ALPHA) avoids the well-known "double-multiplied alpha"
        // smearing on coloured glyphs.
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

    pub fn deinit(self: *TextPipeline) void {
        if (self.glyph_memory != null) {
            c.vkUnmapMemory(self.device, self.glyph_memory);
            c.vkFreeMemory(self.device, self.glyph_memory, null);
        }
        if (self.glyph_buffer != null) c.vkDestroyBuffer(self.device, self.glyph_buffer, null);
        if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.* = undefined;
    }

    /// Copy `glyphs` into the mapped SSBO. Memory is host-coherent, so
    /// no explicit flush is needed before submitting a frame that
    /// reads it. Returns `error.SsboOverflow` if the slice doesn't
    /// fit — caller should bump `max_glyphs` at init time.
    pub fn writeGlyphs(self: *TextPipeline, glyphs: []const GlyphInstance) !void {
        if (glyphs.len > self.glyph_capacity) return error.SsboOverflow;
        @memcpy(self.glyph_mapped[0..glyphs.len], glyphs);
    }

    /// Bind pipeline + descriptor set, set viewport/scissor, push
    /// viewport size, draw 6 verts × `n_glyphs` instances. Must be
    /// called inside an active vkCmdBeginRendering block whose colour
    /// format matches `init`'s `color_format`.
    pub fn recordDraw(
        self: *const TextPipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        n_glyphs: u32,
    ) void {
        if (n_glyphs == 0) return;
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

        const pc = TextPushConsts{ .viewport_size = .{
            @floatFromInt(extent.width),
            @floatFromInt(extent.height),
        } };
        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(TextPushConsts),
            &pc,
        );
        c.vkCmdDraw(cmd, 6, n_glyphs, 0, 0);
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
