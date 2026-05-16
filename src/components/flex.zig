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

    var cur_x = origin[0];
    var cur_y = origin[1];
    var max_w: f32 = 0;
    var max_h: f32 = 0;
    var first = true;

    for (child_slice) |*child| {
        if (!first) {
            switch (c.direction) {
                .row => cur_x += c.gap,
                .column => cur_y += c.gap,
            }
        }
        first = false;

        const child_constraints: element.Constraints = .{ .max_w = constraints.max_w };
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
