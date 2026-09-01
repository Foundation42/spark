//! `:::curve` — a piecewise-linear curve over normalised x, with its knots
//! as pucks you drag. spindrift's kernels say
//!
//!     row.age | over row.life [1.0, 0.7, 0.0] | write row.size
//!
//! — a value over normalised life, linear between evenly spaced knots —
//! and the Spray applet wants to edit that array by hand rather than by
//! retyping it. This is the span it does that with. spindrift is the first
//! paying customer; it lands as a reusable span the way `:::trackball` did.
//!
//! Attribute grammar:
//!
//!     :::curve {target=size_curve value=${state.size_curve}
//!               min=0 max=2 label="size" knots=3 width=240 height=96}
//!     :::
//!
//! - `target` — the state path the curve WRITES. A bare path, same as
//!   `:::slider {target=}` and `:::trackball {r=}`. Omit it and the curve
//!   is a read-only picture of `value`.
//! - `value` — the reactive input: the array, as text. Bind it to the same
//!   path (`${state.size_curve}`) and the widget is a mirror — an external
//!   write moves the pucks, a drag writes the array back. See "The array
//!   on the wire" for the spelling.
//! - `min` / `max` — the y range. Defaults 0..1.
//! - `label` — a caption above the plot. Optional.
//! - `knots` — how many knots to start with when `value` is ABSENT (the
//!   path is unset, so the `${}` never resolved). Default 3, all at `max`.
//!   Ignored once an array has arrived: the plane decides the count, and a
//!   knot-count change is not a gesture this widget has.
//! - `width` — pixel literal or `100%`. Default `100%`.
//! - `height` — the plot's height in pixels. Default 96.
//! - `color` — the curve and its fill. Named or hex, like `:::box {color=}`.
//!
//! ## Why `target=` and not the path inside `value=`
//!
//! The registry hands a component SUBSTITUTED attributes. The template
//! `${state.size_curve}` lives in the Binding and nowhere the factory can
//! see: at create it has already been replaced by the array, and on every
//! reactive fire it is replaced again. The only time the literal reaches
//! `ingest` is when the path is unset, and an attribute that is sometimes
//! a value and sometimes its own name is not a contract. So the write path
//! is its own attribute, which is what every writing widget here does.
//!
//! ## The array on the wire
//!
//! `State` is text. The array is a comma-separated list of numbers, and
//! the brackets a rill literal wears — `[1.0, 0.7, 0.0]` — are optional on
//! the way in and written on the way out, so a value pasted from a kernel
//! and a value this widget authored are the same spelling. Whitespace is
//! tolerated; a token that is not a number is dropped, as `::sparkline`
//! already does; fewer than two numbers is not a curve and is ignored.
//! `parseArray` and `formatArray` are public so the sparkline and a host
//! bridge parse and print the same thing.
//!
//! ## ONE write per gesture segment, because `State.set` re-enters
//!
//! `state.set` notifies subscribers synchronously, and a curve bound to
//! the path it writes is its own subscriber. `:::trackball` writes three
//! paths in a loop, and the ingest fired by the FIRST write freed a path
//! the second was about to hash — a segfault, from a gesture — and re-read
//! a `(new_r, old_g, old_b)` triple that never existed, which made its puck
//! jump. N knots written as N scalar paths would meet both, N times over,
//! and a subscriber watching knot 2 would see the array mid-change.
//!
//! An array is one path, so a drag is ONE `state.set` carrying the whole
//! array: nothing is partially written when the echo arrives, and there is
//! no loop for a freed key to be reused in. What remains is the same two
//! guards the trackball keeps: `target` is not reallocated unless it
//! changed and never while a knot is grabbed, and `value` is ignored while
//! a knot is grabbed. Between gestures the plane is the truth; during one,
//! the widget is.
//!
//! ## Why the drag is relative
//!
//! A press latches the nearest knot COLUMN and the value it held; a move
//! adds the cursor's vertical travel to that value. Absolute — knot to the
//! cursor on press, like the slider's thumb — would nudge a knot by
//! however far the press missed the puck, and a puck is ten pixels wide.
//! Relative means the press itself writes nothing and the first move
//! writes exactly the travel, which is also what makes "one write per
//! segment" a countable thing.
//!
//! ## Mutation tried
//!
//! Dropped the `gesture` guard on the `value` ingest — let the echo of our
//! own write, and any stale array, straight into `knots` mid-drag. Two
//! gates bit: "a re-entrant echo mid-drag frees nothing and moves nothing
//! else" (the echo's `0.5, 0.5, 0.5` replaced the two knots the cursor
//! never touched) and "between gestures the plane is the truth" (its
//! Rule-1 half, which checks the mid-drag hold before the release). The
//! single-write gate did NOT bite, which is right — the mutation changes
//! what the widget believes, not how often it writes — and is why the two
//! gates are separate.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
const relief = @import("relief.zig");

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("curve", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Visual constants ────────────────────────────────────────────────

const DEFAULT_HEIGHT: f32 = 96;
const DEFAULT_KNOTS: usize = 3;
/// The plot is inset from the component's edges by this, so the end
/// pucks sit inside the recess instead of hanging off its lip.
const PAD_X: f32 = 8;
/// The recess, as a NEUTRAL darkening — `:::slider`'s reasoning: black
/// with alpha darkens the panel's own tint instead of replacing it.
const PLOT_BG_COLOR: [4]f32 = .{ 0.0, 0.0, 0.0, 0.32 };
/// Quarter-height rulings across the plot, and one hairline down each
/// knot column. The columns are the affordance: the x positions are
/// fixed, and a faint line where each puck lives says so.
const RULE_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.09 };
const COLUMN_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.14 };
const RULES: usize = 4;
/// The curve, and the fill under it. Slider blue, so a panel of sliders
/// and a curve read as one family.
const CURVE_COLOR: [4]f32 = .{ 0.45, 0.72, 1.0, 1.0 };
const CURVE_WIDTH: f32 = 2.0;
/// The area under the curve fades from this alpha at the line to nothing
/// at the floor. It is what makes the picture read as "this much of the
/// range, over life" rather than as a wire.
const AREA_ALPHA: f32 = 0.26;
const PUCK_R: f32 = 5.0;
const PUCK_COLOR: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
/// A ring in the curve's colour around the puck being dragged, so the
/// grab has feedback even when the value is pinned at a limit.
const PUCK_RING_PAD: f32 = 2.0;
/// Segments in a puck's fan. It is ten pixels across; coarse is invisible.
const PUCK_SEGMENTS: usize = 24;
const LABEL_COLOR: [4]f32 = .{ 0.92, 0.93, 0.97, 1.0 };
const LABEL_GAP: f32 = 4.0;
/// How far outside the plot a press still counts as a grab. The pucks at
/// `min` and `max` sit ON the plot's edge, and a press that misses one by
/// three pixels should not fall through to nothing.
const GRAB_SLOP: f32 = PUCK_R + 4.0;

// ── Component ───────────────────────────────────────────────────────

const Component = struct {
    allocator: std.mem.Allocator,
    /// Owned state path this curve writes. Empty means read-only.
    target: []u8,
    label: []u8,
    /// The knots, left to right, evenly spaced over x in [0, 1]. Owned.
    /// Stored as the plane sent them — an out-of-range knot is drawn
    /// pinned to the plot's edge but NOT rewritten, so a drag on one knot
    /// changes one knot and nothing else.
    knots: []f32,
    /// Knot count to seed when no array has arrived. Only read while
    /// `knots` is still empty.
    default_knots: usize = DEFAULT_KNOTS,
    min: f32 = 0,
    max: f32 = 1,
    width: box_helpers.Length = .{ .percent = 1.0 },
    height: f32 = DEFAULT_HEIGHT,
    color: [4]f32 = CURVE_COLOR,

    // ── Geometry, recorded at layout ──
    //
    // LOCAL to the component's own box, like `:::trackball`'s, so a
    // cached ancestor blitting the widget at a new origin cannot make
    // them stale. `plot_w` depends on the constraints, which only change
    // on a re-walk, never in the middle of a drag.
    plot_top: f32 = 0,
    plot_h: f32 = DEFAULT_HEIGHT,
    plot_x: f32 = PAD_X,
    plot_w: f32 = 0,

    // ── Drag anchor, latched at mouse_down ──
    /// The knot a gesture grabbed. Non-null IS "a gesture is live", and
    /// it is the zone `ingest` tests before it lets a path swap or a
    /// value in.
    grabbed: ?usize = null,
    press_local: [2]f32 = .{ 0, 0 },
    press_value: f32 = 0,
    /// What the gesture last wrote for the grabbed knot. A move that lands
    /// on the same value — pinned at a limit, or a horizontal wobble — is
    /// not re-authored; `::grip` says why an authored write is not free.
    last_written: f32 = 0,

    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var target_raw: ?[]const u8 = null;
        var value_raw: ?[]const u8 = null;
        var min: ?f32 = null;
        var max: ?f32 = null;

        for (spec.attrs) |attr| {
            const k = attr.key;
            if (std.mem.eql(u8, k, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, k, "value")) {
                value_raw = attr.value;
            } else if (std.mem.eql(u8, k, "min")) {
                min = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "max")) {
                max = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "knots")) {
                if (std.fmt.parseInt(usize, std.mem.trim(u8, attr.value, " \t"), 10)) |n| {
                    // One knot is a constant, not a curve; the default
                    // stands rather than seeding something undraggable.
                    if (n >= 2) self.default_knots = n;
                } else |_| {}
            } else if (std.mem.eql(u8, k, "label")) {
                if (!std.mem.eql(u8, self.label, attr.value)) {
                    const dup = try a.dupe(u8, attr.value);
                    a.free(self.label);
                    self.label = dup;
                }
            } else if (std.mem.eql(u8, k, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, k, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    self.height = switch (l) {
                        .pixels => |px| if (px > 8) px else self.height,
                        .percent, .auto => self.height,
                    };
                }
            } else if (std.mem.eql(u8, k, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| self.color = c;
            }
        }

        // ── The bound path, and the re-entrancy that made this a crash ──
        //
        // `state.set(self.target, …)` holds `target` as its hash key while
        // it notifies us, and a `value=${state.size_curve}` binding makes
        // this ingest one of the notified. Freeing `target` here would be
        // the trackball's segfault. Two guards, both wanted: a path that
        // has not CHANGED is never reallocated, and no path is swapped
        // while a knot is grabbed — every route into `writeArray` runs
        // from `onInput` with `grabbed` set, so that is exactly the
        // unsafe window.
        const gesture = self.grabbed != null;
        if (!gesture) {
            if (target_raw) |t| {
                if (!std.mem.eql(u8, self.target, t)) {
                    const dup = try a.dupe(u8, t);
                    a.free(self.target);
                    self.target = dup;
                }
            }
        }

        // Range first — the default knots are seeded at `max`, so reading
        // it after them would seed against the range the document had
        // LAST time.
        if (min) |v| self.min = v;
        if (max) |v| self.max = v;

        // ── During a gesture the WIDGET is the authority ──
        //
        // The value arriving here mid-drag is our own write coming back
        // through the binding — or, through a host's mirror, a frame late.
        // Letting it in would put the grabbed puck where the cursor WAS
        // and the next move would put it back: the trackball's jumping
        // bug. Between gestures the plane is the truth; during one, we are.
        if (!gesture) {
            if (value_raw) |raw| {
                const parsed = try parseArray(a, raw);
                if (parsed.len >= 2) {
                    if (parsed.len == self.knots.len) {
                        // Same count: copy in place. The slice the paint
                        // path and a live `writeArray` hold stays valid,
                        // and a plane republishing sixty times a second
                        // does not churn the heap to arrive at the same
                        // three numbers.
                        @memcpy(self.knots, parsed);
                        a.free(parsed);
                    } else {
                        a.free(self.knots);
                        self.knots = parsed;
                    }
                } else {
                    // Absent (`${…}` unresolved, or empty) or not a curve.
                    // Keep what we have; the seed below covers "nothing
                    // yet".
                    a.free(parsed);
                }
            }
        }

        // Absent value ⇒ `knots=` default, all at `max`. A curve with no
        // array yet still has to be a thing you can drag, and "everything
        // at full" is what an `over` with no knots means in a kernel.
        if (self.knots.len < 2) {
            const seeded = try a.alloc(f32, self.default_knots);
            @memset(seeded, self.max);
            a.free(self.knots);
            self.knots = seeded;
        }

        self.version +%= 1;
    }

    /// Push the whole array out to state as ONE write.
    ///
    /// Not N writes of N scalar paths. `state.set` re-enters this
    /// component synchronously through its own binding, and a loop of
    /// sets is a loop in which the re-entered ingest can free the key the
    /// next iteration hashes (the trackball's segfault) and in which a
    /// subscriber sees the array half-written (the trackball's jump). One
    /// path, one write: the array is whole at every point a subscriber
    /// can observe it.
    fn writeArray(self: *Component, state: *state_mod.State) !void {
        if (self.target.len == 0) return;
        // Formatted into our own buffer BEFORE the set, so `knots` is not
        // borrowed across the re-entry.
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try formatArray(buf.writer(), self.knots);
        try state.set(self.target, buf.items);
    }
};

// ── The array on the wire ───────────────────────────────────────────

/// Parse `"[1.0, 0.7, 0.0]"` or `"1.0, 0.7, 0.0"` into `[1.0, 0.7, 0.0]`.
///
/// Brackets are stripped from the ends if present — a rill literal wears
/// them, a bare list does not, and both are the same array. Tokens that
/// are not numbers drop silently: an unresolved `${state.x}` comes through
/// here as one such token and parses to nothing, which is how "absent" is
/// detected. Caller owns the result.
pub fn parseArray(allocator: std.mem.Allocator, raw: []const u8) ![]f32 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') s = s[1 .. s.len - 1];

    var out = std.ArrayList(f32).init(allocator);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t\r\n");
        if (t.len == 0) continue;
        const v = std.fmt.parseFloat(f32, t) catch continue;
        if (!std.math.isFinite(v)) continue;
        try out.append(v);
    }
    return try out.toOwnedSlice();
}

/// The inverse: `[1.0000, 0.7000, 0.0000]`. Four places, like `::grip` and
/// `:::trackball` and unlike `:::slider`'s two — a size over life runs
/// 0..2 and two decimals is a step you can see the puck take.
pub fn formatArray(w: anytype, values: []const f32) !void {
    try w.writeAll("[");
    for (values, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{d:.4}", .{v});
    }
    try w.writeAll("]");
}

fn parseF32(s: []const u8) ?f32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t\r\n")) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// `std.math.clamp` asserts `min <= max` in debug. A document typo must
/// hand back the low end rather than crash — `::grip`'s rule.
fn clampRange(v: f32, min: f32, max: f32) f32 {
    if (max < min) return min;
    return std.math.clamp(v, min, max);
}

// ── Factory ─────────────────────────────────────────────────────────

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .target = try allocator.dupe(u8, ""),
        .label = &.{},
        .knots = &.{},
    };
    errdefer allocator.free(c.target);
    c.label = try allocator.dupe(u8, "");
    errdefer allocator.free(c.label);
    c.knots = try allocator.alloc(f32, 0);
    errdefer allocator.free(c.knots);

    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.target);
    allocator.free(c.label);
    allocator.free(c.knots);
    allocator.destroy(c);
}

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
};

// ── Geometry ────────────────────────────────────────────────────────

/// Where knot `i` sits, in the component's local frame.
fn knotPos(c: *const Component, i: usize) [2]f32 {
    const n = c.knots.len;
    const fi: f32 = @floatFromInt(i);
    const step = if (n > 1) c.plot_w / @as(f32, @floatFromInt(n - 1)) else 0;
    return .{ c.plot_x + fi * step, c.plot_top + c.plot_h * (1.0 - normalised(c, c.knots[i])) };
}

fn normalised(c: *const Component, v: f32) f32 {
    if (c.max == c.min) return 0;
    return std.math.clamp((v - c.min) / (c.max - c.min), 0.0, 1.0);
}

/// Which knot a press at `local` grabs, if any. The nearest COLUMN wins
/// — not the nearest puck — so a press anywhere in the plot's band at a
/// knot's x picks that knot however far up or down its puck is.
pub fn zoneAt(c: *const Component, local: [2]f32) ?usize {
    const n = c.knots.len;
    if (n < 2 or !(c.plot_w > 0)) return null;
    if (local[1] < c.plot_top - GRAB_SLOP or local[1] > c.plot_top + c.plot_h + GRAB_SLOP) return null;
    if (local[0] < c.plot_x - GRAB_SLOP or local[0] > c.plot_x + c.plot_w + GRAB_SLOP) return null;
    const step = c.plot_w / @as(f32, @floatFromInt(n - 1));
    const raw = @round((local[0] - c.plot_x) / step);
    const idx: usize = @intFromFloat(std.math.clamp(raw, 0, @as(f32, @floatFromInt(n - 1))));
    return idx;
}

// ── Paint ───────────────────────────────────────────────────────────

/// The fill under one segment: a quad with the curve's colour along its
/// top edge fading to nothing at the floor. Split into two triangles by
/// hand because it is not a rectangle — its top edge slopes.
fn areaSegment(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    p0: [2]f32,
    p1: [2]f32,
    floor: f32,
    top: [4]f32,
) !void {
    const clear: [4]f32 = .{ top[0], top[1], top[2], 0.0 };
    const base: u32 = @intCast(out.tris.items.len);
    try out.ensureUnusedTriCapacity(4);
    out.appendTriAssumeCapacity(lc, .{ .pos = p0, .color = top });
    out.appendTriAssumeCapacity(lc, .{ .pos = p1, .color = top });
    out.appendTriAssumeCapacity(lc, .{ .pos = .{ p1[0], floor }, .color = clear });
    out.appendTriAssumeCapacity(lc, .{ .pos = .{ p0[0], floor }, .color = clear });
    try out.tri_indices.ensureUnusedCapacity(6);
    for ([_]u32{ 0, 1, 2, 0, 2, 3 }) |o| out.tri_indices.appendAssumeCapacity(base + o);
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
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 240;
    const w = @max(c.width.resolve(max_w, fallback_w), PAD_X * 2 + 16);

    var y = origin[1];
    var baseline = y;
    if (c.label.len > 0) {
        var arena = std.heap.ArenaAllocator.init(lc.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = lc.theme.body;
        const label_m = lc.fonts.metrics(body.font_id);
        const hb = lc.fonts.hbFont(body.font_id);
        const run = try shape.shapeUtf8(aa, hb, c.label);
        baseline = y + label_m.ascender;
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
            &out.glyph_targets,
            lc.current_target_dispatch_index,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            run,
            body.font_id,
            origin[0],
            baseline,
            LABEL_COLOR,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
        y += label_m.line_height + LABEL_GAP;
    }

    // ── The plot, all in the TRIANGLE layer ──
    //
    // The renderer draws the whole triangle layer beneath the whole quad
    // layer, so a shaded recess with things down inside it has to be
    // triangles top to bottom or the lip's shadow ends up under the fill
    // it should be falling on. Order here IS the stacking: recess fill,
    // rulings, area, curve, the cut-out's shadow, and the pucks riding on
    // top of all of it.
    const plot_top = y;
    const plot_h = c.height;
    const plot_x = origin[0] + PAD_X;
    const plot_w = w - 2 * PAD_X;
    const floor = plot_top + plot_h;

    // Local geometry first — `knotPos` reads it.
    c.plot_top = plot_top - origin[1];
    c.plot_h = plot_h;
    c.plot_x = PAD_X;
    c.plot_w = plot_w;

    try relief.rect(out, lc, origin[0], plot_top, w, plot_h, PLOT_BG_COLOR);

    // Quarter rulings, inset from the lips so they sink into the recess
    // rather than touching its walls.
    var r: usize = 1;
    while (r < RULES) : (r += 1) {
        const ry = plot_top + plot_h * @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(RULES));
        try relief.stroke(out, lc, .{ plot_x, ry }, .{ plot_x + plot_w, ry }, 1.0, RULE_COLOR);
    }
    // One hairline per knot column — the fixed x positions, made visible.
    const n = c.knots.len;
    for (0..n) |i| {
        const p = knotPos(c, i);
        try relief.hairlineV(out, lc, origin[0] + p[0], plot_top + 2, plot_h - 4, 1.0, COLUMN_COLOR);
    }

    // Area under the curve, then the curve. Segments overlap at the knots
    // by nothing — the pucks cover the joints, which is what pucks are for.
    const area_top: [4]f32 = .{ c.color[0], c.color[1], c.color[2], c.color[3] * AREA_ALPHA };
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const p0 = knotPos(c, i);
        const p1 = knotPos(c, i + 1);
        const a: [2]f32 = .{ origin[0] + p0[0], origin[1] + p0[1] };
        const b: [2]f32 = .{ origin[0] + p1[0], origin[1] + p1[1] };
        try areaSegment(out, lc, a, b, floor, area_top);
    }
    i = 0;
    while (i + 1 < n) : (i += 1) {
        const p0 = knotPos(c, i);
        const p1 = knotPos(c, i + 1);
        try relief.stroke(
            out,
            lc,
            .{ origin[0] + p0[0], origin[1] + p0[1] },
            .{ origin[0] + p1[0], origin[1] + p1[1] },
            CURVE_WIDTH,
            c.color,
        );
    }

    // The cut-out, so the lip's shadow falls across everything down inside
    // it. `ends = false`, like `:::slider`: one light from above means the
    // top lip is the one that occludes.
    try relief.groove(out, lc, origin[0], plot_top, w, plot_h, false);

    // Pucks last. The grabbed one wears a ring in the curve's colour.
    for (0..n) |k| {
        const p = knotPos(c, k);
        const centre: [2]f32 = .{ origin[0] + p[0], origin[1] + p[1] };
        if (c.grabbed == k) {
            try relief.disc(out, lc, centre, PUCK_R + PUCK_RING_PAD, c.color, PUCK_SEGMENTS);
        }
        try relief.disc(out, lc, centre, PUCK_R, PUCK_COLOR, PUCK_SEGMENTS);
    }

    y = floor;

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = y - origin[1],
        .baseline = baseline,
    };
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
        .mouse_down => |m| {
            if (m.button != 0) return;
            // Latch. Nothing is written on a press — see "Why the drag is
            // relative" — so the first `state.set` of a gesture is the
            // first move, with `grabbed` already set for `ingest` to test.
            if (zoneAt(c, m.local)) |i| {
                c.grabbed = i;
                c.press_local = m.local;
                c.press_value = c.knots[i];
                c.last_written = c.knots[i];
                c.version +%= 1;
            }
        },
        .mouse_move => |m| {
            if (!m.button_down) return;
            if (c.grabbed != null) try dragKnot(c, state, m.local);
        },
        .mouse_up => |m| {
            if (m.button == 0 and c.grabbed != null) {
                c.grabbed = null;
                c.version +%= 1;
            }
        },
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

fn dragKnot(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    const i = c.grabbed orelse return;
    if (i >= c.knots.len or !(c.plot_h > 1)) return;
    // `local` is measured against the box frozen at mouse_down, so this
    // difference is pure cursor travel even if the panel under the curve
    // was dragged mid-gesture — `:::trackball`'s reasoning. Up is positive.
    const travel = c.press_local[1] - local[1];
    const span = c.max - c.min;
    const v = clampRange(c.press_value + travel / c.plot_h * span, c.min, c.max);
    c.knots[i] = v;
    c.version +%= 1;
    if (v != c.last_written) {
        try c.writeArray(state);
        c.last_written = v;
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

var attr_pool: [8][12]components.Attr = undefined;
var attr_next: usize = 0;

fn specOf(attrs: []const components.Attr) components.Spec {
    const i = attr_next % attr_pool.len;
    attr_next += 1;
    for (attrs, 0..) |a, n| attr_pool[i][n] = a;
    return .{ .name = "curve", .id = null, .attrs = attr_pool[i][0..attrs.len], .body = "" };
}

fn makeCurve(attrs: []const components.Attr) !component_mod.Instance {
    const spec = specOf(attrs);
    return create(&_test_spark, testing.allocator, &spec);
}

/// A size-over-life curve with a geometry a test can aim at: the plot is
/// 200 wide and 100 tall at the local origin, so knot `i` of three sits
/// at x = 100·i and a value `v` on a 0..1 range sits at y = 100·(1 − v).
fn sizeCurve() !component_mod.Instance {
    const inst = try makeCurve(&.{
        .{ .key = "target", .value = "size_curve" },
        .{ .key = "value", .value = "1.0, 0.7, 0.0" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "1" },
    });
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.plot_top = 0;
    c.plot_h = 100;
    c.plot_x = 0;
    c.plot_w = 200;
    return inst;
}

fn down(inst: component_mod.Instance, state: *state_mod.State, x: f32, y: f32) !void {
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ x, y }, .button = 0, .button_down = true } }, @ptrCast(state));
}

fn move(inst: component_mod.Instance, state: *state_mod.State, x: f32, y: f32) !void {
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ x, y }, .button = 0, .button_down = true } }, @ptrCast(state));
}

fn up(inst: component_mod.Instance, state: *state_mod.State, x: f32, y: f32) !void {
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ x, y }, .button = 0, .button_down = false } }, @ptrCast(state));
}

test "curve: parseArray takes a rill literal, a bare list, and nothing else" {
    const a = testing.allocator;

    const lit = try parseArray(a, "[1.0, 0.7, 0.0]");
    defer a.free(lit);
    try testing.expectEqual(@as(usize, 3), lit.len);
    try testing.expectApproxEqAbs(@as(f32, 0.7), lit[1], 1e-6);

    const bare = try parseArray(a, "1,0.7,0");
    defer a.free(bare);
    try testing.expectEqualSlices(f32, lit, bare);

    // An unresolved binding arrives as its own template. It is one
    // non-numeric token, and it must parse to NOTHING — that is how the
    // component tells "absent" from "an array".
    const unresolved = try parseArray(a, "${state.size_curve}");
    defer a.free(unresolved);
    try testing.expectEqual(@as(usize, 0), unresolved.len);

    const empty = try parseArray(a, "");
    defer a.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "curve: formatArray round-trips through parseArray" {
    const a = testing.allocator;
    const src = [_]f32{ 2.0, 1.25, 0.5, 0.0 };
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try formatArray(buf.writer(), &src);
    try testing.expectEqualStrings("[2.0000, 1.2500, 0.5000, 0.0000]", buf.items);

    const back = try parseArray(a, buf.items);
    defer a.free(back);
    try testing.expectEqualSlices(f32, &src, back);
}

test "curve: an ingested array of N draws N knots" {
    // The array round-trip, ingest half: what the plane publishes is
    // what the pucks show, however many there are.
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqual(@as(usize, 3), c.knots.len);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.knots[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), c.knots[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), c.knots[2], 1e-6);
    try testing.expectEqualStrings("size_curve", c.target);

    // Five arrive, five are drawn — the count is the plane's to decide.
    const five = specOf(&.{.{ .key = "value", .value = "[0.1, 0.2, 0.3, 0.4, 0.5]" }});
    try update(inst.ctx, &five);
    try testing.expectEqual(@as(usize, 5), c.knots.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.knots[4], 1e-6);
    // And their x positions are evenly spaced over the plot.
    try testing.expectApproxEqAbs(@as(f32, 50), knotPos(c, 1)[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200), knotPos(c, 4)[0], 1e-4);
}

test "curve: an absent value seeds `knots=` at max" {
    // Rendered before the plane has published anything, `value=` is the
    // unresolved template. That is not "zero knots" — it is the
    // document's `knots=` count, all at `max`, so there is something to
    // drag and the first drag writes an array of the right shape.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const inst = try makeCurve(&.{
        .{ .key = "target", .value = "size_curve" },
        .{ .key = "value", .value = "${state.size_curve}" },
        .{ .key = "knots", .value = "4" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "2" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqual(@as(usize, 4), c.knots.len);
    for (c.knots) |v| try testing.expectApproxEqAbs(@as(f32, 2), v, 1e-6);

    // And the default count is what the FIRST write carries.
    c.plot_top = 0;
    c.plot_h = 100;
    c.plot_x = 0;
    c.plot_w = 300;
    try down(inst, &state, 200, 0); // knot 2 of 4, at the top
    try move(inst, &state, 200, 50); // half the plot down = −1.0 on a 0..2 range
    try testing.expectEqualStrings("[2.0000, 2.0000, 1.0000, 2.0000]", state.get("size_curve").?);
}

test "curve: `knots=` under two, or a one-number array, is not a curve" {
    const inst = try makeCurve(&.{
        .{ .key = "knots", .value = "1" },
        .{ .key = "value", .value = "0.5" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(DEFAULT_KNOTS, c.knots.len);
}

test "curve: a drag writes the same N with only the dragged knot changed, clamped" {
    // The array round-trip, write half — and the reason the knots are
    // stored as the plane sent them rather than clamped on the way in:
    // a drag on knot 1 must change knot 1 and leave 0 and 2 spelled as
    // they were.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Knot 1 holds 0.7, so its puck is at (100, 30). Press on it and drag
    // 20px down: −0.2 on a 0..1 range.
    try down(inst, &state, 100, 30);
    try testing.expectEqual(@as(?usize, 1), c.grabbed);
    try testing.expect(state.get("size_curve") == null); // a press writes nothing
    try move(inst, &state, 100, 50);
    try testing.expectEqualStrings("[1.0000, 0.5000, 0.0000]", state.get("size_curve").?);

    // Keep going past the floor: clamped to `min`, and still three.
    try move(inst, &state, 100, 400);
    try testing.expectEqualStrings("[1.0000, 0.0000, 0.0000]", state.get("size_curve").?);
    try up(inst, &state, 100, 400);

    // The other way, past the ceiling, on knot 2 — clamped to `max`.
    try down(inst, &state, 200, 100);
    try move(inst, &state, 200, -900);
    try testing.expectEqualStrings("[1.0000, 0.0000, 1.0000]", state.get("size_curve").?);
}

const Counter = struct {
    fired: usize = 0,
    fn onSet(ctx: *anyopaque) anyerror!void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.fired += 1;
    }
};

test "curve: a gesture segment is exactly ONE state write" {
    // The single-write rule. Three knots is three scalar paths' worth of
    // temptation, and three `state.set`s from one move is how the
    // trackball segfaulted. Count the sets.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);

    var counter = Counter{};
    _ = try state.subscribe("size_curve", Counter.onSet, @ptrCast(&counter));

    try down(inst, &state, 100, 30);
    try testing.expectEqual(@as(usize, 0), counter.fired);
    try move(inst, &state, 100, 50);
    try testing.expectEqual(@as(usize, 1), counter.fired);
    // Rule 1: that one write carried the whole array, not one knot.
    try testing.expectEqualStrings("[1.0000, 0.5000, 0.0000]", state.get("size_curve").?);

    // A move that lands on the same value is not re-authored.
    try move(inst, &state, 140, 50);
    try testing.expectEqual(@as(usize, 1), counter.fired);
    // And a move that changes it is one more, not three more.
    try move(inst, &state, 100, 60);
    try testing.expectEqual(@as(usize, 2), counter.fired);
}

/// A subscriber that re-enters `update` on the instance that is writing —
/// what `value=${state.size_curve}` sets up in a real document — and does
/// so with a STALE array and a re-pointed target, which is the worst a
/// host's mirror can hand back.
const ReentrantEcho = struct {
    inst: component_mod.Instance,
    fired: usize = 0,

    fn onSet(ctx: *anyopaque) anyerror!void {
        const self: *ReentrantEcho = @ptrCast(@alignCast(ctx));
        self.fired += 1;
        const echo = specOf(&.{
            .{ .key = "target", .value = "other_curve" },
            .{ .key = "value", .value = "[0.5, 0.5, 0.5]" },
        });
        try update(self.inst.ctx, &echo);
    }
};

test "curve: a re-entrant echo mid-drag frees nothing and moves nothing else" {
    // **The trackball's segfault, and its jump, in one fixture.**
    // `state.set` is holding `target` as its hash key while this echo
    // runs; an ingest that freed it would be the crash, and one that took
    // the stale array would move the two knots the cursor never touched.
    // Under the testing allocator a use-after-free is a detected leak or
    // a corrupted read, and either fails the test.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    var echo = ReentrantEcho{ .inst = inst };
    _ = try state.subscribe("size_curve", ReentrantEcho.onSet, @ptrCast(&echo));

    try down(inst, &state, 100, 30);
    try move(inst, &state, 100, 50);

    // Rule 1: the echo really fired, or this proves nothing.
    try testing.expect(echo.fired >= 1);
    // The target survived and still says what the document said.
    try testing.expectEqualStrings("size_curve", c.target);
    // The dragged knot is where the cursor put it; the other two are
    // where the plane left them, not where the echo said.
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.knots[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.knots[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), c.knots[2], 1e-6);
    try testing.expectEqualStrings("[1.0000, 0.5000, 0.0000]", state.get("size_curve").?);
}

test "curve: between gestures the plane is the truth" {
    // The other half of the guard — Rule 1 for the echo gate above. A
    // widget that ignored EVERY external write would pass that gate for
    // the wrong reason, so: held mid-drag, taken after release.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try down(inst, &state, 100, 30);
    try move(inst, &state, 100, 50);
    const stale = specOf(&.{
        .{ .key = "target", .value = "other_curve" },
        .{ .key = "value", .value = "[0.2, 0.2, 0.2]" },
    });
    try update(inst.ctx, &stale);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.knots[1], 1e-6); // held
    try testing.expectEqualStrings("size_curve", c.target); // held

    try up(inst, &state, 100, 50);
    try update(inst.ctx, &stale);
    try testing.expectApproxEqAbs(@as(f32, 0.2), c.knots[1], 1e-6); // taken
    try testing.expectEqualStrings("other_curve", c.target); // and re-pointed
}

test "curve: an unchanged count is copied in place, not reallocated" {
    // A plane republishing sixty times a second must not churn the heap
    // to arrive at three numbers, and the slice a live paint holds must
    // stay valid. Rule 1: a DIFFERENT count still swaps the slice.
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    const before = c.knots.ptr;

    const same_n = specOf(&.{.{ .key = "value", .value = "0.2, 0.3, 0.4" }});
    try update(inst.ctx, &same_n);
    try testing.expectEqual(before, c.knots.ptr);
    try testing.expectApproxEqAbs(@as(f32, 0.3), c.knots[1], 1e-6);

    const more = specOf(&.{.{ .key = "value", .value = "0.2, 0.3, 0.4, 0.5" }});
    try update(inst.ctx, &more);
    try testing.expectEqual(@as(usize, 4), c.knots.len);
}

test "curve: the column picks the knot, and the label picks nothing" {
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqual(@as(?usize, 0), zoneAt(c, .{ 0, 50 }));
    try testing.expectEqual(@as(?usize, 0), zoneAt(c, .{ 40, 90 })); // nearer 0 than 100
    try testing.expectEqual(@as(?usize, 1), zoneAt(c, .{ 60, 10 }));
    try testing.expectEqual(@as(?usize, 2), zoneAt(c, .{ 200, 100 }));
    // A puck ON the plot's edge is still grabbable a few pixels outside.
    try testing.expectEqual(@as(?usize, 2), zoneAt(c, .{ 204, 104 }));
    // The label band above, and the void below, grab nothing.
    try testing.expectEqual(@as(?usize, null), zoneAt(c, .{ 100, -30 }));
    try testing.expectEqual(@as(?usize, null), zoneAt(c, .{ 100, 140 }));
}

test "curve: a press outside every knot starts no gesture" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try down(inst, &state, 100, -30); // the label
    try testing.expectEqual(@as(?usize, null), c.grabbed);
    try move(inst, &state, 100, 50);
    try testing.expect(state.get("size_curve") == null);
}

test "curve: a read-only curve draws and writes nothing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try makeCurve(&.{.{ .key = "value", .value = "[1, 0.5, 0]" }});
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.plot_h = 100;
    c.plot_w = 200;
    c.plot_x = 0;

    try down(inst, &state, 100, 50);
    try move(inst, &state, 100, 80);
    // The puck still moves under the cursor — it is a picture you can
    // poke — but nothing goes to the empty path.
    try testing.expectApproxEqAbs(@as(f32, 0.2), c.knots[1], 1e-5);
    try testing.expect(state.get("") == null);
}

test "curve: the range is ingested before the knots it seeds" {
    // `knots=` comes first and `max=` last in this document; the seed
    // must still land at the NEW max.
    const inst = try makeCurve(&.{
        .{ .key = "knots", .value = "2" },
        .{ .key = "value", .value = "${state.nothing}" },
        .{ .key = "max", .value = "3" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(usize, 2), c.knots.len);
    for (c.knots) |v| try testing.expectApproxEqAbs(@as(f32, 3), v, 1e-6);
}

test "curve: an out-of-range knot is drawn pinned but not rewritten" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try makeCurve(&.{
        .{ .key = "target", .value = "size_curve" },
        .{ .key = "value", .value = "[5, 0.5, 0]" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "1" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.plot_h = 100;
    c.plot_w = 200;
    c.plot_x = 0;

    // Drawn at the ceiling…
    try testing.expectApproxEqAbs(@as(f32, 0), knotPos(c, 0)[1], 1e-6);
    // …but a drag on knot 2 leaves knot 0 spelled as the plane spelled it.
    try down(inst, &state, 200, 100);
    try move(inst, &state, 200, 50);
    try testing.expectEqualStrings("[5.0000, 0.5000, 0.5000]", state.get("size_curve").?);
}

test "curve: an inverted range does not trip clamp's assert" {
    try testing.expectEqual(@as(f32, 5), clampRange(9, 5, 1));
    try testing.expectEqual(@as(f32, 3), clampRange(3, 0, 10));
}

test "curve: the span as a document writes it parses and mounts" {
    // The syntax a document must use, run through the real block
    // parser with the state the demo seeds: `value=${state.size_curve}`
    // resolves to the array, the quoted label survives, and `create`
    // mounts from exactly that Spec. Guards the grammar — a `[`, a `,`
    // or a `"` the attr scanner disliked would surface here and nowhere
    // in the gates above, which all hand-build their Specs.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try state.set("size_curve", "[1.0, 0.7, 0.0]");

    const doc =
        \\:::curve {#size_curve target=size_curve value=${state.size_curve} min=0 max=2 label="size over life" width=320}
        \\:::
        \\
    ;
    const pre = try components.preprocess(arena.allocator(), doc, &state);
    try testing.expectEqual(@as(usize, 1), pre.specs.len);
    const spec = pre.specs[0];
    try testing.expectEqualStrings("curve", spec.name);
    try testing.expectEqualStrings("size_curve", spec.id.?);

    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("size_curve", c.target);
    try testing.expectEqualStrings("size over life", c.label);
    try testing.expectApproxEqAbs(@as(f32, 2), c.max, 1e-6);
    try testing.expectEqual(@as(usize, 3), c.knots.len);
    try testing.expectApproxEqAbs(@as(f32, 0.7), c.knots[1], 1e-6);
}

test "curve: mouse_up ends the gesture, so a later move writes nothing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try sizeCurve();
    defer deinit_(inst.ctx, testing.allocator);

    try down(inst, &state, 100, 30);
    try move(inst, &state, 100, 50);
    const written = try testing.allocator.dupe(u8, state.get("size_curve").?);
    defer testing.allocator.free(written);
    try up(inst, &state, 100, 50);
    try move(inst, &state, 100, 90);
    try testing.expectEqualStrings(written, state.get("size_curve").?);
}
