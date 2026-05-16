//! Numeric utilities shared by the solver internals.

/// Absolute-value cutoff below which coefficients are treated as
/// zero. Mirrors kiwi C++'s `impl::nearZero` threshold from
/// `util.h` (eps = 1e-8). **Load-bearing for solver
/// correctness**: too tight and legitimate floating-point
/// residue near pivot boundaries gets retained, polluting the
/// tableau; too loose and real coefficients get dropped, making
/// constraints look feasible when they aren't.
///
/// Used in `Row.insertSymbol` (drop near-zero cells), in
/// `addConstraint` (detect redundant required equalities), in
/// `Constraint::violated` for `OP_EQ`, in
/// `addWithArtificialVariable` (Phase-1 success check), and in
/// `dualOptimize` (skip already-feasible rows).
pub const eps: f64 = 1.0e-8;

/// True when `|x| < eps`. The sole fuzzy comparison the solver
/// uses against floating-point values.
pub fn nearZero(x: f64) bool {
    return @abs(x) < eps;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "nearZero treats values within eps as zero" {
    try testing.expect(nearZero(0.0));
    try testing.expect(nearZero(1e-9));
    try testing.expect(nearZero(-1e-9));
    // eps itself is NOT nearZero — the comparison is strict <.
    try testing.expect(!nearZero(eps));
    try testing.expect(!nearZero(1e-7));
    try testing.expect(!nearZero(-1e-7));
}
