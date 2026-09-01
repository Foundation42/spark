//! `:::trackball` — a colour-balance disc, a master dial, and the three
//! numbers they drive. The control every grading tool has and spark did
//! not, so `hud/primaries.md` had to spend nine sliders on what is
//! ergonomically three gestures.
//!
//! Attribute grammar:
//!
//!     :::trackball {label="Lift" r=lift_r g=lift_g b=lift_b
//!                   min=-0.3 max=0.3 neutral=0
//!                   value_r=${state.lift_r}
//!                   value_g=${state.lift_g}
//!                   value_b=${state.lift_b}
//!                   size=124}
//!     :::
//!
//! - `r` / `g` / `b` — the state paths to write. Bare paths, same as
//!   `:::slider {target=}` and `:::grip {x=}`. A missing one is simply
//!   not driven, so a two-channel trackball is legal if odd.
//! - `value_r` / `value_g` / `value_b` — the reactive inputs. Bind them
//!   to the same paths and an external write (the console, the bars
//!   view, another panel) moves the puck.
//! - `min` / `max` — the channel range. Defaults 0..1.
//! - `neutral` — the value that means "no change": 0 for a signed lift,
//!   1 for gamma or gain. Defaults to the midpoint of the range, which
//!   is right for lift and gain and wrong for gamma — say it explicitly.
//! - `size` — the disc block's diameter in pixels. Default 124. The
//!   component may end up WIDER than this if the readout needs it.
//! - `label` — a caption above the disc. Optional.
//! - `dial_span` — pixels of horizontal travel that equal the whole
//!   `min..max` range on the dial. Default 260. Same idea, and the same
//!   reasoning, as `:::grip {x_span=}`: the widget produces pixels and
//!   only the document knows what they are worth.
//!
//! ## The three gestures
//!
//! **Disc** — press anywhere on it and the puck jumps to the cursor.
//! Angle is the balance hue, radius is its strength. Both are absolute,
//! so the puck is always under your finger.
//!
//! **Dial** — the ridged strip below the disc. A RELATIVE horizontal
//! drag on the master level, because the master is the value you want to
//! trim by a hair and an absolute strip that narrow would quantise it
//! into about eighty steps. The ridges scroll with the value so the
//! gesture has feedback even when the number is off-screen.
//!
//! **Centre dot** — a click inside it is "neutral": no push, master
//! home. It costs the innermost tenth of the disc's radius, where the
//! push is too weak to aim anyway.
//!
//! ## Why `local` is enough here, when `::grip` needed more
//!
//! `::grip` has to reconstruct the cursor in world space against a
//! FROZEN origin, because a grip moves exactly as far as the thing it
//! drags and measuring against its current box is unity-gain feedback.
//! A trackball does not move while you use it — and even if the panel
//! under it were dragged out from under the cursor mid-gesture, the
//! dispatcher reports `local` against the box frozen at mouse_down, so
//! `local - press_local` is pure cursor travel either way. The frozen
//! box is doing the same work; this component just never has to undo it.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
const color = @import("color.zig");

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("trackball", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Visual constants ────────────────────────────────────────────────

/// Segments in the hue disc's triangle fan. The rim colour is
/// interpolated across each chord, so this is the only thing between a
/// smooth wheel and a visible polygon. 72 is 5° a side, under a pixel of
/// chord error at any size a panel will use.
const DISC_SEGMENTS: usize = 72;
/// Segments across the full 270° level sweep.
const ARC_SEGMENTS: usize = 96;

const DISC_CENTRE_COLOR: [4]f32 = .{ 0.10, 0.11, 0.13, 1.0 };
const ARC_TRACK_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.12 };
const ARC_FILL_COLOR: [4]f32 = .{ 0.93, 0.95, 1.0, 0.95 };
const ARC_NEUTRAL_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.55 };
const CENTRE_DOT_COLOR: [4]f32 = .{ 0.85, 0.87, 0.92, 0.55 };
const PUCK_RING_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.92 };
const DIAL_BG_COLOR: [4]f32 = .{ 0.0, 0.0, 0.0, 0.32 };
const DIAL_RIDGE_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.22 };
const DIAL_CENTRE_COLOR: [4]f32 = .{ 1.0, 0.68, 0.0, 0.85 };
const LABEL_COLOR: [4]f32 = .{ 0.92, 0.93, 0.97, 1.0 };

/// The readout's per-channel ink. Identity by colour, matching the bar
/// view and Resolve's own numeric row — the three numbers are otherwise
/// indistinguishable at a glance.
pub const CHANNEL_COLORS: [4][4]f32 = .{
    .{ 1.00, 0.46, 0.43, 1.0 }, // r
    .{ 0.47, 0.90, 0.50, 1.0 }, // g
    .{ 0.50, 0.68, 1.00, 1.0 }, // b
    .{ 0.88, 0.90, 0.95, 1.0 }, // master
};

const ARC_BAND: f32 = 3.5;
const ARC_GAP: f32 = 5.0;
const LABEL_GAP: f32 = 4.0;
const DIAL_GAP: f32 = 8.0;
const DIAL_H: f32 = 13.0;
const READOUT_GAP: f32 = 5.0;
const PUCK_R: f32 = 5.5;
const DEFAULT_SIZE: f32 = 124.0;
const DEFAULT_DIAL_SPAN: f32 = 260.0;
/// Fraction of the disc radius that reads as "the centre dot".
const CENTRE_FRACTION: f32 = 0.10;
/// How far past the rim a press still counts as a disc grab, as a
/// fraction of the radius. Being generous here matters: the rim is where
/// the strongest pushes live and a press that misses by two pixels
/// should not fall through to nothing.
const DISC_SLOP: f32 = 1.15;
/// The level sweep, as a half-angle either side of straight up. 135°
/// leaves the bottom quadrant open, which is what makes the arc read as
/// a dial rather than a ring.
const SWEEP: f32 = 135.0;
/// Widest readout cell, as a template. Fixed rather than measured from
/// the live numbers so the widget's width does not twitch while a value
/// crosses from `0.10` to `-0.10`.
///
/// Sized for a grading range — the widest thing lift, gamma or gain can
/// print at two decimals is `-0.30`. A trackball bound to something that
/// runs into three digits would overflow its cell into its neighbour;
/// that is a colour control, so the trade is width every day against a
/// binding it was never for.
const READOUT_TEMPLATE = "-0.00";

// ── Component ───────────────────────────────────────────────────────

/// Which zone a gesture grabbed, latched at mouse_down. A drag that
/// starts on the disc and wanders down over the dial keeps steering the
/// disc, which is what every other drag control in the world does.
const Zone = enum { none, disc, dial };

const Component = struct {
    allocator: std.mem.Allocator,
    /// Owned state paths, one per channel. Empty means "not driven".
    paths: [3][]u8,
    label: []u8,
    bal: color.Balance,
    size: f32,
    dial_span: f32,

    /// What this trackball last wrote to each path.
    ///
    /// Not tidiness — the same argument as `::grip`'s `last_written`. A
    /// `state.set` is an authored write that travels out through the
    /// document's mirror to a knob, and a pure hue rotation at zero push
    /// changes none of the three channels. Writing them anyway would
    /// re-author three knobs sixty times a second with the values they
    /// already hold.
    last_written: [3]f32 = .{ 0, 0, 0 },

    // ── Geometry, recorded at layout ──
    //
    // All LOCAL to the component's own box, so unlike `::grip`'s
    // `last_box` these cannot go stale when a cached ancestor blits the
    // widget at a new origin: they depend on `size` and the font
    // metrics, and neither of those changes without an ingest.
    disc_centre: [2]f32 = .{ 0, 0 },
    disc_r: f32 = 1,
    dial_top: f32 = 0,
    content_w: f32 = DEFAULT_SIZE,

    // ── Drag anchor ──
    zone: Zone = .none,
    press_local: [2]f32 = .{ 0, 0 },
    press_master: f32 = 0,

    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var raw: [3]?[]const u8 = .{ null, null, null };
        var values: [3]?f32 = .{ null, null, null };
        var min: ?f32 = null;
        var max: ?f32 = null;
        var neutral: ?f32 = null;

        for (spec.attrs) |attr| {
            const k = attr.key;
            if (std.mem.eql(u8, k, "r")) {
                raw[0] = attr.value;
            } else if (std.mem.eql(u8, k, "g")) {
                raw[1] = attr.value;
            } else if (std.mem.eql(u8, k, "b")) {
                raw[2] = attr.value;
            } else if (std.mem.eql(u8, k, "value_r")) {
                values[0] = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "value_g")) {
                values[1] = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "value_b")) {
                values[2] = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "min")) {
                min = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "max")) {
                max = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "neutral")) {
                neutral = parseF32(attr.value);
            } else if (std.mem.eql(u8, k, "size")) {
                if (parseF32(attr.value)) |v| {
                    if (v > 16) self.size = v;
                }
            } else if (std.mem.eql(u8, k, "dial_span")) {
                if (parseF32(attr.value)) |v| {
                    if (v > 0) self.dial_span = v;
                }
            } else if (std.mem.eql(u8, k, "label")) {
                const dup = try a.dupe(u8, attr.value);
                a.free(self.label);
                self.label = dup;
            }
        }

        // ── The bound paths, and the re-entrancy that made this a crash ──
        //
        // `state.set` notifies subscribers SYNCHRONOUSLY, and this
        // component is one of them: `value_r=${state.lift_r}` binds it to
        // the very path `writeChannels` is writing. So the call stack
        // during a drag is
        //
        //     writeChannels → state.set(paths[0]) → update → ingest
        //
        // and this loop used to free `paths[0]` while `set` was still
        // holding it as its hash key. Segfault in `hashString`, from a
        // gesture, on the frame the second write landed.
        //
        // Two things keep it shut, and both are wanted:
        //
        //   * a path that has not CHANGED is not reallocated, so the
        //     literal `r=lift_r` every real document writes never frees
        //     anything at all — and stops churning the heap sixty times
        //     a second while a puck moves;
        //   * and even a document that genuinely re-points a path mid
        //     drag waits, because `gesture` holds this off until the
        //     button comes up. Every route into `writeChannels` runs
        //     from `onInput` with a zone latched, so that is exactly
        //     the window where a free would be unsafe.
        //
        // `::grip` has the same shape and has never crashed, because its
        // `x=px` carries no `${}` — no binding, no subscriber, no
        // re-entry. That is luck, not design, and it is why this note is
        // long.
        const gesture = self.zone != .none;
        if (!gesture) {
            for (raw, 0..) |maybe, i| {
                if (maybe) |v| {
                    if (std.mem.eql(u8, self.paths[i], v)) continue;
                    const dup = try a.dupe(u8, v);
                    a.free(self.paths[i]);
                    self.paths[i] = dup;
                }
            }
        }

        // Range first — the channel values are clamped into it, so
        // ingesting them in the other order would clamp against the
        // range the document had LAST time.
        if (min) |v| self.bal.min = v;
        if (max) |v| self.bal.max = v;
        if (neutral) |v| {
            self.bal.neutral = v;
        } else if (min != null or max != null) {
            self.bal.neutral = (self.bal.min + self.bal.max) * 0.5;
        }

        // ── During a gesture the WIDGET is the authority ──
        //
        // Same re-entrancy as above, and the cause of the jumping. A
        // trackball writes THREE paths, one `state.set` at a time, and
        // each one notifies us before the next goes out. So the ingest
        // that fires from writing red arrives when green and blue still
        // hold their old values — and `inverse` re-derives hue and push
        // from `(new_r, old_g, old_b)`, a triple that never existed and
        // that points the puck somewhere neither the cursor nor the
        // grade ever asked for. The next mouse_move puts it back, and
        // the frame after that throws it out again.
        //
        // Chris, at the bench: "if I drag the puck in the trackball, it
        // jumps all over the place. Like it's quantized or snapping to
        // specific co-ordinates in the colour space."
        //
        // A `:::slider` cannot meet this: it writes ONE path, so there
        // is no partial state to be re-read from. Any widget that
        // writes several paths from one gesture has to hold its own
        // truth until the gesture ends — which is also, from the other
        // side, what `web/apps/color-grader` threads `pushToDetail`
        // around its wheel to achieve.
        //
        // Between gestures the plane is the truth; during one, we are.
        if (!gesture and
            (values[0] != null or values[1] != null or values[2] != null))
        {
            var next = self.bal.cur;
            for (values, 0..) |maybe, i| {
                if (maybe) |v| next[i] = v;
            }
            self.bal.setChannels(next);
            // What we now believe state holds. Re-seeding here is what
            // makes the write gate honest across a reload: without it a
            // drag's first move would compare against a value from
            // before the document changed under us.
            self.last_written = self.bal.cur;
        }

        self.version +%= 1;
    }

    /// Push the three channels out to state, skipping any that already
    /// hold the value. Returns nothing — a path that is not bound is
    /// simply not written.
    fn writeChannels(self: *Component, state: *state_mod.State) !void {
        for (self.paths, self.bal.cur, 0..) |path, v, i| {
            if (path.len == 0) continue;
            if (v == self.last_written[i]) continue;
            var buf: [32]u8 = undefined;
            // Four places, like `::grip` and unlike `:::slider`'s two: a
            // lift runs -0.3..0.3, where two decimals is a 0.6% step and
            // reads as the puck snapping rather than sliding.
            const s = std.fmt.bufPrint(&buf, "{d:.4}", .{v}) catch continue;
            try state.set(path, s);
            self.last_written[i] = v;
        }
    }
};

fn parseF32(s: []const u8) ?f32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t\r\n")) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

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
        .paths = .{ &.{}, &.{}, &.{} },
        .label = &.{},
        .bal = .{},
        .size = DEFAULT_SIZE,
        .dial_span = DEFAULT_DIAL_SPAN,
    };
    for (&c.paths) |*p| p.* = try allocator.dupe(u8, "");
    errdefer for (c.paths) |p| allocator.free(p);
    c.label = try allocator.dupe(u8, "");
    errdefer allocator.free(c.label);

    try c.ingest(spec);
    // A trackball with no `value_*` bindings still has to start
    // somewhere coherent, and "neutral" is the only defensible guess.
    if (c.bal.cur[0] == c.bal.cur[1] and c.bal.cur[1] == c.bal.cur[2] and c.bal.push == 0) {
        c.bal.neutralise();
        c.last_written = c.bal.cur;
    }
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    for (c.paths) |p| allocator.free(p);
    allocator.free(c.label);
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

// ── Geometry helpers ────────────────────────────────────────────────

/// Screen position at `angle` degrees CLOCKWISE FROM STRAIGHT UP.
///
/// One convention, used by the hue rim, the puck, and the level arc, so
/// the disc is a literal picture of `Balance.hue` and reading the code
/// against the picture works. It matches `web/apps/color-grader`'s
/// `atan2(dx, -dy)`, which is where the numbers have to agree.
fn onCircle(centre: [2]f32, r: f32, angle_deg: f32) [2]f32 {
    const a = angle_deg * std.math.pi / 180.0;
    return .{ centre[0] + r * @sin(a), centre[1] - r * @cos(a) };
}

/// The dial angle for a value fraction: `0` at the bottom-left end of
/// the sweep, `1` at the bottom-right.
fn sweepAngle(f: f32) f32 {
    return -SWEEP + f * (2 * SWEEP);
}

// ── Paint ───────────────────────────────────────────────────────────

fn appendHueDisc(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    centre: [2]f32,
    r: f32,
) !void {
    const base: u32 = @intCast(out.tris.items.len);
    try out.ensureUnusedTriCapacity(DISC_SEGMENTS + 1);
    out.appendTriAssumeCapacity(lc, .{ .pos = centre, .color = DISC_CENTRE_COLOR });
    for (0..DISC_SEGMENTS) |i| {
        const deg = @as(f32, @floatFromInt(i)) / @as(f32, DISC_SEGMENTS) * 360.0;
        const rgb = color.hsv2rgb(deg, 1, 1);
        out.appendTriAssumeCapacity(lc, .{
            .pos = onCircle(centre, r, deg),
            .color = .{ rgb[0], rgb[1], rgb[2], 1.0 },
        });
    }
    try out.tri_indices.ensureUnusedCapacity(DISC_SEGMENTS * 3);
    for (0..DISC_SEGMENTS) |i| {
        const cur: u32 = base + 1 + @as(u32, @intCast(i));
        const nxt: u32 = base + 1 + @as(u32, @intCast((i + 1) % DISC_SEGMENTS));
        out.tri_indices.appendAssumeCapacity(base);
        out.tri_indices.appendAssumeCapacity(cur);
        out.tri_indices.appendAssumeCapacity(nxt);
    }
}

/// A ring segment between two radii, swept between two angles in the
/// `onCircle` convention. `a0` may be greater than `a1`; the band is
/// drawn either way, which is what lets one call serve both a master
/// above neutral and one below it.
fn appendArc(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    centre: [2]f32,
    r_in: f32,
    r_out: f32,
    a0: f32,
    a1: f32,
    col: [4]f32,
    segments: usize,
) !void {
    if (segments == 0) return;
    const lo = @min(a0, a1);
    const hi = @max(a0, a1);
    if (!(hi - lo > 1e-4)) return;

    const n = segments + 1;
    const base: u32 = @intCast(out.tris.items.len);
    try out.ensureUnusedTriCapacity(n * 2);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const a = lo + (hi - lo) * t;
        out.appendTriAssumeCapacity(lc, .{ .pos = onCircle(centre, r_in, a), .color = col });
        out.appendTriAssumeCapacity(lc, .{ .pos = onCircle(centre, r_out, a), .color = col });
    }
    try out.tri_indices.ensureUnusedCapacity(segments * 6);
    for (0..segments) |i| {
        const q: u32 = base + @as(u32, @intCast(i)) * 2;
        for ([_]u32{ q, q + 1, q + 2, q + 1, q + 3, q + 2 }) |idx| {
            out.tri_indices.appendAssumeCapacity(idx);
        }
    }
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = lc.theme.body;
    // Mono for the numbers. Four cells that change independently would
    // shuffle sideways in a proportional face on every drag frame.
    const num_font = lc.theme.code_inline_font_id;
    const num_scale = lc.fonts.scale(num_font);
    const num_metrics = lc.fonts.metrics(num_font);

    const cell_w = blk: {
        const hb = lc.fonts.hbFont(num_font);
        const run = try shape.shapeUtf8(aa, hb, READOUT_TEMPLATE);
        var w: f32 = 0;
        for (run.glyphs) |g| w += g.x_advance * num_scale;
        break :blk w + 6;
    };

    const content_w = @max(c.size, cell_w * 4);
    // A trackball is an intrinsically-sized widget: it never grows into
    // the column the way a slider does, because a wheel with an aspect
    // ratio is not a wheel.
    _ = constraints;

    var y = origin[1];
    if (c.label.len > 0) {
        const label_m = lc.fonts.metrics(body.font_id);
        const hb = lc.fonts.hbFont(body.font_id);
        const run = try shape.shapeUtf8(aa, hb, c.label);
        var lw: f32 = 0;
        for (run.glyphs) |g| lw += g.x_advance * lc.fonts.scale(body.font_id);
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
            origin[0] + (content_w - lw) * 0.5,
            y + label_m.ascender,
            LABEL_COLOR,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
        y += label_m.line_height + LABEL_GAP;
    }

    // ── Disc block ──
    const centre: [2]f32 = .{ origin[0] + content_w * 0.5, y + c.size * 0.5 };
    const arc_r_out = c.size * 0.5;
    const arc_r_in = arc_r_out - ARC_BAND;
    const disc_r = @max(4.0, arc_r_in - ARC_GAP);

    try appendHueDisc(out, lc, centre, disc_r);

    // Level arc: the full sweep as a dim track, then neutral→master
    // filled. The fill's DIRECTION carries the sign, which is why there
    // is no separate colour for a master below neutral.
    try appendArc(out, lc, centre, arc_r_in, arc_r_out, sweepAngle(0), sweepAngle(1), ARC_TRACK_COLOR, ARC_SEGMENTS);
    const f_neutral = c.bal.fractionOf(c.bal.neutral);
    const f_master = c.bal.fractionOf(c.bal.master);
    try appendArc(
        out,
        lc,
        centre,
        arc_r_in,
        arc_r_out,
        sweepAngle(f_neutral),
        sweepAngle(f_master),
        ARC_FILL_COLOR,
        ARC_SEGMENTS,
    );
    // The neutral tick, drawn last so it survives the fill passing over
    // it — it is the only mark that says where "no change" is.
    try appendArc(
        out,
        lc,
        centre,
        arc_r_in - 1.5,
        arc_r_out + 1.5,
        sweepAngle(f_neutral) - 0.9,
        sweepAngle(f_neutral) + 0.9,
        ARC_NEUTRAL_COLOR,
        1,
    );

    // Centre dot — the neutral marker, and the reset target.
    const dot_r = @max(2.5, disc_r * CENTRE_FRACTION * 0.55);
    try out.appendQuad(lc, .{
        .dst_pos = .{ centre[0] - dot_r, centre[1] - dot_r },
        .dst_size = .{ dot_r * 2, dot_r * 2 },
        .color = CENTRE_DOT_COLOR,
        .radius = dot_r,
    });

    // Puck: a white ring under a swatch of the balance hue, so it reads
    // on a red rim and on a blue one.
    const puck = onCircle(centre, @min(1, c.bal.push) * disc_r, c.bal.hue);
    try out.appendQuad(lc, .{
        .dst_pos = .{ puck[0] - PUCK_R - 1.5, puck[1] - PUCK_R - 1.5 },
        .dst_size = .{ (PUCK_R + 1.5) * 2, (PUCK_R + 1.5) * 2 },
        .color = PUCK_RING_COLOR,
        .radius = PUCK_R + 1.5,
    });
    try out.appendQuad(lc, .{
        .dst_pos = .{ puck[0] - PUCK_R, puck[1] - PUCK_R },
        .dst_size = .{ PUCK_R * 2, PUCK_R * 2 },
        .color = c.bal.puckColor(),
        .radius = PUCK_R,
    });

    y += c.size + DIAL_GAP;

    // ── Dial ──
    const dial_top = y;
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], dial_top },
        .dst_size = .{ content_w, DIAL_H },
        .color = DIAL_BG_COLOR,
        .radius = 3,
    });
    // Ridges, phase-shifted by the master's distance from neutral. The
    // dial is a relative control with no absolute position to show, so
    // this scroll is the only feedback that a drag is landing.
    const RIDGE_STEP: f32 = 7.0;
    const phase = @mod((f_master - f_neutral) * c.dial_span, RIDGE_STEP);
    var rx = origin[0] + phase;
    while (rx < origin[0] + content_w - 1) : (rx += RIDGE_STEP) {
        if (rx < origin[0] + 1) continue;
        try out.appendQuad(lc, .{
            .dst_pos = .{ rx, dial_top + 2.5 },
            .dst_size = .{ 1.0, DIAL_H - 5.0 },
            .color = DIAL_RIDGE_COLOR,
            .radius = 0,
        });
    }
    // The home mark, in the grip's own orange so the two draggable
    // things on a panel share a colour.
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + content_w * 0.5 - 0.75, dial_top },
        .dst_size = .{ 1.5, DIAL_H },
        .color = DIAL_CENTRE_COLOR,
        .radius = 0,
    });

    y += DIAL_H + READOUT_GAP;

    // ── Readout ──
    const readout_baseline = y + num_metrics.ascender;
    const cells: [4]f32 = .{ c.bal.cur[0], c.bal.cur[1], c.bal.cur[2], c.bal.master };
    for (cells, CHANNEL_COLORS, 0..) |v, col, i| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.2}", .{v}) catch continue;
        const hb = lc.fonts.hbFont(num_font);
        const run = try shape.shapeUtf8(aa, hb, s);
        var tw: f32 = 0;
        for (run.glyphs) |g| tw += g.x_advance * num_scale;
        const cell_x = origin[0] + cell_w * @as(f32, @floatFromInt(i));
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
            num_font,
            cell_x + (cell_w - tw) * 0.5,
            readout_baseline,
            col,
            body.hot_color,
            body.attention,
            lc.zoom,
        );
    }
    y += num_metrics.line_height;

    // Local geometry for the input path. Origin-independent by
    // construction — see the struct comment.
    c.disc_centre = .{ centre[0] - origin[0], centre[1] - origin[1] };
    c.disc_r = disc_r;
    c.dial_top = dial_top - origin[1];
    c.content_w = content_w;

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = content_w,
        .h = y - origin[1],
        .baseline = readout_baseline,
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
            c.press_local = m.local;
            c.press_master = c.bal.master;
            c.zone = zoneAt(c, m.local);
            switch (c.zone) {
                .disc => try pressDisc(c, state, m.local),
                .dial => {}, // relative: nothing happens until the move
                .none => {},
            }
        },
        .mouse_move => |m| {
            if (!m.button_down) return;
            switch (c.zone) {
                .disc => try pressDisc(c, state, m.local),
                .dial => try dragDial(c, state, m.local),
                .none => {},
            }
        },
        .mouse_up => |m| {
            if (m.button == 0) c.zone = .none;
        },
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

/// Which control a press at `local` grabbed.
pub fn zoneAt(c: *const Component, local: [2]f32) Zone {
    if (local[1] >= c.dial_top and local[1] <= c.dial_top + DIAL_H) return .dial;
    const dx = local[0] - c.disc_centre[0];
    const dy = local[1] - c.disc_centre[1];
    // Generous, but not unbounded: a press on the label above the disc
    // must not fling the puck.
    if (dx * dx + dy * dy <= (c.disc_r * DISC_SLOP) * (c.disc_r * DISC_SLOP)) return .disc;
    return .none;
}

fn pressDisc(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    const dx = local[0] - c.disc_centre[0];
    const dy = local[1] - c.disc_centre[1];
    const dist = @sqrt(dx * dx + dy * dy);

    if (dist <= c.disc_r * CENTRE_FRACTION) {
        // The centre dot is "neutral", not "a very small push". Aiming
        // a push this weak is not possible anyway, so the pixels are
        // better spent on the reset every grading tool has a button for.
        c.bal.neutralise();
    } else {
        c.bal.push = color.clamp(dist / c.disc_r, 0, 1);
        c.bal.hue = @mod(std.math.atan2(dx, -dy) * 180.0 / std.math.pi + 360.0, 360.0);
        c.bal.forward();
    }
    c.version +%= 1;
    try c.writeChannels(state);
}

fn dragDial(c: *Component, state: *state_mod.State, local: [2]f32) !void {
    // `local` is measured against the box frozen at mouse_down, so this
    // difference is pure cursor travel even if the panel moved. See the
    // module header.
    const travel = local[0] - c.press_local[0];
    const span = c.bal.max - c.bal.min;
    c.bal.master = color.clamp(
        c.press_master + travel * span / c.dial_span,
        c.bal.min,
        c.bal.max,
    );
    c.bal.forward();
    c.version +%= 1;
    try c.writeChannels(state);
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
    return .{ .name = "trackball", .id = null, .attrs = attr_pool[i][0..attrs.len], .body = "" };
}

fn makeBall(attrs: []const components.Attr) !component_mod.Instance {
    const spec = specOf(attrs);
    return create(&_test_spark, testing.allocator, &spec);
}

/// A lift-shaped trackball with a geometry a test can aim at: centre at
/// (60, 60) local, radius 50.
fn liftBall() !component_mod.Instance {
    const inst = try makeBall(&.{
        .{ .key = "r", .value = "lift_r" },
        .{ .key = "g", .value = "lift_g" },
        .{ .key = "b", .value = "lift_b" },
        .{ .key = "min", .value = "-0.3" },
        .{ .key = "max", .value = "0.3" },
        .{ .key = "neutral", .value = "0" },
    });
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.disc_centre = .{ 60, 60 };
    c.disc_r = 50;
    c.dial_top = 130;
    c.content_w = 120;
    return inst;
}

test "trackball: ingests three paths and the range" {
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqualStrings("lift_r", c.paths[0]);
    try testing.expectEqualStrings("lift_g", c.paths[1]);
    try testing.expectEqualStrings("lift_b", c.paths[2]);
    try testing.expectApproxEqAbs(@as(f32, -0.3), c.bal.min, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), c.bal.max, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.neutral, 1e-6);
    // A fresh trackball with no `value_*` sits on neutral rather than on
    // whatever `Balance`'s field defaults happened to be.
    for (c.bal.cur) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-6);
}

test "trackball: neutral defaults to the midpoint when the document is quiet" {
    // Right for lift (-0.3..0.3 → 0) and gain (0..2 → 1); WRONG for
    // gamma (0.4..2.5 → 1.45), which is why the header tells documents
    // to say it.
    const inst = try makeBall(&.{
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "2" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectApproxEqAbs(@as(f32, 1), c.bal.neutral, 1e-6);
}

test "trackball: a press on the rim writes all three channels" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Straight up from the centre is hue 0 — red — at full push.
    try pressDisc(c, &state, .{ 60, 10 });

    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.hue, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), c.bal.push, 1e-3);
    try testing.expect(state.get("lift_r") != null);
    try testing.expect(state.get("lift_g") != null);
    try testing.expect(state.get("lift_b") != null);

    // Red up, green and blue down by half as much each — that is what
    // "balance" means, and it is why the mean did not move.
    const r = try std.fmt.parseFloat(f32, state.get("lift_r").?);
    const g = try std.fmt.parseFloat(f32, state.get("lift_g").?);
    const b = try std.fmt.parseFloat(f32, state.get("lift_b").?);
    try testing.expect(r > 0.05);
    try testing.expect(g < 0);
    try testing.expectApproxEqAbs(g, b, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), (r + g + b) / 3.0, 1e-3);
}

test "trackball: the angle convention matches the puck's screen position" {
    // The one thing that would look like a bug rather than read like
    // one: a disc whose hue ring and drag maths disagree, so the puck
    // lands on a colour the wheel does not show there.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const probes = [_][2]f32{ .{ 60, 20 }, .{ 100, 60 }, .{ 60, 100 }, .{ 20, 60 } };
    for (probes) |p| {
        try pressDisc(c, &state, p);
        // Where the paint code would draw the puck for the hue the drag
        // just derived, in the component's own local frame.
        const drawn = onCircle(c.disc_centre, @min(1, c.bal.push) * c.disc_r, c.bal.hue);
        try testing.expectApproxEqAbs(p[0], drawn[0], 0.05);
        try testing.expectApproxEqAbs(p[1], drawn[1], 0.05);
    }
}

test "trackball: the centre dot resets rather than nudging" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try pressDisc(c, &state, .{ 60, 10 }); // way out on the rim
    try dragDial(c, &state, .{ 200, 140 }); // and the master off home
    // Rule 1: both really moved, so the reset below is about the centre
    // dot and not about a widget that never left neutral.
    try testing.expect(c.bal.push > 0.9);
    try testing.expect(@abs(c.bal.master) > 0.01);

    try pressDisc(c, &state, .{ 62, 61 }); // inside the centre dot
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.push, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.master, 1e-6);
    for (c.bal.cur) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-6);
}

test "trackball: the dial is relative, so a second press does not jump" {
    // An absolute strip 120px wide across a 0.6 range would quantise the
    // master into 120 steps and, worse, teleport it to wherever the
    // cursor happened to land. The dial must move by TRAVEL.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Press at x=20 on the dial, drag to x=150: 130px of travel over a
    // 260px span is half the 0.6 range = +0.30... which clamps to max.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(Zone.dial, c.zone);
    // Nothing yet — a press on a relative control is not a value.
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.master, 1e-6);

    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 85, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    // 65px / 260px * 0.6 = 0.15
    try testing.expectApproxEqAbs(@as(f32, 0.15), c.bal.master, 1e-4);

    // Release, then press somewhere else entirely and move by the same
    // 65px. The master must go to 0.30, not back to 0.15.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 85, 135 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 10, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 75, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 0.30), c.bal.master, 1e-4);
}

test "trackball: the zone latches, so a drag off the disc keeps steering it" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 60, 30 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(Zone.disc, c.zone);
    const master_before = c.bal.master;

    // Wander down over the dial with the button still held.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 90, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(Zone.disc, c.zone);
    // The dial did NOT take over: the master is where the disc left it.
    try testing.expectApproxEqAbs(master_before, c.bal.master, 1e-6);
    // Rule 1: the move landed on the disc, so the hue really did change.
    try testing.expect(c.bal.hue > 90 and c.bal.hue < 180);
}

test "trackball: a press outside every control does nothing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Up in the label band, well clear of the disc.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 5, 2 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(Zone.none, c.zone);
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 60, 20 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.push, 1e-6);
    try testing.expect(state.get("lift_r") == null);
}

test "trackball: a channel that did not change is not re-authored" {
    // The `::grip` lesson. A hue rotation with no push changes none of
    // the three numbers, and writing them anyway would push three knobs
    // through the document's mirror on every mouse-move.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try state.set("lift_g", "SENTINEL");

    // Straight up at full push: red up, green and blue equally down.
    try pressDisc(c, &state, .{ 60, 10 });
    const g_first = try testing.allocator.dupe(u8, state.get("lift_g").?);
    defer testing.allocator.free(g_first);
    try testing.expect(!std.mem.eql(u8, "SENTINEL", g_first));

    // Now swing to hue 180 (cyan, straight down): green and blue rise
    // TOGETHER and red falls, so green genuinely moves and is written.
    try pressDisc(c, &state, .{ 60, 110 });
    try testing.expect(!std.mem.eql(u8, g_first, state.get("lift_g").?));

    // And a press at the very same point again writes nothing new.
    try state.set("lift_g", "UNTOUCHED");
    try pressDisc(c, &state, .{ 60, 110 });
    try testing.expectEqualStrings("UNTOUCHED", state.get("lift_g").?);
}

test "trackball: an external write moves the puck" {
    // The whole point of binding `value_*`: the bars view, the console,
    // and a second panel all reach the same three knobs, and this widget
    // has to follow rather than fight them.
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.push, 1e-6);

    const next = specOf(&.{
        .{ .key = "value_r", .value = "0.12" },
        .{ .key = "value_g", .value = "-0.06" },
        .{ .key = "value_b", .value = "-0.06" },
    });
    try update(inst.ctx, &next);

    try testing.expect(c.bal.push > 0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.hue, 0.5); // red
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.master, 1e-3);
}

/// A subscriber that re-enters `update` on the instance that is writing —
/// which is what `value_r=${state.lift_r}` sets up in a real document.
const ReentrantEcho = struct {
    inst: component_mod.Instance,
    fired: usize = 0,

    fn onSet(ctx: *anyopaque) anyerror!void {
        const self: *ReentrantEcho = @ptrCast(@alignCast(ctx));
        self.fired += 1;
        // The spec a re-render hands back: the same three paths, and the
        // values as they stand RIGHT NOW — which mid-`writeChannels`
        // means one channel updated and two not.
        const echo = specOf(&.{
            .{ .key = "r", .value = "lift_r" },
            .{ .key = "g", .value = "lift_g" },
            .{ .key = "b", .value = "lift_b" },
            .{ .key = "value_r", .value = "0.0000" },
            .{ .key = "value_g", .value = "0.0000" },
            .{ .key = "value_b", .value = "0.0000" },
        });
        try update(self.inst.ctx, &echo);
    }
};

test "trackball: a re-entrant update does not free the key `state.set` is holding" {
    // **The segfault.** `state.set` notifies subscribers synchronously and
    // hashes `key` twice — once for the value map, once for the
    // subscriber map. A trackball writes three paths in a loop, so the
    // ingest fired by the FIRST write used to free and re-dupe all three
    // `paths`, and the second iteration handed `set` a freed slice.
    //
    //     writeChannels → state.set → update → ingest → free(paths[1])
    //     … loop continues → state.set(paths[1])  ← freed
    //
    // Chris hit it dragging a puck: "Segmentation fault", in `hashString`
    // under `state.set`, under `pressDisc`.
    //
    // Under the testing allocator a use-after-free here is a detected
    // leak or a corrupted read rather than a segfault, and either fails
    // the test — which is the point of running it with this allocator.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    var echo = ReentrantEcho{ .inst = inst };
    _ = try state.subscribe("lift_r", ReentrantEcho.onSet, @ptrCast(&echo));
    _ = try state.subscribe("lift_g", ReentrantEcho.onSet, @ptrCast(&echo));
    _ = try state.subscribe("lift_b", ReentrantEcho.onSet, @ptrCast(&echo));

    // A real drag: mouse_down latches the zone, then writeChannels runs
    // three `set`s with the echo re-entering after each.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 60, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));

    // Rule 1: the echo must actually have fired, or this gate proves
    // nothing about re-entrancy at all.
    try testing.expect(echo.fired >= 2);

    // The paths survived, and still say what the document said.
    try testing.expectEqualStrings("lift_r", c.paths[0]);
    try testing.expectEqualStrings("lift_g", c.paths[1]);
    try testing.expectEqualStrings("lift_b", c.paths[2]);

    // And all three channels landed — the loop was not cut short.
    try testing.expect(state.get("lift_r") != null);
    try testing.expect(state.get("lift_g") != null);
    try testing.expect(state.get("lift_b") != null);

    // The gesture also held its own ground against the partial echo:
    // hue 0 is what the cursor asked for, and `(new_r, 0, 0)` would have
    // re-derived something else entirely.
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.hue, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), c.bal.push, 1e-3);
}

test "trackball: an unchanged path is not reallocated" {
    // The other half of the crash fix, and worth having on its own: a
    // document re-renders on every state change, so re-duping three
    // paths per parse churned the heap sixty times a second to arrive
    // at the same three strings.
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    const before = c.paths[0].ptr;

    const same = specOf(&.{
        .{ .key = "r", .value = "lift_r" },
        .{ .key = "g", .value = "lift_g" },
        .{ .key = "b", .value = "lift_b" },
    });
    try update(inst.ctx, &same);
    try testing.expectEqual(before, c.paths[0].ptr);

    // Rule 1: a path that DID change is still swapped, so the identity
    // above is about "unchanged" and not about a component that has
    // stopped reading its attributes.
    const moved = specOf(&.{.{ .key = "r", .value = "other_r" }});
    try update(inst.ctx, &moved);
    try testing.expectEqualStrings("other_r", c.paths[0]);
}

test "trackball: a path is not re-pointed mid-gesture" {
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.zone = .disc;

    const moved = specOf(&.{.{ .key = "r", .value = "other_r" }});
    try update(inst.ctx, &moved);
    try testing.expectEqualStrings("lift_r", c.paths[0]); // held

    c.zone = .none;
    try update(inst.ctx, &moved);
    try testing.expectEqualStrings("other_r", c.paths[0]); // and released
}

test "trackball: a stale echo mid-drag does not move the puck" {
    // THE JUMPING BUG. Mid-drag, the values arriving at `ingest` are this
    // widget's own write coming back a frame late through the host's
    // mirror. Letting `inverse` re-derive hue and push from them puts the
    // puck where the cursor WAS, and the next move puts it back — which
    // reads as snapping, not lag.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Press at the top (hue 0) and start dragging.
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 60, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    // Move to the right side — hue 90, full push.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 110, 60 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 90), c.bal.hue, 0.5);

    // Now the echo of the FIRST position arrives, as the host's pump
    // would deliver it a frame later.
    const stale = specOf(&.{
        .{ .key = "value_r", .value = "0.1300" },
        .{ .key = "value_g", .value = "-0.0650" },
        .{ .key = "value_b", .value = "-0.0650" },
    });
    try update(inst.ctx, &stale);

    // The cursor is still at hue 90, so the puck must be.
    try testing.expectApproxEqAbs(@as(f32, 90), c.bal.hue, 0.5);

    // And once the gesture ends, the plane is the truth again — Rule 1,
    // because a widget that ignored every external write would pass the
    // assertion above for the wrong reason.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 110, 60 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    const external = specOf(&.{
        .{ .key = "value_r", .value = "0.1300" },
        .{ .key = "value_g", .value = "-0.0650" },
        .{ .key = "value_b", .value = "-0.0650" },
    });
    try update(inst.ctx, &external);
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.hue, 0.5);
}

test "trackball: a stale echo mid-drag does not move the dial either" {
    // Same cause, the other control: `inverse` recomputes the master as
    // the mean of the echoed channels, so the arc and the ridge phase
    // jumped just as the puck did.
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 20, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 85, 135 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectApproxEqAbs(@as(f32, 0.15), c.bal.master, 1e-4);

    const stale = specOf(&.{
        .{ .key = "value_r", .value = "0.0000" },
        .{ .key = "value_g", .value = "0.0000" },
        .{ .key = "value_b", .value = "0.0000" },
    });
    try update(inst.ctx, &stale);
    try testing.expectApproxEqAbs(@as(f32, 0.15), c.bal.master, 1e-4);
}

test "trackball: the range still ingests mid-drag, only the values are held" {
    // The guard is on the VALUES, not on the whole ingest — a document
    // that re-renders mid-drag still gets its label and bounds through.
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.zone = .disc;

    const next = specOf(&.{
        .{ .key = "max", .value = "0.9" },
        .{ .key = "label", .value = "Shadows" },
        .{ .key = "value_r", .value = "0.8" },
    });
    try update(inst.ctx, &next);
    try testing.expectApproxEqAbs(@as(f32, 0.9), c.bal.max, 1e-6);
    try testing.expectEqualStrings("Shadows", c.label);
    try testing.expectApproxEqAbs(@as(f32, 0), c.bal.cur[0], 1e-6); // held
}

test "trackball: an unbound channel is skipped, not written to the empty path" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const inst = try makeBall(&.{
        .{ .key = "r", .value = "only_r" },
        .{ .key = "min", .value = "-0.3" },
        .{ .key = "max", .value = "0.3" },
        .{ .key = "neutral", .value = "0" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.disc_centre = .{ 60, 60 };
    c.disc_r = 50;
    c.dial_top = 130;

    try pressDisc(c, &state, .{ 60, 10 });
    try testing.expect(state.get("only_r") != null);
    try testing.expect(state.get("") == null);
}

test "trackball: the range is ingested before the values it clamps" {
    // Ingesting in attribute order would clamp `value_*` against the
    // PREVIOUS range, so a document that widens its bounds and its
    // values in one edit would pin every channel at the old limit.
    const inst = try makeBall(&.{
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "1" },
        .{ .key = "neutral", .value = "0.5" },
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // `value_r` comes FIRST in the attribute list, before the new max.
    const next = specOf(&.{
        .{ .key = "value_r", .value = "1.8" },
        .{ .key = "value_g", .value = "1.0" },
        .{ .key = "value_b", .value = "1.0" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "2" },
        .{ .key = "neutral", .value = "1" },
    });
    try update(inst.ctx, &next);
    try testing.expectApproxEqAbs(@as(f32, 1.8), c.bal.cur[0], 1e-5);
}

test "trackball: zoneAt separates the three controls" {
    const inst = try liftBall();
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    try testing.expectEqual(Zone.disc, zoneAt(c, .{ 60, 60 })); // centre
    try testing.expectEqual(Zone.disc, zoneAt(c, .{ 60, 15 })); // rim
    try testing.expectEqual(Zone.disc, zoneAt(c, .{ 60, 6 })); // just past it
    try testing.expectEqual(Zone.none, zoneAt(c, .{ 60, -20 })); // the label
    try testing.expectEqual(Zone.dial, zoneAt(c, .{ 60, 135 }));
    try testing.expectEqual(Zone.none, zoneAt(c, .{ 60, 160 })); // the readout
}

test "trackball: a degenerate dial span does not divide by nothing" {
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const inst = try makeBall(&.{
        .{ .key = "r", .value = "x" },
        .{ .key = "dial_span", .value = "0" }, // rejected → default
    });
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    c.disc_centre = .{ 60, 60 };
    c.disc_r = 50;
    c.dial_top = 130;

    try testing.expectApproxEqAbs(DEFAULT_DIAL_SPAN, c.dial_span, 1e-6);
    c.press_local = .{ 0, 135 };
    c.press_master = c.bal.master;
    try dragDial(c, &state, .{ 100, 135 });
    try testing.expect(std.math.isFinite(c.bal.master));
}
