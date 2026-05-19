//! Single-source pipeline cache. Effects-spec Phase B.4.b.1 — every
//! registered `.single_source` filter shader_id gets one pre-built
//! `VkPipeline` sharing a single `VkPipelineLayout` (one combined-
//! image-sampler descriptor set + push-constants @ fragment stage).
//! Eager construction at Spark.init via `compile()` per registered
//! filter shader. Dispatch-time lookup is a constant-time
//! `AutoHashMap` get.
//!
//! **Sibling of `PatternPipelineCache`.** Same eager-registration
//! lifecycle, same lookup shape, same overwrite-on-conflict semantics
//! — the divergence is pipeline-layout shape (we have one descriptor
//! set binding, patterns have none) and what runs in `endFrame`
//! (patterns dispatch into the main attachment with push constants;
//! single-source dispatches sample a pre-rendered target via the
//! combined-image-sampler binding). Worth reading
//! `pattern_pipeline.zig` first if you're new to either.
//!
//! **Per-Spark instance.** Sibling field on `Spark` (the
//! [[feedback-spark-sibling-fields]] pattern), not file-scope state —
//! `two_instances.zig` invariant. Two Sparks each own their cache;
//! no cross-instance bleed.
//!
//! **Shared sampler policy.** One `VkSampler` for every single-source
//! pipeline: linear min/mag, clamp-to-edge wrap, no mip. Drop-shadow,
//! frosted-glass, and the copy substrate stub all sample at the same
//! filtering policy in v1. Phase C chain effects (bloom mips,
//! anisotropic) will want per-pipeline samplers — when that lands,
//! `sampler` becomes a per-pipeline field rather than cache-wide.
//!
//! **Stateless overlay pipeline state.** Same shape as
//! `PatternPipelineCache.buildPipeline`: no depth, premultiplied-
//! alpha blend, one color attachment matching `spark.color_format`,
//! no vertex input (`fullscreen.vert` reads `gl_VertexIndex`),
//! triangle list, 3 verts, dynamic viewport + scissor. The
//! divergence between pattern and single-source pipelines is *only*
//! the pipeline layout; pipeline state is identical so the
//! bind-on-change optimisation in `endFrame` could share a
//! "last-bound" cursor across both arms if a future profile shows
//! it matters (v1 keeps them separate — one cursor per arm).

const std = @import("std");
const vk = @import("../gpu/vk.zig");
const component = @import("../component.zig");
const element = @import("../element.zig");
const c = vk.c;

const ShaderId = component.ShaderId;

pub const Error = error{
    ShaderModuleCreation,
    PipelineLayoutCreation,
    PipelineCreation,
    DescriptorSetLayoutCreation,
    SamplerCreation,
    ShaderNotInCache,
} || std.mem.Allocator.Error;

pub const SingleSourcePipelineCache = struct {
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    color_format: c.VkFormat,

    /// One combined-image-sampler binding at set=0, binding=0
    /// (matches `copy.frag` and every B.5+ filter shader). Shared
    /// across every pipeline this cache builds — a per-dispatch
    /// descriptor set (allocated from B.4.b.2's per-frame pool)
    /// gets written with the offscreen target's view + the shared
    /// `sampler` below, then bound before the draw call.
    descriptor_set_layout: c.VkDescriptorSetLayout,

    /// Shared pipeline layout for every single-source pipeline.
    /// One descriptor set + one push-constant range
    /// `[0..MAX_PASS_UNIFORM_BYTES] @ STAGE_FRAGMENT`. Layout
    /// destroyed once at cache deinit regardless of how many
    /// pipelines hang off it.
    layout: c.VkPipelineLayout,

    /// Shared sampler — linear filter, clamp-to-edge, no mip. See
    /// the cache-wide policy comment at the top of this file.
    sampler: c.VkSampler,

    /// Shared fullscreen vertex shader module — every single-source
    /// filter frag pairs with this one vert (the A.4
    /// `fullscreen.vert`, same module that `PatternPipelineCache`
    /// uses; two separate `VkShaderModule` handles for the same
    /// SPIR-V is fine — Vulkan modules are cheap, and keeping each
    /// cache self-contained beats threading shared resources across
    /// init boundaries).
    fullscreen_vert_module: c.VkShaderModule,

    /// `shader_id` → `VkPipeline`. Populated eagerly from
    /// `Spark.init` via `compile()` per registered single-source
    /// filter shader.
    pipelines: std.AutoHashMap(ShaderId, c.VkPipeline),

    pub fn init(
        allocator: std.mem.Allocator,
        vk_ctx: *const vk.Context,
        color_format: c.VkFormat,
        fullscreen_vert_spv: []align(4) const u8,
    ) !SingleSourcePipelineCache {
        const device = vk_ctx.device;

        // Descriptor set layout — one combined-image-sampler at
        // binding 0, fragment stage. Matches `copy.frag`'s
        // `layout(set = 0, binding = 0) uniform sampler2D u_target`.
        var dsl_binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        dsl_binding.binding = 0;
        dsl_binding.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        dsl_binding.descriptorCount = 1;
        dsl_binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        var dsl_ci = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        dsl_ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        dsl_ci.bindingCount = 1;
        dsl_ci.pBindings = &dsl_binding;
        var dsl: c.VkDescriptorSetLayout = null;
        try vk.check(c.vkCreateDescriptorSetLayout(device, &dsl_ci, null, &dsl));
        errdefer c.vkDestroyDescriptorSetLayout(device, dsl, null);

        // Shared sampler — linear/clamp/no-mip per cache policy.
        var sampler_ci = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_ci.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_ci.magFilter = c.VK_FILTER_LINEAR;
        sampler_ci.minFilter = c.VK_FILTER_LINEAR;
        sampler_ci.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sampler_ci.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_ci.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_ci.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_ci.anisotropyEnable = c.VK_FALSE;
        sampler_ci.compareEnable = c.VK_FALSE;
        sampler_ci.minLod = 0.0;
        sampler_ci.maxLod = 0.0;
        sampler_ci.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
        sampler_ci.unnormalizedCoordinates = c.VK_FALSE;
        var sampler: c.VkSampler = null;
        try vk.check(c.vkCreateSampler(device, &sampler_ci, null, &sampler));
        errdefer c.vkDestroySampler(device, sampler, null);

        // Pipeline layout — one descriptor set + one push-constant
        // range covering the full inline uniform buffer at fragment
        // stage. Range size matches PatternPipelineCache so a future
        // shader-id-to-arm reshuffle doesn't need a layout rebuild.
        var pc_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = element.MAX_PASS_UNIFORM_BYTES,
        };
        var pl_ci = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pl_ci.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl_ci.setLayoutCount = 1;
        pl_ci.pSetLayouts = &dsl;
        pl_ci.pushConstantRangeCount = 1;
        pl_ci.pPushConstantRanges = &pc_range;
        var layout: c.VkPipelineLayout = null;
        try vk.check(c.vkCreatePipelineLayout(device, &pl_ci, null, &layout));
        errdefer c.vkDestroyPipelineLayout(device, layout, null);

        // Cached fullscreen vertex module — paired with every filter
        // frag. Separate module instance from
        // `PatternPipelineCache.fullscreen_vert_module`; same bytes,
        // independent lifetime.
        const vert_module = try createShaderModule(device, fullscreen_vert_spv);
        errdefer c.vkDestroyShaderModule(device, vert_module, null);

        return .{
            .allocator = allocator,
            .device = device,
            .color_format = color_format,
            .descriptor_set_layout = dsl,
            .layout = layout,
            .sampler = sampler,
            .fullscreen_vert_module = vert_module,
            .pipelines = std.AutoHashMap(ShaderId, c.VkPipeline).init(allocator),
        };
    }

    pub fn deinit(self: *SingleSourcePipelineCache) void {
        var it = self.pipelines.iterator();
        while (it.next()) |entry| {
            c.vkDestroyPipeline(self.device, entry.value_ptr.*, null);
        }
        self.pipelines.deinit();
        c.vkDestroyShaderModule(self.device, self.fullscreen_vert_module, null);
        c.vkDestroyPipelineLayout(self.device, self.layout, null);
        c.vkDestroySampler(self.device, self.sampler, null);
        c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.* = undefined;
    }

    /// Build the pipeline for `shader_id`'s filter fragment shader
    /// paired with the cached fullscreen vert. Insert into the map.
    /// Re-registering the same id overwrites (the old pipeline is
    /// destroyed first).
    pub fn compile(
        self: *SingleSourcePipelineCache,
        shader_id: ShaderId,
        frag_spv: []align(4) const u8,
    ) !void {
        const dev = self.device;
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

        const gop = try self.pipelines.getOrPut(shader_id);
        if (gop.found_existing) {
            c.vkDestroyPipeline(dev, gop.value_ptr.*, null);
        }
        gop.value_ptr.* = pipeline;
    }

    /// Constant-time lookup. Returns `null` for unregistered ids —
    /// `Spark.endFrame`'s B.4.b.3 single-source arm should skip the
    /// dispatch rather than crashing; the resolver-level fail-fast
    /// in `Factory.create` should have caught the typo at doc-load
    /// time.
    pub fn lookup(
        self: *const SingleSourcePipelineCache,
        shader_id: ShaderId,
    ) ?c.VkPipeline {
        return self.pipelines.get(shader_id);
    }
};

// ── Pipeline construction (stateless overlay shape) ────────────────

/// Build one single-source filter pipeline. **Stateless overlay**
/// policy mirrored from `PatternPipelineCache.buildPipeline`: no
/// depth, blend-over-source (premultiplied alpha), one color
/// attachment matching `color_format`, no vertex input
/// (fullscreen.vert reads `gl_VertexIndex`), triangle list, 3 verts,
/// dynamic viewport + scissor. The only meaningful divergence from
/// the pattern path is the descriptor-set-bearing pipeline layout
/// passed in.
///
/// Phase C HDR formats may diverge — fork from this function rather
/// than mutating it.
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

    var fmt = color_format;
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

// ── Tests ──────────────────────────────────────────────────────────
//
// Substrate smoke gate per effects-spec Phase B.4.b.1. Three checks:
//   (a) `shaders.copy_frag` carries the SPIR-V magic-number signature
//       (build infrastructure end-to-end).
//   (b) `SingleSourcePipelineCache.init` + `compile(copy.frag)` +
//       `lookup` round-trips; validation layers gate the descriptor-
//       set-layout-vs-shader-binding match at pipeline creation, so
//       a successful compile *is* the bind-cleanliness check.
//   (c) Implicit via (b): the substrate stub validates the descriptor
//       set layout shape; B.5's `:::drop_shadow` filter inherits the
//       same layout, so any B.5 failure is factory-side, not
//       substrate-side.

const testing = std.testing;
const fixture = @import("../tests/fixture.zig");

test "SingleSourcePipelineCache: copy.frag carries SPIR-V magic number" {
    // Mirrors the A.4 fullscreen.vert build-infrastructure smoke
    // check. If glslc compilation succeeded and @embedFile landed
    // real bytes, this passes; truncated or empty .spv files (a
    // build-step misconfiguration class of bug) fail here before
    // any pipeline test runs.
    const shaders = @import("shaders");
    try testing.expect(shaders.copy_frag.len > 0);
    try testing.expectEqual(@as(u8, 0x03), shaders.copy_frag[0]);
    try testing.expectEqual(@as(u8, 0x02), shaders.copy_frag[1]);
    try testing.expectEqual(@as(u8, 0x23), shaders.copy_frag[2]);
    try testing.expectEqual(@as(u8, 0x07), shaders.copy_frag[3]);
}

test "SingleSourcePipelineCache: init + compile(copy.frag) + lookup round-trips" {
    // End-to-end substrate validation. The pipeline-creation step
    // is where Vulkan's validation layers check that the shader's
    // descriptor binding declaration matches the pipeline layout's
    // descriptor set layout. Mismatched binding type / set index /
    // stage flags fail here (loud), not silently at first-frame
    // dispatch like the A.6.b GLSL/push-constant mismatch did.
    //
    // This is the substrate gate B.5 inherits — if a future filter
    // shader declares the wrong binding shape, this test fails
    // before the factory ships.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const shaders = @import("shaders");
    var cache = try SingleSourcePipelineCache.init(
        allocator,
        &fx.ctx,
        fx.swapchain.format,
        &shaders.fullscreen_vert,
    );
    defer cache.deinit();

    const resolver_mod = @import("shader_resolver.zig");
    const copy_id = resolver_mod.shaderIdFromName("copy.frag");
    try cache.compile(copy_id, &shaders.copy_frag);

    const pipeline = cache.lookup(copy_id);
    try testing.expect(pipeline != null);
}

test "SingleSourcePipelineCache: lookup misses return null" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const shaders = @import("shaders");
    var cache = try SingleSourcePipelineCache.init(
        allocator,
        &fx.ctx,
        fx.swapchain.format,
        &shaders.fullscreen_vert,
    );
    defer cache.deinit();

    const resolver_mod = @import("shader_resolver.zig");
    const missing_id = resolver_mod.shaderIdFromName("nonexistent.frag");
    try testing.expectEqual(@as(?c.VkPipeline, null), cache.lookup(missing_id));
}
