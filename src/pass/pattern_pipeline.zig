//! Pattern-pass pipeline cache. Effects-spec Phase A.6.b — every
//! registered `.pattern` shader_id gets one pre-built `VkPipeline`
//! sharing a single `VkPipelineLayout` (push-constants @ fragment
//! stage, no descriptor sets). Eager construction at Spark.init via
//! `compile()` per registered shader. Dispatch-time lookup is a
//! constant-time `AutoHashMap` get.
//!
//! **Per-Spark instance.** This cache lives as a sibling field on
//! `Spark` (the [[feedback-spark-sibling-fields]] pattern), not as
//! file-scope state — `two_instances.zig` invariant. Two Sparks each
//! own their pipeline cache; no cross-instance bleed.
//!
//! **Stateless overlay pipeline state.** All pattern-pass pipelines
//! share the same state: no depth, blend-over-source (premultiplied
//! alpha), one color attachment matching `spark.color_format`, no
//! vertex input (fullscreen.vert reads `gl_VertexIndex`), triangle
//! list, 3 verts. Phase B's `.single_source` variant diverges on
//! attachments (sampling an offscreen target → descriptor set) and
//! Phase C diverges on HDR formats; the boundary marker for these
//! divergences is the `stateless overlay` comment on `buildPipeline`.

const std = @import("std");
const vk = @import("../gpu/vk.zig");
const component = @import("../component.zig");
const element = @import("../element.zig");
const c = vk.c;

const ShaderId = component.ShaderId;

/// One shader's pipeline in each attachment format.
///
/// `offscreen` is null when the host format and the offscreen format are the
/// same — the SDR case, and any device that cannot colour-attach RGBA16F —
/// so nothing is built or destroyed twice for nothing. See
/// `vk.Attachment` for why two exist at all.
pub const Variants = struct {
    main: c.VkPipeline,
    offscreen: c.VkPipeline = null,

    pub fn forAttachment(self: Variants, att: vk.Attachment) c.VkPipeline {
        return switch (att) {
            .main => self.main,
            .offscreen => self.offscreen orelse self.main,
        };
    }
};


pub const Error = error{
    ShaderModuleCreation,
    PipelineLayoutCreation,
    PipelineCreation,
    ShaderNotInCache,
} || std.mem.Allocator.Error;

pub const PatternPipelineCache = struct {
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    color_format: c.VkFormat,
    /// See `vk.pickOffscreenFormat`. Equal to `color_format` when the
    /// device or the host format makes a second variant pointless.
    offscreen_format: c.VkFormat,

    /// Shared pipeline layout for all pattern-pass pipelines. One
    /// push-constant range `[0..MAX_PASS_UNIFORM_BYTES] @ STAGE_FRAGMENT`,
    /// no descriptor sets. Layout destroyed once at cache deinit
    /// regardless of how many pipelines hang off it.
    layout: c.VkPipelineLayout,

    /// Shared fullscreen vertex shader module — every pattern frag
    /// pairs with this one vert (the A.4 `fullscreen.vert`).
    /// Cached once so we don't re-build the module per shader_id.
    fullscreen_vert_module: c.VkShaderModule,

    /// `shader_id` → `VkPipeline`. Populated eagerly from
    /// `Spark.init` via `compile()` per registered pattern shader.
    pipelines: std.AutoHashMap(ShaderId, Variants),

    pub fn init(
        allocator: std.mem.Allocator,
        vk_ctx: *const vk.Context,
        color_format: c.VkFormat,
        offscreen_format: c.VkFormat,
        fullscreen_vert_spv: []align(4) const u8,
    ) !PatternPipelineCache {
        const device = vk_ctx.device;

        // Pipeline layout — single push-constant range covering the
        // full inline uniform buffer at fragment stage. No descriptor
        // sets (pattern-pass effects don't sample textures).
        var pc_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = element.MAX_PASS_UNIFORM_BYTES,
        };
        var pl_ci = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pl_ci.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_ci.setLayoutCount = 0;
        pl_ci.pushConstantRangeCount = 1;
        pl_ci.pPushConstantRanges = &pc_range;
        var layout: c.VkPipelineLayout = null;
        try vk.check(c.vkCreatePipelineLayout(device, &pl_ci, null, &layout));
        errdefer c.vkDestroyPipelineLayout(device, layout, null);

        // Cached fullscreen vertex module — paired with every frag.
        const vert_module = try createShaderModule(device, fullscreen_vert_spv);
        errdefer c.vkDestroyShaderModule(device, vert_module, null);

        return .{
            .allocator = allocator,
            .device = device,
            .color_format = color_format,
            .offscreen_format = offscreen_format,
            .layout = layout,
            .fullscreen_vert_module = vert_module,
            .pipelines = std.AutoHashMap(ShaderId, Variants).init(allocator),
        };
    }

    pub fn deinit(self: *PatternPipelineCache) void {
        var it = self.pipelines.iterator();
        while (it.next()) |entry| {
            c.vkDestroyPipeline(self.device, entry.value_ptr.main, null);
            if (entry.value_ptr.offscreen) |off| c.vkDestroyPipeline(self.device, off, null);
        }
        self.pipelines.deinit();
        c.vkDestroyShaderModule(self.device, self.fullscreen_vert_module, null);
        c.vkDestroyPipelineLayout(self.device, self.layout, null);
        self.* = undefined;
    }

    /// Build the pipeline for `shader_id`'s fragment shader paired
    /// with the cached fullscreen vert. Insert into the map.
    /// Re-registering the same id overwrites (the old pipeline is
    /// destroyed first) — useful for hot-reload paths later.
    pub fn compile(
        self: *PatternPipelineCache,
        shader_id: ShaderId,
        frag_spv: []align(4) const u8,
    ) !void {
        const dev = self.device;
        // Frag module is transient — destroyed once the pipeline
        // captures the SPIR-V (Vulkan spec § VkShaderModule lifetime).
        const frag_module = try createShaderModule(dev, frag_spv);
        defer c.vkDestroyShaderModule(dev, frag_module, null);

        const pipeline = try buildPipeline(
            dev,
            self.layout,
            self.color_format,
            self.fullscreen_vert_module,
            frag_module,
        );
        errdefer c.vkDestroyPipeline(dev, pipeline, null);

        // The offscreen twin: same layout, same blend, same shaders, one
        // attachment format apart. Built only when that format differs.
        var offscreen: c.VkPipeline = null;
        if (self.offscreen_format != self.color_format) {
            offscreen = try buildPipeline(
                dev,
                self.layout,
                self.offscreen_format,
                self.fullscreen_vert_module,
                frag_module,
            );
        }
        errdefer if (offscreen) |off| c.vkDestroyPipeline(dev, off, null);

        // Overwrite-on-conflict: destroy the prior pipeline before
        // replacing the map entry.
        const gop = try self.pipelines.getOrPut(shader_id);
        if (gop.found_existing) {
            c.vkDestroyPipeline(dev, gop.value_ptr.main, null);
            if (gop.value_ptr.offscreen) |off| c.vkDestroyPipeline(dev, off, null);
        }
        gop.value_ptr.* = .{ .main = pipeline, .offscreen = offscreen };
    }

    /// Constant-time lookup. Returns `null` for unregistered ids —
    /// callers (`Spark.endFrame`) skip the dispatch in that case
    /// rather than crashing; the resolver-level fail-fast in
    /// `Factory.create` should have caught the typo at doc-load
    /// time, so a missing pipeline here means something is wrong
    /// with the eager-registration path.
    pub fn lookup(self: *const PatternPipelineCache, shader_id: ShaderId, att: vk.Attachment) ?c.VkPipeline {
        const v = self.pipelines.get(shader_id) orelse return null;
        return v.forAttachment(att);
    }
};

// ── Pipeline construction (stateless overlay shape) ────────────────

/// Build one pattern-pass pipeline. **Stateless overlay** policy:
/// no depth, blend-over-source (premultiplied alpha), one color
/// attachment matching `color_format`, no vertex input
/// (fullscreen.vert reads `gl_VertexIndex`), triangle list, 3 verts,
/// dynamic viewport + scissor (the scissor is the per-dispatch
/// `PassRegion`). Same state for every `.pattern` factory.
///
/// Phase B's `.single_source` variant diverges on attachments and
/// sampling; Phase C diverges on HDR formats. Either phase forks
/// from this function rather than mutating it — the stateless-overlay
/// invariant is load-bearing for the bind-on-change optimisation in
/// `endFrame` (every pattern pipeline interchangeable except for the
/// frag shader).
fn buildPipeline(
    dev: c.VkDevice,
    layout: c.VkPipelineLayout,
    color_format: c.VkFormat,
    vert_module: c.VkShaderModule,
    frag_module: c.VkShaderModule,
) !c.VkPipeline {
    var stages = [_]c.VkPipelineShaderStageCreateInfo{
        stageInfo(c.VK_SHADER_STAGE_VERTEX_BIT, vert_module),
        stageInfo(c.VK_SHADER_STAGE_FRAGMENT_BIT, frag_module),
    };

    var vis = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vis.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    // No bindings, no attributes — fullscreen.vert reads gl_VertexIndex.

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

    // Premultiplied-alpha blend (matches text_pipeline + quad_pipeline
    // policy — uniform compositing behaviour across rasterizer and
    // pattern-pass layers).
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

    var fmt = color_format; // pColorAttachmentFormats wants a pointer
    var rendering_info = std.mem.zeroes(c.VkPipelineRenderingCreateInfo);
    rendering_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    rendering_info.colorAttachmentCount = 1;
    rendering_info.pColorAttachmentFormats = &fmt;

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
    gpci.layout = layout;

    var pipeline: c.VkPipeline = null;
    try vk.check(c.vkCreateGraphicsPipelines(dev, null, 1, &gpci, null, &pipeline));
    return pipeline;
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
