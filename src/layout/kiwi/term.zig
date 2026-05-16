//! `Term` — one (coefficient, variable) pair inside an
//! Expression. The simplest building block of the constraint
//! algebra; everything from `3*x` through to `0.5*y - 2*z`
//! decomposes into a slice of Terms plus a constant.
//!
//! Plain old data. No allocator, no lifecycle. Stored by value
//! in `Expression.terms`.

const types = @import("types.zig");

pub const Term = struct {
    variable: types.VariableId,
    coefficient: f64 = 1.0,

    /// Convenience constructor — `Term.of(v)` for the common
    /// `1 * v` case; `Term.scaled(v, 3)` for `3 * v`.
    pub fn of(variable: types.VariableId) Term {
        return .{ .variable = variable };
    }

    pub fn scaled(variable: types.VariableId, coefficient: f64) Term {
        return .{ .variable = variable, .coefficient = coefficient };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "Term.of defaults coefficient to 1.0" {
    const v: types.VariableId = @enumFromInt(7);
    const t = Term.of(v);
    try testing.expectEqual(v, t.variable);
    try testing.expectEqual(@as(f64, 1.0), t.coefficient);
}

test "Term.scaled carries the coefficient" {
    const v: types.VariableId = @enumFromInt(3);
    const t = Term.scaled(v, -2.5);
    try testing.expectEqual(v, t.variable);
    try testing.expectEqual(@as(f64, -2.5), t.coefficient);
}
