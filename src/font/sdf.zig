//! Single-channel signed distance field generation from a FreeType
//! grayscale bitmap. The output is a same-size R8 image where:
//!
//!   * 0.5 (byte 128) sits exactly on the glyph boundary
//!   * < 0.5 is outside the glyph, with distance growing toward 0
//!   * > 0.5 is inside the glyph, with distance growing toward 1
//!
//! Sampling: bilinear-filter and threshold near 0.5 in the fragment
//! shader. `smoothstep(0.5 - aa, 0.5 + aa, sample.r)` gives crisp
//! coverage at any display size, including aggressive upscaling.
//!
//! Algorithm: bounded-radius brute-force. For each pixel, scan an
//! `±radius` neighbourhood for the closest opposite-state pixel,
//! signed by the central pixel's state. O(W·H·R²) per glyph; with
//! W·H ≤ 80² (64-px-tall body glyphs) and R = 8 that's ~50k ops per
//! glyph — fast enough at startup, fine because results land in
//! the atlas cache and never re-run.
//!
//! The radius bound is also the visible "halo" the shader has to
//! work with. Pixels farther than `radius` from any boundary clamp
//! to the extreme byte value (0 or 255). At display time, glow /
//! drop-shadow effects can sample at distances < 0.5 to draw outside
//! the glyph silhouette — so the radius doubles as our outer-effect
//! budget. Phase 6 doesn't use it for that yet; the field is sized
//! so we can.
//!
//! True multi-channel SDF (Chlumsky's MSDF, corner-preserving) would
//! need the FT outline, not the bitmap — left for a future swap if
//! single-channel quality proves insufficient.

const std = @import("std");

const RADIUS: i32 = 8;

/// Generate a same-size SDF byte-image from a tight, top-down
/// grayscale source. `src` is `w*h` bytes; `out` is `w*h` bytes
/// (caller allocates). Source >127 is "inside", ≤127 is "outside".
pub fn generate(w: u32, h: u32, src: []const u8, out: []u8) void {
    std.debug.assert(src.len == w * h);
    std.debug.assert(out.len == w * h);
    if (w == 0 or h == 0) return;

    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    const r2_max: f32 = @floatFromInt(RADIUS * RADIUS);

    var y: i32 = 0;
    while (y < ih) : (y += 1) {
        var x: i32 = 0;
        while (x < iw) : (x += 1) {
            const here_inside = src[@intCast(y * iw + x)] > 127;
            var best_d2: f32 = r2_max;

            // Bounded neighbourhood scan. `min/max` clip keeps the
            // inner loop branchless w.r.t. image bounds.
            const y0 = @max(0, y - RADIUS);
            const y1 = @min(ih - 1, y + RADIUS);
            const x0 = @max(0, x - RADIUS);
            const x1 = @min(iw - 1, x + RADIUS);

            var ny: i32 = y0;
            while (ny <= y1) : (ny += 1) {
                var nx: i32 = x0;
                while (nx <= x1) : (nx += 1) {
                    const neighbor_inside = src[@intCast(ny * iw + nx)] > 127;
                    if (neighbor_inside == here_inside) continue;
                    const dx = nx - x;
                    const dy = ny - y;
                    const d2: f32 = @floatFromInt(dx * dx + dy * dy);
                    if (d2 < best_d2) best_d2 = d2;
                }
            }

            const dist: f32 = @sqrt(best_d2);
            // Signed: positive inside, negative outside. Normalise
            // by RADIUS so the value lives in [-1, 1], then remap to
            // [0, 1] with 0.5 sitting on the boundary.
            const signed_d: f32 = if (here_inside) dist else -dist;
            const normalised: f32 = (signed_d / @as(f32, @floatFromInt(RADIUS)) + 1.0) * 0.5;
            const byte: u8 = @intFromFloat(std.math.clamp(normalised * 255.0, 0.0, 255.0));
            out[@intCast(y * iw + x)] = byte;
        }
    }
}
