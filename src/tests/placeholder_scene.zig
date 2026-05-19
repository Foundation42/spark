//! `:::placeholder_scene` — test-only factory exercising the
//! `.host_slot` PassShape arm end-to-end. Effects-spec Phase B.7.
//!
//! Not registered by `installCoreComponents` (spec D#11 exception:
//! stubs aren't vocabulary). Tests in `integration_render.zig` and
//! the synthetic substrate test (when one lands) register this
//! factory on a fresh Spark before exercising the dispatch path.
//! Lights up the union arm so it doesn't bitrot before Phase D's
//! `:::3d-scene` matryoshka adoption ships — "if you reserve a
//! type variant, you build a call site for it."
//!
//! Attribute grammar:
//!
//!     :::placeholder_scene {width=200 height=120 color=#1a1a2e}
//!     :::
//!
//! Renders a flat clear-to-color into the offscreen target via the
//! host callback (this file's `invokeCallback`), then composites
//! the target back to MAIN via the default
//! `host_slot_passthrough.frag` shader. The visible result is a
//! rectangle of `color` at the claimed region — same effect as
//! `:::box {color=...}` but routed through the host_slot dispatch
//! path so the substrate gets exercised.
//!
//! **Per-instance state shape.** Each instance owns its own
//! `Component` struct on the registry allocator. The vtable's
//! `invoke_host_slot` hook returns
//! `(invokeCallback, @ptrCast(component))` — `invokeCallback`
//! reads its `Component.clear_color` and emits the corresponding
//! `vkCmdBeginRendering` + `vkCmdEndRendering` (clear-load-op +
//! no draws). Per-instance discrimination via `user_data` is the
//! exact mechanism Phase D's `:::3d-scene scene_id=hud` /
//! `scene_id=settings` will use to route into different
//! matryoshka scenes.

const std = @import("std");
const spark = @import("../lib.zig");
const element = @import("../element.zig");
const component_mod = @import("../component.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const params = @import("../params.zig");
const box_helpers = @import("../components/box.zig");
const pass = @import("../pass/root.zig");
const vk = @import("../gpu/vk.zig");

pub const Error = error{
    PlaceholderShaderNotRegistered,
};

const SHADER_NAME = "host_slot_passthrough.frag";
pub const SHADER_ID: component_mod.ShaderId = pass.shaderIdFromName(SHADER_NAME);

const Component = struct {
    width: box_helpers.Length,
    height: box_helpers.Length,
    /// Premultiplied RGBA clear color the host callback writes
    /// into the offscreen target. Read at callback-firing time, not
    /// at create time — `update` re-parses on attr changes so
    /// `<:::update {target=color} {#id}>#newcolor` propagates
    /// without rebuilding the instance.
    clear_color: [4]f32,

    fn fromSpec(spec: *const components.Spec) Component {
        const width = if (params.find(spec, "width")) |s|
            box_helpers.parseLength(s) orelse box_helpers.Length{ .pixels = 200 }
        else
            box_helpers.Length{ .pixels = 200 };
        const height = if (params.find(spec, "height")) |s|
            box_helpers.parseLength(s) orelse box_helpers.Length{ .pixels = 120 }
        else
            box_helpers.Length{ .pixels = 120 };
        const color = params.resolve([4]f32, spec, "color", .{ 0.1, 0.05, 0.25, 1.0 });
        return .{
            .width = width,
            .height = height,
            .clear_color = color,
        };
    }
};

pub fn install(sp: *spark_mod.Spark) !void {
    try sp.registry.register("placeholder_scene", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .pass_shape = .{ .host_slot = .{
        .composite_shader_id = SHADER_ID,
        .hdr_target = false,
    } },
};

fn create(
    sp: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    // Fail-fast barrier — parallel to gradient.zig's. A missing
    // host_slot_passthrough.frag (build skipped, name typo, missing
    // registerEmbeddedPassShaders entry) trips here at create time
    // rather than mid-dispatch as a "lookup miss → silent no-op."
    _ = sp.shader_resolver.resolve(SHADER_ID) catch return Error.PlaceholderShaderNotRegistered;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = Component.fromSpec(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.* = Component.fromSpec(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    // host_slot requires `invoke_host_slot` (walker errors otherwise).
    // snapshot_uniforms NOT wired — HostSlotStep carries no uniforms
    // in v1, so the walker's snapshot pathway is skipped for
    // host_slot dispatches.
    .invoke_host_slot = invokeHostSlot,
    .snapshot_uniforms = snapshotUniforms,
};

/// Per-instance vtable hook. Returns the (callback, user_data) pair
/// the walker captures onto the emitted HostSlotStep. `user_data` is
/// the Component pointer — the callback reads `Component.clear_color`
/// at firing time so subsequent `update`-driven attr changes
/// propagate without rebuilding the instance.
fn invokeHostSlot(ctx: *anyopaque) element.HostSlotInvocation {
    return .{
        .callback = invokeCallback,
        .user_data = ctx,
    };
}

/// HostSlotStep carries no uniforms in v1 — the walker's snapshot
/// pathway still calls this hook for non-content elements (it's
/// mandatory at the walker layer), so return 0 bytes written.
/// Symmetric with the pattern factories' early-zero-pad shape.
fn snapshotUniforms(ctx: *anyopaque, out: []u8) usize {
    _ = ctx;
    @memset(out, 0);
    return 0;
}

/// Host-side render callback. Spark hands us a cmd buffer already
/// bound + a target image already in COLOR_ATTACHMENT_OPTIMAL
/// (Phase 1 dispatch contract — see `element.HostSlotCtx`). We
/// open a one-color-attachment `vkCmdBeginRendering` scope with
/// LOAD_OP_CLEAR to `clear_color`, then close it. No draws — the
/// clear IS the render. Spark transitions back to SHADER_READ on
/// return.
///
/// **Why a real Vulkan scope and not just a barrier-clear?** The
/// callback exercises the contract Phase D's `:::3d-scene` will
/// inherit: hosts open their OWN render-pass scopes (matryoshka's
/// scene render is multi-attachment MRT with depth, doesn't fit
/// spark's single-color-attachment world). The B.7 stub uses the
/// simplest possible scope (one attachment, no draws) so the
/// contract is exercised end-to-end at minimum complexity.
fn invokeCallback(user_data: *anyopaque, ctx: element.HostSlotCtx) void {
    const c: *const Component = @ptrCast(@alignCast(user_data));
    const cmd: vk.c.VkCommandBuffer = @ptrCast(ctx.cmd);
    const view: vk.c.VkImageView = @ptrCast(ctx.target_view);

    var color_att = std.mem.zeroes(vk.c.VkRenderingAttachmentInfo);
    color_att.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    color_att.imageView = view;
    color_att.imageLayout = vk.c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    color_att.loadOp = vk.c.VK_ATTACHMENT_LOAD_OP_CLEAR;
    color_att.storeOp = vk.c.VK_ATTACHMENT_STORE_OP_STORE;
    color_att.clearValue = .{ .color = .{ .float32 = c.clear_color } };

    var ri = std.mem.zeroes(vk.c.VkRenderingInfo);
    ri.sType = vk.c.VK_STRUCTURE_TYPE_RENDERING_INFO;
    ri.renderArea = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = ctx.width, .height = ctx.height },
    };
    ri.layerCount = 1;
    ri.colorAttachmentCount = 1;
    ri.pColorAttachments = &color_att;
    vk.c.vkCmdBeginRendering(cmd, &ri);
    vk.c.vkCmdEndRendering(cmd);
}

/// Claim the requested width/height; emit no DrawList work — the
/// host_slot dispatch path generates the pixels via the callback +
/// composite, not via DrawList primitives. Same shape as the pattern
/// canary factories' layout.
fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    _ = lc;
    _ = out;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    const w = c.width.resolve(constraints.max_w, constraints.max_w);
    const h = c.height.resolve(constraints.max_h, 120);
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "factory: pass_shape is .host_slot with correct composite shader_id" {
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .host_slot),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .host_slot => |h| try testing.expectEqual(SHADER_ID, h.composite_shader_id),
        else => unreachable,
    }
}

test "fromSpec: defaults when attrs omitted" {
    const spec: components.Spec = .{ .name = "placeholder_scene" };
    const c = Component.fromSpec(&spec);
    try testing.expect(c.width == .pixels);
    try testing.expectApproxEqAbs(@as(f32, 0.1), c.clear_color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.clear_color[3], 0.001);
}

test "fromSpec: parses color attr" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "#ff0000" },
        .{ .key = "width", .value = "256" },
        .{ .key = "height", .value = "192" },
    };
    const spec: components.Spec = .{ .name = "placeholder_scene", .attrs = &attrs };
    const c = Component.fromSpec(&spec);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.clear_color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), c.clear_color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.clear_color[3], 0.001);
    switch (c.width) {
        .pixels => |p| try testing.expectApproxEqAbs(@as(f32, 256), p, 0.001),
        else => try testing.expect(false),
    }
}

test "invokeHostSlot: returns callback paired with ctx pointer" {
    // Lock-in: the per-instance pair must carry the ctx as user_data,
    // not some factory-level singleton. Phase D matryoshka's
    // :::3d-scene scene_id=hud / scene_id=settings discrimination
    // depends on this being the per-instance Component pointer.
    var c = Component{
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 100 },
        .clear_color = .{ 0, 0, 0, 1 },
    };
    const inv = invokeHostSlot(@ptrCast(&c));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&c)), inv.user_data);
    try testing.expect(@intFromPtr(inv.callback) != 0);
}
