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
const spark_mod = @import("../spark.zig");
const markdown = @import("../markdown.zig");
const element_layout = @import("../element_layout.zig");
const layout_cache = @import("../layout_cache.zig");
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
    /// Captured at create time. `deinit_` reaches the registry
    /// through it to tear down child instances in this scope.
    spark: ?*spark_mod.Spark = null,
    /// The body text this instance's `root` was parsed from.
    body: component_mod.Body = .{},
};

/// One-time install. Call after registering the other factories
/// the flex's children may use (e.g. `:::box`).
pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("flex", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    const id_raw = spec.id orelse return error.FlexMissingId;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    c.* = .{
        .direction = .row,
        .gap = 0,
        .body = .{},
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
        .spark = spark,
    };
    errdefer c.arena.deinit();

    // The namespace this block's CHILDREN are parsed into: this
    // instance's own registry key, which is unique by construction.
    // `id_raw` alone is not — every unnamed block shares the empty
    // string, in this document and in every other one, so two panels
    // each holding an unnamed effect resolved their children to one
    // set of instances. See `Spec.scope`.
    c.scope = try allocator.dupe(u8, component_mod.specScope(spec, id_raw));
    errdefer allocator.free(c.scope);

    applyAttrs(c, spec);

    _ = c.body.adopt(spec.body);
    c.root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        spec.body,
        spark.theme,
        spark.registry,
        component_mod.specState(spec, spark.host_state),  // the DOCUMENT's state, not the Spark's root — see specState
        c.scope,
    );

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const prev_version = c.version;
    applyAttrs(c, spec);
    c.version = prev_version +% 1;
    // The body is authored text too, and it can change under a live
    // instance — a hot-reloaded document hands the same `#id` a new body.
    // Re-parse when it does, and only then: an unchanged body must not
    // throw away this subtree's layout cache on every `:::update`.
    if (c.body.adopt(spec.body)) {
        if (c.spark) |sp| {
            // The block-layout cache is keyed by element ADDRESS
            // (`layout_cache.elementIdentity`), which is sound while a
            // parsed tree lives as long as its document — and false the
            // instant one is re-parsed into the same arena, because the
            // recycled allocations land on the same addresses and the new
            // heading collides with the old one's cached draws. Dropping
            // the cache is the honest price of a re-parse, and a re-parse
            // is a human-scale event.
            sp.layout_cache.clear();
            // Empty first, so a parse that fails leaves a valid root
            // rather than one pointing into the arena we just reset.
            c.root = element.Element{ .paragraph = &[_]element.Element{} };
            _ = c.arena.reset(.retain_capacity);
            c.root = try markdown.parseWithStateAndScope(
                c.arena.allocator(),
                spec.body,
                sp.theme,
                sp.registry,
                component_mod.specState(spec, sp.host_state),  // the DOCUMENT's state, not the Spark's root — see specState
                c.scope,
            );
        }
    }
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Tear down child instances FIRST (their bindings reference
    // state we're about to free), then the arena, then us.
    if (c.spark) |sp| sp.registry.deinitScope(c.scope);
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
    // Stage 15 Phase C.5: the flex caches as a whole. `contentVersion`
    // XOR's each child's content_version into its own — so a
    // descendant bump (drag suggestion, state-driven box attr,
    // streaming chart…) flips our effective version and the cache
    // hit becomes a miss. Idle frames blit one entry; partial
    // changes re-walk children (each of whom may still hit their
    // own per-block cache via `layoutAndRenderCached`).
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    // Stage 15 Phase C.5 — hierarchical aggregation. Combine our own
    // version with the children's content_versions so a descendant
    // bump invalidates the flex's cache entry. Without this, the
    // outer cache would replay stale baked-in child output.
    const children: []const element.Element = switch (c.root) {
        .container => |co| co.children,
        else => &[_]element.Element{},
    };
    return c.version ^ layout_cache.aggregateChildVersions(children);
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
        // Stage 15 Phase C.4: cached child walks. Unchanged children
        // hit the block-layout cache and blit. The flex itself still
        // disables its outer cache (children would otherwise need
        // version aggregation up the tree).
        const child_box = try element_layout.layoutAndRenderCached(
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
