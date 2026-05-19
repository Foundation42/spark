//! Effects-spec Phase B.4.b.3 substrate gate — synthetic
//! single_source dispatch through the full Phase 1 processor.
//!
//! No factory ships a `.pass_shape = .single_source` until B.5
//! (`:::drop_shadow`), so the production `dispatchOffscreenPasses`
//! call from a real host never enters the populated path at
//! B.4.b.3. This test manually pushes a synthetic single_source
//! `PassDispatch` (referencing the registered `copy.frag`
//! substrate-smoke filter from B.4.b.1), then drives
//! `dispatchOffscreenPasses` against a real Vulkan command buffer
//! and verifies the substrate end-to-end:
//!
//!   * Target acquired from `target_pool`, recorded in
//!     `dispatch_target_map` AND `acquired_targets`.
//!   * Offscreen render-pass begin/end + image-layout barriers
//!     pass Vulkan validation (validation layers gate the barrier
//!     stage/access flags, rendering attachment shape, descriptor
//!     bind shape — silent layer = correct substrate wiring).
//!   * Release path closes cleanly via `target_pool.sweepUnreleased`
//!     when the test skips Phase 3 (no `endFrame` call).
//!
//! Full Phase 2 + Phase 3 testing waits for B.5 — that's when a
//! real factory exercises both the offscreen path and the main-
//! pass compose against a populated target.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const pass = spark.pass;
const element = spark.element;
const vk = spark.vk;
const fixture = @import("fixture.zig");

const c = vk.c;

/// Allocate + begin a transient command buffer for the test. Caller
/// owns teardown via `endCommandBuffer` + `vkDestroyCommandPool`.
const TestCmd = struct {
    pool: c.VkCommandPool,
    cmd: c.VkCommandBuffer,
    device: c.VkDevice,

    fn init(ctx: *const vk.Context) !TestCmd {
        var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        cpci.queueFamilyIndex = ctx.queue_family;
        var pool: c.VkCommandPool = null;
        try vk.check(c.vkCreateCommandPool(ctx.device, &cpci, null, &pool));
        errdefer c.vkDestroyCommandPool(ctx.device, pool, null);

        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try vk.check(c.vkAllocateCommandBuffers(ctx.device, &ai, &cmd));

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        return .{ .pool = pool, .cmd = cmd, .device = ctx.device };
    }

    fn finish(self: *TestCmd) !void {
        try vk.check(c.vkEndCommandBuffer(self.cmd));
    }

    fn deinit(self: *TestCmd) void {
        // Destroying the pool frees the cmd buffer implicitly.
        c.vkDestroyCommandPool(self.device, self.pool, null);
        self.* = undefined;
    }
};

test "dispatchOffscreenPasses: empty pass_dispatches is a clean no-op" {
    // Sanity baseline. With no single_source dispatches in the
    // list, Phase 1 walks zero entries; the only state change is
    // `dispatch_target_map` getting cleared + resized to zero.
    // Confirms the iteration logic doesn't trip on the empty case.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();

    var tc = try TestCmd.init(&fx.ctx);
    defer tc.deinit();

    try sp.dispatchOffscreenPasses(tc.cmd);
    try tc.finish();

    try testing.expectEqual(@as(usize, 0), sp.acquired_targets.items.len);
    try testing.expectEqual(@as(usize, 0), sp.dispatch_target_map.items.len);
}

test "dispatchOffscreenPasses: synthetic single_source acquires + barriers" {
    // The substrate end-to-end test. Manually push a single_source
    // dispatch referencing the B.4.b.1 substrate-smoke filter
    // (`copy.frag`), drive Phase 1 against a real command buffer,
    // and verify the (target acquire, render-pass scope, barrier,
    // dispatch_target_map population) chain.
    //
    // Validation layers gate the substrate's GPU correctness — any
    // mismatched barrier stage/access, attachment shape, or layout
    // transition prints loudly and (in this test's hidden GLFW
    // window setup) fails by abort. Silent passage = correct
    // substrate wiring.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();

    // Synthesize one single_source dispatch. Filter is the
    // B.4.b.1 substrate-smoke `copy.frag` — registered eagerly at
    // Spark.init, so the pipeline is in
    // `single_source_pipelines` already.
    const filter_id = pass.shaderIdFromName("copy.frag");
    try sp.pass_dispatches.append(.{
        .single_source = .{
            .target_size = .{ 64, 64 },
            .filter_shader_id = filter_id,
            .filter_uniforms = [_]u8{0} ** element.MAX_PASS_UNIFORM_BYTES,
            .filter_uniforms_len = 4, // copy.frag: float alpha
            .compose_region = .{ .x = 10, .y = 10, .w = 64, .h = 64 },
            .subtree_dispatch_range = .{ 1, 1 }, // empty subtree
            .sequence_index = 0,
        },
    });

    var tc = try TestCmd.init(&fx.ctx);
    defer tc.deinit();

    try sp.dispatchOffscreenPasses(tc.cmd);
    try tc.finish();

    // One target acquired, recorded in both bookkeeping lists.
    try testing.expectEqual(@as(usize, 1), sp.acquired_targets.items.len);
    try testing.expectEqual(@as(usize, 1), sp.dispatch_target_map.items.len);
    try testing.expect(sp.dispatch_target_map.items[0] != null);

    // The target_pool's allocation list should have one entry (the
    // freshly-acquired offscreen target). ref_count stays at 1
    // because we never reached Phase 3 (release happens in
    // `endFrame` which the test doesn't call).
    try testing.expectEqual(@as(usize, 1), sp.target_pool.allocations.items.len);
    try testing.expectEqual(@as(u32, 1), sp.acquired_targets.items[0].allocation.ref_count);

    // Manually release so Spark.deinit's target_pool.deinit doesn't
    // have to rely on its destruction-regardless behaviour. Cleanest
    // teardown path; equivalent to Phase 3's release sweep.
    sp.target_pool.release(sp.acquired_targets.items[0]);
    sp.acquired_targets.clearRetainingCapacity();
}

test "dispatchOffscreenPasses: nested single_sources processed depth-first" {
    // Recursion semantics. Two single_source dispatches with the
    // inner nested inside the outer's subtree_dispatch_range. Phase
    // 1's recursive processing should:
    //   * Process the inner FIRST (depth-first post-order)
    //   * Process the outer SECOND
    // Result: acquired_targets ordering reflects acquisition order
    // (inner THEN outer); dispatch_target_map has both slots filled.
    //
    // The outer's render pass includes a compose-sample against
    // the inner's target — validation layers gate the
    // descriptor-set bind for that sample.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();

    const filter_id = pass.shaderIdFromName("copy.frag");

    // pass_dispatches layout:
    //   [0] outer single_source, subtree_dispatch_range = [1, 2)
    //   [1] inner single_source, subtree_dispatch_range = [2, 2) (empty)
    // The outer's subtree covers exactly the inner's slot, so
    // Phase 1's depth-first recursion handles inner before outer.
    try sp.pass_dispatches.append(.{
        .single_source = .{
            .target_size = .{ 100, 100 },
            .filter_shader_id = filter_id,
            .filter_uniforms = [_]u8{0} ** element.MAX_PASS_UNIFORM_BYTES,
            .filter_uniforms_len = 4,
            .compose_region = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
            .subtree_dispatch_range = .{ 1, 2 }, // covers inner
            .sequence_index = 0,
        },
    });
    try sp.pass_dispatches.append(.{
        .single_source = .{
            .target_size = .{ 50, 50 },
            .filter_shader_id = filter_id,
            .filter_uniforms = [_]u8{0} ** element.MAX_PASS_UNIFORM_BYTES,
            .filter_uniforms_len = 4,
            .compose_region = .{ .x = 25, .y = 25, .w = 50, .h = 50 }, // inside outer
            .subtree_dispatch_range = .{ 2, 2 }, // empty (no further nesting)
            .sequence_index = 1,
        },
    });

    var tc = try TestCmd.init(&fx.ctx);
    defer tc.deinit();

    try sp.dispatchOffscreenPasses(tc.cmd);
    try tc.finish();

    // Two targets acquired. Order is inner-first (depth-first
    // post-order) — the inner finishes its render pass + barrier
    // before the outer's begins, so the outer's compose-sample of
    // the inner's target is valid Vulkan.
    try testing.expectEqual(@as(usize, 2), sp.acquired_targets.items.len);
    try testing.expectEqual(@as(usize, 2), sp.dispatch_target_map.items.len);
    try testing.expect(sp.dispatch_target_map.items[0] != null); // outer
    try testing.expect(sp.dispatch_target_map.items[1] != null); // inner

    // Both pool allocations are distinct (different sizes — 100×100
    // vs 50×50 — so different free-list buckets).
    try testing.expectEqual(@as(usize, 2), sp.target_pool.allocations.items.len);

    // Cleanup — release both in reverse acquisition order to keep
    // the pool's invariants clean.
    sp.target_pool.release(sp.acquired_targets.items[1]);
    sp.target_pool.release(sp.acquired_targets.items[0]);
    sp.acquired_targets.clearRetainingCapacity();
}
