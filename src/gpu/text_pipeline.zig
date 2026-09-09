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
const display_mod = @import("display.zig");
const atlas_mod = @import("atlas.zig");
const growable = @import("growable.zig");
const shaders = @import("shaders");

const c = vk.c;

/// Per-glyph SSBO entry. Layout must match the GLSL `GlyphInstance`
/// struct in `shaders/text.vert` under std430:
///   * each `vec2` is 8-byte aligned (8 bytes wide → no padding)
///   * `color` (vec4) at offset 32, naturally 16-byte aligned.
///   * `hot_color` (vec4) at offset 48 — `color → hot_color` lerp
///     target for the attention modulation.
///   * `tex_select` (uint) at offset 64.
///   * `attention` (float) at offset 68.
///   * `fx_kind` (uint) at offset 72 — reserved for Phase 7+
///     effect-type dispatch (underline / size-pulse / per-glyph PBR).
///   * Struct alignment is 16 (from the vec4s); std430 pads to a
///     multiple of 16. Total: 80 bytes with a trailing 4-byte pad
///     declared explicitly to keep Zig's `extern struct` size in
///     lockstep with the GLSL stride.
pub const GlyphInstance = extern struct {
    dst_pos: [2]f32,
    dst_size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
    hot_color: [4]f32,
    /// 0 = mono atlas (R8 coverage), 1 = colour atlas (RGBA8), 2 =
    /// SDF (R8 atlas, distance-field sampling). See
    /// `glyph_cache.AtlasKind` — the int values are kept in sync.
    tex_select: u32,
    /// LM-driven attribute the shader reads. Phase 6 wires it to
    /// the SDF threshold (weight pulse) and to a `color → hot_color`
    /// lerp (hue shift) in both mono and SDF branches. Colour-atlas
    /// glyphs (emoji) deliberately ignore it — their artwork is not
    /// tinted. Range nominally [0, 1]; shader clamps.
    attention: f32,
    /// Reserved for future per-glyph effect dispatch — Phase 7+.
    /// 0 = no effect (pass-through). Other values will route to
    /// underline / size-pulse / shimmer / colour-warp branches.
    fx_kind: u32,
    _pad: u32,
};

comptime {
    std.debug.assert(@sizeOf(GlyphInstance) == 80);
}

/// Push-constant block mirrors text.vert's `PC`. `world_offset`
/// matches the quad/tri/image pipelines — (0, 0) for the main
/// attachment, `compose_region.xy` for a single_source offscreen
/// target (Phase B.5 substrate).
pub const TextPushConsts = extern struct {
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
    // `PC` in text.vert.
    std.debug.assert(@sizeOf(TextPushConsts) == 24);
    // `display` is the tail of the block in the GLSL too. A drift here
    // is silent GPU garbage, which is why it is pinned by offset and
    // not only by total size.
    std.debug.assert(@offsetOf(TextPushConsts, "display") == 16);
}

pub const TextPipeline = struct {
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set: c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    /// The same pipeline, built for the offscreen effect-target format.
    /// `null` when the two formats are the same and one pipeline serves
    /// both — which keeps `deinit` from ever destroying an alias twice.
    pipeline_offscreen: c.VkPipeline = null,

    /// The glyph SSBO, sized to whatever the frame turned out to need.
    /// `initial_glyphs` is a starting point, not a budget — this is the
    /// buffer whose fixed cap turned `demo.md` black (`14aedd9`). See
    /// `growable.zig`.
    glyphs: Glyphs,

    device: c.VkDevice, // borrowed

    pub const Glyphs = growable.Growable(GlyphInstance, "glyph", error.TooManyGlyphs);

    pub fn init(
        ctx: *const vk.Context,
        color_format: c.VkFormat,
        offscreen_format: c.VkFormat,
        mono_atlas: *const atlas_mod.Atlas,
        color_atlas: *const atlas_mod.Atlas,
        initial_glyphs: u32,
    ) !TextPipeline {
        const dev = ctx.device;
        var self: TextPipeline = .{
            .descriptor_set_layout = null,
            .descriptor_pool = null,
            .descriptor_set = null,
            .pipeline_layout = null,
            .pipeline = null,
            .glyphs = .{},
            .device = dev,
        };
        errdefer self.deinit();

        // ── SSBO: host-visible, host-coherent so writes from the CPU
        // are immediately visible to subsequent submits without
        // explicit flush. `initial_glyphs` is the starting size; the buffer
        // grows past it on the frame that needs more. ─
        self.glyphs = try Glyphs.init(ctx, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, initial_glyphs);

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
        var writes = [_]c.VkWriteDescriptorSet{
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
        writes[1].dstBinding = 2;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[1].pImageInfo = &color_info;
        c.vkUpdateDescriptorSets(dev, writes.len, &writes, 0, null);
        // Binding 1 is the SSBO, and it is the one that moves: it goes
        // through the same call a grow uses, so init and grow cannot
        // drift into writing two different descriptors.
        self.pointDescriptorAtBuffer();

        // ── Pipeline layout: descriptor set + viewport push consts ──
        var pc_range = c.VkPushConstantRange{
            // Both stages: the vertex stage reads viewport/offset, the
            // fragment stage reads `display`. One range, one push.
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
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

    /// Bind the SSBO the pipeline currently owns into binding 1. Called
    /// once at init and again after every grow — a grown buffer is a
    /// NEW `VkBuffer`, and a descriptor still pointing at the old one
    /// is a draw reading freed memory.
    fn pointDescriptorAtBuffer(self: *TextPipeline) void {
        var buf_info = c.VkDescriptorBufferInfo{
            .buffer = self.glyphs.buffer,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = self.descriptor_set;
        write.dstBinding = 1;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo = &buf_info;
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    /// Make room for `n` glyphs. See `Spark.reserveForDrawlist` for
    /// where in the frame this is safe to call: before anything has
    /// bound the descriptor set into the command buffer being recorded.
    pub fn reserve(self: *TextPipeline, n: usize) !void {
        if (try self.glyphs.reserve(n)) self.pointDescriptorAtBuffer();
    }

    pub fn deinit(self: *TextPipeline) void {
        self.glyphs.deinit();
        if (self.pipeline_offscreen != null) c.vkDestroyPipeline(self.device, self.pipeline_offscreen, null);
        if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.* = undefined;
    }

    /// Copy `glyphs` into the mapped SSBO. Memory is host-coherent, so
    /// no explicit flush is needed before submitting a frame that reads
    /// it.
    ///
    /// `error.SsboOverflow` is now a can't-happen — `reserve` ran at
    /// the frame boundary and the buffer is already the right size —
    /// but it is still checked, because a can't-happen that is checked
    /// is a bug report and one that is not is a heap smash. It used to
    /// mean "bump `max_glyphs`"; there is nothing left to bump.
    pub fn writeGlyphs(self: *TextPipeline, glyphs: []const GlyphInstance) !void {
        try self.glyphs.write(glyphs);
    }

    /// Bind pipeline + descriptor set, set viewport/scissor, push
    /// viewport size, draw 6 verts × `n_glyphs` instances. Must be
    /// called inside an active vkCmdBeginRendering block whose colour
    /// format matches `init`'s `color_format`. Convenience for the
    /// "draw every glyph in the buffer from offset 0" common case —
    /// thin wrapper over `recordDrawRange(cmd, extent, 0, n_glyphs)`.
    pub fn recordDraw(
        self: *const TextPipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        n_glyphs: u32,
        att: vk.Attachment,
    ) void {
        self.recordDrawRange(cmd, extent, .{ 0, 0 }, 0, n_glyphs, .{}, att, null);
    }

    /// Bind + draw a contiguous subrange of the glyph instance
    /// buffer. Phase B.4.b.4 per-target routing: callers iterate
    /// `element.runs(dl.glyph_targets.items, target)` and issue one
    /// of these per yielded `Run`. Vulkan's `firstInstance` argument
    /// is exactly the subrange offset — the vertex shader reads
    /// `gl_InstanceIndex` which is `gl_BaseInstance + per-instance
    /// counter`, so offset is transparent.
    ///
    /// `world_offset`: see `quad_pipeline.recordDrawRange` —
    /// (0, 0) for MAIN, `compose_region.xy` for an offscreen target.
    /// `scissor_px`: see `quad_pipeline.recordDrawRange`. Clipping TEXT
    /// is the half that matters for a scroll view — a partly-visible line
    /// at the edge of the viewport has to be cut mid-glyph, which is why
    /// this is a GPU scissor and not a CPU cull of primitives outside the
    /// box.
    pub fn recordDrawRange(
        self: *const TextPipeline,
        cmd: c.VkCommandBuffer,
        extent: c.VkExtent2D,
        world_offset: [2]f32,
        first_instance: u32,
        instance_count: u32,
        disp: display_mod.Push,
        att: vk.Attachment,
        scissor_px: ?[4]u32,
    ) void {
        if (instance_count == 0) return;
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipelineFor(att));
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
        var scissor = if (scissor_px) |s| c.VkRect2D{
            .offset = .{ .x = @intCast(s[0]), .y = @intCast(s[1]) },
            .extent = .{ .width = s[2], .height = s[3] },
        } else c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);

        const pc = TextPushConsts{ .world_offset = world_offset, .display = disp, .viewport_size = .{
            @floatFromInt(extent.width),
            @floatFromInt(extent.height),
        } };
        c.vkCmdPushConstants(
            cmd,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            @sizeOf(TextPushConsts),
            &pc,
        );
        c.vkCmdDraw(cmd, 6, instance_count, 0, first_instance);
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
