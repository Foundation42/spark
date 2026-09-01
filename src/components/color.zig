//! Colour maths for the grading widgets — shared by `:::trackball` and
//! `:::color_bars`, which are two RENDERINGS of the same three numbers.
//!
//! Nothing here draws or allocates. It is the part that has to be right,
//! so it is the part that is a pure function with a test beside it.
//!
//! ## What a trackball actually is
//!
//! Three channel values (r, g, b over some range) re-parameterised as:
//!
//!   * `master` — their mean. The tonal level of this range.
//!   * `hue` + `push` — the direction and strength of the colour balance,
//!     i.e. how far the three numbers spread apart and which way.
//!
//! `forward` goes (hue, push, master) → channels; `inverse` goes back.
//! A document binds the CHANNELS, so two widgets on the same paths agree
//! without either knowing the other exists — open `primaries` and `bars`
//! together and drag one.
//!
//! ## One deliberate difference from `web/apps/color-grader`
//!
//! The JS pushes along `hsv2rgb(h,1,1)` centred on its own mean, whose
//! LENGTH varies with hue: it is `sqrt(2/3)` at the six primaries and
//! secondaries and about 0.71 halfway between, so an identical push at
//! 30° lands 13% weaker than the same push at 0°. Worse, it makes the
//! round trip lossy — `inverse(forward(h, s, M))` hands back a smaller
//! `s` than it was given, so the puck creeps toward the centre every time
//! a value round-trips through state.
//!
//! Here the direction is NORMALISED, so push strength means the same
//! thing at every hue and the round trip is exact. The two UIs still
//! agree, because what they mirror is the channel values and not the
//! puck. See the round-trip test at the bottom.

const std = @import("std");

/// `|cen|` for a normalised push — the length the JS gets at a pure
/// primary, kept as the scale factor so the two implementations produce
/// the same numbers where the JS is self-consistent.
pub const PURE_MAG: f32 = 0.816496580927726; // sqrt(2/3)

/// How much of the available headroom a full push spends. A push of 1.0
/// at `neutral` moves a channel by `PUSH_SCALE` of the distance to the
/// nearer end of the range, so the disc rim stays inside the legal range
/// with room to still raise the master afterwards.
pub const PUSH_SCALE: f32 = 0.65;

/// Clamp that survives an inverted range rather than tripping
/// `std.math.clamp`'s assert on a document typo. Same guard, and the
/// same reasoning, as `grip.clampRange`.
pub fn clamp(v: f32, lo: f32, hi: f32) f32 {
    if (hi < lo) return lo;
    if (!std.math.isFinite(v)) return lo;
    return std.math.clamp(v, lo, hi);
}

// ── HSV ─────────────────────────────────────────────────────────────

pub const Hsv = struct { h: f32, s: f32, v: f32 };

/// `h` in degrees (any sign, wrapped), `s`/`v` in 0..1.
pub fn hsv2rgb(h_deg: f32, s: f32, v: f32) [3]f32 {
    const sc = clamp(s, 0, 1);
    const vc = clamp(v, 0, 1);
    // `@mod` takes the sign of the divisor, so a negative hue wraps up
    // into 0..360 rather than producing a negative sector index.
    const h = @mod(h_deg, 360.0) / 60.0;
    const i = @floor(h);
    const f = h - i;
    const p = vc * (1 - sc);
    const q = vc * (1 - sc * f);
    const t = vc * (1 - sc * (1 - f));
    const sector: u32 = @intFromFloat(@min(5.0, @max(0.0, i)));
    return switch (sector) {
        0 => .{ vc, t, p },
        1 => .{ q, vc, p },
        2 => .{ p, vc, t },
        3 => .{ p, q, vc },
        4 => .{ t, p, vc },
        else => .{ vc, p, q },
    };
}

pub fn rgb2hsv(r: f32, g: f32, b: f32) Hsv {
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f32 = 0;
    if (d > 1e-9) {
        if (mx == r) {
            h = 60 * @mod((g - b) / d, 6.0);
        } else if (mx == g) {
            h = 60 * ((b - r) / d + 2);
        } else {
            h = 60 * ((r - g) / d + 4);
        }
    }
    if (h < 0) h += 360;
    return .{ .h = h, .s = if (mx > 1e-9) d / mx else 0, .v = mx };
}

// ── The balance ─────────────────────────────────────────────────────

pub const Balance = struct {
    /// The channel range. Every written value is clamped into it.
    min: f32 = 0,
    max: f32 = 1,
    /// The value that means "no change" — 0 for a signed lift, 1 for a
    /// multiplicative gamma or gain. It is the master's home and the
    /// origin the push is measured from, so it is NOT in general the
    /// midpoint of the range: gamma runs 0.4..2.5 around a neutral of 1.
    neutral: f32 = 1,

    /// Balance direction, in degrees clockwise from straight up. Same
    /// convention as the puck's screen position, so the disc is a
    /// literal picture of this number.
    hue: f32 = 0,
    /// Balance strength, 0 at the centre to 1 at the rim.
    push: f32 = 0,
    /// The tonal level — the mean of the three channels.
    master: f32 = 1,

    /// The three channel values, r/g/b. This is the authoritative pair
    /// of state with (hue, push, master); the two are kept in step by
    /// `forward` and `inverse` and either may be driven.
    cur: [3]f32 = .{ 1, 1, 1 },

    /// Scale from a push of 1.0 to a channel offset. Uses the NEARER
    /// end of the range so a full push cannot pin one channel at a
    /// limit while the others still have room — which would break the
    /// round trip in a way the user reads as the puck sticking.
    pub fn pushScale(self: Balance) f32 {
        const room = @min(self.neutral - self.min, self.max - self.neutral);
        return @max(1e-4, room) * PUSH_SCALE;
    }

    /// (hue, push, master) → the three channels.
    pub fn forward(self: *Balance) void {
        const dir = hsv2rgb(self.hue, 1, 1);
        const mean = (dir[0] + dir[1] + dir[2]) / 3.0;
        var cen: [3]f32 = .{ dir[0] - mean, dir[1] - mean, dir[2] - mean };
        const mag = @sqrt(cen[0] * cen[0] + cen[1] * cen[1] + cen[2] * cen[2]);
        // Normalise, so push strength means the same at every hue. See
        // the module header — the un-normalised version makes the round
        // trip lossy and the puck creeps inward.
        if (mag > 1e-6) {
            for (&cen) |*v| v.* = v.* / mag * PURE_MAG;
        }
        const scale = self.pushScale() * self.push;
        for (&self.cur, cen) |*out, c| {
            out.* = clamp(self.master + c * scale, self.min, self.max);
        }
    }

    /// The three channels → (hue, push, master).
    pub fn inverse(self: *Balance) void {
        self.master = (self.cur[0] + self.cur[1] + self.cur[2]) / 3.0;
        const off: [3]f32 = .{
            self.cur[0] - self.master,
            self.cur[1] - self.master,
            self.cur[2] - self.master,
        };
        const mag = @sqrt(off[0] * off[0] + off[1] * off[1] + off[2] * off[2]);
        self.push = clamp(mag / (self.pushScale() * PURE_MAG), 0, 1);
        // A hue is meaningless with no push behind it, and reading one
        // out of the rounding noise would make the puck spin as it
        // approached the centre. Keep the last one instead.
        if (self.push > 1e-3) {
            const mn = @min(off[0], @min(off[1], off[2]));
            self.hue = rgb2hsv(off[0] - mn, off[1] - mn, off[2] - mn).h;
        }
    }

    /// Drive one channel directly — the bars view, or an external write
    /// landing on one of the three bound paths. Re-derives the disc.
    pub fn setChannel(self: *Balance, ch: usize, v: f32) void {
        self.cur[ch] = clamp(v, self.min, self.max);
        self.inverse();
    }

    /// Drive all three at once, without three redundant `inverse` runs.
    pub fn setChannels(self: *Balance, v: [3]f32) void {
        for (&self.cur, v) |*out, in| out.* = clamp(in, self.min, self.max);
        self.inverse();
    }

    /// Home: no push, master back to neutral.
    pub fn neutralise(self: *Balance) void {
        self.push = 0;
        self.master = self.neutral;
        self.forward();
    }

    /// Where the channel sits in the range, 0..1. The bars and the level
    /// arc are both drawn from this.
    pub fn fractionOf(self: Balance, v: f32) f32 {
        const span = self.max - self.min;
        if (!(span > 0)) return 0.5;
        return clamp((v - self.min) / span, 0, 1);
    }

    /// The swatch the puck wears: the balance hue, lifted off black so a
    /// blue push is still legible against a dark disc.
    pub fn puckColor(self: Balance) [4]f32 {
        const c = hsv2rgb(self.hue, @min(1, self.push), 1);
        return .{
            0.35 + 0.65 * c[0],
            0.35 + 0.65 * c[1],
            0.35 + 0.65 * c[2],
            1.0,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "hsv2rgb: the six corners" {
    const cases = [_]struct { h: f32, rgb: [3]f32 }{
        .{ .h = 0, .rgb = .{ 1, 0, 0 } },
        .{ .h = 60, .rgb = .{ 1, 1, 0 } },
        .{ .h = 120, .rgb = .{ 0, 1, 0 } },
        .{ .h = 180, .rgb = .{ 0, 1, 1 } },
        .{ .h = 240, .rgb = .{ 0, 0, 1 } },
        .{ .h = 300, .rgb = .{ 1, 0, 1 } },
    };
    for (cases) |c| {
        const got = hsv2rgb(c.h, 1, 1);
        for (got, c.rgb) |g, want| try testing.expectApproxEqAbs(want, g, 1e-5);
    }
}

test "hsv2rgb: a negative hue wraps rather than falling off the sector table" {
    // `@mod` takes the sign of the divisor. Getting this wrong indexes
    // the switch with a negative sector, which in a release build is a
    // silent wrong colour rather than a crash.
    const neg = hsv2rgb(-60, 1, 1);
    const pos = hsv2rgb(300, 1, 1);
    for (neg, pos) |a, b| try testing.expectApproxEqAbs(b, a, 1e-5);

    // And 360 is 0, not a sixth sector.
    const wrapped = hsv2rgb(360, 1, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), wrapped[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), wrapped[1], 1e-5);
}

test "hsv2rgb: zero saturation is grey at v" {
    const g = hsv2rgb(210, 0, 0.4);
    for (g) |v| try testing.expectApproxEqAbs(@as(f32, 0.4), v, 1e-5);
}

test "rgb2hsv: inverts hsv2rgb around the wheel" {
    var h: f32 = 0;
    while (h < 360) : (h += 17) {
        const rgb = hsv2rgb(h, 1, 1);
        const back = rgb2hsv(rgb[0], rgb[1], rgb[2]);
        try testing.expectApproxEqAbs(h, back.h, 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 1), back.s, 1e-5);
    }
}

test "balance: neutral means all three channels sit on neutral" {
    var b: Balance = .{ .min = -0.3, .max = 0.3, .neutral = 0 };
    b.neutralise();
    for (b.cur) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), b.master, 1e-6);
}

test "balance: a push spreads the channels but leaves the mean alone" {
    // The property that makes the two controls separable: the disc
    // moves colour, the dial moves level, and neither touches the other.
    var b: Balance = .{ .min = 0, .max = 2, .neutral = 1, .master = 1.4 };
    b.hue = 0; // red
    b.push = 1;
    b.forward();

    const mean = (b.cur[0] + b.cur[1] + b.cur[2]) / 3.0;
    try testing.expectApproxEqAbs(@as(f32, 1.4), mean, 1e-5);
    // Rule 1: the push really did something, so "the mean held" is
    // about the centring and not about a push of zero.
    try testing.expect(b.cur[0] > b.cur[1] + 0.1);
    try testing.expectApproxEqAbs(b.cur[1], b.cur[2], 1e-5);
}

test "balance: forward/inverse round-trips at every hue" {
    // THE reason `forward` normalises the direction. With the JS's
    // un-normalised push this fails everywhere except the six corners:
    // a push of 1.0 at 30° comes back as 0.87, so a value that
    // round-trips through state drags the puck toward the centre.
    var h: f32 = 0;
    while (h < 360) : (h += 11) {
        var b: Balance = .{ .min = -0.3, .max = 0.3, .neutral = 0 };
        b.hue = h;
        b.push = 0.8;
        b.master = 0.05;
        b.forward();

        // Rule 1 again — the offsets must be real for the round trip to
        // be worth asserting.
        const spread = @max(b.cur[0], @max(b.cur[1], b.cur[2])) -
            @min(b.cur[0], @min(b.cur[1], b.cur[2]));
        try testing.expect(spread > 0.05);

        b.inverse();
        try testing.expectApproxEqAbs(@as(f32, 0.8), b.push, 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 0.05), b.master, 1e-5);
        try testing.expectApproxEqAbs(h, b.hue, 0.05);
    }
}

test "balance: pushScale uses the nearer end, so a full push stays in range" {
    // gamma's range is lopsided — 0.4..2.5 around a neutral of 1, so
    // there is 0.6 below and 1.5 above. A push scaled by the FAR end
    // would drive the low channel under `min` and clamp, which breaks
    // the round trip and sticks the puck.
    var b: Balance = .{ .min = 0.4, .max = 2.5, .neutral = 1 };
    b.hue = 0;
    b.push = 1;
    b.master = 1;
    b.forward();
    for (b.cur) |v| {
        try testing.expect(v > b.min);
        try testing.expect(v < b.max);
    }
    b.inverse();
    try testing.expectApproxEqAbs(@as(f32, 1), b.push, 1e-3);
}

test "balance: the hue survives a trip through the centre" {
    // Pulling the puck to the middle and back out must not spin the
    // hue, which is what reading it out of the rounding noise would do.
    var b: Balance = .{ .min = -0.3, .max = 0.3, .neutral = 0 };
    b.hue = 210;
    b.push = 0.7;
    b.forward();

    b.push = 0;
    b.forward();
    b.inverse(); // push is 0 — the hue must be kept, not recomputed
    try testing.expectApproxEqAbs(@as(f32, 210), b.hue, 0.05);
}

test "balance: setChannel drives the disc from one number" {
    // The bars view, and any external write landing on one bound path.
    var b: Balance = .{ .min = 0, .max = 2, .neutral = 1 };
    b.neutralise();
    try testing.expectApproxEqAbs(@as(f32, 0), b.push, 1e-6);

    b.setChannel(0, 1.4); // more red
    try testing.expect(b.push > 0.1);
    // Mean of (1.4, 1, 1) — the master rises with it, which is correct:
    // one channel up IS a brighter range as well as a warmer one.
    try testing.expectApproxEqAbs(@as(f32, (1.4 + 1 + 1) / 3.0), b.master, 1e-5);
    // Red is hue 0.
    try testing.expectApproxEqAbs(@as(f32, 0), b.hue, 0.5);
}

test "balance: an out-of-range channel is clamped rather than believed" {
    var b: Balance = .{ .min = 0, .max = 1, .neutral = 0.5 };
    b.setChannel(1, 99);
    try testing.expectApproxEqAbs(@as(f32, 1), b.cur[1], 1e-6);
    b.setChannel(1, -99);
    try testing.expectApproxEqAbs(@as(f32, 0), b.cur[1], 1e-6);
}

test "balance: a degenerate range does not divide by nothing" {
    var b: Balance = .{ .min = 1, .max = 1, .neutral = 1 };
    b.push = 1;
    b.forward();
    for (b.cur) |v| try testing.expect(std.math.isFinite(v));
    b.inverse();
    try testing.expect(std.math.isFinite(b.push));
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.fractionOf(1), 1e-6);
}

test "balance: an inverted range is survived, not asserted on" {
    try testing.expectApproxEqAbs(@as(f32, 5), clamp(9, 5, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3), clamp(3, 0, 10), 1e-6);
    // A NaN reaching a clamp would propagate into vertex positions and
    // take out the whole triangle batch, not just this widget.
    try testing.expectApproxEqAbs(@as(f32, 0), clamp(std.math.nan(f32), 0, 1), 1e-6);
}

// ── The other parameterisation ──────────────────────────────────────

/// Three channels as an ABSOLUTE colour: hue, saturation, value.
///
/// `Balance` is for a signed push around a neutral, which is what a
/// grading primary is. A TINT is not that. `render/light/sun_tint` runs
/// 0..1 per channel with a default of white — and white is the TOP of
/// that range, so there is no headroom above neutral to push into and
/// `Balance.pushScale` collapses to nothing. A trackball there would be
/// inert, which is why `hud/light.md` and `hud/sky.md` still spend three
/// sliders on every colour they own.
///
/// So: the same three numbers, read as a colour instead of as an offset.
pub const Swatch = struct {
    min: f32 = 0,
    max: f32 = 1,

    /// Degrees, `relief.onCircle` convention — the same one the disc is
    /// drawn in, so the puck sits on the colour it names.
    hue: f32 = 0,
    /// 0 at the centre (grey) to 1 at the rim.
    sat: f32 = 0,
    /// 0 black to 1 full.
    val: f32 = 1,

    cur: [3]f32 = .{ 1, 1, 1 },

    /// (hue, sat, val) → the three channels.
    pub fn forward(self: *Swatch) void {
        const rgb = hsv2rgb(self.hue, self.sat, self.val);
        const span = self.max - self.min;
        for (&self.cur, rgb) |*out, v| {
            out.* = clamp(self.min + v * span, self.min, self.max);
        }
    }

    /// The three channels → (hue, sat, val).
    ///
    /// Hue and saturation are UNDEFINED at the ends — every hue is black
    /// at value 0, and every hue is white at saturation 0 — so they are
    /// kept rather than recomputed out of the rounding noise there. Drag
    /// a picker down to black and back up and the colour returns; without
    /// this it would come back grey, having forgotten what it was.
    pub fn inverse(self: *Swatch) void {
        const span = self.max - self.min;
        if (!(span > 0)) return;
        var t: [3]f32 = undefined;
        for (&t, self.cur) |*out, v| out.* = clamp((v - self.min) / span, 0, 1);

        const hsv = rgb2hsv(t[0], t[1], t[2]);
        self.val = hsv.v;
        if (hsv.v > 1e-3) self.sat = hsv.s;
        if (hsv.v > 1e-3 and hsv.s > 1e-3) self.hue = hsv.h;
    }

    pub fn setChannels(self: *Swatch, v: [3]f32) void {
        for (&self.cur, v) |*out, in| out.* = clamp(in, self.min, self.max);
        self.inverse();
    }

    /// The colour itself, for a swatch or a puck — always at full value
    /// so the chip stays legible when the picker is turned down.
    pub fn chip(self: Swatch) [4]f32 {
        const rgb = hsv2rgb(self.hue, self.sat, 1);
        return .{ rgb[0], rgb[1], rgb[2], 1.0 };
    }
};

test "swatch: white is saturation zero at full value" {
    var s: Swatch = .{};
    s.setChannels(.{ 1, 1, 1 });
    try testing.expectApproxEqAbs(@as(f32, 0), s.sat, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), s.val, 1e-5);
}

test "swatch: forward/inverse round-trips around the wheel" {
    var h: f32 = 0;
    while (h < 360) : (h += 13) {
        var s: Swatch = .{};
        s.hue = h;
        s.sat = 0.7;
        s.val = 0.8;
        s.forward();
        // Rule 1: the colour is actually coloured, or the round trip
        // below would be about grey.
        const spread = @max(s.cur[0], @max(s.cur[1], s.cur[2])) -
            @min(s.cur[0], @min(s.cur[1], s.cur[2]));
        try testing.expect(spread > 0.3);

        s.inverse();
        try testing.expectApproxEqAbs(h, s.hue, 0.05);
        try testing.expectApproxEqAbs(@as(f32, 0.7), s.sat, 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 0.8), s.val, 1e-3);
    }
}

test "swatch: hue and saturation survive a trip through black" {
    // Both are undefined at value 0. Recomputing them there would make a
    // picker forget its colour the moment you turned it down.
    var s: Swatch = .{};
    s.hue = 210;
    s.sat = 0.8;
    s.val = 0.9;
    s.forward();

    s.val = 0;
    s.forward();
    s.inverse();
    try testing.expectApproxEqAbs(@as(f32, 210), s.hue, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 0.8), s.sat, 1e-3);

    // And through white, where the hue is equally undefined.
    s.val = 1;
    s.sat = 0;
    s.forward();
    s.inverse();
    try testing.expectApproxEqAbs(@as(f32, 210), s.hue, 0.05);
}

test "swatch: a range other than 0..1 maps through it" {
    var s: Swatch = .{ .min = -1, .max = 3 };
    s.hue = 0;
    s.sat = 1;
    s.val = 1;
    s.forward();
    // Pure red at full: r at max, g and b at min.
    try testing.expectApproxEqAbs(@as(f32, 3), s.cur[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), s.cur[1], 1e-5);
    s.inverse();
    try testing.expectApproxEqAbs(@as(f32, 1), s.val, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), s.sat, 1e-4);
}

test "swatch: a degenerate range does not divide by nothing" {
    var s: Swatch = .{ .min = 1, .max = 1 };
    s.setChannels(.{ 1, 1, 1 });
    for (s.cur) |v| try testing.expect(std.math.isFinite(v));
    try testing.expect(std.math.isFinite(s.val));
}
