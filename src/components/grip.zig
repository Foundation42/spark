//! `::grip` — a two-axis drag source.
//!
//! Press it, move the mouse, and it writes the cursor's travel into one
//! or two state paths. That is the whole component. It has no idea what
//! those paths mean, which is the point: a host that mirrors them onto
//! something positional gets a draggable thing, and spark never learns
//! what that thing is.
//!
//! Its first use is moving matryoshka's HUD panels, whose pins are plane
//! knobs the document already mirrors. The document does the wiring:
//!
//!     plane:
//!       px:    mirror hud/panels/0/x
//!       py:    mirror hud/panels/0/y
//!       spanx: read   hud/panels/span/x
//!       spany: read   hud/panels/span/y
//!
//!     :::grip {x=px y=py x_span=${state.spanx} y_span=${state.spany}}
//!     :::
//!
//! Attribute grammar:
//!
//! - `x` / `y` (both optional, at least one wanted) — the state paths to
//!   write. Bare paths, same as `:::slider {target=...}`. Omit one for a
//!   single-axis drag.
//! - `x_span` / `y_span` (optional) — how many SCREEN PIXELS of travel
//!   equal one unit of the written value. Defaults to the surface extent,
//!   which is right whenever the target is a plain fraction of the
//!   screen and wrong by the panel's own size when the host maps the
//!   fraction across a smaller span. See "Units" below.
//! - `min` / `max` (optional) — clamp on the written value. Defaults 0
//!   and 1, because a normalised pin is what this exists to drive.
//! - `width` / `height` (optional) — the grip's own box. Defaults to the
//!   full available width and 22px, i.e. a title bar.
//! - `color` (optional) — fill. Default: a faint neutral that reads on
//!   a panel without demanding attention.
//! - `radius` (optional) — corner radius in pixels, same units as
//!   `:::box`.
//!
//! ## Units, and why the span is an attribute
//!
//! The grip produces a delta in screen pixels. The value it writes is in
//! whatever units the target path holds, and only the HOST knows the
//! conversion. matryoshka maps a panel pin across
//! `width - PANEL_WIDTH - 2*MARGIN` rather than across the window, so a
//! grip that normalised by the window would lag the cursor by the
//! panel's own width, about 15% at 2560 across — the panel slides out
//! from under your finger on a long drag.
//!
//! So the host publishes the number and the document passes it in. Four
//! lines of frontmatter, and spark stays ignorant of panels. The
//! viewport default keeps the attribute optional for the case where the
//! target really is a fraction of the screen.
//!
//! ## The frozen origin
//!
//! `::handle` documents this trap and a move grip meets a worse version
//! of it. The dispatcher latches the Hit at mouse_down (`Spark.captured`)
//! and every later `mouse_move` arrives with `local` measured against
//! that FROZEN box. Recover the cursor by adding the frozen origin back.
//!
//! Add the *current* box instead and the grip's own motion double-counts
//! into the delta. For a resize handle that is a drift; for a grip, the
//! grip moves exactly as far as the thing it is moving, so the feedback
//! is unity-gain and the panel launches off the screen on the first
//! mouse_move.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const box_helpers = @import("box.zig"); // parseLength / Length / parseColor

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("grip", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

/// Faint neutral. A grip is a place to grab rather than a control to
/// read, so it should be findable and quiet.
const GRIP_DEFAULT_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.10 };
const GRIP_DEFAULT_HEIGHT: f32 = 22;
const GRIP_DEFAULT_RADIUS: f32 = 4;

// ── Component state ─────────────────────────────────────────────────

const Component = struct {
    allocator: std.mem.Allocator,
    /// Owned state paths. Empty means "this axis is not driven".
    x_path: []u8,
    y_path: []u8,
    /// Screen pixels per unit of written value. Null falls back to the
    /// surface extent at drag time.
    x_span: ?f32,
    y_span: ?f32,
    min: f32,
    max: f32,
    width: box_helpers.Length,
    height: f32,
    color: [4]f32,
    radius: f32,

    /// Last laid-out box. Written by `on_layout_complete` rather than by
    /// `layoutAndRender`, so it stays correct when a cached ancestor
    /// blits the grip at a new origin without walking it.
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    // ── Drag anchor, frozen at mouse_down ──
    drag_active: bool = false,
    /// The grip's box origin at the moment the drag latched. Read the
    /// module header before replacing this with `last_box`.
    drag_start_origin: [2]f32 = .{ 0, 0 },
    /// Cursor position in world coords at the moment the drag latched.
    drag_start_cursor: [2]f32 = .{ 0, 0 },
    /// The values the two paths held at the moment the drag latched.
    drag_start_value: [2]f32 = .{ 0, 0 },
    /// What this grip last wrote to each path, so an axis that has not
    /// moved is not written.
    ///
    /// Not tidiness. A `state.set` is an authored write that travels the
    /// whole way out through the host's mirror to a knob, and a drag
    /// straight along x would otherwise re-author y sixty times a second
    /// with the value it already has. It also changes what the value
    /// LOOKS like: the grip formats to four places, so an untouched
    /// `0.4` would become `0.4000` for no reason anyone could point at.
    ///
    /// Seeded from `drag_start_value` at mouse_down and compared against
    /// the LAST WRITE rather than against the start, so a drag that
    /// wanders away and comes back writes the return trip.
    last_written: [2]f32 = .{ 0, 0 },

    /// Captured at create. Supplies the surface extent for the default
    /// span.
    spark: ?*spark_mod.Spark = null,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var x_raw: ?[]const u8 = null;
        var y_raw: ?[]const u8 = null;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "x")) {
                x_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "y")) {
                y_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "x_span")) {
                self.x_span = parsePositive(attr.value);
            } else if (std.mem.eql(u8, attr.key, "y_span")) {
                self.y_span = parsePositive(attr.value);
            } else if (std.mem.eql(u8, attr.key, "min")) {
                if (std.fmt.parseFloat(f32, attr.value)) |v| self.min = v else |_| {}
            } else if (std.mem.eql(u8, attr.key, "max")) {
                if (std.fmt.parseFloat(f32, attr.value)) |v| self.max = v else |_| {}
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    self.height = switch (l) {
                        .pixels => |px| px,
                        // A grip's height is a fixed bar rather than a
                        // fraction of anything, so a percent has nothing
                        // to resolve against and keeps the default.
                        .percent, .auto => self.height,
                    };
                }
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| self.color = c;
            } else if (std.mem.eql(u8, attr.key, "radius")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    self.radius = switch (l) {
                        .pixels => |px| px,
                        .percent, .auto => self.radius,
                    };
                }
            }
        }

        // Paths are re-read on every ingest, so `x=${state.which}` is a
        // legal thing to write: a document can re-point a grip at a
        // different pin without remounting.
        if (x_raw) |v| {
            const dup = try a.dupe(u8, v);
            a.free(self.x_path);
            self.x_path = dup;
        }
        if (y_raw) |v| {
            const dup = try a.dupe(u8, v);
            a.free(self.y_path);
            self.y_path = dup;
        }
        self.version +%= 1;
    }
};

/// A span of zero or less would divide the drag by nothing. Reject it
/// here so the fallback (the surface extent) takes over rather than
/// producing an infinity on the first mouse_move.
fn parsePositive(s: []const u8) ?f32 {
    const v = std.fmt.parseFloat(f32, s) catch return null;
    if (!(v > 0) or !std.math.isFinite(v)) return null;
    return v;
}

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .x_path = try allocator.dupe(u8, ""),
        .y_path = try allocator.dupe(u8, ""),
        .x_span = null,
        .y_span = null,
        .min = 0,
        .max = 1,
        .width = .{ .percent = 1.0 },
        .height = GRIP_DEFAULT_HEIGHT,
        .color = GRIP_DEFAULT_COLOR,
        .radius = GRIP_DEFAULT_RADIUS,
        .spark = spark,
    };
    errdefer {
        allocator.free(c.x_path);
        allocator.free(c.y_path);
    }
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.x_path);
    allocator.free(c.y_path);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .on_layout_complete = onLayoutComplete,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

/// Fires on a cache HIT as well as a walk, which is the reason the box
/// is recorded here instead of in `layoutAndRender`. A grip inside a
/// cached block is blitted at the panel's new origin without being
/// walked, and a stale `last_box` would freeze the drag anchor at
/// wherever the panel was when it was last laid out from scratch.
fn onLayoutComplete(ctx: *anyopaque, box: element.Box, lc: *element.LayoutCtx) void {
    _ = lc;
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.last_box = box;
}

// ── Layout + paint ──────────────────────────────────────────────────

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 240;
    const w = c.width.resolve(max_w, fallback_w);

    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, c.height },
        .color = c.color,
        .radius = c.radius,
    });

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = c.height,
        .baseline = 0,
    };
    c.last_box = box;
    return box;
}

// ── Input ───────────────────────────────────────────────────────────

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_raw: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const state: *state_mod.State = @ptrCast(@alignCast(state_raw));

    switch (event) {
        .mouse_down => |m| if (m.button == 0) startDrag(c, state, m.local),
        .mouse_move => |m| if (m.button_down and c.drag_active) try applyDrag(c, state, m.local),
        .mouse_up => |m| {
            if (m.button == 0) c.drag_active = false;
        },
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

/// Latch the anchor: where the grip was, where the cursor was, and what
/// the driven paths held. Every later event is a delta against these
/// three, and none of them is re-read mid-drag.
fn startDrag(c: *Component, state: *const state_mod.State, local: [2]f32) void {
    c.drag_start_origin = .{ c.last_box.x, c.last_box.y };
    c.drag_start_cursor = .{
        c.last_box.x + local[0],
        c.last_box.y + local[1],
    };
    c.drag_start_value = .{
        readPath(state, c.x_path) orelse 0,
        readPath(state, c.y_path) orelse 0,
    };
    c.last_written = c.drag_start_value;
    c.drag_active = true;
}

fn applyDrag(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    // Cursor world reconstruction against the FROZEN origin. See the
    // module header; using `c.last_box` here is the runaway.
    const cursor_now: [2]f32 = .{
        c.drag_start_origin[0] + local[0],
        c.drag_start_origin[1] + local[1],
    };
    const delta: [2]f32 = .{
        cursor_now[0] - c.drag_start_cursor[0],
        cursor_now[1] - c.drag_start_cursor[1],
    };

    if (c.x_path.len > 0) {
        const v = clampToRange(c, c.drag_start_value[0] + delta[0] / spanX(c));
        if (v != c.last_written[0]) {
            try writePath(state, c.x_path, v);
            c.last_written[0] = v;
        }
    }
    if (c.y_path.len > 0) {
        const v = clampToRange(c, c.drag_start_value[1] + delta[1] / spanY(c));
        if (v != c.last_written[1]) {
            try writePath(state, c.y_path, v);
            c.last_written[1] = v;
        }
    }
}

/// Screen pixels per unit of written value, horizontally.
pub fn spanFor(explicit: ?f32, extent_px: u32) f32 {
    if (explicit) |v| return v;
    return @max(1.0, @as(f32, @floatFromInt(extent_px)));
}

fn spanX(c: *const Component) f32 {
    const px: u32 = if (c.spark) |s| s.frame_info.extent.width else 0;
    return spanFor(c.x_span, px);
}

fn spanY(c: *const Component) f32 {
    const px: u32 = if (c.spark) |s| s.frame_info.extent.height else 0;
    return spanFor(c.y_span, px);
}

pub fn clampRange(v: f32, min: f32, max: f32) f32 {
    // An inverted range (max < min) would make `clamp` trip its own
    // assert in debug. Hand back the low end rather than crashing on a
    // document typo.
    if (max < min) return min;
    return std.math.clamp(v, min, max);
}

fn clampToRange(c: *const Component, v: f32) f32 {
    return clampRange(v, c.min, c.max);
}

fn readPath(state: *const state_mod.State, path: []const u8) ?f32 {
    if (path.len == 0) return null;
    const raw = state.get(path) orelse return null;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, raw, " \t")) catch null;
}

fn writePath(state: *state_mod.State, path: []const u8, v: f32) !void {
    // Four places, not the slider's two. A pin is a fraction of the
    // screen, so two decimals is a 1% step: 25px of dead zone on a 2560
    // display, which reads as the panel snapping rather than dragging.
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.4}", .{v}) catch return;
    try state.set(path, s);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

var attr_pool: [8][6]components.Attr = undefined;
var attr_next: usize = 0;

fn specOf(attrs: []const components.Attr) components.Spec {
    const i = attr_next % attr_pool.len;
    attr_next += 1;
    for (attrs, 0..) |a, n| attr_pool[i][n] = a;
    return .{ .name = "grip", .id = null, .attrs = attr_pool[i][0..attrs.len], .body = "" };
}

fn makeGrip(attrs: []const components.Attr) !component_mod.Instance {
    const spec = specOf(attrs);
    return create(&_test_spark, testing.allocator, &spec);
}

test "grip: ingests both paths and the spans" {
    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "y", .value = "py" },
        .{ .key = "x_span", .value = "1000" },
        .{ .key = "y_span", .value = "500" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqualStrings("px", c.x_path);
    try testing.expectEqualStrings("py", c.y_path);
    try testing.expectEqual(@as(?f32, 1000), c.x_span);
    try testing.expectEqual(@as(?f32, 500), c.y_span);
    try testing.expectEqual(@as(f32, 0), c.min);
    try testing.expectEqual(@as(f32, 1), c.max);
}

test "grip: a single axis is legal" {
    const inst = try makeGrip(&.{.{ .key = "y", .value = "py" }});
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("", c.x_path);
    try testing.expectEqualStrings("py", c.y_path);
}

test "grip: a drag writes travel divided by the span" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("px", "0.25");
    try state.set("py", "0.50");

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "y", .value = "py" },
        .{ .key = "x_span", .value = "1000" },
        .{ .key = "y_span", .value = "500" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.last_box = .{ .x = 100, .y = 40, .w = 300, .h = 22 };

    // Press at (150, 50) in world, i.e. (50, 10) local.
    startDrag(c, &state, .{ 50, 10 });
    try testing.expect(c.drag_active);

    // Move 200px right and 50px down. The dispatcher reports local
    // against the FROZEN box, so local goes to (250, 60).
    try applyDrag(c, &state, .{ 250, 60 });

    // 200/1000 = 0.20 on top of 0.25; 50/500 = 0.10 on top of 0.50.
    try testing.expectEqualStrings("0.4500", state.get("px").?);
    try testing.expectEqualStrings("0.6000", state.get("py").?);
}

test "grip: the anchor is frozen, so a moving grip does not amplify" {
    // THE BUG this component's header is about. A grip moves exactly as
    // far as the thing it drags, so if the delta were measured against
    // the CURRENT box the feedback would be unity-gain and the panel
    // would launch off the screen on the first move.
    //
    // The fixture: press, then move 100px while the grip itself has
    // already been laid out 100px further along (which is what happens
    // the frame after the first write lands). The written value must
    // reflect 100px of CURSOR travel, not 200.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("px", "0.0");

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "x_span", .value = "1000" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.last_box = .{ .x = 0, .y = 0, .w = 300, .h = 22 };

    startDrag(c, &state, .{ 0, 0 });

    // The panel moved. `last_box` now says 100, and it must not matter.
    c.last_box = .{ .x = 100, .y = 0, .w = 300, .h = 22 };
    try applyDrag(c, &state, .{ 100, 0 });

    try testing.expectEqualStrings("0.1000", state.get("px").?);
}

test "grip: the written value is clamped to min/max" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("px", "0.9");

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "x_span", .value = "100" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.last_box = .{ .x = 0, .y = 0, .w = 300, .h = 22 };

    startDrag(c, &state, .{ 0, 0 });
    try applyDrag(c, &state, .{ 500, 0 }); // 0.9 + 5.0, way past the end
    try testing.expectEqualStrings("1.0000", state.get("px").?);

    startDrag(c, &state, .{ 0, 0 });
    try applyDrag(c, &state, .{ -500, 0 });
    try testing.expectEqualStrings("0.0000", state.get("px").?);
}

test "grip: mouse_up ends the drag" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("px", "0.5");

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "x_span", .value = "1000" },
    });
    defer deinit_(inst.ctx, testing.allocator);

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 0, 0 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 100, 0 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    const moved = try testing.allocator.dupe(u8, state.get("px").?);
    defer testing.allocator.free(moved);
    try testing.expect(!std.mem.eql(u8, "0.5", moved));

    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 100, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));

    // A move after release must be ignored. Rule 1: the move above
    // really did write, so "nothing changed" here is about the release
    // rather than about the harness never having worked.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 900, 0 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings(moved, state.get("px").?);
}

test "grip: an unset path starts the drag from zero rather than refusing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "nosuch" },
        .{ .key = "x_span", .value = "100" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    startDrag(c, &state, .{ 0, 0 });
    try testing.expectEqual(@as(f32, 0), c.drag_start_value[0]);
    try applyDrag(c, &state, .{ 50, 0 });
    try testing.expectEqualStrings("0.5000", state.get("nosuch").?);
}

test "grip: spanFor falls back to the extent, and refuses a useless span" {
    try testing.expectEqual(@as(f32, 640), spanFor(null, 640));
    try testing.expectEqual(@as(f32, 250), spanFor(250, 640));

    // A zero or negative span divides the drag by nothing. `parsePositive`
    // rejects it at ingest so the extent takes over instead of an
    // infinity reaching `state.set` on the first move.
    try testing.expectEqual(@as(?f32, null), parsePositive("0"));
    try testing.expectEqual(@as(?f32, null), parsePositive("-40"));
    try testing.expectEqual(@as(?f32, null), parsePositive("wide"));
    try testing.expectEqual(@as(?f32, 40), parsePositive("40"));

    // And with no spark attached at all the extent reads zero, which
    // must still not divide by nothing.
    try testing.expectEqual(@as(f32, 1), spanFor(null, 0));
}

test "grip: an inverted range does not trip clamp's assert" {
    try testing.expectEqual(@as(f32, 5), clampRange(9, 5, 1));
    try testing.expectEqual(@as(f32, 3), clampRange(3, 0, 10));
}

test "grip: paths are re-read on update, so a bound path may move" {
    const inst = try makeGrip(&.{.{ .key = "x", .value = "px" }});
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("px", c.x_path);

    const next = specOf(&.{.{ .key = "x", .value = "qx" }});
    try update(inst.ctx, &next);
    try testing.expectEqualStrings("qx", c.x_path);
}

test "grip: vtable records its box through on_layout_complete" {
    // Load-bearing rather than tidy. A grip inside a cached block is
    // blitted at the panel's new origin WITHOUT `layoutAndRender`
    // running, and `layoutAndRenderCached` fires this hook on the hit
    // path for exactly that reason. Recording the box only in the paint
    // path would freeze the drag anchor wherever the panel last missed
    // its cache.
    try testing.expect(vtable.on_layout_complete != null);
    try testing.expect(vtable.on_input != null);

    const inst = try makeGrip(&.{.{ .key = "x", .value = "px" }});
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    var lc: element.LayoutCtx = undefined;
    onLayoutComplete(inst.ctx, .{ .x = 12, .y = 34, .w = 300, .h = 22 }, &lc);
    try testing.expectEqual(@as(f32, 12), c.last_box.x);
    try testing.expectEqual(@as(f32, 34), c.last_box.y);
}

test "grip: an axis that did not move is not written" {
    // A drag straight along x must leave y ALONE. Writing it is not
    // merely redundant: `state.set` is an authored write that travels
    // out through the host's mirror to a knob, and the grip's four-place
    // format would rewrite an untouched `0.4` as `0.4000`.
    //
    // Found by a capture comparison — a dragged panel and a panel moved
    // by writing its pin directly agreed on position and disagreed on
    // the readout under it.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("px", "0.4");
    try state.set("py", "0.4");

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "y", .value = "py" },
        .{ .key = "x_span", .value = "552" },
        .{ .key = "y_span", .value = "492" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.last_box = .{ .x = 244, .y = 220, .w = 360, .h = 28 };

    startDrag(c, &state, .{ 156, 14 });
    try applyDrag(c, &state, .{ 356, 14 }); // +200 in x, nothing in y

    // Rule 1: x really did move, so "y is untouched" is about the gate
    // and not about the drag having done nothing at all.
    try testing.expectEqualStrings("0.7623", state.get("px").?);
    try testing.expectEqualStrings("0.4", state.get("py").?);
}

test "grip: a return trip is written, because the gate is on the last WRITE" {
    // Comparing against the drag's START value instead would leave the
    // furthest-out value stuck in place when the cursor came home.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("px", "0.5");

    const inst = try makeGrip(&.{
        .{ .key = "x", .value = "px" },
        .{ .key = "x_span", .value = "1000" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.last_box = .{ .x = 0, .y = 0, .w = 300, .h = 22 };

    startDrag(c, &state, .{ 0, 0 });
    try applyDrag(c, &state, .{ 100, 0 });
    try testing.expectEqualStrings("0.6000", state.get("px").?);

    // All the way back to where it started.
    try applyDrag(c, &state, .{ 0, 0 });
    try testing.expectEqualStrings("0.5000", state.get("px").?);
}
