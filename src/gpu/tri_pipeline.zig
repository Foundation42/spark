//! Triangle pipeline — VBO + IBO indexed draw, flat-colour fragments
//! (stage 13d.1). Used by `:::svg` for tessellated SVG fills.
//!
//! Differences from `QuadPipeline`:
//!
//!   * No SSBO instancing. We use a real vertex buffer + index
//!     buffer (host-visible host-coherent so the host can rewrite
//!     each frame). One indexed `vkCmdDrawIndexed` per recordDraw.
//!   * Vertex input bindings carry pos (vec2) + colour (vec4)
//!     interleaved. The `Vertex` struct in `svg_tessellate.zig`
//!     matches the GLSL layout slot-for-slot.
//!
//! Same shape as QuadPipeline otherwise:
//!   * Dynamic rendering, dynamic viewport / scissor.
//!   * Viewport size in push constant.
//!   * Premultiplied-alpha blend with srcFactor = ONE.
//!
//! Capacity: caller picks `max_vertices` / `max_indices` at init.
//! `writeMesh(verts, idx)` returns SsboOverflow if either capacity
//! is exceeded — same error sentinel as text / quad to keep host
//! error-handling uniform.

const std = @import("std");
const vk = @import("vk.zig");
const display_mod = @import("display.zig");
const shaders = @import("shaders");
const tess = @import("../svg_tessellate.zig");

const c = vk.c;

/// Interleaved per-vertex format. Mirrors `tess.Vertex`. Pos in
/// display pixels (NDC conversion in the vertex shader).
pub const Vertex = tess.Vertex;

/// Push-constant block mirrors tri.vert's `PC`. `world_offset`
/// matches the quad/text/image pipelines — (0, 0) for the main
/// attachment, `compose_region.xy` for a single_source offscreen
/// target (Phase B.5 substrate).
pub const TriPushConsts = extern struct {
    viewport_size: [2]f32,
    world_offset: [2]f32 = .{ 0, 0 },
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
    // `PC` in tri.vert.
    std.debug.assert(@sizeOf(TriPushConsts) == 24);
    // `display` is the tail of the block in the GLSL too. A drift here
    // is silent GPU garbage, which is why it is pinned by offset and
    // not only by total size.
    std.debug.assert(@offsetOf(TriPushConsts, "display") == 16);
}

pub const TrianglePipeline = struct {
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    /// The same pipeline, built for the offscreen effect-target format.
    /// `null` when the two formats are the same and one pipeline serves
    /// both — which keeps `deinit` from ever destroying an alias twice.
    pipeline_offscreen: c.VkPipeline = null,

    vertex_buffer: c.VkBuffer,
    vertex_memory: c.VkDeviceMemory,
    vertex_mapped: [*]Vertex,
    vertex_capacity: u32,

    index_buffer: c.VkBuffer,
    index_memory: c.VkDeviceMemory,
    index_mapped: [*]u32,
    index_capacity: u32,

    device: c.VkDevice, // borrowed

    pub fn init(
        ctx: *const vk.Context,
        color_format: c.VkFormat,
        offscreen_format: c.VkFormat,
        max_vertices: u32,
        max_indices: u32,
    ) !TrianglePipeline {
        const dev = ctx.device;
        var self: TrianglePipeline = .{
            .pipeline_layout = null,
            .pipeline = null,
            .vertex_buffer = null,
            .vertex_memory = null,
            .vertex_mapped = undefined,
            .vertex_capacity = max_vertices,
            .index_buffer = null,
            .index_memory = null,
            .index_mapped = undefined,
            .index_capacity = max_indices,
            .device = dev,
        };
        errdefer self.deinit();

        // ── VBO + IBO ──────────────────────────────────────────────
        try createMappedBuffer(
            ctx,
            @as(u64, max_vertices) * @sizeOf(Vertex),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            &self.vertex_buffer,
            &self.vertex_memory,
            @ptrCast(&self.vertex_mapped),
        );
        try createMappedBuffer(
            ctx,
            @as(u64, max_indices) * @sizeOf(u32),
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            &self.index_buffer,
            &self.index_memory,
            @ptrCast(&self.index_mapped),
        );

        // ── Pipeline layout — push constant only, no descriptors ──
        var pc_range = c.VkPushConstantRange{
            // Both stages: the vertex stage reads viewport/offset, the
            // fragment stage reads `display`. One range, one push.
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(TriPushConsts),
        };
        var pl_ci = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pl_ci.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_ci.pushConstantRangeCount = 1;
        pl_ci.pPushConstantRanges = &pc_range;
        try vk.check(c.vkCreatePipelineLayout(dev, &pl_ci, null, &self.pipeline_layout));

        // ── Shader modules ─────────────────────────────────────────
        const vert_mod = try createShaderModule(dev, &shaders.tri_vert);
        defer c.vkDestroyShaderModule(dev, vert_mod, null);
        const frag_mod = try createShaderModule(dev, &shaders.tri_frag);
        defer c.vkDestroyShaderModule(dev, frag_mod, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            stageInfo(c.VK_SHADER_STAGE_VERTEX_BIT, vert_mod),
            stageInfo(c.VK_SHADER_STAGE_FRAGMENT_BIT, frag_mod),
        };

        // Vertex input — one binding, two attributes.
        var binding = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };
        var attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "color") },
        };
        var vis = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vis.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vis.vertexBindingDescriptionCount = 1;
        vis.pVertexBindingDescriptions = &binding;
        vis.vertexAttributeDescriptionCount = attrs.len;
        vis.pVertexAttributeDescriptions = &attrs;

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
        // Earcut emits triangles in mixed winding depending on
        // input orientation; safest to disable culling so we don't
        // accidentally drop back-facing tris.
        rs.cullMode = c.VK_CULL_MODE_NONE;
        rs.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.lineWidth = 1.0;

        var ms = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        ms.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

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

    pub fn deinit(self: *TrianglePipeline) void {
        if (self.vertex_memory != null) {
            c.vkUnmapMemory(self.device, self.vertex_memory);
            c.vkFreeMemory(self.device, self.vertex_memory, null);
        }
        if (self.vertex_buffer != null) c.vkDestroyBuffer(self.device, self.vertex_buffer, null);
        if (self.index_memory != null) {
            c.vkUnmapMemory(self.device, self.index_memory);
            c.vkFreeMemory(self.device, self.index_memory, null);
        }
        if (self.index_buffer != null) c.vkDestroyBuffer(self.device, self.index_buffer, null);
        if (self.pipeline_offscreen != null) c.vkDestroyPipeline(self.device, self.pipeline_offscreen, null);
        if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.* = undefined;
    }

    /// Copy `verts` + `indices` into the mapped VBO/IBO. Host-
    /// coherent memory → no flush needed before submit.
    pub fn writeMesh(self: *TrianglePipeline, verts: []const Vertex, indices: []const u32) !void {
        if (verts.len > self.vertex_capacity) return error.SsboOverflow;
        if (indices.len > self.index_capacity) return error.SsboOverflow;
        @memcpy(self.vertex_mapped[0..verts.len], verts);
        @memcpy(self.index_mapped[0..indices.len], indices);
    }

    /// Bind + draw `n_indices / 3` triangles. Records before quads /
    /// text in the same render pass so SVG fills sit behind chrome
    /// and glyphs. Convenience over `recordDrawIndexedRange(cmd,
    /// extent, 0, n_indices)`.
    pub fn recordDraw(
        self: *const TrianglePipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        n_indices: u32,
        att: vk.Attachment,
    ) void {
        self.recordDrawIndexedRange(cmd, extent, .{ 0, 0 }, 0, n_indices, .{}, att);
    }

    /// Bind + draw a contiguous subrange of the index buffer.
    /// Phase B.4.b.4 per-target routing — callers iterate
    /// `element.triRuns(dl.tri_targets.items, dl.tri_indices.items,
    /// target)` and issue one of these per yielded `TriRun`. The
    /// (first_index, index_count) pair feeds `vkCmdDrawIndexed`
    /// directly; vertex offset stays 0 because indices reference
    /// absolute positions in the shared vertex buffer.
    ///
    /// `world_offset`: see `quad_pipeline.recordDrawRange` —
    /// (0, 0) for MAIN, `compose_region.xy` for an offscreen target.
    pub fn recordDrawIndexedRange(
        self: *const TrianglePipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        world_offset: [2]f32,
        first_index: u32,
        index_count: u32,
        disp: display_mod.Push,
        att: vk.Attachment,
    ) void {
        if (index_count == 0) return;
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

        const pc = TriPushConsts{ .world_offset = world_offset, .display = disp, .viewport_size = .{
            @floatFromInt(extent.width),
            @floatFromInt(extent.height),
        } };
        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(TriPushConsts),
            &pc,
        );

        var offsets = [_]c.VkDeviceSize{0};
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &self.vertex_buffer, &offsets);
        c.vkCmdBindIndexBuffer(cmd, self.index_buffer, 0, c.VK_INDEX_TYPE_UINT32);
        c.vkCmdDrawIndexed(cmd, index_count, 1, first_index, 0, 0);
    }
};

fn createMappedBuffer(
    ctx: *const vk.Context,
    bytes: u64,
    usage: c.VkBufferUsageFlags,
    out_buffer: *c.VkBuffer,
    out_memory: *c.VkDeviceMemory,
    out_mapped: *[*]u8,
) !void {
    const dev = ctx.device;
    var bci = std.mem.zeroes(c.VkBufferCreateInfo);
    bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = bytes;
    bci.usage = usage;
    bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    try vk.check(c.vkCreateBuffer(dev, &bci, null, out_buffer));

    var req: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(dev, out_buffer.*, &req);
    const mt = try findMemoryType(
        ctx.physical_device,
        req.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
    mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = req.size;
    mai.memoryTypeIndex = mt;
    try vk.check(c.vkAllocateMemory(dev, &mai, null, out_memory));
    try vk.check(c.vkBindBufferMemory(dev, out_buffer.*, out_memory.*, 0));

    var raw: ?*anyopaque = null;
    try vk.check(c.vkMapMemory(dev, out_memory.*, 0, bytes, 0, &raw));
    out_mapped.* = @ptrCast(@alignCast(raw.?));
}

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
