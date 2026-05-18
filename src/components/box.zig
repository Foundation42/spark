//! `:::box` — the first concrete component (stage 7c). Validates the
//! end-to-end loop: directive parse → registry resolve → factory
//! create → cached instance → layout returns Box → quad emit.
//!
//! Attribute grammar:
//!
//!     :::box {#optional-id color=red width=200 height=80 radius=8}
//!     :::
//!
//! Supported values:
//!
//!   * `color` — named (red, green, blue, yellow, orange, purple,
//!     cyan, magenta, white, black, gray) or hex (`#RGB`, `#RRGGBB`,
//!     `#RRGGBBAA`). Missing or unparseable → opaque magenta so the
//!     author notices the typo. `rgb()` / `rgba()` syntax deferred.
//!   * `width` / `height` — `200` or `200px` → pixel literal,
//!     `100%` → fraction of `constraints.max_w` (or 0 if unbounded).
//!     Missing → `width=100%`, `height=80px` as banner-strip
//!     defaults.
//!   * `radius` — pixel literal, defaults to 0.
//!
//! The component's per-instance state lives in the registry's
//! allocator (NOT the parse arena) so it persists across re-parses.
//! `update` is wired so attr edits in subsequent parses mutate the
//! cached instance in place instead of triggering a destroy + create
//! cycle — this is the "cheap edit" path the live-documents vision
//! relies on.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const kiwi = @import("../layout/kiwi/root.zig");
const layout_context_mod = @import("../layout/context.zig");

pub const Length = union(enum) {
    pixels: f32,
    percent: f32, // 0..1 (so 100% is 1.0)
    auto,

    pub fn resolve(self: Length, max: f32, fallback: f32) f32 {
        return switch (self) {
            .pixels => |p| p,
            .percent => |f| if (std.math.isFinite(max)) max * f else fallback,
            .auto => fallback,
        };
    }
};

const Component = struct {
    color: [4]f32,
    width: Length,
    height: Length,
    radius: f32,
    /// Flex-grow weight (stage 15 Phase C.3). 0 (the default) means
    /// "claim my intrinsic width"; nonzero means "claim a proportional
    /// share of any slack my parent flex has after subtracting
    /// fixed-width siblings." Honoured by `:::flex`; ignored by
    /// stack_v / grid / direct render.
    grow: u32 = 0,
    /// Float side (stage 15 Phase E text exclusion). `.normal` flows
    /// in document order. `.float_left` / `.float_right` opt the box
    /// out of normal flow: stack_v positions the box at the
    /// container's left or right edge at the current cursor and
    /// doesn't advance, while the box registers a rect exclusion so
    /// following text wraps around it. Floats default to `width=120
    /// height=120` if the author leaves the dimensions unset — a
    /// `100%`-wide float would consume the whole column and defeat the
    /// purpose.
    float: element.FlowKind = .normal,
    /// Bumped on every mutation; consulted by the retained layout
    /// cache so a state-driven attr change invalidates the cached
    /// block. See `layout_cache.zig`.
    version: u64 = 0,

    fn fromSpec(spec: *const components.Spec) Component {
        var c: Component = .{
            .color = MAGENTA,
            .width = .{ .percent = 1.0 },
            .height = .{ .pixels = 80 },
            .radius = 0,
            .grow = 0,
            .float = .normal,
        };
        var explicit_width = false;
        var explicit_height = false;
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "color")) {
                if (parseColor(a.value)) |col| c.color = col;
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (parseLength(a.value)) |l| {
                    c.width = l;
                    explicit_width = true;
                }
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (parseLength(a.value)) |l| {
                    c.height = l;
                    explicit_height = true;
                }
            } else if (std.mem.eql(u8, a.key, "radius")) {
                if (parseLength(a.value)) |l| {
                    c.radius = switch (l) {
                        .pixels => |p| p,
                        .percent => |_| 0, // percent radius makes no sense without a context
                        .auto => 0,
                    };
                }
            } else if (std.mem.eql(u8, a.key, "grow")) {
                c.grow = std.fmt.parseInt(u32, std.mem.trim(u8, a.value, " \t"), 10) catch 0;
            } else if (std.mem.eql(u8, a.key, "float")) {
                const v = std.mem.trim(u8, a.value, " \t");
                if (std.mem.eql(u8, v, "left")) {
                    c.float = .float_left;
                } else if (std.mem.eql(u8, v, "right")) {
                    c.float = .float_right;
                } else {
                    c.float = .normal;
                }
            }
        }
        // Floats need finite intrinsic dimensions — the percent default
        // would devour the whole column and produce no wrap-around
        // space. Backfill author-friendly pixel defaults when float is
        // on and dimensions weren't set explicitly.
        if (c.float != .normal) {
            if (!explicit_width) c.width = .{ .pixels = 120 };
            if (!explicit_height) c.height = .{ .pixels = 120 };
        }
        return c;
    }
};

const MAGENTA: [4]f32 = .{ 1.0, 0.0, 1.0, 1.0 };

// Module-global LayoutContext reference (matches the handle pattern).
// Used in `deinit_` to unregister the component's bumper + clear its
// last_size entry so stale `@intFromPtr` keys don't linger past
// component destruction. Set by `install`; null when the box was
// registered via `registry.register(...)` directly (pre-15 Phase C.4
// callers). When null, `deinit_` just frees the component — the
// stale-bumper window stays open for that path.
var layout_context_ref: ?*layout_context_mod.LayoutContext = null;

/// Preferred registration path for stage 15 Phase C.4 onwards.
/// Stashes the LayoutContext so `deinit_` can clean up the bumper
/// + last_size entry. Use instead of `registry.register("box", factory)`
/// for hosts that wire a LayoutContext.
pub fn install(
    registry: *component_mod.Registry,
    layout_context: *layout_context_mod.LayoutContext,
) !void {
    layout_context_ref = layout_context;
    try registry.register("box", factory);
}

/// Test-side helper for tearing down the global reference between
/// runs. Hosts that own a single LayoutContext for their lifetime
/// (the typical case) don't need to call this.
pub fn deinitGlobals() void {
    layout_context_ref = null;
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

fn create(
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    c.* = Component.fromSpec(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const prev_version = c.version;
    c.* = Component.fromSpec(spec);
    c.version = prev_version +% 1;
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Clean up persistent state keyed by our pointer before we
    // free it. If a new box gets allocated at the same address
    // later, it'll register fresh bumper + size entries; without
    // this, the stale entries would briefly point at freed memory
    // until the new component overwrote them.
    if (layout_context_ref) |lc| {
        const key = @intFromPtr(c);
        lc.unregisterBumper(key);
        lc.clearSize(key);
    }
    allocator.destroy(c);
}

/// Component-target update path. Each action targets one field; body
/// is the new value as a string. Unknown actions are silent no-ops at
/// this stage — production telemetry / logging is the next refinement.
///
/// Conflict with `${state.x}`-templated attrs: the host's slider /
/// state.set path goes through `factory.update`, which calls
/// `fromSpec` and re-reads every templated attr. A subsequent
/// `state.set` of any templated path will therefore stomp these
/// direct-set values. That's by design — the binding is the source
/// of truth for templated components. `handle_update` is the cheap
/// path for *non-templated* attrs or for components that own their
/// state opaquely (charts, scrolling logs, …).
fn handleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.version +%= 1;
    const value = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.eql(u8, action, "set-color")) {
        if (parseColor(value)) |col| c.color = col;
    } else if (std.mem.eql(u8, action, "set-width")) {
        if (parseLength(value)) |l| c.width = l;
    } else if (std.mem.eql(u8, action, "set-height")) {
        if (parseLength(value)) |l| c.height = l;
    } else if (std.mem.eql(u8, action, "set-radius")) {
        if (parseLength(value)) |l| {
            c.radius = switch (l) {
                .pixels => |p| p,
                else => 0,
            };
        }
    }
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    .measure_block = measureBlock,
    .on_layout_complete = onLayoutComplete,
    .flow_kind = flowKind,
};

fn flowKind(ctx: *anyopaque) element.FlowKind {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.float;
}

/// Post-layout hook (stage 15 Phase C.4). Fires after every walk —
/// cache hit OR miss — via `element_layout`. Records the box's
/// resolved size into `LayoutContext.last_sizes` so that drag
/// handlers reading the target's size via `lc.lastSize(key)` get a
/// fresh value even when the box was cache-hit and therefore didn't
/// re-add itself to the solver this frame.
fn onLayoutComplete(ctx: *anyopaque, box: element.Box, lc: *element.LayoutCtx) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (lc.layout_context) |lctx| {
        lctx.recordSize(@intFromPtr(c), box.w, box.h) catch {
            // Out of memory on a size cache write isn't fatal — the
            // drag fallback degrades gracefully (handler reads null,
            // initial_size defaults to 0). Don't propagate.
        };

        // Stage 15 Phase E text exclusion: a floated box re-registers
        // its rect exclusion on every walk (cache hit and miss alike).
        // beginPass cleared the exclusion list at frame start; this
        // hook repopulates it from the box's resolved box, ensuring
        // following paragraphs see the up-to-date exclusion regardless
        // of cache state.
        if (c.float != .normal) {
            const side: layout_context_mod.ExclusionSide = switch (c.float) {
                .float_left => .left,
                .float_right => .right,
                .normal => unreachable,
            };
            lctx.registerExclusion(.{
                .x_min = box.x,
                .y_min = box.y,
                .x_max = box.x + box.w,
                .y_max = box.y + box.h,
                .side = side,
            }) catch {
                // OOM on an exclusion append leaves following lines
                // wrapping the full column for this frame — visually
                // wrong but recoverable next frame. Don't propagate.
            };
        }
    }
}

/// Block-context measure (stage 15 Phase C.3). Reports the box's
/// intrinsic size and grow weight to a constraint-aware parent
/// (`:::flex` currently; future grid row tracks). The reported width
/// is the attr-driven `width` resolved against `constraints.max_w`
/// — same math `layoutAndRender` uses. The suggestion channel
/// (drag-driven overrides) is deliberately NOT consulted here: a box
/// inside a flex reports its declared size, and the flex's grow
/// distribution then drives the actual width.
fn measureBlock(
    ctx: *anyopaque,
    lc: *element.LayoutCtx,
    constraints: element.Constraints,
) anyerror!element.BlockMetrics {
    _ = lc;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 320.0;
    const w_target = c.width.resolve(max_w, fallback_w);
    const h_target = c.height.resolve(max_w, 80.0);
    return .{
        .width = w_target,
        .height = h_target,
        .grow = c.grow,
    };
}

/// Version bumper trampoline registered with LayoutContext.bumpers.
/// External suggestion mutations (drag handlers etc.) call into here
/// via the type-erased VersionBumper so the block-layout cache
/// invalidates and the next walk picks up the new geometry.
fn bumpVersion(ctx: *anyopaque) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.version +%= 1;
}

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
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 320.0;
    const w_target = c.width.resolve(max_w, fallback_w);
    const h_target = c.height.resolve(max_w, 80.0);

    // Stage 15 Phase B: when the host wires a LayoutContext, the box
    // declares its bounds as solver variables — four anonymous
    // External symbols, four required equalities (anchor x, anchor y,
    // width, height) — then reads positions back from the solver.
    // Visual output is identical to the fallback path; the
    // architectural commitment is that future providers can now
    // negotiate against the same solver this box just produced
    // bounds in.
    if (lc.layout_context) |layout_ctx| {
        return layoutViaConstraints(c, layout_ctx, lc.allocator, origin, w_target, h_target, out);
    }

    // Fallback: imperative path used by tests + by any future host
    // that hasn't wired a LayoutContext yet. Produces the same
    // bounds; just skips the solver round-trip.
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w_target, h_target },
        .color = c.color,
        .radius = c.radius,
    });
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = w_target,
        .h = h_target,
        .baseline = 0,
    };
}

/// Constraint-path layout. Fetches the box's bounds quad from the
/// LayoutContext's element pool (keyed by `@intFromPtr(component)`
/// so parent providers can reach the same vars to negotiate
/// against), registers four required equalities, asks the solver
/// for resolved positions, emits the quad.
///
/// Per-pass solver overhead: ~10-30µs per box on top of the
/// fallback path's near-zero — well within the frame budget. The
/// `getBounds` route means a future `:::flex` parent walker can
/// look up *this* box's bounds before walking into it, and
/// constrain `box[i+1].x_min == box[i].x_max + gap` without the
/// box having to expose its variable handles.
fn layoutViaConstraints(
    c: *Component,
    layout_ctx: *layout_context_mod.LayoutContext,
    alloc: std.mem.Allocator,
    origin: [2]f32,
    w_target: f32,
    h_target: f32,
    out: *element.DrawList,
) anyerror!element.Box {
    // Stage-14b parallel walker reaches us on worker threads —
    // serialise solver + bounds_map mutation across all callers.
    // See `LayoutContext.mutex` for the full rationale.
    layout_ctx.mutex.lock();
    defer layout_ctx.mutex.unlock();

    const key = @intFromPtr(c);
    const bounds = try layout_ctx.getBounds(key);

    // Register a version bumper so external suggestion mutations
    // (drag handlers, future scripted layouts) invalidate this box
    // in the retained block-layout cache. Cleared each `beginPass`;
    // re-registered here on every walk.
    try layout_ctx.registerBumper(key, .{ .bump = bumpVersion, .ctx = @ptrCast(c) });

    var c1 = try kiwi.expr(alloc, bounds.x_min).eq(@as(f64, origin[0])).required();
    defer c1.deinit(alloc);
    _ = try layout_ctx.solver.addConstraint(c1);

    var c2 = try kiwi.expr(alloc, bounds.y_min).eq(@as(f64, origin[1])).required();
    defer c2.deinit(alloc);
    _ = try layout_ctx.solver.addConstraint(c2);

    // Width: solve to the attr-driven `w_target` unless a width
    // suggestion exists for this box, in which case the suggested
    // value drives via an edit variable at medium strength.
    // Required `x_max - x_min >= 0` keeps the box from inverting
    // even if a negative drag delta crosses the floor.
    if (layout_ctx.getSuggestion(key, .width)) |sw| {
        try layout_ctx.solver.addEditVariable(bounds.x_max, kiwi.strength.medium);
        try layout_ctx.solver.suggestValue(bounds.x_max, @as(f64, origin[0]) + sw);
        var c_floor = try kiwi.expr(alloc, bounds.x_max).minus(bounds.x_min).geq(@as(f64, 0)).required();
        defer c_floor.deinit(alloc);
        _ = try layout_ctx.solver.addConstraint(c_floor);
    } else {
        var c3 = try kiwi.expr(alloc, bounds.x_max).minus(bounds.x_min).eq(@as(f64, w_target)).required();
        defer c3.deinit(alloc);
        _ = try layout_ctx.solver.addConstraint(c3);
    }

    if (layout_ctx.getSuggestion(key, .height)) |sh| {
        try layout_ctx.solver.addEditVariable(bounds.y_max, kiwi.strength.medium);
        try layout_ctx.solver.suggestValue(bounds.y_max, @as(f64, origin[1]) + sh);
        var c_floor = try kiwi.expr(alloc, bounds.y_max).minus(bounds.y_min).geq(@as(f64, 0)).required();
        defer c_floor.deinit(alloc);
        _ = try layout_ctx.solver.addConstraint(c_floor);
    } else {
        var c4 = try kiwi.expr(alloc, bounds.y_max).minus(bounds.y_min).eq(@as(f64, h_target)).required();
        defer c4.deinit(alloc);
        _ = try layout_ctx.solver.addConstraint(c4);
    }

    layout_ctx.solver.updateVariables();

    const sx: f32 = @floatCast(layout_ctx.solver.value(bounds.x_min));
    const sy: f32 = @floatCast(layout_ctx.solver.value(bounds.y_min));
    const sw: f32 = @floatCast(layout_ctx.solver.value(bounds.x_max) - layout_ctx.solver.value(bounds.x_min));
    const sh: f32 = @floatCast(layout_ctx.solver.value(bounds.y_max) - layout_ctx.solver.value(bounds.y_min));

    try out.quads.append(.{
        .dst_pos = .{ sx, sy },
        .dst_size = .{ sw, sh },
        .color = c.color,
        .radius = c.radius,
    });

    return .{
        .x = sx,
        .y = sy,
        .w = sw,
        .h = sh,
        .baseline = 0,
    };
}

// ── Parsing helpers ────────────────────────────────────────────────

pub fn parseColor(s: []const u8) ?[4]f32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '#') return parseHexColor(trimmed[1..]);
    return parseNamedColor(trimmed);
}

fn parseHexColor(hex: []const u8) ?[4]f32 {
    return switch (hex.len) {
        3 => decodeHex(.{
            expandHexDigit(hex[0]) orelse return null,
            expandHexDigit(hex[1]) orelse return null,
            expandHexDigit(hex[2]) orelse return null,
            255,
        }),
        6 => decodeHex(.{
            (hexNibble(hex[0]) orelse return null) * 16 + (hexNibble(hex[1]) orelse return null),
            (hexNibble(hex[2]) orelse return null) * 16 + (hexNibble(hex[3]) orelse return null),
            (hexNibble(hex[4]) orelse return null) * 16 + (hexNibble(hex[5]) orelse return null),
            255,
        }),
        8 => decodeHex(.{
            (hexNibble(hex[0]) orelse return null) * 16 + (hexNibble(hex[1]) orelse return null),
            (hexNibble(hex[2]) orelse return null) * 16 + (hexNibble(hex[3]) orelse return null),
            (hexNibble(hex[4]) orelse return null) * 16 + (hexNibble(hex[5]) orelse return null),
            (hexNibble(hex[6]) orelse return null) * 16 + (hexNibble(hex[7]) orelse return null),
        }),
        else => null,
    };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Expand a single hex digit to a byte by doubling (CSS `#RGB`
/// shorthand): "f" → 0xff, "a" → 0xaa, "0" → 0x00.
fn expandHexDigit(c: u8) ?u8 {
    const n = hexNibble(c) orelse return null;
    return n * 16 + n;
}

fn decodeHex(bytes: [4]u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(bytes[0])) / 255.0,
        @as(f32, @floatFromInt(bytes[1])) / 255.0,
        @as(f32, @floatFromInt(bytes[2])) / 255.0,
        @as(f32, @floatFromInt(bytes[3])) / 255.0,
    };
}

fn parseNamedColor(name: []const u8) ?[4]f32 {
    const Named = struct { n: []const u8, c: [4]f32 };
    const table = [_]Named{
        .{ .n = "red", .c = .{ 0.90, 0.30, 0.30, 1.0 } },
        .{ .n = "green", .c = .{ 0.30, 0.78, 0.40, 1.0 } },
        .{ .n = "blue", .c = .{ 0.36, 0.55, 0.95, 1.0 } },
        .{ .n = "yellow", .c = .{ 0.96, 0.85, 0.30, 1.0 } },
        .{ .n = "orange", .c = .{ 0.96, 0.60, 0.25, 1.0 } },
        .{ .n = "purple", .c = .{ 0.68, 0.45, 0.92, 1.0 } },
        .{ .n = "cyan", .c = .{ 0.30, 0.85, 0.92, 1.0 } },
        .{ .n = "magenta", .c = .{ 0.92, 0.40, 0.78, 1.0 } },
        .{ .n = "white", .c = .{ 0.95, 0.95, 0.98, 1.0 } },
        .{ .n = "black", .c = .{ 0.02, 0.02, 0.03, 1.0 } },
        .{ .n = "gray", .c = .{ 0.50, 0.52, 0.58, 1.0 } },
        .{ .n = "grey", .c = .{ 0.50, 0.52, 0.58, 1.0 } },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.n, name)) return entry.c;
    }
    return null;
}

pub fn parseLength(s: []const u8) ?Length {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;

    if (trimmed[trimmed.len - 1] == '%') {
        const num = std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) catch return null;
        return .{ .percent = num / 100.0 };
    }
    const numeric_end = blk: {
        // Strip an optional `px` suffix; everything else parses as
        // the raw float, which catches both `200` and `200.5`.
        if (std.mem.endsWith(u8, trimmed, "px"))
            break :blk trimmed.len - 2;
        break :blk trimmed.len;
    };
    const num = std.fmt.parseFloat(f32, trimmed[0..numeric_end]) catch return null;
    return .{ .pixels = num };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseColor: named" {
    const red = parseColor("red") orelse unreachable;
    try testing.expect(red[0] > 0.5);
    try testing.expect(red[1] < 0.5);
    try testing.expect(parseColor("RED") != null);
    try testing.expect(parseColor("not-a-color") == null);
    try testing.expect(parseColor("") == null);
}

test "parseColor: hex" {
    const six = parseColor("#ff0000") orelse unreachable;
    try testing.expectApproxEqAbs(@as(f32, 1.0), six[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), six[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), six[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), six[3], 0.001);

    // Short form expands by digit-doubling.
    const short = parseColor("#f00") orelse unreachable;
    try testing.expectApproxEqAbs(@as(f32, 1.0), short[0], 0.001);

    // With alpha.
    const with_alpha = parseColor("#0000ff80") orelse unreachable;
    try testing.expectApproxEqAbs(@as(f32, 1.0), with_alpha[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), with_alpha[3], 0.01);

    try testing.expect(parseColor("#zzzz") == null);
    try testing.expect(parseColor("#12") == null); // wrong length
}

test "parseLength: pixels" {
    try testing.expectEqual(@as(f32, 200), parseLength("200").?.pixels);
    try testing.expectEqual(@as(f32, 200), parseLength("200px").?.pixels);
    try testing.expectEqual(@as(f32, 12.5), parseLength("12.5").?.pixels);
}

test "parseLength: percent" {
    const p = parseLength("100%") orelse unreachable;
    try testing.expectEqual(@as(f32, 1.0), p.percent);
    try testing.expectEqual(@as(f32, 0.5), parseLength("50%").?.percent);
}

test "parseLength: garbage returns null" {
    try testing.expect(parseLength("apples") == null);
    try testing.expect(parseLength("") == null);
}

test "Length.resolve" {
    const px: Length = .{ .pixels = 200 };
    try testing.expectEqual(@as(f32, 200), px.resolve(400, 0));

    const pc: Length = .{ .percent = 0.5 };
    try testing.expectEqual(@as(f32, 200), pc.resolve(400, 0));
    // Unbounded max_w → fallback.
    try testing.expectEqual(@as(f32, 99), pc.resolve(std.math.inf(f32), 99));

    const a: Length = .auto;
    try testing.expectEqual(@as(f32, 42), a.resolve(400, 42));
}

test "Component.fromSpec: defaults" {
    const spec: components.Spec = .{ .name = "box" };
    const c = Component.fromSpec(&spec);
    try testing.expectEqual(MAGENTA, c.color); // missing color → magenta indicator
    try testing.expect(c.width == .percent);
    try testing.expectEqual(@as(f32, 1.0), c.width.percent);
    try testing.expect(c.height == .pixels);
    try testing.expectEqual(@as(f32, 80), c.height.pixels);
    try testing.expectEqual(@as(f32, 0), c.radius);
}

test "Component.fromSpec: full attrs" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "blue" },
        .{ .key = "width", .value = "300" },
        .{ .key = "height", .value = "120px" },
        .{ .key = "radius", .value = "12" },
    };
    const spec: components.Spec = .{ .name = "box", .attrs = &attrs };
    const c = Component.fromSpec(&spec);
    try testing.expect(c.color[2] > 0.5); // blue dominant
    try testing.expectEqual(@as(f32, 300), c.width.pixels);
    try testing.expectEqual(@as(f32, 120), c.height.pixels);
    try testing.expectEqual(@as(f32, 12), c.radius);
}

test "handleUpdate: set-color mutates instance color" {
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 50 },
        .radius = 0,
    };
    try handleUpdate(@ptrCast(&c), "set-color", "orange");
    try testing.expect(c.color[0] > 0.5); // orange has dominant red+green
    try testing.expect(c.color[1] > 0.4);

    // Trailing whitespace trimmed from body.
    try handleUpdate(@ptrCast(&c), "set-color", "  green  \n");
    try testing.expect(c.color[1] > 0.5);
    try testing.expect(c.color[0] < 0.5);
}

test "handleUpdate: set-radius / set-width / set-height" {
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 50 },
        .radius = 0,
    };
    try handleUpdate(@ptrCast(&c), "set-radius", "20");
    try testing.expectEqual(@as(f32, 20), c.radius);

    try handleUpdate(@ptrCast(&c), "set-width", "250px");
    try testing.expectEqual(@as(f32, 250), c.width.pixels);

    try handleUpdate(@ptrCast(&c), "set-height", "75%");
    try testing.expect(c.height == .percent);
    try testing.expectEqual(@as(f32, 0.75), c.height.percent);
}

test "Component.fromSpec: grow attr parses to u32" {
    const attrs_yes = [_]components.Attr{
        .{ .key = "grow", .value = "3" },
    };
    const spec_yes: components.Spec = .{ .name = "box", .attrs = &attrs_yes };
    try testing.expectEqual(@as(u32, 3), Component.fromSpec(&spec_yes).grow);

    // Missing grow → default 0.
    const spec_no: components.Spec = .{ .name = "box" };
    try testing.expectEqual(@as(u32, 0), Component.fromSpec(&spec_no).grow);

    // Garbage grow → default 0.
    const attrs_bad = [_]components.Attr{
        .{ .key = "grow", .value = "notanumber" },
    };
    const spec_bad: components.Spec = .{ .name = "box", .attrs = &attrs_bad };
    try testing.expectEqual(@as(u32, 0), Component.fromSpec(&spec_bad).grow);
}

test "vtable.measure_block reports attr-driven width + grow" {
    // Build a Component directly (no factory needed — measure_block
    // doesn't touch the registry).
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 120 },
        .height = .{ .pixels = 40 },
        .radius = 0,
        .grow = 2,
    };

    // measure_block takes a LayoutCtx pointer but doesn't read it
    // (current impl). Synthesise a minimal one — we just need the
    // pointer to be non-null and the function not to crash.
    var lc: element.LayoutCtx = undefined;
    const m = try measureBlock(@ptrCast(&c), &lc, .{ .max_w = 400 });
    try testing.expectEqual(@as(f32, 120), m.width);
    try testing.expectEqual(@as(f32, 40), m.height);
    try testing.expectEqual(@as(u32, 2), m.grow);

    // Percent width resolves against constraints.max_w.
    c.width = .{ .percent = 0.5 };
    const m2 = try measureBlock(@ptrCast(&c), &lc, .{ .max_w = 400 });
    try testing.expectEqual(@as(f32, 200), m2.width);
}

test "handleUpdate: unknown action is silent no-op" {
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 50 },
        .radius = 0,
    };
    try handleUpdate(@ptrCast(&c), "explode", "boom");
    try testing.expectEqual(MAGENTA, c.color);
}
