//! `Constraint` — `Expression OP 0` carrying a strength tier.
//!
//! A Constraint owns its Expression. Users build these via the
//! builder DSL (`expr(x).eq(y).medium()`); `Solver.addConstraint`
//! takes one by value, copies the Expression into its internal
//! storage, and returns a `ConstraintId` handle.
//!
//! Plain struct with public fields — there are no invariants
//! between op/strength that warrant a constructor barrier; the
//! solver does the meaningful validation on `addConstraint`
//! (UnsatisfiableConstraint, DuplicateConstraint).

const std = @import("std");
const types = @import("types.zig");
const expression_mod = @import("expression.zig");
const strength_mod = @import("strength.zig");

const Expression = expression_mod.Expression;
const Term = @import("term.zig").Term;
const RelationalOperator = types.RelationalOperator;
const Strength = strength_mod.Strength;

pub const Constraint = struct {
    expression: Expression,
    op: RelationalOperator,
    strength: Strength,

    pub fn deinit(self: *Constraint, alloc: std.mem.Allocator) void {
        self.expression.deinit(alloc);
        self.* = undefined;
    }

    /// Deep-copy. Caller owns the result and must `deinit` it.
    /// Used by the solver when ingesting a user-provided
    /// Constraint into its internal pool.
    pub fn clone(self: Constraint, alloc: std.mem.Allocator) std.mem.Allocator.Error!Constraint {
        return .{
            .expression = try self.expression.clone(alloc),
            .op = self.op,
            .strength = self.strength,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "clone produces an independent deep copy" {
    const v: types.VariableId = @enumFromInt(2);
    var expr = expression_mod.Expression.initConstant(5.0);
    try expr.addTerm(testing.allocator, Term.scaled(v, 2.0));

    var src = Constraint{
        .expression = expr,
        .op = .eq,
        .strength = strength_mod.medium,
    };
    defer src.deinit(testing.allocator);

    var dst = try src.clone(testing.allocator);
    defer dst.deinit(testing.allocator);

    // Mutate dst → src untouched.
    dst.expression.scale(2.0);
    try testing.expectEqual(@as(f64, 5.0), src.expression.constant);
    try testing.expectEqual(@as(f64, 2.0), src.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, 10.0), dst.expression.constant);
    try testing.expectEqual(@as(f64, 4.0), dst.expression.terms.items[0].coefficient);

    // op + strength are scalars; cloned by value.
    try testing.expectEqual(RelationalOperator.eq, dst.op);
    try testing.expectEqual(strength_mod.medium, dst.strength);
}
