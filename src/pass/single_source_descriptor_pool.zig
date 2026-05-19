//! Single-source descriptor-set pool. Effects-spec Phase B.4.b.2 —
//! per-frame descriptor sets for single-source compose dispatches,
//! allocated from a pre-warmed `VkDescriptorPool` (base cap = 64
//! combined-image-sampler sets) with grow-on-overflow into
//! additional pools. `resetAll()` wholesale-resets every pool on
//! frame boundary; keep-on-reset retains overflow allocations so
//! the steady-state converges to the doc's high-water mark with no
//! per-frame syscalls after the first overflow.
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

    /// All allocated pools — `[0]` is the base pool created at
    /// init, subsequent entries are overflow allocations from
    /// `acquire()` exceeding `BASE_POOL_SIZE * pools.items.len`.
    /// Never shrunk (keep-on-reset).
    pools: std.ArrayList(c.VkDescriptorPool),

    /// Index into `pools` of the pool currently being filled.
    /// Advances on overflow; reset to 0 by `resetAll()`.
    current_pool_index: usize,

    /// Sets allocated from `pools.items[current_pool_index]`
    /// since the last `resetAll()`. Reaches `BASE_POOL_SIZE`,
    /// next `acquire` advances `current_pool_index` (and
    /// grow-allocates if at end of list).
    sets_in_current_pool: u32,

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
            .pools = std.ArrayList(c.VkDescriptorPool).init(allocator),
            .current_pool_index = 0,
            .sets_in_current_pool = 0,
        };
        errdefer self.pools.deinit();

        const base_pool = try createPool(device);
        errdefer c.vkDestroyDescriptorPool(device, base_pool, null);
        try self.pools.append(base_pool);
        return self;
    }

    pub fn deinit(self: *SingleSourceDescriptorPool) void {
        for (self.pools.items) |pool| {
            c.vkDestroyDescriptorPool(self.device, pool, null);
        }
        self.pools.deinit();
        self.* = undefined;
    }

    /// Acquire one descriptor set, write it with the given
    /// `(view, sampler)` combined-image-sampler binding, return
    /// the set ready to bind. Returns `error.DescriptorPoolCreation`
    /// or `error.DescriptorSetAllocation` on growth-allocation
    /// failure (driver OOM, device-side limit hit) — same shape as
    /// `target_pool.acquire`. Caller may choose to drop the effect,
    /// log, render a fallback; panic-on-failure would foreclose
    /// that.
    pub fn acquire(
        self: *SingleSourceDescriptorPool,
        view: c.VkImageView,
        sampler: c.VkSampler,
    ) !c.VkDescriptorSet {
        // Advance / grow if the current pool is full.
        if (self.sets_in_current_pool >= BASE_POOL_SIZE) {
            const next_index = self.current_pool_index + 1;
            if (next_index >= self.pools.items.len) {
                const new_pool = try createPool(self.device);
                errdefer c.vkDestroyDescriptorPool(self.device, new_pool, null);
                try self.pools.append(new_pool);
            }
            self.current_pool_index = next_index;
            self.sets_in_current_pool = 0;
        }

        var set: c.VkDescriptorSet = null;
        var layout = self.set_layout; // pSetLayouts wants a pointer
        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.pools.items[self.current_pool_index];
        alloc_info.descriptorSetCount = 1;
        alloc_info.pSetLayouts = &layout;
        try vk.check(c.vkAllocateDescriptorSets(self.device, &alloc_info, &set));
        self.sets_in_current_pool += 1;

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

    /// Wholesale-reset every pool. Called from `Spark.beginFrame`
    /// on `opts.reset = true`; no-op-equivalent on `.reset = false`
    /// (the caller simply doesn't invoke us). Pools stay allocated
    /// — keep-on-reset; steady-state allocations converge to the
    /// doc's high-water mark.
    ///
    /// See the symmetric comment on `target_pool.sweepUnreleased`
    /// — both run together on the reset path; both are skipped on
    /// the dirty-gate path so frame N+1's identical redraw stays
    /// valid.
    pub fn resetAll(self: *SingleSourceDescriptorPool) void {
        for (self.pools.items) |pool| {
            // Flags = 0 — caller does not request the
            // pool's command memory be freed back to the system.
            _ = c.vkResetDescriptorPool(self.device, pool, 0);
        }
        self.current_pool_index = 0;
        self.sets_in_current_pool = 0;
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

    try testing.expectEqual(@as(usize, 1), pool.pools.items.len); // base pool only
    try testing.expectEqual(@as(usize, 0), pool.current_pool_index);
    try testing.expectEqual(@as(u32, 0), pool.sets_in_current_pool);
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
    try testing.expectEqual(@as(u32, 1), pool.sets_in_current_pool);
    try testing.expectEqual(@as(usize, 0), pool.current_pool_index);
}

test "SingleSourceDescriptorPool: acquire past BASE_POOL_SIZE grows + advances" {
    // The grow-on-overflow path. Allocate BASE_POOL_SIZE + 1 sets;
    // the +1 forces the pool list to gain a second entry and the
    // current_pool_index to advance. Subsequent sets land in the
    // overflow pool with their own count.
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
    try testing.expectEqual(@as(usize, 1), pool.pools.items.len); // still base
    try testing.expectEqual(@as(u32, BASE_POOL_SIZE), pool.sets_in_current_pool);

    // The next acquire triggers growth.
    _ = try pool.acquire(target.view(), sub.cache.sampler);
    try testing.expectEqual(@as(usize, 2), pool.pools.items.len); // overflow allocated
    try testing.expectEqual(@as(usize, 1), pool.current_pool_index);
    try testing.expectEqual(@as(u32, 1), pool.sets_in_current_pool);
}

test "SingleSourceDescriptorPool: resetAll reuses pools, no growth on second frame" {
    // Keep-on-reset invariant. Frame 1 grows to 2 pools; resetAll
    // rewinds both indices; frame 2 fills both pools again without
    // any new vkCreateDescriptorPool calls. This is the steady-state
    // shape — high-water-mark allocation amortised across the
    // Spark's lifetime.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var sub = try Substrate.init(allocator, &fx);
    defer sub.deinit();

    var pool = try SingleSourceDescriptorPool.init(allocator, &fx.ctx, sub.cache.descriptor_set_layout);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 32, .height = 32, .format = fx.swapchain.format };
    const target = try sub.target_pool.acquire(key);

    // Frame 1: fill base + push into overflow.
    var i: u32 = 0;
    while (i < BASE_POOL_SIZE + 5) : (i += 1) {
        _ = try pool.acquire(target.view(), sub.cache.sampler);
    }
    try testing.expectEqual(@as(usize, 2), pool.pools.items.len);

    // Reset.
    pool.resetAll();
    try testing.expectEqual(@as(usize, 0), pool.current_pool_index);
    try testing.expectEqual(@as(u32, 0), pool.sets_in_current_pool);
    try testing.expectEqual(@as(usize, 2), pool.pools.items.len); // pools retained

    // Frame 2: reuse both pools, no growth.
    i = 0;
    while (i < BASE_POOL_SIZE + 5) : (i += 1) {
        _ = try pool.acquire(target.view(), sub.cache.sampler);
    }
    try testing.expectEqual(@as(usize, 2), pool.pools.items.len); // still 2, no third
    try testing.expectEqual(@as(usize, 1), pool.current_pool_index);
    try testing.expectEqual(@as(u32, 5), pool.sets_in_current_pool);
}
