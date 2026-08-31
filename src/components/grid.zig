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
//!     :::grid {#id columns="100px 1fr 1fr" row-gap=8 column-gap=16}
//!     :::box {color=red width=100% height=80 radius=8}
//!     :::
//!     ...more cells...
//!     :::
//!
//! ### Tracks
//!
//! `columns` accepts either an integer count (`columns=3` → three
//! `1fr` flex tracks) or a space-separated track list:
//!   * `100px` (or bare `100`) — fixed-width track.
//!   * `1fr`, `2fr`, … — flex track that takes a share of the
//!     remaining width proportional to its `fr` weight.
//!
//! Resolution: sum the fixed widths, subtract from `max_w` (along
//! with `(columns − 1) × column_gap`), then distribute what's left
//! across the flex tracks by `fr` weight. A track list with no
//! flex tracks underfills cleanly; a list with no fixed tracks
//! recovers the equal-width behaviour of `columns=N`.
//!
//! ### Gaps
//!
//! `row-gap` and `column-gap` set the two axes independently;
//! `gap` is a shorthand that sets both. Last-attribute-wins
//! semantics, so `{gap=12 column-gap=24}` resolves to
//! `row_gap=12, column_gap=24`.
//!
//! ## Required #id
//!
//! Like `:::flex` and `:::embedded-document`, the grid requires an
//! `#id` so its children get scoped cache keys (e.g.
//! `dashboard/auto:0`) instead of colliding with outer-document
//! `auto:N` keys. Missing id → `error.GridMissingId`.
//!
//! ## Layout (stage 15e)
//!
//! Each cell `i` lands at column `i % columns`, row `i / columns`.
//! Children receive a child-constraint with `max_w =
//! track_width[col]`, so `:::box {width=100%}` fills its track.
//! Row height = tallest child in the row; the next row starts
//! `row_height + row_gap` below.
//!
//! Per-cell bounds still flow through the kiwi solver via the
//! children's own `layoutViaConstraints` calls (the `:::box` case
//! today; any future grid child that opts in). Cell *positioning*
//! is imperative — solver-driven negotiation between rows + cells
//! lands when a measure pass arrives.

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

pub const Error = error{
    GridMissingId,
    GridNotInstalled,
};

/// Upper bound on column count — well above any sane document
/// grid. Inline-storing the track list dodges per-update arena
/// growth (applyAttrs runs on every host-driven attribute change).
pub const MAX_TRACKS: usize = 32;

/// One column track. `fixed` = pixel width; `flex` = share weight
/// (the `fr` unit), distributing `(avail - fixed_total -
/// total_column_gap)` proportionally across all flex tracks.
pub const TrackSpec = union(enum) {
    fixed: f32,
    flex: f32,
};

const Component = struct {
    tracks: [MAX_TRACKS]TrackSpec,
    track_count: u32,
    row_gap: f32,
    column_gap: f32,
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
    /// Captured at create time. `deinit_` reaches the registry
    /// through it to tear down child instances in this scope.
    spark: ?*spark_mod.Spark = null,
    /// The body text this instance's `root` was parsed from.
    body: component_mod.Body = .{},
};

/// One-time install. Call after registering the other factories
/// the grid's children may use (e.g. `:::box`, `:::flex`).
pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("grid", factory);
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
    const id_raw = spec.id orelse return error.GridMissingId;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    c.* = .{
        .tracks = undefined,
        .track_count = 0,
        .body = .{},
        .row_gap = 0,
        .column_gap = 0,
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
    // Defaults: single flex track, no gap. A grid with no `columns`
    // attr renders as a vertical stack — same shape `:::flex
    // {direction=column}` produces.
    c.tracks[0] = .{ .flex = 1.0 };
    c.track_count = 1;
    c.row_gap = 0;
    c.column_gap = 0;
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "columns")) {
            const n = parseColumns(a.value, &c.tracks);
            if (n > 0) c.track_count = n;
        } else if (std.mem.eql(u8, a.key, "gap")) {
            if (parsePixelLength(a.value)) |p| {
                c.row_gap = p;
                c.column_gap = p;
            }
        } else if (std.mem.eql(u8, a.key, "row-gap")) {
            if (parsePixelLength(a.value)) |p| c.row_gap = p;
        } else if (std.mem.eql(u8, a.key, "column-gap")) {
            if (parsePixelLength(a.value)) |p| c.column_gap = p;
        }
    }
}

/// Extract a pixel value from a length string, dropping percent /
/// auto since those don't make sense for a gap.
fn parsePixelLength(s: []const u8) ?f32 {
    return switch (box_component.parseLength(s) orelse return null) {
        .pixels => |p| p,
        else => null,
    };
}

/// Parse the `columns=…` attribute into a track list. Accepts
/// either an integer count ("3" → three `1fr` tracks) or a
/// space-separated track list ("100px 1fr 1fr"). Returns the
/// number of tracks written into `out`; clamped at `MAX_TRACKS`.
pub fn parseColumns(s: []const u8, out: *[MAX_TRACKS]TrackSpec) u32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return 0;

    // Plain integer N → N × 1fr tracks. Matches the simple-case
    // ergonomics from the Phase F.1 commit so existing `columns=3`
    // call sites keep working.
    if (std.fmt.parseInt(u32, trimmed, 10)) |n| {
        const count = @min(@as(u32, @intCast(@min(n, MAX_TRACKS))), @as(u32, MAX_TRACKS));
        var i: u32 = 0;
        while (i < count) : (i += 1) out[i] = .{ .flex = 1.0 };
        return count;
    } else |_| {}

    var count: u32 = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |token| {
        if (count >= MAX_TRACKS) break;
        if (parseTrack(token)) |t| {
            out[count] = t;
            count += 1;
        }
    }
    return count;
}

/// Parse one track token: `1fr` / `2.5fr` → flex; `100px` / `100`
/// → fixed. Percent tokens are rejected — defer until a concrete
/// callsite asks for them.
pub fn parseTrack(s: []const u8) ?TrackSpec {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.endsWith(u8, trimmed, "fr")) {
        const num = std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 2]) catch return null;
        if (num <= 0) return null;
        return .{ .flex = num };
    }
    return switch (box_component.parseLength(trimmed) orelse return null) {
        .pixels => |p| .{ .fixed = p },
        else => null,
    };
}

/// Resolve track widths against the available width. Fixed tracks
/// take their pixel value as-is; flex tracks share the remainder
/// in proportion to their `fr` weight. Negative leftovers clamp
/// to zero (oversubscribed fixed tracks underfill).
pub fn resolveTrackWidths(
    tracks: []const TrackSpec,
    avail_w: f32,
    column_gap: f32,
    out: *[MAX_TRACKS]f32,
) void {
    if (tracks.len == 0) return;
    const cols_f: f32 = @floatFromInt(tracks.len);
    const total_gap = column_gap * @max(0.0, cols_f - 1.0);

    var fixed_total: f32 = 0;
    var flex_total: f32 = 0;
    for (tracks) |t| switch (t) {
        .fixed => |p| fixed_total += p,
        .flex => |f| flex_total += f,
    };

    const remaining = @max(0.0, avail_w - total_gap - fixed_total);

    for (tracks, 0..) |t, i| {
        out[i] = switch (t) {
            .fixed => |p| p,
            .flex => |f| if (flex_total > 0) remaining * (f / flex_total) else 0,
        };
    }
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    // Stage 15 Phase C.5: the grid caches as a whole, mirroring
    // `:::flex`. `contentVersion` aggregates each cell's version so
    // a descendant bump propagates up. Idle dashboards blit one
    // entry; cell mutations re-walk affected cells while siblings
    // hit their per-block cache.
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    // Stage 15 Phase C.5 — hierarchical aggregation. Same pattern
    // as `:::flex`: fold each cell's content_version into our own
    // so a descendant bump invalidates the grid's cache entry.
    const cells: []const element.Element = switch (c.root) {
        .container => |co| co.children,
        else => &[_]element.Element{},
    };
    return c.version ^ layout_cache.aggregateChildVersions(cells);
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

    if (cells.len == 0 or c.track_count == 0) {
        return .{ .x = origin[0], .y = origin[1], .w = 0, .h = 0, .baseline = 0 };
    }

    // Resolve track widths from the available width. When `max_w`
    // is infinite (unconstrained), fall back to a reasonable
    // default so flex tracks at `width=100%` still get a sensible
    // cell.
    const avail_w: f32 = if (std.math.isFinite(constraints.max_w))
        constraints.max_w
    else
        640.0;
    var track_widths: [MAX_TRACKS]f32 = undefined;
    const tracks = c.tracks[0..c.track_count];
    resolveTrackWidths(tracks, avail_w, c.column_gap, &track_widths);

    // Precompute the per-column x offset so cell placement is O(1).
    var track_offsets: [MAX_TRACKS]f32 = undefined;
    {
        var off: f32 = 0;
        for (tracks, 0..) |_, i| {
            track_offsets[i] = off;
            off += track_widths[i] + c.column_gap;
        }
    }

    var cur_row: usize = 0;
    var row_y: f32 = origin[1];
    var row_h: f32 = 0;
    var max_x: f32 = origin[0];

    for (cells, 0..) |*cell, i| {
        const col: usize = i % c.track_count;
        const row: usize = i / c.track_count;

        // Crossed a row boundary — advance vertical cursor by the
        // previous row's height plus a row gap.
        if (row != cur_row) {
            row_y += row_h + c.row_gap;
            row_h = 0;
            cur_row = row;
        }

        const cell_x = origin[0] + track_offsets[col];
        const cell_constraints: element.Constraints = .{ .max_w = track_widths[col] };

        // Stage 15 Phase C.4: cached cell walks. Static cells (most
        // grid cells) hit the block-layout cache. The grid itself
        // stays disable_cache=true; aggregation up the tree is a
        // separate follow-on.
        const cell_box = try element_layout.layoutAndRenderCached(
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

fn emptyComponent() Component {
    return .{
        .tracks = undefined,
        .track_count = 0,
        .row_gap = 0,
        .column_gap = 0,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .version = 0,
    };
}

test "parseTrack: pixel and fr" {
    try testing.expectEqual(@as(f32, 100), parseTrack("100").?.fixed);
    try testing.expectEqual(@as(f32, 100), parseTrack("100px").?.fixed);
    try testing.expectEqual(@as(f32, 1), parseTrack("1fr").?.flex);
    try testing.expectEqual(@as(f32, 2.5), parseTrack("2.5fr").?.flex);
    try testing.expect(parseTrack("0fr") == null); // weight must be positive
    try testing.expect(parseTrack("garbage") == null);
    try testing.expect(parseTrack("") == null);
}

test "parseColumns: integer shorthand expands to N flex tracks" {
    var buf: [MAX_TRACKS]TrackSpec = undefined;
    const n = parseColumns("3", &buf);
    try testing.expectEqual(@as(u32, 3), n);
    try testing.expectEqual(@as(f32, 1.0), buf[0].flex);
    try testing.expectEqual(@as(f32, 1.0), buf[1].flex);
    try testing.expectEqual(@as(f32, 1.0), buf[2].flex);
}

test "parseColumns: mixed fixed + fr list" {
    var buf: [MAX_TRACKS]TrackSpec = undefined;
    const n = parseColumns("100px 1fr 2fr", &buf);
    try testing.expectEqual(@as(u32, 3), n);
    try testing.expectEqual(@as(f32, 100), buf[0].fixed);
    try testing.expectEqual(@as(f32, 1), buf[1].flex);
    try testing.expectEqual(@as(f32, 2), buf[2].flex);
}

test "parseColumns: garbage tokens are silently skipped" {
    var buf: [MAX_TRACKS]TrackSpec = undefined;
    const n = parseColumns("100px notatrack 1fr", &buf);
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(@as(f32, 100), buf[0].fixed);
    try testing.expectEqual(@as(f32, 1), buf[1].flex);
}

test "parseColumns: empty string returns zero tracks" {
    var buf: [MAX_TRACKS]TrackSpec = undefined;
    try testing.expectEqual(@as(u32, 0), parseColumns("", &buf));
    try testing.expectEqual(@as(u32, 0), parseColumns("   ", &buf));
}

test "resolveTrackWidths: pure flex divides evenly" {
    const tracks = [_]TrackSpec{ .{ .flex = 1 }, .{ .flex = 1 }, .{ .flex = 1 } };
    var widths: [MAX_TRACKS]f32 = undefined;
    resolveTrackWidths(&tracks, 312, 6, &widths); // 312 - 12 (2*gap) = 300; /3 = 100
    try testing.expectEqual(@as(f32, 100), widths[0]);
    try testing.expectEqual(@as(f32, 100), widths[1]);
    try testing.expectEqual(@as(f32, 100), widths[2]);
}

test "resolveTrackWidths: fixed + flex shares the remainder" {
    const tracks = [_]TrackSpec{ .{ .fixed = 100 }, .{ .flex = 1 }, .{ .flex = 2 } };
    var widths: [MAX_TRACKS]f32 = undefined;
    // avail=412, column_gap=6 → total_gap=12 → remaining for flex = 412 - 12 - 100 = 300.
    // 1fr + 2fr → 1/3 (100px) and 2/3 (200px).
    resolveTrackWidths(&tracks, 412, 6, &widths);
    try testing.expectEqual(@as(f32, 100), widths[0]);
    try testing.expectApproxEqAbs(@as(f32, 100), widths[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 200), widths[2], 1e-3);
}

test "resolveTrackWidths: oversubscribed fixed tracks underfill (no negative widths)" {
    const tracks = [_]TrackSpec{ .{ .fixed = 500 }, .{ .flex = 1 } };
    var widths: [MAX_TRACKS]f32 = undefined;
    resolveTrackWidths(&tracks, 200, 0, &widths);
    try testing.expectEqual(@as(f32, 500), widths[0]); // fixed honoured
    try testing.expectEqual(@as(f32, 0), widths[1]); // flex clamped to zero
}

test "resolveTrackWidths: no flex tracks → underfill, no panic on flex_total=0" {
    const tracks = [_]TrackSpec{ .{ .fixed = 100 }, .{ .fixed = 50 } };
    var widths: [MAX_TRACKS]f32 = undefined;
    resolveTrackWidths(&tracks, 400, 0, &widths);
    try testing.expectEqual(@as(f32, 100), widths[0]);
    try testing.expectEqual(@as(f32, 50), widths[1]);
}

test "applyAttrs parses integer columns + uniform gap" {
    var c = emptyComponent();
    defer c.arena.deinit();
    const attrs = [_]components.Attr{
        .{ .key = "columns", .value = "3" },
        .{ .key = "gap", .value = "16" },
    };
    applyAttrs(&c, &.{ .name = "grid", .attrs = &attrs });

    try testing.expectEqual(@as(u32, 3), c.track_count);
    try testing.expectEqual(@as(f32, 1.0), c.tracks[0].flex);
    try testing.expectEqual(@as(f32, 16), c.row_gap);
    try testing.expectEqual(@as(f32, 16), c.column_gap);
}

test "applyAttrs parses mixed track list" {
    var c = emptyComponent();
    defer c.arena.deinit();
    const attrs = [_]components.Attr{
        .{ .key = "columns", .value = "200px 1fr 1fr" },
    };
    applyAttrs(&c, &.{ .name = "grid", .attrs = &attrs });

    try testing.expectEqual(@as(u32, 3), c.track_count);
    try testing.expectEqual(@as(f32, 200), c.tracks[0].fixed);
    try testing.expectEqual(@as(f32, 1), c.tracks[1].flex);
    try testing.expectEqual(@as(f32, 1), c.tracks[2].flex);
}

test "applyAttrs: row-gap and column-gap override gap independently" {
    var c = emptyComponent();
    defer c.arena.deinit();
    const attrs = [_]components.Attr{
        .{ .key = "gap", .value = "12" }, // shorthand sets both
        .{ .key = "column-gap", .value = "24" }, // last-wins overrides one axis
    };
    applyAttrs(&c, &.{ .name = "grid", .attrs = &attrs });

    try testing.expectEqual(@as(f32, 12), c.row_gap);
    try testing.expectEqual(@as(f32, 24), c.column_gap);
}

test "applyAttrs: row-gap alone leaves column-gap at zero" {
    var c = emptyComponent();
    defer c.arena.deinit();
    const attrs = [_]components.Attr{
        .{ .key = "row-gap", .value = "8" },
    };
    applyAttrs(&c, &.{ .name = "grid", .attrs = &attrs });

    try testing.expectEqual(@as(f32, 8), c.row_gap);
    try testing.expectEqual(@as(f32, 0), c.column_gap);
}

test "applyAttrs: defaults to single flex track, zero gaps" {
    var c = emptyComponent();
    defer c.arena.deinit();
    applyAttrs(&c, &.{ .name = "grid" });

    try testing.expectEqual(@as(u32, 1), c.track_count);
    try testing.expectEqual(@as(f32, 1.0), c.tracks[0].flex);
    try testing.expectEqual(@as(f32, 0), c.row_gap);
    try testing.expectEqual(@as(f32, 0), c.column_gap);
}

test "applyAttrs accepts pixel gap with px suffix" {
    var c = emptyComponent();
    defer c.arena.deinit();
    const attrs = [_]components.Attr{ .{ .key = "gap", .value = "14px" } };
    applyAttrs(&c, &.{ .name = "grid", .attrs = &attrs });

    try testing.expectEqual(@as(f32, 14), c.row_gap);
    try testing.expectEqual(@as(f32, 14), c.column_gap);
}
