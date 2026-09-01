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
    ///
    /// Capped in pixels as well as proportioned, for the same reason
    /// `TOP` is: a lip occludes a fixed distance into the recess, not a
    /// share of its length. Without the cap a 300px slider got 42px of
    /// gloom at each end, which reads as a vignette rather than a lip.
    pub const END: [4]f32 = .{ 0.0, 0.0, 0.0, 0.30 };
    pub const END_FRACTION: f32 = 0.14;
    pub const END_MAX_PX: f32 = 16.0;
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
        const end_w = @min(@min(w * 0.5, w * Groove.END_FRACTION), Groove.END_MAX_PX);
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

/// A solid circle whose rim fades over `FEATHER` pixels.
///
/// Use this rather than a quad with `radius = size / 2` whenever the
/// circle is small enough to look at. That quad IS a circle — `quad.frag`
/// resolves it exactly — but its anti-aliasing band is centred on the
/// edge, and the edge is the quad's own boundary, so the outer half of
/// the band falls outside the rasterised rect and is simply lost. A 14px
/// slider thumb came out fourteen rows tall with one soft row at the top
/// and none at the bottom, which reads as a circle with a flat cap.
/// Chris, 2026-09-01: "the round thumb tack top is chopped off. Looks
/// like it is one pixel row missing at the top."
///
/// Here the band lives in the geometry, so it is symmetric and complete.
pub fn disc(
    out: *element.DrawList,
    lc: *element.LayoutCtx,
    centre: [2]f32,
    r: f32,
    col: [4]f32,
    segments: usize,
) !void {
    if (!(r > 0) or segments < 3) return;
    const base: u32 = @intCast(out.tris.items.len);
    const n: u32 = @intCast(segments);

    try out.ensureUnusedTriCapacity(1 + segments * 2);
    out.appendTriAssumeCapacity(lc, .{ .pos = centre, .color = col });
    for (0..2) |ring| {
        const rr = if (ring == 0) r else r + FEATHER;
        const cc = if (ring == 0) col else withAlpha(col, 0);
        for (0..segments) |i| {
            const deg = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * 360.0;
            out.appendTriAssumeCapacity(lc, .{ .pos = onCircle(centre, rr, deg), .color = cc });
        }
    }

    try out.tri_indices.ensureUnusedCapacity(segments * 9);
    for (0..segments) |i| {
        const a: u32 = 1 + @as(u32, @intCast(i));
        const b: u32 = 1 + @as(u32, @intCast((i + 1) % segments));
        for ([_]u32{ 0, a, b }) |o| out.tri_indices.appendAssumeCapacity(base + o);
        for ([_]u32{ a, a + n, b, b, a + n, b + n }) |o| {
            out.tri_indices.appendAssumeCapacity(base + o);
        }
    }
}

/// A hue wheel, optionally darkened toward its rim.
pub const HueDisc = struct {
    centre: [2]f32,
    r: f32,
    centre_color: [4]f32,
    segments: usize = 72,
    /// A function pointer rather than a closure because Zig has neither.
    /// The one caller wants HSV; a future one wanting a different ramp
    /// supplies its own, and `relief` never learns what a hue is.
    hueAt: *const fn (deg: f32) [3]f32,
    /// How far the rim is darkened toward black, 0..1, over
    /// `shade_px` inward. Zero for a flat wheel.
    ///
    /// **Folded into this mesh on purpose.** It was a separate dark arc
    /// laid over the disc, and the two edges did not line up: the arc
    /// ended hard at the rim while the disc was still fading out over
    /// the pixel beyond it, so the outermost ring came out brighter than
    /// the darkened one just inside it. Against saturated hues that
    /// bright-on-dark fringe reads as compression noise — Chris,
    /// 2026-09-01: "a slight gamma aliasing issue on the color wheel
    /// outside edge. It reads as jpeg artifacting."
    ///
    /// One mesh has one edge. The rim colour is MIXED toward black
    /// rather than composited under a black overlay, so the pixel is a
    /// single opaque value that then fades — one blend at the edge
    /// instead of two.
    rim_shade: f32 = 0,
    shade_px: f32 = 0,
};

pub fn hueDisc(out: *element.DrawList, lc: *element.LayoutCtx, p: HueDisc) !void {
    if (!(p.r > 0) or p.segments < 3) return;

    const shaded = p.rim_shade > 1e-4 and p.shade_px > 1e-4 and p.shade_px < p.r;
    const k = 1.0 - std.math.clamp(p.rim_shade, 0, 1);

    // Radius, brightness and alpha for each ring, outward from the middle.
    var ring_r: [3]f32 = undefined;
    var ring_k: [3]f32 = undefined;
    var ring_a: [3]f32 = undefined;
    const rings: usize = if (shaded) 3 else 2;
    if (shaded) {
        ring_r = .{ p.r - p.shade_px, p.r, p.r + FEATHER };
        ring_k = .{ 1.0, k, k };
        ring_a = .{ 1.0, 1.0, 0.0 };
    } else {
        ring_r = .{ p.r, p.r + FEATHER, 0 };
        ring_k = .{ 1.0, 1.0, 0 };
        ring_a = .{ 1.0, 0.0, 0 };
    }

    const base: u32 = @intCast(out.tris.items.len);
    const n: u32 = @intCast(p.segments);

    try out.ensureUnusedTriCapacity(1 + p.segments * rings);
    out.appendTriAssumeCapacity(lc, .{ .pos = p.centre, .color = p.centre_color });
    for (0..rings) |ring| {
        for (0..p.segments) |i| {
            const deg = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(p.segments)) * 360.0;
            const rgb = p.hueAt(deg);
            const m = ring_k[ring];
            out.appendTriAssumeCapacity(lc, .{
                .pos = onCircle(p.centre, ring_r[ring], deg),
                .color = .{ rgb[0] * m, rgb[1] * m, rgb[2] * m, ring_a[ring] },
            });
        }
    }

    try out.tri_indices.ensureUnusedCapacity(p.segments * (3 + (rings - 1) * 6));
    for (0..p.segments) |i| {
        const a: u32 = 1 + @as(u32, @intCast(i));
        const b: u32 = 1 + @as(u32, @intCast((i + 1) % p.segments));
        // The solid fan out to the innermost ring.
        for ([_]u32{ 0, a, b }) |o| out.tri_indices.appendAssumeCapacity(base + o);
        // Then a strip between each pair of rings.
        for (0..rings - 1) |ring| {
            const off: u32 = @intCast(ring * p.segments);
            for ([_]u32{ a + off, a + off + n, b + off, b + off, a + off + n, b + off + n }) |o| {
                out.tri_indices.appendAssumeCapacity(base + o);
            }
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
    //
    // A zero feather drops the two feather rows ENTIRELY rather than
    // emitting them at the band's own radii. Keeping them would put two
    // vertices at the same position with different alphas — degenerate
    // triangles carrying a hard discontinuity, which rasterise as
    // speckle along the edge.
    const soft_radial = p.feather > 1e-4;
    const rows: usize = if (soft_radial) 4 else 2;
    var radii: [4]f32 = undefined;
    var row_col: [4][4]f32 = undefined;
    if (soft_radial) {
        radii = .{ p.r_in - p.feather, p.r_in, p.r_out, p.r_out + p.feather };
        row_col = .{
            withAlpha(p.inner_color, 0),
            p.inner_color,
            p.outer_color,
            withAlpha(p.outer_color, 0),
        };
    } else {
        radii[0] = p.r_in;
        radii[1] = p.r_out;
        row_col[0] = p.inner_color;
        row_col[1] = p.outer_color;
    }

    const base: u32 = @intCast(out.tris.items.len);
    try out.ensureUnusedTriCapacity(cols * rows);
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
        for (radii[0..rows], row_col[0..rows]) |rr, cc| {
            out.appendTriAssumeCapacity(lc, .{
                .pos = onCircle(p.centre, @max(0, rr), a),
                .color = if (edge) withAlpha(cc, 0) else cc,
            });
        }
    }

    try out.tri_indices.ensureUnusedCapacity((cols - 1) * (rows - 1) * 6);
    for (0..cols - 1) |ci| {
        const c0: u32 = base + @as(u32, @intCast(ci * rows));
        const c1: u32 = c0 + @as(u32, @intCast(rows));
        for (0..rows - 1) |ri| {
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
    try hueDisc(&dl, &lc, .{
        .centre = .{ 50, 50 },
        .r = 20,
        .centre_color = .{ 0, 0, 0, 1 },
        .segments = SEG,
        .hueAt = redAt,
    });

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

test "hueDisc: the rim shade is IN the mesh, so there is one edge" {
    // The artifact this exists for. The shade used to be a separate dark
    // arc laid on top, ending hard at the rim while the disc was still
    // fading over the pixel beyond it — so the outermost ring came out
    // BRIGHTER than the darkened one just inside. Against saturated hues
    // that reads as compression noise.
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const SEG = 8;
    try hueDisc(&dl, &lc, .{
        .centre = .{ 50, 50 },
        .r = 20,
        .centre_color = .{ 0, 0, 0, 1 },
        .segments = SEG,
        .hueAt = redAt,
        .rim_shade = 0.25,
        .shade_px = 5,
    });

    // centre + three rings: full hue, darkened rim, darkened feather.
    try testing.expectEqual(@as(usize, 1 + SEG * 3), dl.tris.items.len);
    const inner = dl.tris.items[1];
    const rim = dl.tris.items[1 + SEG];
    const feath = dl.tris.items[1 + SEG * 2];

    // Brightness falls outward and the two outer rings AGREE, so the
    // fade carries a single colour instead of crossing a step.
    try testing.expectApproxEqAbs(@as(f32, 1.0), inner.color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), rim.color[0], 1e-6);
    try testing.expectApproxEqAbs(rim.color[0], feath.color[0], 1e-6);
    // Only the outermost is transparent.
    try testing.expectEqual(@as(f32, 1), inner.color[3]);
    try testing.expectEqual(@as(f32, 1), rim.color[3]);
    try testing.expectEqual(@as(f32, 0), feath.color[3]);
    // And the radii step outward, so no two rings sit on each other.
    try testing.expect(@abs(inner.pos[1] - 50) < @abs(rim.pos[1] - 50));
    try testing.expect(@abs(rim.pos[1] - 50) < @abs(feath.pos[1] - 50));

    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
}

test "disc: the anti-aliasing band is in the geometry, not off the edge" {
    // Why a thumb is not a `radius = size/2` quad: that circle's AA band
    // is centred on the quad's own boundary, so its outer half is never
    // rasterised and the circle comes out with a flat cap.
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const SEG = 8;
    try disc(&dl, &lc, .{ 10, 10 }, 7, .{ 1, 1, 1, 1 }, SEG);

    try testing.expectEqual(@as(usize, 1 + SEG * 2), dl.tris.items.len);
    // The rim is opaque, the ring beyond it is not, and it really is
    // BEYOND — a feather drawn inside the radius would eat the shape.
    try testing.expectEqual(@as(f32, 1), dl.tris.items[1].color[3]);
    try testing.expectEqual(@as(f32, 0), dl.tris.items[1 + SEG].color[3]);
    const rim_d = @abs(dl.tris.items[1].pos[1] - 10);
    const feath_d = @abs(dl.tris.items[1 + SEG].pos[1] - 10);
    try testing.expectApproxEqAbs(@as(f32, 7), rim_d, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 7 + FEATHER), feath_d, 1e-5);
    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
}

test "arc: a zero feather drops the feather rows instead of doubling them" {
    // Emitting them at the band's own radii puts two vertices in the
    // same place with different alphas — degenerate triangles carrying a
    // hard discontinuity, which speckle along the edge.
    var dl = testList();
    defer dl.deinit();
    var lc = testCtx();
    const col: [4]f32 = .{ 1, 1, 1, 0.5 };
    try arc(&dl, &lc, .{
        .centre = .{ 0, 0 },
        .r_in = 20,
        .r_out = 24,
        .a0 = 0,
        .a1 = 90,
        .inner_color = col,
        .outer_color = col,
        .segments = 4,
        .feather = 0,
    });

    // Two rows, not four.
    try testing.expectEqual(@as(usize, 5 * 2), dl.tris.items.len);
    // No two vertices coincide with different alphas.
    for (dl.tris.items) |v| try testing.expectApproxEqAbs(@as(f32, 0.5), v.color[3], 1e-6);
    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
    try testing.expectEqual(@as(usize, 4 * 1 * 6), dl.tri_indices.items.len);
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
