//! `:::flex` — the first multi-child layout provider (stage 15c.2).
//!
//! Reads `direction` (row|column) and `gap` (pixels) from
//! attributes; its body holds nested `:::name` directives that
//! become its children. The factory re-runs the markdown parser
//! against the body so children get resolved through the same
//! registry the outer document uses — they're cached across
//! re-parses just like top-level components.
//!
//! ## Required #id
//!
//! Like `:::embedded-document`, `:::flex` requires an `#id` so
//! its children get scoped cache keys (e.g. `mygrid/auto:0`)
//! instead of colliding with outer-document `auto:N` keys.
//! Missing id → `error.FlexMissingId`.
//!
//! ## Layout (Phase C.2 MVP)
//!
//! Children placed imperatively in sequence with cumulative-x
//! (row) or cumulative-y (column), gap between siblings. Each
//! child still goes through the constraint substrate for its own
//! width/height bounds — the flex parent computes positions; the
//! children constrain their sizes. Phase C.3 (later) lifts gap
//! positioning into the solver so siblings can grow/shrink
//! against each other.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const markdown = @import("../markdown.zig");
const element_layout = @import("../element_layout.zig");
const state_mod = @import("../state.zig");
const box_component = @import("box.zig");

pub const Direction = enum { row, column };

pub const Error = error{
    FlexMissingId,
    FlexNotInstalled,
};

const Component = struct {
    direction: Direction,
    gap: f32,
    /// Owns every allocation the parsed child tree refers to.
    arena: std.heap.ArenaAllocator,
    /// Parsed child root. Typically a `container.stack_v` whose
    /// children are the resolved `:::name` directives from the
    /// flex's body.
    root: element.Element,
    /// Scope prefix for child registry keys. Owned by the
    /// Component so `deinit` can call `registry.deinitScope`.
    scope: []u8,
    version: u64 = 0,
};

// ── Module globals (matches the embedded-document pattern; the
// factory.create signature doesn't yet thread host context). ──
var registry_ref: ?*component_mod.Registry = null;
var theme_ref: ?*const element.Theme = null;
var state_ref: ?*state_mod.State = null;

/// One-time install. Call after registering the other factories
/// the flex's children may use (e.g. `:::box`).
pub fn install(
    registry: *component_mod.Registry,
    theme: *const element.Theme,
    state: *state_mod.State,
) !void {
    registry_ref = registry;
    theme_ref = theme;
    state_ref = state;
    try registry.register("flex", factory);
}

pub fn deinitGlobals() void {
    registry_ref = null;
    theme_ref = null;
    state_ref = null;
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

fn create(
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    const reg = registry_ref orelse return error.FlexNotInstalled;
    const theme = theme_ref orelse return error.FlexNotInstalled;
    const state = state_ref orelse return error.FlexNotInstalled;
    const id_raw = spec.id orelse return error.FlexMissingId;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    c.* = .{
        .direction = .row,
        .gap = 0,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    errdefer c.arena.deinit();

    c.scope = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(c.scope);

    applyAttrs(c, spec);

    c.root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        spec.body,
        theme,
        reg,
        state,
        c.scope,
    );

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const prev_version = c.version;
    applyAttrs(c, spec);
    c.version = prev_version +% 1;
    // Phase C MVP: body changes don't trigger a re-parse — same
    // limitation `:::embedded-document` documents. Author bumps
    // the #id to force destroy + recreate when content changes.
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Tear down child instances FIRST (their bindings reference
    // state we're about to free), then the arena, then us.
    if (registry_ref) |r| r.deinitScope(c.scope);
    c.arena.deinit();
    allocator.free(c.scope);
    allocator.destroy(c);
}

fn applyAttrs(c: *Component, spec: *const components.Spec) void {
    c.direction = .row;
    c.gap = 0;
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "direction")) {
            if (std.mem.eql(u8, a.value, "column")) c.direction = .column else c.direction = .row;
        } else if (std.mem.eql(u8, a.key, "gap")) {
            if (box_component.parseLength(a.value)) |l| {
                c.gap = switch (l) {
                    .pixels => |p| p,
                    else => 0,
                };
            }
        }
    }
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    // Stage 15D: flex caches its children's draws into a single
    // block-cache entry. When a child opts into the suggestion
    // channel (drag-driven resizing via `:::handle`), bumping the
    // child's version doesn't invalidate THIS entry — the flex
    // would hit cache and replay the stale baked-in child output.
    // Disabling block-grain caching here ensures every frame
    // re-walks the children so their layoutViaConstraints sees
    // any new suggestion. Cost is small (flex walks a handful of
    // children imperatively); hierarchical cache invalidation can
    // earn this back in a future stage.
    .disable_cache = true,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *const Component = @ptrCast(@alignCast(ctx));

    // The body parser produced a container.stack_v of the child
    // directives. Iterate its children directly — we're imposing
    // our own layout (row/column with gap) instead of letting the
    // container default to vertical stacking.
    const child_slice: []const element.Element = switch (c.root) {
        .container => |ctn| ctn.children,
        else => &[_]element.Element{},
    };

    // Phase C.3 measure pass — runs only for row direction with a
    // finite parent width. Asks each child for its intrinsic
    // BlockMetrics (width + grow weight); computes slack = parent_w
    // − Σ(fixed widths) − Σ(gaps), then distributes slack to grow>0
    // children proportionally to their weights. Result is a final
    // width per child, passed to its `layoutAndRender` as max_w —
    // boxes at `width=100%` (the default) resolve to the slot; boxes
    // with explicit width keep their declared size.
    //
    // When all children have grow=0, the math reduces to "each child
    // gets its intrinsic width" — visually identical to pre-C.3
    // behaviour. Column direction skips the pass entirely (heights
    // are unbounded under stack_v, so slack is undefined).
    var final_widths: ?[]f32 = null;
    if (c.direction == .row and
        std.math.isFinite(constraints.max_w) and
        child_slice.len > 0)
    {
        final_widths = try computeRowWidths(c, child_slice, constraints.max_w, lc);
    }
    defer if (final_widths) |fw| lc.allocator.free(fw);

    var cur_x = origin[0];
    var cur_y = origin[1];
    var max_w: f32 = 0;
    var max_h: f32 = 0;
    var first = true;

    for (child_slice, 0..) |*child, i| {
        if (!first) {
            switch (c.direction) {
                .row => cur_x += c.gap,
                .column => cur_y += c.gap,
            }
        }
        first = false;

        const child_max_w: f32 = if (final_widths) |fw| fw[i] else constraints.max_w;
        const child_constraints: element.Constraints = .{ .max_w = child_max_w };
        const child_box = try element_layout.layoutAndRender(
            child.*,
            .{ cur_x, cur_y },
            child_constraints,
            lc,
            out,
        );

        switch (c.direction) {
            .row => {
                cur_x += child_box.w;
                if (child_box.h > max_h) max_h = child_box.h;
            },
            .column => {
                cur_y += child_box.h;
                if (child_box.w > max_w) max_w = child_box.w;
            },
        }
    }

    return switch (c.direction) {
        .row => .{
            .x = origin[0],
            .y = origin[1],
            .w = cur_x - origin[0],
            .h = max_h,
            .baseline = 0,
        },
        .column => .{
            .x = origin[0],
            .y = origin[1],
            .w = max_w,
            .h = cur_y - origin[1],
            .baseline = 0,
        },
    };
}

/// Stage 15 Phase C.3 — compute per-child width for a row-direction
/// flex. Measures each child via `element_layout.measureBlock` to
/// learn its intrinsic width + grow weight, then:
///
///   * Children with `grow == 0` claim their intrinsic width.
///   * Slack = parent_w − Σ(intrinsic for grow=0) − Σ(gaps).
///   * Children with `grow > 0` split slack proportionally.
///
/// Result allocated against `lc.allocator` (per-frame arena in the
/// typical host wiring); caller is responsible for freeing.
fn computeRowWidths(
    c: *const Component,
    children: []const element.Element,
    max_w: f32,
    lc: *element.LayoutCtx,
) ![]f32 {
    const N = children.len;
    const final = try lc.allocator.alloc(f32, N);
    errdefer lc.allocator.free(final);

    const metrics = try lc.allocator.alloc(element.BlockMetrics, N);
    defer lc.allocator.free(metrics);

    var total_fixed: f32 = 0;
    var total_grow: u32 = 0;
    for (children, 0..) |child, i| {
        const m = try element_layout.measureBlock(
            child,
            .{ .max_w = max_w },
            lc,
        );
        metrics[i] = m;
        if (m.grow == 0) {
            total_fixed += m.width;
        } else {
            total_grow += m.grow;
        }
    }

    const total_gap: f32 = if (N >= 2)
        @as(f32, @floatFromInt(N - 1)) * c.gap
    else
        0;
    const slack: f32 = @max(0.0, max_w - total_fixed - total_gap);

    for (children, 0..) |_, i| {
        if (metrics[i].grow > 0 and total_grow > 0) {
            const share = (@as(f32, @floatFromInt(metrics[i].grow)) /
                @as(f32, @floatFromInt(total_grow))) * slack;
            final[i] = share;
        } else {
            final[i] = metrics[i].width;
        }
    }
    return final;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "applyAttrs parses direction + gap" {
    var c: Component = .{
        .direction = .row,
        .gap = 0,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const attrs = [_]components.Attr{
        .{ .key = "direction", .value = "column" },
        .{ .key = "gap", .value = "20" },
    };
    const spec: components.Spec = .{ .name = "flex", .attrs = &attrs };
    applyAttrs(&c, &spec);

    try testing.expectEqual(Direction.column, c.direction);
    try testing.expectEqual(@as(f32, 20), c.gap);
}

test "applyAttrs defaults to row direction + zero gap" {
    var c: Component = .{
        .direction = .column, // start with something non-default
        .gap = 99,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const spec: components.Spec = .{ .name = "flex" }; // no attrs
    applyAttrs(&c, &spec);

    try testing.expectEqual(Direction.row, c.direction);
    try testing.expectEqual(@as(f32, 0), c.gap);
}

test "applyAttrs accepts pixel gap with px suffix" {
    var c: Component = .{
        .direction = .row,
        .gap = 0,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const attrs = [_]components.Attr{
        .{ .key = "gap", .value = "12px" },
    };
    const spec: components.Spec = .{ .name = "flex", .attrs = &attrs };
    applyAttrs(&c, &spec);

    try testing.expectEqual(@as(f32, 12), c.gap);
}
