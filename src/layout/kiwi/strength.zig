//! Strength algebra for the Cassowary solver.
//!
//! Strengths form a four-tier scheme — required, strong, medium,
//! weak — packed into a single `f64` via `create(a, b, c, w=1.0)`.
//! Each sub-strength is multiplied by `w`, clamped to `[0, 1000]`,
//! then placed into one of three base-1000 "digits":
//!
//!     create(a, b, c, w) = clamp(a*w, 0, 1000) * 1e6
//!                        + clamp(b*w, 0, 1000) * 1e3
//!                        + clamp(c*w, 0, 1000)
//!
//! The encoding ensures lexicographic ordering: any positive
//! amount in the top digit dominates any quantity in the lower
//! two. The named constants below pick out specific points in
//! this lattice.
//!
//! `required` is checked by **exact-equality post-clip** in
//! `addEditVariable` (the `BadRequiredStrength` check). A
//! strength that drifts even slightly below `required` would
//! pass through silently. Do not approximate. The constant must
//! be `1_001_001_000.0` exactly — verified by test below.

const std = @import("std");

/// Solver strength — opaque `f64` packed via `create`. Use the
/// named constants or call `create` directly. Comparing
/// strengths with `<` / `>` works because of the lexicographic
/// encoding.
pub const Strength = f64;

/// Inviolable strength. Required-strength constraints must be
/// feasible; an unsatisfiable required constraint surfaces as
/// `AddConstraintError.UnsatisfiableConstraint`. Exact value is
/// `create(1000, 1000, 1000, 1.0)`.
pub const required: Strength = 1_001_001_000.0;

/// Structural — provider invariants that hold unless fighting
/// required. ≈ `1e6`.
pub const strong: Strength = 1_000_000.0;

/// Author preferences (`width=300`, `height=auto`). ≈ `1e3`.
pub const medium: Strength = 1_000.0;

/// Content-derived hints (intrinsic widths, natural sizes). `1.0`.
pub const weak: Strength = 1.0;

/// Pack three sub-strengths into a single Strength. Each is
/// multiplied by `w`, clamped to `[0, 1000]`, then placed into
/// its base-1000 digit position.
pub fn create(a: f64, b: f64, c: f64, w: f64) Strength {
    return clampDigit(a * w) * 1.0e6 + clampDigit(b * w) * 1.0e3 + clampDigit(c * w);
}

/// Clamp a strength into the valid range `[0, required]`.
/// Mirrors kiwi's `strength::clip`. Used internally before
/// equality checks so a slightly-over-required input doesn't
/// false-trip `BadRequiredStrength`.
pub fn clip(s: Strength) Strength {
    return std.math.clamp(s, 0.0, required);
}

fn clampDigit(x: f64) f64 {
    return std.math.clamp(x, 0.0, 1000.0);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "named constants have exact kiwi values" {
    try testing.expectEqual(@as(f64, 1_001_001_000.0), required);
    try testing.expectEqual(@as(f64, 1_000_000.0), strong);
    try testing.expectEqual(@as(f64, 1_000.0), medium);
    try testing.expectEqual(@as(f64, 1.0), weak);
}

test "create(1000, 1000, 1000, 1.0) equals required" {
    try testing.expectEqual(required, create(1000, 1000, 1000, 1.0));
}

test "create with single digit matches the named tier" {
    try testing.expectEqual(strong, create(1, 0, 0, 1.0));
    try testing.expectEqual(medium, create(0, 1, 0, 1.0));
    try testing.expectEqual(weak, create(0, 0, 1, 1.0));
}

test "create clamps overflow per-digit (a > 1000 caps at 1e9, NOT required)" {
    // 1500 in the top slot clamps to 1000 → 1000 * 1e6 = 1e9.
    // The other two slots stay 0, so total is exactly 1e9 —
    // NOT required (which is 1.001001e9).
    try testing.expectEqual(@as(f64, 1.0e9), create(1500, 0, 0, 1.0));
    try testing.expect(create(1500, 0, 0, 1.0) < required);
}

test "create clamps negative inputs to 0" {
    try testing.expectEqual(@as(f64, 0.0), create(-5, -5, -5, 1.0));
    try testing.expectEqual(strong, create(1, -1, -1, 1.0));
}

test "create applies weight before clamping" {
    // 0.5 * 2.0 = 1.0 — exactly strong.
    try testing.expectEqual(strong, create(0.5, 0, 0, 2.0));
    // 1.0 * 3.0 = 3.0 — three units in the strong slot.
    try testing.expectEqual(@as(f64, 3.0e6), create(1, 0, 0, 3.0));
    // 600 * 2.0 = 1200, clamps to 1000.
    try testing.expectEqual(@as(f64, 1.0e9), create(600, 0, 0, 2.0));
}

test "clip caps at required and floors at 0" {
    try testing.expectEqual(required, clip(required + 100.0));
    try testing.expectEqual(required, clip(required));
    try testing.expectEqual(@as(f64, 0.0), clip(-1.0));
    try testing.expectEqual(@as(f64, 0.0), clip(0.0));
    try testing.expectEqual(medium, clip(medium));
}

test "named tiers strictly increase" {
    try testing.expect(weak < medium);
    try testing.expect(medium < strong);
    try testing.expect(strong < required);
}

test "required strictly dominates any non-required combination" {
    // Largest non-required strength has slot a < 1000:
    //   create(999, 1000, 1000) = 999e6 + 1e6 + 1e3 = 1_000_001_000
    // required is 1_001_001_000, so the gap is exactly 1e6 (one
    // full unit in slot a). Anything below `required` cannot
    // reach it without slot a touching 1000.
    const max_below = create(999, 1000, 1000, 1.0);
    try testing.expectEqual(@as(f64, 1_000_001_000.0), max_below);
    try testing.expect(max_below < required);
    try testing.expectEqual(@as(f64, 1.0e6), required - max_below);
}

test "named tiers are NOT lexicographically dominant for sub-unit amounts" {
    // The encoding only dominates if the top slot is fully
    // saturated. `strong` (1 unit in slot a → 1e6) is matched by
    // `create(0, 1000, 0)` (1000 in slot b → 1e6), and BEATEN by
    // `create(0, 1000, 1000)` (1_001_000). Documents the
    // gotcha — author code should stick to the named tiers + a
    // small weight multiplier, not raw create() with intermediate
    // values.
    try testing.expectEqual(strong, create(0, 1000, 0, 1.0));
    try testing.expect(strong < create(0, 1000, 1000, 1.0));
}
