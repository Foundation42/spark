//! Transient render-target pool — recycles offscreen targets across
//! a frame for single-source / chain effects. Keyed by `(w, h,
//! format)` per Decision #4 so multiple effects with the same
//! footprint share one physical allocation.
//!
//! **Effects-spec Phase B.1.** First real implementation of the
//! ref-counted allocator that A.3 stubbed. Free-list keyed by
//! `TargetKey`, per-allocation ref count, mid-frame release on
//! last-consumer dispatch-complete (Decision #4). Phase A pattern-
//! passes still don't allocate offscreen targets — the pool sits
//! empty during Phase A docs; it lights up the moment Phase B's
//! `.single_source` walker emits its first target acquire.
//!
//! **Release model.** "Dispatch-complete" is CPU-side: the consumer
//! (the pass-graph compiler emitting the compose dispatch) calls
//! `release` once it's recorded the last command that references the
//! target. The GPU still has work in flight, but the CPU is done
//! with the handle, so the pool can hand it back to the next
//! acquire in the same frame. Two effects with matching keys share
//! one allocation across a frame as long as their lifetimes don't
//! overlap. Frame-end sweep (`sweepUnreleased`) is a sanity check
//! that resets any stragglers — symptom of a missing `release` call
//! in the compiler, worth a debug log + reset rather than a leak.
//!
//! **Per-Spark.** Sibling field on Spark per [[feedback-spark-sibling-fields]];
//! `two_instances.zig` invariant. Two Sparks each own their pool;
//! no cross-instance bleed even when both render the same effect.

const std = @import("std");
const vk = @import("../gpu/vk.zig");
const c = vk.c;

/// Identifies a target slot in the pool. Decision #4: targets are
/// shared across effects with matching footprint; this tuple is the
/// equivalence class. Format is included because Phase C HDR passes
/// will request RGBA16F vs the LDR sRGB norm — different formats
/// can't share.
pub const TargetKey = struct {
    width: u32,
    height: u32,
    format: c.VkFormat,
};

/// Internal per-target allocation. Owned by the pool's `allocations`
/// list; pointers handed out as `TargetHandle.allocation` are stable
/// across the pool's lifetime (never reallocated — see comment on
/// `allocations`).
const Allocation = struct {
    image: c.VkImage,
    view: c.VkImageView,
    memory: c.VkDeviceMemory,
    key: TargetKey,
    ref_count: u32,
};

/// Opaque handle for an acquired target. Holds a pointer into the
/// pool's internal allocation list; valid until `release()` is
/// called. After release, the underlying allocation may be handed
/// back to a subsequent `acquire` with a matching key — DO NOT
/// dereference a `TargetHandle` after releasing it.
pub const TargetHandle = struct {
    allocation: *Allocation,

    pub fn image(self: TargetHandle) c.VkImage {
        return self.allocation.image;
    }

    pub fn view(self: TargetHandle) c.VkImageView {
        return self.allocation.view;
    }

    pub fn key(self: TargetHandle) TargetKey {
        return self.allocation.key;
    }
};

pub const TargetPool = struct {
    allocator: std.mem.Allocator,
    vk_ctx: *const vk.Context,

    /// Owned allocations. Heap-allocated `*Allocation`s; never
    /// reallocated (we append new entries, never shrink — pool size
    /// only grows across the Spark's lifetime). Pointers handed out
    /// in `TargetHandle.allocation` stay valid until pool deinit.
    allocations: std.ArrayList(*Allocation),

    /// Free list keyed by TargetKey: each entry is the list of
    /// allocations of that shape currently with `ref_count == 0`.
    /// `acquire` pops from the matching bucket; `release` pushes
    /// back. Empty bucket → allocate new.
    free_list: std.AutoHashMap(TargetKey, std.ArrayList(*Allocation)),

    pub fn init(allocator: std.mem.Allocator, vk_ctx: *const vk.Context) TargetPool {
        return .{
            .allocator = allocator,
            .vk_ctx = vk_ctx,
            .allocations = std.ArrayList(*Allocation).init(allocator),
            .free_list = std.AutoHashMap(TargetKey, std.ArrayList(*Allocation)).init(allocator),
        };
    }

    pub fn deinit(self: *TargetPool) void {
        const dev = self.vk_ctx.device;
        for (self.allocations.items) |a| {
            c.vkDestroyImageView(dev, a.view, null);
            c.vkDestroyImage(dev, a.image, null);
            c.vkFreeMemory(dev, a.memory, null);
            self.allocator.destroy(a);
        }
        self.allocations.deinit();

        var it = self.free_list.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.free_list.deinit();
        self.* = undefined;
    }

    /// Acquire a target matching `key`. Returns a free allocation
    /// from the matching bucket if any; otherwise creates a new
    /// VkImage + memory + view, appends to `allocations`, returns
    /// a handle to it. `ref_count` set to 1.
    pub fn acquire(self: *TargetPool, key: TargetKey) !TargetHandle {
        // Fast path: matching free allocation available.
        if (self.free_list.getPtr(key)) |bucket| {
            if (bucket.items.len > 0) {
                const alloc = bucket.pop().?;
                alloc.ref_count = 1;
                return .{ .allocation = alloc };
            }
        }
        // Slow path: allocate new.
        const alloc = try self.allocateNew(key);
        try self.allocations.append(alloc);
        return .{ .allocation = alloc };
    }

    /// Release a previously-acquired target. Decrements `ref_count`;
    /// when it reaches zero, returns the allocation to the free
    /// list (still alive, still in `allocations` — just available
    /// for the next matching `acquire`). After release, the caller
    /// must not dereference the handle.
    pub fn release(self: *TargetPool, handle: TargetHandle) void {
        const alloc = handle.allocation;
        std.debug.assert(alloc.ref_count > 0); // double-release = bug
        alloc.ref_count -= 1;
        if (alloc.ref_count == 0) {
            const gop = self.free_list.getOrPut(alloc.key) catch {
                // OOM here = the free-list entry can't grow. The
                // allocation stays alive in `self.allocations` and
                // gets destroyed at pool deinit — leak only for the
                // remainder of this Spark's lifetime, not forever.
                return;
            };
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(*Allocation).init(self.allocator);
            }
            gop.value_ptr.*.append(alloc) catch {
                // Same OOM tolerance as above.
            };
        }
    }

    /// End-of-frame sanity sweep. Force-releases any allocation
    /// with a non-zero ref_count back to the free list — symptom
    /// of a missing `release` call in the dispatch consumer. Logs
    /// the leak count in debug builds; resets quietly otherwise so
    /// the next frame doesn't compound the bug. Returns the number
    /// of stragglers swept (zero is healthy).
    ///
    /// **Reset cadence symmetric with `SingleSourceDescriptorPool.resetAll()`
    /// in `single_source_descriptor_pool.zig`.** Both are wired
    /// into `Spark.beginFrame`'s `.reset = true` branch; both no-op
    /// on `.reset = false`. The dirty-gate path preserves target
    /// allocations *and* the descriptor sets that reference them,
    /// so frame N+1's identical redraw stays valid. Asymmetry here
    /// is a class of bug — drift in either direction (descriptor
    /// sets reset while targets carry over, or vice versa) leaves
    /// dangling references that validation layers won't catch
    /// until first dispatch.
    pub fn sweepUnreleased(self: *TargetPool) usize {
        var leaked: usize = 0;
        for (self.allocations.items) |alloc| {
            if (alloc.ref_count > 0) {
                leaked += 1;
                alloc.ref_count = 0;
                const gop = self.free_list.getOrPut(alloc.key) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(*Allocation).init(self.allocator);
                }
                gop.value_ptr.*.append(alloc) catch {};
            }
        }
        return leaked;
    }

    fn allocateNew(self: *TargetPool, key: TargetKey) !*Allocation {
        const dev = self.vk_ctx.device;
        const pd = self.vk_ctx.physical_device;

        // Image: 2D, single mip, single layer, single sample, OPTIMAL
        // tiling. Usage: COLOR_ATTACHMENT (render into it) + SAMPLED
        // (Phase B.4's compose-from-target binds it as a combined
        // image sampler in the filter pipeline's descriptor set).
        var image_ci = std.mem.zeroes(c.VkImageCreateInfo);
        image_ci.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_ci.imageType = c.VK_IMAGE_TYPE_2D;
        image_ci.format = key.format;
        image_ci.extent = .{ .width = key.width, .height = key.height, .depth = 1 };
        image_ci.mipLevels = 1;
        image_ci.arrayLayers = 1;
        image_ci.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_ci.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_ci.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        image_ci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        image_ci.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        var image: c.VkImage = null;
        try vk.check(c.vkCreateImage(dev, &image_ci, null, &image));
        errdefer c.vkDestroyImage(dev, image, null);

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, image, &mem_reqs);

        const mem_type = try findMemoryType(
            pd,
            mem_reqs.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );
        var mem_ai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mem_ai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mem_ai.allocationSize = mem_reqs.size;
        mem_ai.memoryTypeIndex = mem_type;

        var memory: c.VkDeviceMemory = null;
        try vk.check(c.vkAllocateMemory(dev, &mem_ai, null, &memory));
        errdefer c.vkFreeMemory(dev, memory, null);

        try vk.check(c.vkBindImageMemory(dev, image, memory, 0));

        var view_ci = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_ci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_ci.image = image;
        view_ci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_ci.format = key.format;
        view_ci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };

        var view: c.VkImageView = null;
        try vk.check(c.vkCreateImageView(dev, &view_ci, null, &view));
        errdefer c.vkDestroyImageView(dev, view, null);

        const alloc = try self.allocator.create(Allocation);
        alloc.* = .{
            .image = image,
            .view = view,
            .memory = memory,
            .key = key,
            .ref_count = 1,
        };
        return alloc;
    }
};

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

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = @import("../tests/fixture.zig");

test "TargetPool: init + deinit on empty pool" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    var pool = TargetPool.init(allocator, &fx.ctx);
    defer pool.deinit();
    try testing.expectEqual(@as(usize, 0), pool.allocations.items.len);
}

test "TargetPool: acquire allocates new on cache miss" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var pool = TargetPool.init(allocator, &fx.ctx);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 128, .height = 128, .format = fx.swapchain.format };
    const h = try pool.acquire(key);
    try testing.expectEqual(@as(usize, 1), pool.allocations.items.len);
    try testing.expectEqual(@as(u32, 1), h.allocation.ref_count);
    // Don't release here — pool.deinit destroys the allocation regardless.
}

test "TargetPool: release + re-acquire returns same allocation" {
    // The load-bearing Decision #4 test: matching key after release
    // should hit the free list and return the SAME underlying
    // allocation, not allocate fresh. This is the recycling
    // invariant — without it, every effect frame leaks a target.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var pool = TargetPool.init(allocator, &fx.ctx);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 64, .height = 64, .format = fx.swapchain.format };
    const h1 = try pool.acquire(key);
    const a1 = h1.allocation;
    pool.release(h1);
    try testing.expectEqual(@as(u32, 0), a1.ref_count);

    const h2 = try pool.acquire(key);
    try testing.expectEqual(a1, h2.allocation); // recycled, same pointer
    try testing.expectEqual(@as(u32, 1), h2.allocation.ref_count);
    try testing.expectEqual(@as(usize, 1), pool.allocations.items.len); // no new alloc
}

test "TargetPool: distinct keys produce distinct allocations" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var pool = TargetPool.init(allocator, &fx.ctx);
    defer pool.deinit();

    const k_a: TargetKey = .{ .width = 32, .height = 32, .format = fx.swapchain.format };
    const k_b: TargetKey = .{ .width = 64, .height = 32, .format = fx.swapchain.format };
    const h_a = try pool.acquire(k_a);
    const h_b = try pool.acquire(k_b);
    try testing.expect(h_a.allocation != h_b.allocation);
    try testing.expectEqual(@as(usize, 2), pool.allocations.items.len);
}

test "TargetPool: concurrent acquires of same key allocate distinct targets" {
    // While the first acquire's handle is still held, a second
    // acquire of the same key cannot recycle — it must allocate
    // fresh. Two single-source effects with overlapping lifetimes
    // need their own targets.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var pool = TargetPool.init(allocator, &fx.ctx);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 48, .height = 48, .format = fx.swapchain.format };
    const h1 = try pool.acquire(key);
    const h2 = try pool.acquire(key);
    try testing.expect(h1.allocation != h2.allocation);
    try testing.expectEqual(@as(usize, 2), pool.allocations.items.len);
}

test "TargetPool: sweepUnreleased reports + resets stragglers" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();
    var pool = TargetPool.init(allocator, &fx.ctx);
    defer pool.deinit();

    const key: TargetKey = .{ .width = 16, .height = 16, .format = fx.swapchain.format };
    const h1 = try pool.acquire(key);
    const h2 = try pool.acquire(key);
    _ = h1;
    _ = h2;
    // Simulate a missing-release bug: walker forgot to release both.
    // Sweep reports the leak count, returns refs to the free list so
    // the next frame doesn't double-allocate.
    const leaked = pool.sweepUnreleased();
    try testing.expectEqual(@as(usize, 2), leaked);
    // After sweep, both refs are zero — next acquire recycles one.
    const h3 = try pool.acquire(key);
    try testing.expectEqual(@as(usize, 2), pool.allocations.items.len); // no new alloc
    _ = h3;
}
