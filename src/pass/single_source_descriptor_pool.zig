//! Single-source descriptor-set pool. Effects-spec Phase B.4.b.2 —
//! per-frame descriptor sets for single-source compose dispatches,
//! allocated from a pre-warmed `VkDescriptorPool` (base cap = 64
//! combined-image-sampler sets) with grow-on-overflow into
//! additional pools. `advance()` rotates to the next family and
//! resets it on frame boundary; keep-on-reset retains overflow
//! allocations so the steady-state converges to the doc's
//! high-water mark with no per-frame syscalls after the first
//! overflow.
//!
//! **Per-frame-slot families.** Multi-frame-in-flight (renderer
//! keeps `FRAMES = 2` frames concurrent) means a pool reset
//! the moment a new frame begins recording would race the GPU
//! finishing the previous frame's reads — Vulkan validation
//! catches this with VUID-vkResetDescriptorPool-descriptorPool-00313.
//! Fix: keep `FRAMES` independent pool families and rotate.
//! Each frame uses only its slot's family. After `advance()`
//! (called from `Spark.beginFrame` on the reset path, which fires
//! AFTER the renderer's per-slot `vkWaitForFences`), the
//! about-to-be-active family is one full rotation old → its
//! previous-use GPU submission has completed → reset is safe.
//! Same N-frame-old invariant the cmd-pool reset relies on.
//!
//! **Per-Spark instance.** Sibling field on `Spark` per the
//! [[feedback-spark-sibling-fields]] pattern. `two_instances.zig`
//! invariant: two Sparks each own their own pool list; descriptor
//! sets never cross instance boundaries.
//!
//! **Why a custom pool wrapper, not `vkAllocateDescriptorSets` direct
//! every frame.** A descriptor pool has a fixed `maxSets` and per-
//! descriptor-type capacities set at creation. Per-frame allocation
//! against a single pre-warmed pool is the standard pattern; the
//! wrapper here adds grow-on-overflow (so a busy doc doesn't fail
//! mid-frame) and a single reset point (so `Spark.beginFrame`'s
//! reset gate is one call, not an enumeration of pools).
//!
//! **No `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.`** With
//! the bit unset, `vkFreeDescriptorSets` is disallowed — sets are
//! reset wholesale via `vkResetDescriptorPool`. That's the simpler
//! and more performant path (drivers don't have to track per-set
//! freelists) and matches `resetAll()`'s shape exactly. Enabling
//! the bit "for flexibility" would cost perf without unlocking any
//! capability this module needs.
//!
//! **Reset cadence symmetric with `target_pool.zig`'s
//! `sweepUnreleased()`.** Both are wired into `Spark.beginFrame`'s
//! `.reset = true` branch; both no-op on `.reset = false`. The
//! dirty-gate path (`.reset = false`) preserves both pools so frame
//! N+1's identical redraw stays valid — the descriptor sets keep
//! pointing at the same target views, the target views keep pointing
//! at the same physical images. Asymmetry here is a class of bug
//! (stale descriptor sets pointing at recycled target memory, or
//! freshly-allocated descriptor sets with no surviving target to
//! sample); the cross-reference comment in `target_pool.zig` pins
//! the discipline from the other side too.
//!
//! **Memory growth profile.** Monotonic to the doc's high-water mark.
//! Spark lifetimes are app-long, doc complexity is stable in steady
//! state, HWM is bounded — keep-on-reset converges fast and stays
//! bounded. If memory pressure becomes a real concern (mobile/
//! embedded deployments, wildly-varying doc complexity), switch to
//! destroy-on-reset and revisit `BASE_POOL_SIZE` — that's a Phase
//! C+ profiling decision, not a v1 design decision.

const std = @import("std");
const vk = @import("../gpu/vk.zig");
const c = vk.c;

/// Sets per pool — base allocation and every overflow allocation.
/// Sized for typical HUD complexity (8–10 single-source effects per
/// doc) with healthy headroom; one dense doc (50+ effects) triggers
/// one overflow allocation and stays bounded thereafter. The
/// allocation cost of 64 descriptor sets is ~2–3 KB device memory,
/// negligible against the cost of one `vkCreateDescriptorPool`
/// syscall per frame avoided. Don't drop this lower — savings are
/// noise; the overflow trigger threshold matters more.
pub const BASE_POOL_SIZE: u32 = 64;

/// Frame slots = renderer's MAX_FRAMES_IN_FLIGHT. Hard-coded to
/// match `src/gpu/renderer.zig`'s constant; keep in sync. If the
/// renderer ever raises it (e.g. for triple-buffering tearing
/// reduction), bump this too.
pub const FRAMES: u32 = 2;

/// One pool family — a list of VkDescriptorPools (base + overflow)
/// owned by a single frame slot. `acquire` pulls sets from
/// `pools[current_pool_index]`, growing the list on overflow.
/// `reset` wholesale-resets every pool in this family.
const Family = struct {
    pools: std.ArrayList(c.VkDescriptorPool),
    current_pool_index: usize,
    sets_in_current_pool: u32,
};

pub const Error = error{
    DescriptorPoolCreation,
    DescriptorSetAllocation,
} || std.mem.Allocator.Error;

pub const SingleSourceDescriptorPool = struct {
    allocator: std.mem.Allocator,
    device: c.VkDevice,

    /// Borrowed descriptor set layout — owned by
    /// `SingleSourcePipelineCache` (sibling field on Spark).
    /// We store the handle by value (Vulkan handles are opaque
    /// integers); Spark.deinit order destroys this pool before
    /// the pipeline cache so the layout is alive across our
    /// lifetime regardless.
    set_layout: c.VkDescriptorSetLayout,

    /// `FRAMES` independent pool families. The active family is
    /// `families[active_family]`; acquire pulls from it. `advance`
    /// rotates to the next slot and resets it (safe because that
    /// slot was last used `FRAMES` frames ago, past the renderer's
    /// per-slot fence wait).
    families: [FRAMES]Family,
    active_family: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        vk_ctx: *const vk.Context,
        set_layout: c.VkDescriptorSetLayout,
    ) !SingleSourceDescriptorPool {
        const device = vk_ctx.device;
        var self: SingleSourceDescriptorPool = .{
            .allocator = allocator,
            .device = device,
            .set_layout = set_layout,
            .families = undefined,
            .active_family = 0,
        };

        // Init each family with its own base pool. On error mid-way,
        // unwind the families already created.
        var i: u32 = 0;
        errdefer {
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                for (self.families[j].pools.items) |pool| {
                    c.vkDestroyDescriptorPool(device, pool, null);
                }
                self.families[j].pools.deinit();
            }
        }
        while (i < FRAMES) : (i += 1) {
            self.families[i] = .{
                .pools = std.ArrayList(c.VkDescriptorPool).init(allocator),
                .current_pool_index = 0,
                .sets_in_current_pool = 0,
            };
            const base_pool = try createPool(device);
            errdefer c.vkDestroyDescriptorPool(device, base_pool, null);
            try self.families[i].pools.append(base_pool);
        }
        return self;
    }

    pub fn deinit(self: *SingleSourceDescriptorPool) void {
        for (&self.families) |*fam| {
            for (fam.pools.items) |pool| {
                c.vkDestroyDescriptorPool(self.device, pool, null);
            }
            fam.pools.deinit();
        }
        self.* = undefined;
    }

    /// Acquire one descriptor set from the active family, write it
    /// with the given `(view, sampler)` combined-image-sampler
    /// binding, return the set ready to bind. Returns
    /// `error.DescriptorPoolCreation` or
    /// `error.DescriptorSetAllocation` on growth-allocation failure.
    pub fn acquire(
        self: *SingleSourceDescriptorPool,
        view: c.VkImageView,
        sampler: c.VkSampler,
    ) !c.VkDescriptorSet {
        const fam = &self.families[self.active_family];

        // Advance / grow if the current pool in this family is full.
        if (fam.sets_in_current_pool >= BASE_POOL_SIZE) {
            const next_index = fam.current_pool_index + 1;
            if (next_index >= fam.pools.items.len) {
                const new_pool = try createPool(self.device);
                errdefer c.vkDestroyDescriptorPool(self.device, new_pool, null);
                try fam.pools.append(new_pool);
            }
            fam.current_pool_index = next_index;
            fam.sets_in_current_pool = 0;
        }

        var set: c.VkDescriptorSet = null;
        var layout = self.set_layout; // pSetLayouts wants a pointer
        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = fam.pools.items[fam.current_pool_index];
        alloc_info.descriptorSetCount = 1;
        alloc_info.pSetLayouts = &layout;
        try vk.check(c.vkAllocateDescriptorSets(self.device, &alloc_info, &set));
        fam.sets_in_current_pool += 1;

        // Write the combined-image-sampler binding immediately —
        // single API surface, single failure mode. Callers never
        // see an "uninitialised" descriptor set.
        var image_info = c.VkDescriptorImageInfo{
            .sampler = sampler,
            .imageView = view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &image_info;
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);

        return set;
    }

    /// Rotate to the next frame slot and reset its family. Called
    /// from `Spark.beginFrame` on `opts.reset = true` — fires AFTER
    /// the renderer's per-slot `vkWaitForFences`, so the
    /// about-to-be-active family is one full FRAMES rotation old
    /// and its previous-use GPU submission has completed.
    ///
    /// Symmetric with `target_pool.sweepUnreleased` per the module
    /// comment — both run together on the reset path; both are
    /// skipped on the dirty-gate path so frame N+1's identical
    /// redraw stays valid.
    pub fn advance(self: *SingleSourceDescriptorPool) void {
        self.active_family = (self.active_family + 1) % FRAMES;
        const fam = &self.families[self.active_family];
        for (fam.pools.items) |pool| {
            // Flags = 0 — descriptor pool memory stays allocated.
            _ = c.vkResetDescriptorPool(self.device, pool, 0);
        }
        fam.current_pool_index = 0;
        fam.sets_in_current_pool = 0;
    }
};

// ── Pool construction ──────────────────────────────────────────────

fn createPool(device: c.VkDevice) !c.VkDescriptorPool {
    var pool_size = c.VkDescriptorPoolSize{
        .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = BASE_POOL_SIZE,
    };
    var ci = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    ci.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    // Flags = 0 explicitly — no FREE_DESCRIPTOR_SET_BIT (see
    // the module comment on wholesale-reset-only policy).
    ci.flags = 0;
    ci.maxSets = BASE_POOL_SIZE;
    ci.poolSizeCount = 1;
    ci.pPoolSizes = &pool_size;
    var pool: c.VkDescriptorPool = null;
    try vk.check(c.vkCreateDescriptorPool(device, &ci, null, &pool));
    return pool;
}

// ── Tests ──────────────────────────────────────────────────────────
//
// Substrate-gate tests at B.4.b.2. Same fixtures as
// `single_source_pipeline.zig` and `target_pool.zig` — every test
// runs the full Vulkan stack under the testing allocator's leak
// checker. Validation layers gate the descriptor-set / sampler /
// image-view shape mismatches at write time, so a "set acquires
// cleanly" test *is* the integration check against the pipeline
// cache's layout.

const testing = std.testing;
const fixture = @import("../tests/fixture.zig");
const SingleSourcePipelineCache = @import("single_source_pipeline.zig").SingleSourcePipelineCache;
const TargetPool = @import("target_pool.zig").TargetPool;
const TargetKey = @import("target_pool.zig").TargetKey;

/// Spin up the substrate (pipeline cache for the set layout +
/// shared sampler, target pool for view sources). Tests own the
/// teardown via the standard `defer .deinit()` ladder.
const Substrate = struct {
    cache: SingleSourcePipelineCache,
    target_pool: TargetPool,

    fn init(allocator: std.mem.Allocator, fx: *fixture.Fixture) !Substrate {
        const shaders = @import("shaders");
        var cache = try SingleSourcePipelineCache.init(
            allocator,
            &fx.ctx,
            fx.swapchain.format,
            fx.swapchain.format, // one format: these tests are not about the twin
            &shaders.fullscreen_vert,
        );
        errdefer cache.deinit();
        const tp = TargetPool.init(allocator, &fx.ctx);
        return .{ .cache = cache, .target_pool = tp };
    }

    fn deinit(self: *Substrate) void {
        self.target_pool.deinit();
        self.cache.deinit();
    }
};

test "SingleSourceDescriptorPool: init + deinit leaves no leaks" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var sub = try Substrate.init(allocator, &fx);
    defer sub.deinit();

    var pool = try SingleSourceDescriptorPool.init(allocator, &fx.ctx, sub.cache.descriptor_set_layout);
    defer pool.deinit();

    try testing.expectEqual(@as(u32, 0), pool.active_family);
    for (&pool.families) |*fam| {
        try testing.expectEqual(@as(usize, 1), fam.pools.items.len); // base pool only per family
        try testing.expectEqual(@as(usize, 0), fam.current_pool_index);
        try testing.expectEqual(@as(u32, 0), fam.sets_in_current_pool);
    }
}

test "SingleSourceDescriptorPool: acquire writes a usable set" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var sub = try Substrate.init(allocator, &fx);
    defer sub.deinit();

    var pool = try SingleSourceDescriptorPool.init(allocator, &fx.ctx, sub.cache.descriptor_set_layout);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 64, .height = 64, .format = fx.swapchain.format };
    const target = try sub.target_pool.acquire(key);

    // Acquire one set against the real target view + shared sampler.
    // Validation layers will catch mismatched binding shape, image
    // layout flags, or sampler incompatibility at the vkUpdate call;
    // a successful return is the substrate's "binding shape is
    // correct" signal.
    const set = try pool.acquire(target.view(), sub.cache.sampler);
    try testing.expect(set != null);
    const active = &pool.families[pool.active_family];
    try testing.expectEqual(@as(u32, 1), active.sets_in_current_pool);
    try testing.expectEqual(@as(usize, 0), active.current_pool_index);
}

test "SingleSourceDescriptorPool: acquire past BASE_POOL_SIZE grows + advances" {
    // The grow-on-overflow path within a single family. Allocate
    // BASE_POOL_SIZE + 1 sets; the +1 forces the family's pool list
    // to gain a second entry and the family's current_pool_index to
    // advance. Subsequent sets land in the overflow pool with their
    // own count.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var sub = try Substrate.init(allocator, &fx);
    defer sub.deinit();

    var pool = try SingleSourceDescriptorPool.init(allocator, &fx.ctx, sub.cache.descriptor_set_layout);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 16, .height = 16, .format = fx.swapchain.format };
    const target = try sub.target_pool.acquire(key);

    var i: u32 = 0;
    while (i < BASE_POOL_SIZE) : (i += 1) {
        _ = try pool.acquire(target.view(), sub.cache.sampler);
    }
    const active = &pool.families[pool.active_family];
    try testing.expectEqual(@as(usize, 1), active.pools.items.len); // still base
    try testing.expectEqual(@as(u32, BASE_POOL_SIZE), active.sets_in_current_pool);

    // The next acquire triggers growth.
    _ = try pool.acquire(target.view(), sub.cache.sampler);
    try testing.expectEqual(@as(usize, 2), active.pools.items.len); // overflow allocated
    try testing.expectEqual(@as(usize, 1), active.current_pool_index);
    try testing.expectEqual(@as(u32, 1), active.sets_in_current_pool);
}

test "SingleSourceDescriptorPool: advance rotates families + resets on FRAMES-cycle reuse" {
    // Per-frame-slot keep-on-reset invariant. Cycle through all
    // FRAMES slots, allocating in each; after a full rotation, the
    // first slot's reset is safe (its prior use is N frames old →
    // past the renderer's per-slot fence wait). Verify each family
    // converges to its own high-water mark independently.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var sub = try Substrate.init(allocator, &fx);
    defer sub.deinit();

    var pool = try SingleSourceDescriptorPool.init(allocator, &fx.ctx, sub.cache.descriptor_set_layout);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 32, .height = 32, .format = fx.swapchain.format };
    const target = try sub.target_pool.acquire(key);

    // Frame 1 (advance to slot 1): fill base + push into overflow.
    pool.advance();
    try testing.expectEqual(@as(u32, 1), pool.active_family);
    var i: u32 = 0;
    while (i < BASE_POOL_SIZE + 5) : (i += 1) {
        _ = try pool.acquire(target.view(), sub.cache.sampler);
    }
    try testing.expectEqual(@as(usize, 2), pool.families[1].pools.items.len);

    // Frame 2 (advance to slot 0 — was untouched, will only have
    // base pool). Allocating BASE_POOL_SIZE here stays in the base.
    pool.advance();
    try testing.expectEqual(@as(u32, 0), pool.active_family);
    i = 0;
    while (i < BASE_POOL_SIZE) : (i += 1) {
        _ = try pool.acquire(target.view(), sub.cache.sampler);
    }
    try testing.expectEqual(@as(usize, 1), pool.families[0].pools.items.len);

    // Frame 3 (advance back to slot 1 — reset reuses the
    // already-allocated 2-pool family, no growth).
    pool.advance();
    try testing.expectEqual(@as(u32, 1), pool.active_family);
    try testing.expectEqual(@as(usize, 0), pool.families[1].current_pool_index);
    try testing.expectEqual(@as(u32, 0), pool.families[1].sets_in_current_pool);
    try testing.expectEqual(@as(usize, 2), pool.families[1].pools.items.len); // pools retained

    i = 0;
    while (i < BASE_POOL_SIZE + 5) : (i += 1) {
        _ = try pool.acquire(target.view(), sub.cache.sampler);
    }
    try testing.expectEqual(@as(usize, 2), pool.families[1].pools.items.len); // still 2
    try testing.expectEqual(@as(usize, 1), pool.families[1].current_pool_index);
    try testing.expectEqual(@as(u32, 5), pool.families[1].sets_in_current_pool);
}
