//! `:::handle` — drag-to-suggest layout handle (stage 15D).
//!
//! Sits in a document and on drag, mutates one axis of a sibling
//! component's solver bounds via `LayoutContext.setSuggestion`. The
//! target component reads the suggestion during its layout pass and
//! translates it into an `addEditVariable + suggestValue` at medium
//! strength — the substrate's GPU-input → kiwi channel in concrete
//! form.
//!
//! Attribute grammar:
//!
//!     :::handle {target=#mybox axis=horizontal width=6 height=100}
//!     :::
//!
//! - `target` (required) — `#id` of the component whose size the
//!   handle drives. Resolved through the registry at event time so
//!   stale lookups can't outlive their target.
//! - `axis` (optional) — `horizontal` (default) drags x, suggests
//!   `width`; `vertical` drags y, suggests `height`.
//! - `width` / `height` — handle's own dimensions. Defaults pick
//!   sensible thicknesses (6px on the drag axis, 100% on the
//!   perpendicular axis).
//! - `color` — handle bar fill colour. Default: a neutral grip grey.
//!
//! Drag model: mouse_down anywhere on the handle starts a drag;
//! anchor (cursor position in screen-space) + initial target size
//! get recorded. mouse_move (with button held) recomputes new size
//! as `initial_size + (cursor_global_now - cursor_global_at_start)`
//! and calls `lc.setSuggestion`. mouse_up clears the active flag
//! but keeps the suggestion in place — resize and stay resized.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const box_helpers = @import("box.zig"); // reuse parseLength + Length + parseColor
const layout_context_mod = @import("../layout/context.zig");

pub const Error = error{
    HandleMissingTarget,
    HandleNotInstalled,
};

pub const Axis = enum { horizontal, vertical };

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("handle", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Component state ────────────────────────────────────────────────

const Component = struct {
    allocator: std.mem.Allocator,
    target: []u8, // owned, leading '#' stripped
    axis: Axis,
    width: box_helpers.Length,
    height: box_helpers.Length,
    color: [4]f32,

    // Transient drag state. Persisted across mouse_move/up events
    // within one drag, reset on mouse_down.
    drag_active: bool = false,
    drag_start_cursor_global: f32 = 0,
    drag_start_target_size: f64 = 0,
    /// Handle's box position at the moment mouse_down latched the
    /// drag. The dispatcher captures the Hit struct at mouse_down
    /// (`fc.captured`), so `local[0]` for every subsequent
    /// mouse_move is `current_cursor_world - FROZEN_handle_x`.
    /// We MUST use this frozen value (not `c.last_box.x`, which
    /// updates each layout pass as the handle moves) to recover
    /// cursor world — otherwise the handle's own motion gets
    /// double-counted into the cursor delta and the suggestion
    /// runs away in a positive feedback loop.
    drag_start_handle_origin: f32 = 0,

    // Last laid-out box. Read by on_input to convert local mouse
    // coords back to screen-space.
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    version: u64 = 0,
    /// Captured at create time. on_input reaches the layout context
    /// and registry through it (drag targets, suggestion channel).
    spark: ?*spark_mod.Spark = null,

    fn fromSpec(allocator: std.mem.Allocator, spec: *const components.Spec) !Component {
        var target_raw: ?[]const u8 = null;
        var axis: Axis = .horizontal;
        var width: box_helpers.Length = .{ .pixels = 6 };
        var height: box_helpers.Length = .{ .percent = 1.0 };
        var color: [4]f32 = HANDLE_DEFAULT_COLOR;

        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "target")) {
                target_raw = a.value;
            } else if (std.mem.eql(u8, a.key, "axis")) {
                if (std.mem.eql(u8, a.value, "vertical")) {
                    axis = .vertical;
                } else {
                    axis = .horizontal;
                }
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (box_helpers.parseLength(a.value)) |l| width = l;
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (box_helpers.parseLength(a.value)) |l| height = l;
            } else if (std.mem.eql(u8, a.key, "color")) {
                if (box_helpers.parseColor(a.value)) |c| color = c;
            }
        }

        const t_raw = target_raw orelse return Error.HandleMissingTarget;
        const t_stripped = if (t_raw.len > 0 and t_raw[0] == '#') t_raw[1..] else t_raw;

        // Sensible perpendicular-axis default. The user can override
        // explicitly with width=/height= attrs.
        if (axis == .vertical) {
            width = .{ .percent = 1.0 };
            height = .{ .pixels = 6 };
            // Re-apply explicit attrs in case the author specified
            // both — the second loop is cheaper than threading
            // "was-explicit" flags through the first.
            for (spec.attrs) |a| {
                if (std.mem.eql(u8, a.key, "width")) {
                    if (box_helpers.parseLength(a.value)) |l| width = l;
                } else if (std.mem.eql(u8, a.key, "height")) {
                    if (box_helpers.parseLength(a.value)) |l| height = l;
                }
            }
        }

        return .{
            .allocator = allocator,
            .target = try allocator.dupe(u8, t_stripped),
            .axis = axis,
            .width = width,
            .height = height,
            .color = color,
        };
    }

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        // Update path: refresh attrs without touching drag state.
        // We intentionally keep `target` (the handle's identity) —
        // re-pointing a live drag at a new component would surprise
        // anyone watching.
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "axis")) {
                self.axis = if (std.mem.eql(u8, a.value, "vertical")) .vertical else .horizontal;
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (box_helpers.parseLength(a.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (box_helpers.parseLength(a.value)) |l| self.height = l;
            } else if (std.mem.eql(u8, a.key, "color")) {
                if (box_helpers.parseColor(a.value)) |c| self.color = c;
            }
        }
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = try Component.fromSpec(allocator, spec);
    c.spark = spark;
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.target);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
    // Like slider, the handle's visible state (drag highlight) and
    // its last_box need updating each frame; skip the block cache.
    .disable_cache = true,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Visual constants ───────────────────────────────────────────────

const HANDLE_DEFAULT_COLOR: [4]f32 = .{ 0.45, 0.50, 0.58, 1.0 };
const HANDLE_ACTIVE_COLOR: [4]f32 = .{ 0.85, 0.90, 1.0, 1.0 };

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const max_h = if (std.math.isFinite(constraints.max_h)) constraints.max_h else 100;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 6;
    const w = c.width.resolve(max_w, fallback_w);
    const h = c.height.resolve(max_h, max_h);

    const color = if (c.drag_active) HANDLE_ACTIVE_COLOR else c.color;
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = color,
        .radius = 3,
    });

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = 0,
    };
    c.last_box = box;
    return box;
}

// ── Input handling ─────────────────────────────────────────────────

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_raw: *anyopaque,
) anyerror!void {
    _ = state_raw;
    const c: *Component = @ptrCast(@alignCast(ctx));

    switch (event) {
        .mouse_down => |m| try startDrag(c, m.local),
        .mouse_move => |m| if (m.button_down and c.drag_active) try applyDrag(c, m.local),
        .mouse_up => |m| {
            if (m.button == 0) c.drag_active = false;
        },
        // Keyboard / focus channels — handle doesn't take focus.
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

/// Begin a drag. Records the cursor's position in screen-space (via
/// the handle's `last_box` origin) and the target's current size as
/// the drag anchor. mouse_move events compute deltas against this
/// anchor; mouse_up clears the active flag (the suggestion sticks).
fn startDrag(c: *Component, local: [2]f32) !void {
    const target = resolveTarget(c) orelse return;
    const target_key = @intFromPtr(target.ctx);

    const lc = (c.spark orelse return).layout_context;
    const axis: layout_context_mod.Axis = if (c.axis == .horizontal) .width else .height;

    // Read the target's current size. Priority order:
    //   1. A live suggestion — the user has dragged before; resume
    //      from where they left off.
    //   2. The target's last solver-resolved size — first drag,
    //      target re-walked this frame.
    //   3. The persistent last_sizes cache (stage 15 Phase C.4) —
    //      first drag, target was cache-hit so the solver doesn't
    //      know about it. Populated by `on_layout_complete`.
    //   4. Zero — fallback if none of the above hits.
    const initial_size: f64 = blk: {
        if (lc.getSuggestion(target_key, axis)) |s| break :blk s;
        if (lc.bounds_map.get(target_key)) |b| {
            switch (axis) {
                .width => break :blk lc.solver.value(b.x_max) - lc.solver.value(b.x_min),
                .height => break :blk lc.solver.value(b.y_max) - lc.solver.value(b.y_min),
                else => break :blk 0,
            }
        }
        if (lc.lastSize(target_key)) |sz| {
            break :blk @as(f64, switch (axis) {
                .width => sz[0],
                .height => sz[1],
                else => 0,
            });
        }
        break :blk 0;
    };

    c.drag_active = true;
    c.drag_start_target_size = initial_size;
    c.drag_start_handle_origin = switch (c.axis) {
        .horizontal => c.last_box.x,
        .vertical => c.last_box.y,
    };
    c.drag_start_cursor_global = switch (c.axis) {
        .horizontal => c.drag_start_handle_origin + local[0],
        .vertical => c.drag_start_handle_origin + local[1],
    };
}

/// Per-event delta application. Converts local cursor coords back
/// to screen-space (via the handle's current `last_box`), diffs
/// against the drag-start anchor, adds to the initial target size,
/// and posts the new value as a suggestion. The bumper LayoutContext
/// fires invalidates the block cache for the target so the next
/// layout pass picks up the change.
fn applyDrag(c: *Component, local: [2]f32) !void {
    const target = resolveTarget(c) orelse return;
    const target_key = @intFromPtr(target.ctx);

    const lc = (c.spark orelse return).layout_context;
    const axis: layout_context_mod.Axis = if (c.axis == .horizontal) .width else .height;

    // Cursor world reconstruction uses the FROZEN origin captured at
    // drag start, NOT `c.last_box.x`. The dispatcher's `fc.captured`
    // latches the Hit at mouse_down — every subsequent mouse_move
    // delivers `local = current_cursor - frozen_origin`. Adding
    // `frozen_origin` back recovers true cursor world. Adding the
    // moving `last_box.x` would double-count the handle's own motion
    // and runaway-amplify the drag.
    const cursor_global_now: f32 = switch (c.axis) {
        .horizontal => c.drag_start_handle_origin + local[0],
        .vertical => c.drag_start_handle_origin + local[1],
    };
    const delta: f64 = @as(f64, cursor_global_now - c.drag_start_cursor_global);
    var new_size = c.drag_start_target_size + delta;
    if (new_size < 0) new_size = 0;

    try lc.setSuggestion(target_key, axis, new_size);
}

/// Resolve the handle's `target=#id` attr to a live registry entry.
/// Returns null when the target isn't registered (or was GC'd) —
/// the handle silently does nothing in that case rather than
/// crashing the host.
///
/// Uses `lookupSibling` so the author writes `target=#resizer_left`
/// and gets the box in the same `:::flex {#scope}` scope as the
/// handle itself, rather than having to write the full scoped path.
/// Falls back to a scope-less lookup automatically when the target
/// lives at top level. Cheap enough at input frequency to re-resolve
/// on every event instead of caching across the drag.
fn resolveTarget(c: *Component) ?component_mod.Resolved {
    const sp = c.spark orelse return null;
    if (c.target.len == 0) return null;
    return sp.registry.lookupSibling(@ptrCast(c), c.target);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Component.fromSpec: target stripped of leading hash" {
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "#left" },
    };
    const spec: components.Spec = .{ .name = "handle", .attrs = &attrs };
    const c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    try testing.expectEqualStrings("left", c.target);
    try testing.expectEqual(Axis.horizontal, c.axis);
}

test "Component.fromSpec: vertical axis swaps default dims" {
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "top" },
        .{ .key = "axis", .value = "vertical" },
    };
    const spec: components.Spec = .{ .name = "handle", .attrs = &attrs };
    const c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    try testing.expectEqual(Axis.vertical, c.axis);
    // Vertical-axis handle should be wide × thin by default.
    try testing.expectEqual(box_helpers.Length{ .percent = 1.0 }, c.width);
    try testing.expectEqual(box_helpers.Length{ .pixels = 6 }, c.height);
}

test "Component.fromSpec: missing target rejected" {
    const spec: components.Spec = .{ .name = "handle" };
    try testing.expectError(Error.HandleMissingTarget, Component.fromSpec(testing.allocator, &spec));
}
