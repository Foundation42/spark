//! The output display transform, host side — a CPU mirror of
//! `shaders/display.glsl` plus the mode a host selects per frame.
//!
//! Two reasons this exists rather than the shader owning the maths alone:
//!
//! 1. **A host has to be able to predict it.** A host compositing spark over
//!    its own HDR frame needs to know what paperwhite spark will land on, and
//!    a capture gate needs an expected pixel. Reading it out of GLSL is not
//!    an option from Zig.
//! 2. **It is the readback gate's other half.** `tests/display_transform.zig`
//!    renders a known colour through the real pipeline on a real device and
//!    compares the pixel that comes back against `pq()` below. Neither copy
//!    is the authority on its own — the gate is that they AGREE, which is
//!    what makes a divergent edit to either one fail loudly.
//!
//! Keep in lockstep with `shaders/display.glsl`. The gate is the enforcement.
const std = @import("std");

/// What the host's attachment wants this frame.
///
/// The numeric values are the wire format — they go into a push constant as
/// a float and are compared against 0.5 in the shader, so `sdr` must stay 0
/// and `pq` must stay non-zero. A host that presents to an 8-bit UNORM
/// swapchain wants `.sdr`; one that presents to A2B10G10R10 with
/// `VK_COLOR_SPACE_HDR10_ST2084_EXT` wants `.pq`.
pub const Mode = enum(u32) {
    /// Passthrough. What spark did before this transform existed, and the
    /// default — an existing host that never sets it renders byte-identically.
    sdr = 0,
    /// Rec.2020 + ST 2084, chrome mapped to paperwhite.
    pq = 1,
};

/// Reference paperwhite in nits — the luminance a diffuse white page sits at
/// on an HDR display.
///
/// 203 is ITU-R BT.2408's reference level for HDR graphics white, which is
/// also what most desktop compositors map SDR content to. A host that knows
/// better (a user brightness preference, a display's own paperwhite) should
/// say so per frame; this is the value for one that does not.
pub const REFERENCE_PAPERWHITE_NITS: f32 = 203.0;

/// The per-frame display state, as the pipelines push it.
///
/// `extern` and exactly two floats because it is the tail of every push
/// constant block — see the `@sizeOf` asserts in the four pipeline modules,
/// which is where a layout drift between this and the GLSL gets caught.
pub const Push = extern struct {
    mode: f32 = @floatFromInt(@intFromEnum(Mode.sdr)),
    paperwhite_nits: f32 = REFERENCE_PAPERWHITE_NITS,

    pub fn from(mode: Mode, paperwhite_nits: f32) Push {
        return .{
            .mode = @floatFromInt(@intFromEnum(mode)),
            .paperwhite_nits = paperwhite_nits,
        };
    }

    /// The offscreen answer. Effect targets are intermediate surfaces that
    /// get composited into the host's attachment later, so encoding into one
    /// would encode twice. Named rather than spelled `.{}` at the call sites
    /// so the reason travels with the value.
    pub const offscreen: Push = .{};
};

/// ST 2084 (PQ) inverse-EOTF constants, by their names in the standard.
const m1: f32 = 2610.0 / 16384.0; // 0.1593017578125
const m2: f32 = 128.0 * 2523.0 / 4096.0; // 78.84375
const c1: f32 = 3424.0 / 4096.0; // 0.8359375
const c2: f32 = 32.0 * 2413.0 / 4096.0; // 18.8515625
const c3: f32 = 32.0 * 2392.0 / 4096.0; // 18.6875

/// Rec.709 → Rec.2020, row-major. Matches the three `dot` calls in
/// `sparkPq`, digit for digit.
const REC709_TO_REC2020 = [3][3]f32{
    .{ 0.6274040, 0.3292820, 0.0433136 },
    .{ 0.0690970, 0.9195400, 0.0113612 },
    .{ 0.0163916, 0.0880132, 0.8955950 },
};

/// The CPU mirror of `sparkPq`. Same order of operations as the GLSL so the
/// float results agree to within a readback's quantisation.
pub fn pq(rgb: [3]f32, paperwhite_nits: f32) [3]f32 {
    var lin: [3]f32 = undefined;
    for (rgb, 0..) |v, i| {
        lin[i] = paperwhite_nits * std.math.pow(f32, @max(v, 0.0), 2.2);
    }

    var out: [3]f32 = undefined;
    for (REC709_TO_REC2020, 0..) |row, i| {
        const nits = row[0] * lin[0] + row[1] * lin[1] + row[2] * lin[2];
        const y = std.math.clamp(nits / 10000.0, 0.0, 1.0);
        const ym = std.math.pow(f32, y, m1);
        out[i] = std.math.pow(f32, (c1 + c2 * ym) / (1.0 + c3 * ym), m2);
    }
    return out;
}

/// The CPU mirror of `sparkDisplay` — the whole transform including the
/// passthrough arm, which is the one a host most needs to be able to predict.
pub fn apply(rgb: [3]f32, push: Push) [3]f32 {
    if (push.mode < 0.5) return rgb;
    return pq(rgb, push.paperwhite_nits);
}

// ── Gates ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "gate: SDR is passthrough, and it is the default a host gets" {
    // The identity property. Every host that existed before this transform
    // did keeps rendering exactly what it rendered, because the default Push
    // is the passthrough arm — not because callers remember to ask for it.
    const c_in = [3]f32{ 0.25, 0.5, 0.75 };
    try testing.expectEqual(c_in, apply(c_in, .{}));
    try testing.expectEqual(c_in, apply(c_in, Push.offscreen));
    try testing.expectEqual(@as(f32, 0), (Push{}).mode);
}

test "gate: PQ is NOT passthrough at the value SDR would have shown" {
    // Rule 1 — run where the two arms differ and assert the difference
    // first. Without this, every check below passes against `apply` doing
    // nothing at all, which is the whole beat deleted.
    const c_in = [3]f32{ 0.25, 0.5, 0.75 };
    const encoded = apply(c_in, Push.from(.pq, REFERENCE_PAPERWHITE_NITS));
    for (c_in, encoded) |a, b| try testing.expect(@abs(a - b) > 0.01);
}

test "gate: PQ anchors — black is zero and paperwhite lands where BT.2408 says" {
    // ST 2084 pins the ends: 0 nits encodes to 0, and 10000 nits to 1. The
    // interesting anchor in between is diffuse white, which must come back as
    // the PQ code for `paperwhite` nits and nothing else — that is the whole
    // reason the transform takes a paperwhite argument instead of encoding
    // straight to the 10000-nit ceiling.
    const black = pq(.{ 0, 0, 0 }, REFERENCE_PAPERWHITE_NITS);
    for (black) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-6);

    // White is preserved through the 709→2020 matrix (its rows sum to 1), so
    // all three channels land on the same code: the PQ encoding of exactly
    // `paperwhite` nits.
    const white = pq(.{ 1, 1, 1 }, REFERENCE_PAPERWHITE_NITS);
    const expected = pqOfNits(REFERENCE_PAPERWHITE_NITS);
    for (white) |v| try testing.expectApproxEqAbs(expected, v, 1e-5);

    // ~0.58 for 203 nits. Pinned as a NUMBER as well as a formula: the
    // formula check above would survive both sides being wrong the same way,
    // which is exactly how a transcribed constant table goes bad.
    try testing.expectApproxEqAbs(@as(f32, 0.5806), expected, 0.001);

    // And the ceiling still reaches 1, so nothing has been scaled away.
    try testing.expectApproxEqAbs(@as(f32, 1.0), pqOfNits(10000.0), 1e-5);
}

test "gate: paperwhite is a knob, and a brighter one encodes brighter" {
    // The argument has to actually reach the maths. A mutation that ignored
    // `paperwhite_nits` and hardcoded the reference would pass every anchor
    // above; it dies here.
    const dim = pq(.{ 1, 1, 1 }, 100.0);
    const bright = pq(.{ 1, 1, 1 }, 400.0);
    try testing.expect(bright[0] > dim[0] + 0.05);
}

test "gate: monotonic in input — a brighter colour never encodes darker" {
    // PQ is a monotonic curve and the 2.2 decode is monotonic, so the
    // composition must be. This catches a sign slip or a swapped constant
    // that the endpoint anchors would not: c1/c2/c3 transposed still pins
    // 0 → 0, but the curve between stops behaving like a curve.
    var prev: f32 = -1.0;
    var i: u32 = 0;
    while (i <= 32) : (i += 1) {
        const v = @as(f32, @floatFromInt(i)) / 32.0;
        const enc = pq(.{ v, v, v }, REFERENCE_PAPERWHITE_NITS)[0];
        try testing.expect(enc > prev);
        prev = enc;
    }
}

test "gate: the 709 -> 2020 matrix preserves white and stays in gamut" {
    // Each row summing to 1 is what makes neutral stay neutral — a colour
    // cast on every grey in the HUD is the failure this prevents, and it is
    // subtle enough to ship unnoticed.
    for (REC709_TO_REC2020) |row| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), row[0] + row[1] + row[2], 1e-5);
    }
}

/// The PQ code for an absolute luminance, straight from ST 2084 — the
/// standard's own formula rather than a rearrangement of `pq` above, so the
/// anchor test is checking the implementation against the spec and not
/// against itself.
fn pqOfNits(nits: f32) f32 {
    const y = std.math.clamp(nits / 10000.0, 0.0, 1.0);
    const ym = std.math.pow(f32, y, m1);
    return std.math.pow(f32, (c1 + c2 * ym) / (1.0 + c3 * ym), m2);
}
