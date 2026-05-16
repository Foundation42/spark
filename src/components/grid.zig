//! `:::grid` — the second multi-child layout provider (stage 15d).
//!
//! Sibling to `:::flex` for the 2D case. Reads `columns` (track
//! count) and `gap` (pixels, uniform across both axes for the MVP)
//! from attributes; its body holds nested `:::name` directives that
//! become its cells. Children fill cells in **row-major** order;
//! each row's height is the tallest cell in that row.
//!
//! Attribute grammar:
//!
//!     :::grid {#id columns=3 gap=12}
//!     :::box {color=red width=100% height=80 radius=8}
//!     :::
//!     ...more cells...
//!     :::
//!
//! ## Required #id
//!
//! Like `:::flex` and `:::embedded-document`, the grid requires an
//! `#id` so its children get scoped cache keys (e.g.
//! `dashboard/auto:0`) instead of colliding with outer-document
//! `auto:N` keys. Missing id → `error.GridMissingId`.
//!
//! ## Layout (Phase F.1 MVP)
//!
//! Equal-width columns derived from `constraints.max_w`:
//!
//!     col_width = (max_w - (columns - 1) * gap) / columns
//!
//! Cell at index `i` lands at column `i % columns`, row
//! `i / columns`. Children receive a child-constraint with
//! `max_w = col_width`, so `:::box {width=100%}` fills its cell.
//! Row height = tallest child in the row; the next row starts
//! `row_height + gap` below.
//!
//! Per-cell bounds still flow through the kiwi solver via the
//! children's own `layoutViaConstraints` calls (the `:::box` case
//! today; any future grid child that opts in). Cell *positioning*
//! is imperative in the MVP — same trade-off as Phase C.2. Later
//! lift to solver-driven track sizing (`1fr`, named tracks) once
//! a concrete demand surfaces.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const markdown = @import("../markdown.zig");
const element_layout = @import("../element_layout.zig");
const state_mod = @import("../state.zig");
const box_component = @import("box.zig");

pub const Error = error{
    GridMissingId,
    GridNotInstalled,
};

const Component = struct {
    columns: u32,
    gap: f32,
    /// Owns every allocation the parsed child tree refers to.
    arena: std.heap.ArenaAllocator,
    /// Parsed child root — typically a `container.stack_v` whose
    /// children are the resolved `:::name` directives from the
    /// grid's body, walked row-major by `layoutAndRender`.
    root: element.Element,
    /// Scope prefix for child registry keys. Owned by the
    /// Component so `deinit` can call `registry.deinitScope`.
    scope: []u8,
    version: u64 = 0,
};

// ── Module globals (matches the flex / embedded-document pattern;
// the factory.create signature doesn't yet thread host context). ──
var registry_ref: ?*component_mod.Registry = null;
var theme_ref: ?*const element.Theme = null;
var state_ref: ?*state_mod.State = null;

/// One-time install. Call after registering the other factories
/// the grid's children may use (e.g. `:::box`, `:::flex`).
pub fn install(
    registry: *component_mod.Registry,
    theme: *const element.Theme,
    state: *state_mod.State,
) !void {
    registry_ref = registry;
    theme_ref = theme;
    state_ref = state;
    try registry.register("grid", factory);
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
    const reg = registry_ref orelse return error.GridNotInstalled;
    const theme = theme_ref orelse return error.GridNotInstalled;
    const state = state_ref orelse return error.GridNotInstalled;
    const id_raw = spec.id orelse return error.GridMissingId;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    c.* = .{
        .columns = 1,
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
    // Phase F MVP: body changes don't re-parse — author bumps the
    // #id to force destroy + recreate when content shape changes.
    // Attribute changes (columns, gap) take effect immediately.
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
    c.columns = 1;
    c.gap = 0;
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "columns")) {
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, a.value, " \t"), 10) catch continue;
            if (n >= 1) c.columns = n;
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

    // Body parser produced a container.stack_v of cell directives.
    const cells: []const element.Element = switch (c.root) {
        .container => |ctn| ctn.children,
        else => &[_]element.Element{},
    };

    if (cells.len == 0 or c.columns == 0) {
        return .{ .x = origin[0], .y = origin[1], .w = 0, .h = 0, .baseline = 0 };
    }

    // Equal-width tracks derived from the available width. When
    // `max_w` is infinite (unconstrained), fall back to a reasonable
    // default so children at `width=100%` still get a sensible cell.
    const avail_w: f32 = if (std.math.isFinite(constraints.max_w))
        constraints.max_w
    else
        640.0;
    const cols_f: f32 = @floatFromInt(c.columns);
    const total_gap_w: f32 = c.gap * (cols_f - 1);
    const col_width: f32 = @max(0.0, (avail_w - total_gap_w) / cols_f);

    var cur_row: usize = 0;
    var row_y: f32 = origin[1];
    var row_h: f32 = 0;
    var max_x: f32 = origin[0];

    for (cells, 0..) |*cell, i| {
        const col: usize = i % c.columns;
        const row: usize = i / c.columns;

        // Crossed a row boundary — advance vertical cursor by the
        // previous row's height plus a row gap.
        if (row != cur_row) {
            row_y += row_h + c.gap;
            row_h = 0;
            cur_row = row;
        }

        const cell_x = origin[0] + @as(f32, @floatFromInt(col)) * (col_width + c.gap);
        const cell_constraints: element.Constraints = .{ .max_w = col_width };

        const cell_box = try element_layout.layoutAndRender(
            cell.*,
            .{ cell_x, row_y },
            cell_constraints,
            lc,
            out,
        );

        if (cell_box.h > row_h) row_h = cell_box.h;
        const right = cell_x + cell_box.w;
        if (right > max_x) max_x = right;
    }

    const total_h = (row_y - origin[1]) + row_h;
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = max_x - origin[0],
        .h = total_h,
        .baseline = 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "applyAttrs parses columns + gap" {
    var c: Component = .{
        .columns = 1,
        .gap = 0,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const attrs = [_]components.Attr{
        .{ .key = "columns", .value = "3" },
        .{ .key = "gap", .value = "16" },
    };
    const spec: components.Spec = .{ .name = "grid", .attrs = &attrs };
    applyAttrs(&c, &spec);

    try testing.expectEqual(@as(u32, 3), c.columns);
    try testing.expectEqual(@as(f32, 16), c.gap);
}

test "applyAttrs defaults to columns=1, gap=0" {
    var c: Component = .{
        .columns = 5, // start non-default
        .gap = 99,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const spec: components.Spec = .{ .name = "grid" };
    applyAttrs(&c, &spec);

    try testing.expectEqual(@as(u32, 1), c.columns);
    try testing.expectEqual(@as(f32, 0), c.gap);
}

test "applyAttrs rejects columns=0 (keeps prior value)" {
    var c: Component = .{
        .columns = 2,
        .gap = 0,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const attrs = [_]components.Attr{
        .{ .key = "columns", .value = "0" },
    };
    const spec: components.Spec = .{ .name = "grid", .attrs = &attrs };
    applyAttrs(&c, &spec);

    // applyAttrs resets to default (1) before applying, so a
    // rejected value leaves the default in place — not the prior 2.
    try testing.expectEqual(@as(u32, 1), c.columns);
}

test "applyAttrs accepts pixel gap with px suffix" {
    var c: Component = .{
        .columns = 1,
        .gap = 0,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
    defer c.arena.deinit();

    const attrs = [_]components.Attr{
        .{ .key = "gap", .value = "14px" },
    };
    const spec: components.Spec = .{ .name = "grid", .attrs = &attrs };
    applyAttrs(&c, &spec);

    try testing.expectEqual(@as(f32, 14), c.gap);
}
