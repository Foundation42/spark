//! `relief.zig` — the shading vocabulary for recessed controls.
//!
//! Two problems, one mechanism. Triangles carry a colour PER VERTEX and
//! the fragment stage premultiplies at output, so a vertex at alpha 0
//! gives a smooth ramp to nothing. That buys:
//!
//!   * **anti-aliasing**, which triangles otherwise do not have at all.
//!     `:::box` and every rounded quad get theirs from `quad.frag`'s
//!     signed-distance smoothstep; the triangle pipeline has no SDF, no
//!     derivatives and no MSAA, so a disc rim or an arc drawn as a fan
//!     is a hard polygon edge. Chris, 2026-09-01: "the trackballs have
//!     crispy aliased edges on the circular edges — same with the lift
//!     ring."
//!
//!   * **ambient occlusion**, the shallow kind a physical panel has.
//!     Resolve and XSI put their dials and sliders in cut-outs, and the
//!     depth is sold by a shadow under the top lip and by the dial
//!     fading as it curves away at the ends. Chris again: "you see the
//!     dial ring fading into the recess at the edges."
//!
//! Neither needs a shader. Both are vertex colours.
//!
//! ## Keep it quiet
//!
//! Every alpha here is under 0.4 and most are under 0.2. The effect
//! should be invisible as an effect and only read as depth — the failure
//! mode of skeuomorphism is not subtlety, it is a panel that looks
//! moulded out of plastic. If you can point at the shadow, it is too
//! strong.

const std = @import("std");
const element = @import("../element.zig");

/// Edge softening, in pixels. One pixel is what `quad.frag`'s smoothstep
/// spends, so the two vocabularies agree at a seam — a feathered disc
/// sitting on a rounded quad has no visible difference in crispness.
pub const FEATHER: f32 = 1.0;

/// Screen position at `angle` degrees CLOCKWISE FROM STRAIGHT UP.
///
/// One convention for the hue rim, the puck and the level arc, so the
/// disc is a literal picture of the balance hue. It matches
/// `web/apps/color-grader`'s `atan2(dx, -dy)`, which is where the two
/// implementations have to agree.
pub fn onCircle(centre: [2]f32, r: f32, angle_deg: f32) [2]f32 {
    const a = angle_deg * std.math.pi / 180.0;
    return .{ centre[0] + r * @sin(a), centre[1] - r * @cos(a) };
}

fn withAlpha(c: [4]f32, a: f32) [4]f32 {
    return .{ c[0], c[1], c[2], c[3] * a };
}

// ── Gradient rectangle ──────────────────────────────────────────────

/// A rectangle with a colour at each corner, bilinearly interpolated.
///
/// The workhorse: a groove's top shadow is this with a dark top edge and
/// a transparent bottom one, and the fade at a dial's end is the same
/// thing turned ninety degrees.
pub fn gradientRect(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    top_left: [4]f32,
    top_right: [4]f32,
    bottom_left: [4]f32,
    bottom_right: [4]f32,
) !void {
    if (!(w > 0) or !(h > 0)) return;
    const base: u32 = @intCast(out.tris.items.len);
    try out.ensureUnusedTriCapacity(4);
    out.appendTriAssumeCapacity(lc, .{ .pos = .{ x, y }, .color = top_left });
    out.appendTriAssumeCapacity(lc, .{ .pos = .{ x + w, y }, .color = top_right });
    out.appendTriAssumeCapacity(lc, .{ .pos = .{ x, y + h }, .color = bottom_left });
    out.appendTriAssumeCapacity(lc, .{ .pos = .{ x + w, y + h }, .color = bottom_right });
    try out.tri_indices.ensureUnusedCapacity(6);
    for ([_]u32{ 0, 1, 2, 1, 3, 2 }) |o| out.tri_indices.appendAssumeCapacity(base + o);
}

/// A flat rectangle, in the TRIANGLE layer.
///
/// `:::box` and friends draw a rect as a quad, which is better — it gets
/// `quad.frag`'s rounded corners and its anti-aliasing. Use this one only
/// when the rect has to be ORDERED among other triangles: the renderer
/// draws the whole triangle layer beneath the whole quad layer, so a
/// quad fill under a triangle shadow comes out with the shadow behind
/// the thing it is supposed to be falling on.
pub fn rect(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    col: [4]f32,
) !void {
    try gradientRect(out, lc, x, y, w, h, col, col, col, col);
}

/// A vertical line with both edges faded, so a 1px mark lands crisply
/// wherever it falls instead of snapping to a pixel boundary.
///
/// Triangles have no anti-aliasing and a `radius = 0` quad takes
/// `quad.frag`'s flat-fill fast path, which has none either — so a
/// hairline drawn as either is at the mercy of where its edges land
/// relative to pixel centres. A ruled dial full of those shimmers.
pub fn hairlineV(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    cx: f32,
    y: f32,
    h: f32,
    w: f32,
    col: [4]f32,
) !void {
    if (!(h > 0) or !(w > 0)) return;
    const clear = withAlpha(col, 0);
    const half = w * 0.5;
    try gradientRect(out, lc, cx - half - FEATHER * 0.5, y, FEATHER * 0.5 + half, h, clear, col, clear, col);
    try gradientRect(out, lc, cx, y, half + FEATHER * 0.5, h, col, clear, col, clear);
}

/// Vertical ramp — `top` at the top edge, `bottom` at the bottom.
pub fn shadeV(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    top: [4]f32,
    bottom: [4]f32,
) !void {
    try gradientRect(out, lc, x, y, w, h, top, top, bottom, bottom);
}

/// Horizontal ramp — `left` at the left edge, `right` at the right.
pub fn shadeH(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    left: [4]f32,
    right: [4]f32,
) !void {
    try gradientRect(out, lc, x, y, w, h, left, right, left, right);
}

// ── The cut-out ─────────────────────────────────────────────────────

/// How a recess is lit. One light, from above — which is the only
/// assumption that makes a panel of controls read as one surface.
pub const Groove = struct {
    /// Shadow cast by the top lip, down into the cut-out.
    pub const TOP: [4]f32 = .{ 0.0, 0.0, 0.0, 0.34 };
    /// How far that shadow reaches, as a fraction of the groove's
    /// height, capped by `TOP_MAX_PX`. A fraction alone would put a
    /// tall slot in permanent gloom.
    pub const TOP_FRACTION: f32 = 0.22;
    pub const TOP_MAX_PX: f32 = 6.0;
    /// The lit lower lip. Much weaker than the shadow: a real recess
    /// catches a sliver of bounce, it does not glow.
    pub const LIP: [4]f32 = .{ 1.0, 1.0, 1.0, 0.09 };
    pub const LIP_PX: f32 = 1.5;
    /// Shadow at the left and right ends of a horizontal cut-out.
    pub const END: [4]f32 = .{ 0.0, 0.0, 0.0, 0.30 };
    pub const END_FRACTION: f32 = 0.14;
};

const CLEAR: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
const CLEAR_W: [4]f32 = .{ 1.0, 1.0, 1.0, 0.0 };

/// Shade a rectangle so it reads as cut INTO the panel rather than laid
/// on top of it: a shadow falling from the top lip and a thin lit edge
/// along the bottom one.
///
/// Draw it over the groove's own fill, under whatever rides in the
/// groove. `ends` adds the same treatment at the left and right, which a
/// horizontal dial wants and a vertical slot does not.
pub fn groove(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    ends: bool,
) !void {
    if (!(w > 0) or !(h > 0)) return;

    const top_h = @min(Groove.TOP_MAX_PX, h * Groove.TOP_FRACTION);
    if (top_h > 0.25) {
        try shadeV(out, lc, x, y, w, top_h, Groove.TOP, CLEAR);
    }
    const lip_h = @min(Groove.LIP_PX, h * 0.2);
    if (lip_h > 0.25) {
        try shadeV(out, lc, x, y + h - lip_h, w, lip_h, CLEAR_W, Groove.LIP);
    }
    if (ends) {
        const end_w = @min(w * 0.5, w * Groove.END_FRACTION);
        if (end_w > 0.25) {
            try shadeH(out, lc, x, y, end_w, h, Groove.END, CLEAR);
            try shadeH(out, lc, x + w - end_w, y, end_w, h, CLEAR, Groove.END);
        }
    }
}

/// How much of a mark at `t` (0 at the left end of a cut-out, 1 at the
/// right) survives the recess.
///
/// This is what makes a ridged dial read as a CYLINDER: the ridges do
/// not stop at the ends, they curve away out of the light. A hard edge
/// reads as a printed texture instead.
pub fn edgeFade(t: f32, edge: f32) f32 {
    if (!(edge > 0)) return 1;
    const d = @min(t, 1.0 - t);
    if (d >= edge) return 1;
    const u = std.math.clamp(d / edge, 0, 1);
    // Smoothstep, so the fade has no visible start.
    return u * u * (3.0 - 2.0 * u);
}

// ── Feathered round geometry ────────────────────────────────────────

/// A hue wheel: full saturation at the rim, `centre_col` at the middle,
/// with the rim fading over `FEATHER` pixels so the circle has an edge
/// the triangle pipeline could not otherwise give it.
///
/// `hueAt` is passed as a function pointer rather than a closure because
/// Zig has neither — the one caller wants HSV, and a future one wanting
/// a different ramp supplies its own.
pub fn hueDisc(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    centre: [2]f32,
    r: f32,
    centre_col: [4]f32,
    segments: usize,
    hueAt: *const fn (deg: f32) [3]f32,
) !void {
    if (!(r > 0) or segments < 3) return;

    const base: u32 = @intCast(out.tris.items.len);
    const n: u32 = @intCast(segments);

    // centre, then the rim, then the feather ring beyond it.
    try out.ensureUnusedTriCapacity(1 + segments * 2);
    out.appendTriAssumeCapacity(lc, .{ .pos = centre, .color = centre_col });
    for (0..segments) |i| {
        const deg = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * 360.0;
        const rgb = hueAt(deg);
        out.appendTriAssumeCapacity(lc, .{
            .pos = onCircle(centre, r, deg),
            .color = .{ rgb[0], rgb[1], rgb[2], 1.0 },
        });
    }
    for (0..segments) |i| {
        const deg = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * 360.0;
        const rgb = hueAt(deg);
        out.appendTriAssumeCapacity(lc, .{
            .pos = onCircle(centre, r + FEATHER, deg),
            .color = .{ rgb[0], rgb[1], rgb[2], 0.0 },
        });
    }

    try out.tri_indices.ensureUnusedCapacity(segments * 9);
    for (0..segments) |i| {
        const a: u32 = 1 + @as(u32, @intCast(i));
        const b: u32 = 1 + @as(u32, @intCast((i + 1) % segments));
        // The solid fan.
        for ([_]u32{ 0, a, b }) |o| out.tri_indices.appendAssumeCapacity(base + o);
        // And the ring that fades it out.
        for ([_]u32{ a, a + n, b, b, a + n, b + n }) |o| {
            out.tri_indices.appendAssumeCapacity(base + o);
        }
    }
}

/// A ring segment, feathered on every side it has.
pub const Arc = struct {
    centre: [2]f32,
    r_in: f32,
    r_out: f32,
    /// Degrees, `onCircle` convention. Either order; the band is drawn
    /// between them.
    a0: f32,
    a1: f32,
    /// Colour at `r_in` and at `r_out`. Equal for a flat band; different
    /// for the shadow that makes a circular groove look sunk.
    inner_color: [4]f32,
    outer_color: [4]f32,
    segments: usize = 64,
    /// Radial softening, in pixels.
    feather: f32 = FEATHER,
    /// Angular softening at each end, in degrees. Zero leaves the ends
    /// hard, which is what a tick mark wants; a level fill wants them
    /// soft so it dissolves into the groove instead of stopping dead.
    end_feather: f32 = 0,
};

pub fn arc(out: *element.DrawList, lc: *element.LayoutCtx, p: Arc) !void {
    const lo = @min(p.a0, p.a1);
    const hi = @max(p.a0, p.a1);
    if (!(hi - lo > 1e-4)) return;
    if (!(p.r_out > p.r_in) or p.segments == 0) return;

    // Columns run across the sweep; the two extra ones at the ends are
    // the angular feather and are only added when it is wanted.
    const soft_ends = p.end_feather > 1e-4;
    const inner_cols = p.segments + 1;
    const cols = inner_cols + @as(usize, if (soft_ends) 2 else 0);

    // Rows run outward: the radial feather, the band, the radial feather.
    const radii = [4]f32{ p.r_in - p.feather, p.r_in, p.r_out, p.r_out + p.feather };
    const row_col = [4][4]f32{
        withAlpha(p.inner_color, 0),
        p.inner_color,
        p.outer_color,
        withAlpha(p.outer_color, 0),
    };

    const base: u32 = @intCast(out.tris.items.len);
    try out.ensureUnusedTriCapacity(cols * 4);
    for (0..cols) |ci| {
        // Angle for this column, and whether it is a feather column.
        var a: f32 = undefined;
        var edge = false;
        if (soft_ends and ci == 0) {
            a = lo - p.end_feather;
            edge = true;
        } else if (soft_ends and ci == cols - 1) {
            a = hi + p.end_feather;
            edge = true;
        } else {
            const k = if (soft_ends) ci - 1 else ci;
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(p.segments));
            a = lo + (hi - lo) * t;
        }
        for (radii, row_col) |rr, cc| {
            out.appendTriAssumeCapacity(lc, .{
                .pos = onCircle(p.centre, @max(0, rr), a),
                .color = if (edge) withAlpha(cc, 0) else cc,
            });
        }
    }

    try out.tri_indices.ensureUnusedCapacity((cols - 1) * 3 * 6);
    for (0..cols - 1) |ci| {
        const c0: u32 = base + @as(u32, @intCast(ci)) * 4;
        const c1: u32 = c0 + 4;
        for (0..3) |ri| {
            const r0: u32 = @intCast(ri);
            for ([_]u32{
                c0 + r0,     c1 + r0,     c0 + r0 + 1,
                c1 + r0,     c1 + r0 + 1, c0 + r0 + 1,
            }) |idx| out.tri_indices.appendAssumeCapacity(idx);
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn testList() element.DrawList {
    return element.DrawList.init(testing.allocator);
}

/// A LayoutCtx is a big struct full of GPU-side handles, and none of the
/// helpers here read anything but `current_target_dispatch_index`.
fn testCtx() element.LayoutCtx {
    var lc: element.LayoutCtx = undefined;
    lc.current_target_dispatch_index = element.MAIN_TARGET;
    return lc;
}

test "gradientRect: four corners, two triangles, colours preserved" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();

    const a: [4]f32 = .{ 1, 0, 0, 1 };
    const b: [4]f32 = .{ 0, 1, 0, 0 };
    try gradientRect(&dl, &lc, 10, 20, 30, 40, a, a, b, b);

    try testing.expectEqual(@as(usize, 4), dl.tris.items.len);
    try testing.expectEqual(@as(usize, 6), dl.tri_indices.items.len);
    try testing.expectEqual(@as(f32, 10), dl.tris.items[0].pos[0]);
    try testing.expectEqual(@as(f32, 40), dl.tris.items[1].pos[0]);
    try testing.expectEqual(@as(f32, 60), dl.tris.items[2].pos[1]);
    // The bottom row carries the transparent colour — the ramp IS the
    // alpha, so losing it would silently produce a flat block.
    try testing.expectEqual(@as(f32, 1), dl.tris.items[0].color[3]);
    try testing.expectEqual(@as(f32, 0), dl.tris.items[2].color[3]);
    // Every index addresses a vertex that exists.
    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
}

test "gradientRect: a degenerate rect emits nothing" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    try gradientRect(&dl, &lc, 0, 0, 0, 10, CLEAR, CLEAR, CLEAR, CLEAR);
    try gradientRect(&dl, &lc, 0, 0, 10, -4, CLEAR, CLEAR, CLEAR, CLEAR);
    try testing.expectEqual(@as(usize, 0), dl.tris.items.len);
}

test "groove: the shadow is on top and the lip is on the bottom" {
    // The one thing that would look wrong rather than read wrong: a
    // recess lit from below. One light, from above, everywhere.
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    try groove(&dl, &lc, 0, 100, 200, 40, false);

    try testing.expect(dl.tris.items.len >= 8);
    // First quad: the top shadow, opaque-ish at y=100 and clear below.
    try testing.expectEqual(@as(f32, 100), dl.tris.items[0].pos[1]);
    try testing.expect(dl.tris.items[0].color[3] > dl.tris.items[2].color[3]);
    try testing.expectEqual(@as(f32, 0), dl.tris.items[0].color[0]); // black

    // Second quad: the lip, clear at its top and lit at the bottom edge.
    const lip = dl.tris.items[4..8];
    try testing.expect(lip[3].pos[1] > lip[0].pos[1]);
    try testing.expect(lip[3].color[3] > lip[0].color[3]);
    try testing.expectEqual(@as(f32, 1), lip[3].color[0]); // white
    // And it is much weaker than the shadow — bounce, not a glow.
    try testing.expect(lip[3].color[3] < dl.tris.items[0].color[3] * 0.5);
}

test "groove: ends are opt-in, because a vertical slot has none" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    try groove(&dl, &lc, 0, 0, 200, 40, false);
    const without = dl.tris.items.len;

    dl.clearRetainingCapacity();
    try groove(&dl, &lc, 0, 0, 200, 40, true);
    try testing.expectEqual(without + 8, dl.tris.items.len);
}

test "groove: a shallow groove does not draw a shadow deeper than itself" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    try groove(&dl, &lc, 0, 0, 200, 3, false);
    for (dl.tris.items) |v| {
        try testing.expect(v.pos[1] >= 0);
        try testing.expect(v.pos[1] <= 3.001);
    }
}

test "edgeFade: 1 in the middle, 0 at both ends, smooth between" {
    try testing.expectApproxEqAbs(@as(f32, 1), edgeFade(0.5, 0.2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), edgeFade(0.0, 0.2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), edgeFade(1.0, 0.2), 1e-6);
    // Symmetric, and monotone on the way in.
    try testing.expectApproxEqAbs(edgeFade(0.05, 0.2), edgeFade(0.95, 0.2), 1e-6);
    try testing.expect(edgeFade(0.05, 0.2) < edgeFade(0.15, 0.2));
    // No edge means no fade — the caller opts in.
    try testing.expectApproxEqAbs(@as(f32, 1), edgeFade(0.0, 0), 1e-6);
}

fn redAt(deg: f32) [3]f32 {
    _ = deg;
    return .{ 1, 0, 0 };
}

test "hueDisc: a solid fan plus a ring that fades to nothing" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const SEG = 8;
    try hueDisc(&dl, &lc, .{ 50, 50 }, 20, .{ 0, 0, 0, 1 }, SEG, redAt);

    // centre + rim + feather ring.
    try testing.expectEqual(@as(usize, 1 + SEG * 2), dl.tris.items.len);
    // The rim is opaque and the feather ring is not — without that the
    // edge is the hard polygon it was before.
    try testing.expectEqual(@as(f32, 1), dl.tris.items[1].color[3]);
    try testing.expectEqual(@as(f32, 0), dl.tris.items[1 + SEG].color[3]);
    // And the feather sits OUTSIDE the rim, not inside it — otherwise it
    // eats the wheel instead of softening it.
    const rim = dl.tris.items[1].pos;
    const feath = dl.tris.items[1 + SEG].pos;
    try testing.expect(@abs(feath[1] - 50) > @abs(rim[1] - 50));

    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
    try testing.expectEqual(@as(usize, SEG * 9), dl.tri_indices.items.len);
}

test "arc: four radial rows, with the outer two transparent" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const col: [4]f32 = .{ 1, 1, 1, 0.9 };
    try arc(&dl, &lc, .{
        .centre = .{ 0, 0 },
        .r_in = 20,
        .r_out = 24,
        .a0 = -45,
        .a1 = 45,
        .inner_color = col,
        .outer_color = col,
        .segments = 4,
    });

    try testing.expectEqual(@as(usize, 5 * 4), dl.tris.items.len);
    // Row order per column: feather, band, band, feather.
    try testing.expectEqual(@as(f32, 0), dl.tris.items[0].color[3]);
    try testing.expectApproxEqAbs(@as(f32, 0.9), dl.tris.items[1].color[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), dl.tris.items[2].color[3], 1e-6);
    try testing.expectEqual(@as(f32, 0), dl.tris.items[3].color[3]);
    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
}

test "arc: soft ends add a transparent column at each end" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const col: [4]f32 = .{ 1, 1, 1, 1 };
    const p: Arc = .{
        .centre = .{ 0, 0 },
        .r_in = 20,
        .r_out = 24,
        .a0 = 0,
        .a1 = 90,
        .inner_color = col,
        .outer_color = col,
        .segments = 4,
    };
    try arc(&dl, &lc, p);
    const hard = dl.tris.items.len;

    dl.clearRetainingCapacity();
    var soft = p;
    soft.end_feather = 2;
    try arc(&dl, &lc, soft);
    try testing.expectEqual(hard + 8, dl.tris.items.len);

    // Every vertex of the first and last column is transparent, so the
    // band dissolves rather than stopping dead.
    for (dl.tris.items[0..4]) |v| try testing.expectEqual(@as(f32, 0), v.color[3]);
    for (dl.tris.items[dl.tris.items.len - 4 ..]) |v| {
        try testing.expectEqual(@as(f32, 0), v.color[3]);
    }
    // Rule 1: the MIDDLE is still opaque, or "it fades" would be true of
    // an arc that never drew anything.
    try testing.expectEqual(@as(f32, 1), dl.tris.items[9].color[3]);
}

test "arc: a radial gradient is what makes a circular groove look sunk" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    try arc(&dl, &lc, .{
        .centre = .{ 0, 0 },
        .r_in = 20,
        .r_out = 24,
        .a0 = 0,
        .a1 = 90,
        .inner_color = .{ 0, 0, 0, 0.0 },
        .outer_color = .{ 0, 0, 0, 0.3 },
        .segments = 2,
    });
    try testing.expectApproxEqAbs(@as(f32, 0), dl.tris.items[1].color[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), dl.tris.items[2].color[3], 1e-6);
}

test "arc: degenerate inputs emit nothing rather than a fold" {
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const col: [4]f32 = .{ 1, 1, 1, 1 };
    const base: Arc = .{
        .centre = .{ 0, 0 },
        .r_in = 20,
        .r_out = 24,
        .a0 = 30,
        .a1 = 30,
        .inner_color = col,
        .outer_color = col,
    };
    try arc(&dl, &lc, base); // zero sweep
    var inverted = base;
    inverted.a1 = 90;
    inverted.r_out = 10; // r_out < r_in
    try arc(&dl, &lc, inverted);
    var none = base;
    none.a1 = 90;
    none.segments = 0;
    try arc(&dl, &lc, none);
    try testing.expectEqual(@as(usize, 0), dl.tris.items.len);
}
