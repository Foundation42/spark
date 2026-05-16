//! Builder DSL — turn the bare Expression / Constraint structs
//! into the documented method-chain call site:
//!
//!     const c = try expr(alloc, x_max).minus(x_min)
//!                  .eq(width).required();
//!     try solver.addConstraint(c);
//!
//! ## Single-use discipline
//!
//! Builders are **move-by-value through the chain**. After
//! `b.plus(...)` returns, the original `b` shares the same
//! ArrayList backing as the returned builder; mutating either
//! after that point can invalidate the other's slice header.
//! Treat builders as consumed by every method call. Real call
//! sites only ever hold the head of the chain, so this never
//! bites in practice.
//!
//! ## Deferred errors
//!
//! Mid-chain methods (`plus` / `minus` / `times` / ... / `eq` /
//! `leq` / `geq`) never return errors. If an allocation fails,
//! the builder enters an "err" state that propagates through
//! every subsequent method. The error surfaces at the commit
//! step (`required` / `strong` / `medium` / `weak` / `atStrength`),
//! which is the only step that returns `!Constraint`. Chains
//! stay clean with a single `try` at the end. On error, the
//! commit step deinits the partial expression so the caller
//! doesn't have to.
//!
//! ## Supported operand types
//!
//! `expr()` and `plus` / `minus` / `eq` / `leq` / `geq` accept,
//! via `anytype` + comptime dispatch:
//!
//!   - `VariableId`           — treated as `1 * variable`
//!   - `Term`                 — taken as-is
//!   - `ExprBuilder`          — merged in (terms appended, constants summed)
//!   - `comptime_int` / `comptime_float` / `f32` / `f64`
//!                            — added to the running constant
//!
//! Anything else is a compile error.

const std = @import("std");
const types = @import("types.zig");
const term_mod = @import("term.zig");
const expression_mod = @import("expression.zig");
const constraint_mod = @import("constraint.zig");
const strength_mod = @import("strength.zig");

const Term = term_mod.Term;
const Expression = expression_mod.Expression;
const Constraint = constraint_mod.Constraint;
const VariableId = types.VariableId;
const RelationalOperator = types.RelationalOperator;
const Strength = strength_mod.Strength;

pub const BuilderError = error{
    OutOfMemory,
};

/// Entry point for the builder chain. Accepts any single
/// operand type (see module doc).
pub fn expr(alloc: std.mem.Allocator, operand: anytype) ExprBuilder {
    var b: ExprBuilder = .{ .alloc = alloc, .expression = Expression.init() };
    b.addOperand(operand, 1.0);
    return b;
}

pub const ExprBuilder = struct {
    alloc: std.mem.Allocator,
    expression: Expression,
    err: ?BuilderError = null,

    /// Internal: add an operand to `self.expression` with the
    /// given sign (+1 or -1, used to fold `minus` into `plus`).
    /// Sets `self.err` on allocator failure.
    fn addOperand(self: *ExprBuilder, operand: anytype, sign: f64) void {
        if (self.err != null) return;
        const T = @TypeOf(operand);
        switch (T) {
            VariableId => self.expression.addTerm(
                self.alloc,
                Term.scaled(operand, sign),
            ) catch |e| {
                self.err = e;
            },
            Term => self.expression.addTerm(
                self.alloc,
                Term.scaled(operand.variable, operand.coefficient * sign),
            ) catch |e| {
                self.err = e;
            },
            ExprBuilder => {
                // Merge another builder's accumulated expression
                // in. Propagate its err state; consume its
                // backing memory.
                var rhs = operand;
                if (rhs.err) |e| {
                    self.err = e;
                    rhs.expression.deinit(rhs.alloc);
                    return;
                }
                defer rhs.expression.deinit(rhs.alloc);
                for (rhs.expression.terms.items) |t| {
                    self.expression.addTerm(
                        self.alloc,
                        Term.scaled(t.variable, t.coefficient * sign),
                    ) catch |e| {
                        self.err = e;
                        return;
                    };
                }
                self.expression.constant += rhs.expression.constant * sign;
            },
            else => {
                // Numeric literal / float — add to the constant.
                if (T == comptime_int or T == comptime_float or T == f32 or T == f64) {
                    self.expression.constant += @as(f64, operand) * sign;
                } else {
                    @compileError("unsupported builder operand: " ++ @typeName(T));
                }
            },
        }
    }

    pub fn plus(self: ExprBuilder, rhs: anytype) ExprBuilder {
        var out = self;
        out.addOperand(rhs, 1.0);
        return out;
    }

    pub fn minus(self: ExprBuilder, rhs: anytype) ExprBuilder {
        var out = self;
        out.addOperand(rhs, -1.0);
        return out;
    }

    pub fn times(self: ExprBuilder, k: f64) ExprBuilder {
        var out = self;
        if (out.err == null) out.expression.scale(k);
        return out;
    }

    pub fn divide(self: ExprBuilder, k: f64) ExprBuilder {
        return self.times(1.0 / k);
    }

    pub fn negate(self: ExprBuilder) ExprBuilder {
        var out = self;
        if (out.err == null) out.expression.negate();
        return out;
    }

    /// Terminate the chain into a `PartialConstraint`. Builds
    /// `self - rhs op 0` so the solver sees a standard form.
    fn finishWith(self: ExprBuilder, op: RelationalOperator, rhs: anytype) PartialConstraint {
        var out = self;
        out.addOperand(rhs, -1.0);
        return .{
            .alloc = out.alloc,
            .expression = out.expression,
            .op = op,
            .err = out.err,
        };
    }

    pub fn eq(self: ExprBuilder, rhs: anytype) PartialConstraint {
        return self.finishWith(.eq, rhs);
    }

    pub fn leq(self: ExprBuilder, rhs: anytype) PartialConstraint {
        return self.finishWith(.lt_eq, rhs);
    }

    pub fn geq(self: ExprBuilder, rhs: anytype) PartialConstraint {
        return self.finishWith(.gt_eq, rhs);
    }
};

pub const PartialConstraint = struct {
    alloc: std.mem.Allocator,
    expression: Expression,
    op: RelationalOperator,
    err: ?BuilderError = null,

    fn finish(self: PartialConstraint, s: Strength) BuilderError!Constraint {
        if (self.err) |e| {
            // Clean up the partial expression on error so the
            // caller doesn't have to.
            var to_free = self.expression;
            to_free.deinit(self.alloc);
            return e;
        }
        return .{
            .expression = self.expression,
            .op = self.op,
            .strength = s,
        };
    }

    pub fn required(self: PartialConstraint) BuilderError!Constraint {
        return self.finish(strength_mod.required);
    }
    pub fn strong(self: PartialConstraint) BuilderError!Constraint {
        return self.finish(strength_mod.strong);
    }
    pub fn medium(self: PartialConstraint) BuilderError!Constraint {
        return self.finish(strength_mod.medium);
    }
    pub fn weak(self: PartialConstraint) BuilderError!Constraint {
        return self.finish(strength_mod.weak);
    }
    pub fn atStrength(self: PartialConstraint, s: Strength) BuilderError!Constraint {
        return self.finish(s);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "expr(v).eq(0).required() → v == 0, required" {
    const v: VariableId = @enumFromInt(0);
    var c = try expr(testing.allocator, v).eq(@as(f64, 0)).required();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(RelationalOperator.eq, c.op);
    try testing.expectEqual(strength_mod.required, c.strength);
    try testing.expectEqual(@as(usize, 1), c.expression.terms.items.len);
    try testing.expectEqual(v, c.expression.terms.items[0].variable);
    try testing.expectEqual(@as(f64, 1.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, 0.0), c.expression.constant);
}

test "expr(v).eq(10) folds into v - 10 == 0" {
    const v: VariableId = @enumFromInt(0);
    var c = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -10.0), c.expression.constant);
}

test "plus combines variables into a single expression" {
    const v: VariableId = @enumFromInt(0);
    const w: VariableId = @enumFromInt(1);
    var c = try expr(testing.allocator, v).plus(w).eq(@as(f64, 0)).medium();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), c.expression.terms.items.len);
    try testing.expectEqual(strength_mod.medium, c.strength);
}

test "minus negates the rhs into the expression" {
    const v: VariableId = @enumFromInt(0);
    const w: VariableId = @enumFromInt(1);
    // v - w == 0 → expression terms: [v with +1, w with -1]
    var c = try expr(testing.allocator, v).minus(w).eq(@as(f64, 0)).required();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), c.expression.terms.items.len);
    try testing.expectEqual(@as(f64, 1.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -1.0), c.expression.terms.items[1].coefficient);
}

test "times scales every coefficient and the constant" {
    const v: VariableId = @enumFromInt(0);
    // 3*(v + 4) == 0 → 3*v + 12 == 0
    var c = try expr(testing.allocator, v).plus(@as(f64, 4)).times(3.0).eq(@as(f64, 0)).strong();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 3.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, 12.0), c.expression.constant);
    try testing.expectEqual(strength_mod.strong, c.strength);
}

test "geq produces gt_eq op" {
    const v: VariableId = @enumFromInt(0);
    var c = try expr(testing.allocator, v).geq(@as(f64, 5)).required();
    defer c.deinit(testing.allocator);
    try testing.expectEqual(RelationalOperator.gt_eq, c.op);
    // v - 5 >= 0
    try testing.expectEqual(@as(f64, -5.0), c.expression.constant);
}

test "leq produces lt_eq op" {
    const v: VariableId = @enumFromInt(0);
    var c = try expr(testing.allocator, v).leq(@as(f64, 100)).weak();
    defer c.deinit(testing.allocator);
    try testing.expectEqual(RelationalOperator.lt_eq, c.op);
    try testing.expectEqual(@as(f64, -100.0), c.expression.constant);
}

test "builder as rhs merges its expression in (consumed)" {
    const v: VariableId = @enumFromInt(0);
    const w: VariableId = @enumFromInt(1);

    // v == w + 3   →   v - w - 3 == 0
    var c = try expr(testing.allocator, v).eq(
        expr(testing.allocator, w).plus(@as(f64, 3)),
    ).required();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), c.expression.terms.items.len);
    try testing.expectEqual(@as(f64, 1.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -1.0), c.expression.terms.items[1].coefficient);
    try testing.expectEqual(@as(f64, -3.0), c.expression.constant);
}

test "Term as operand carries its coefficient" {
    const v: VariableId = @enumFromInt(0);
    // 3*v == 15  →  3*v - 15 == 0
    var c = try expr(testing.allocator, Term.scaled(v, 3.0)).eq(@as(f64, 15)).required();
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 3.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -15.0), c.expression.constant);
}

test "atStrength accepts custom strength values" {
    const v: VariableId = @enumFromInt(0);
    const custom = strength_mod.create(0, 1, 0, 2.5);  // 2.5 * medium
    var c = try expr(testing.allocator, v).eq(@as(f64, 1)).atStrength(custom);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(custom, c.strength);
}

test "divide is times(1/k)" {
    const v: VariableId = @enumFromInt(0);
    // (4*v) / 2 == 6  →  2*v - 6 == 0
    var c = try expr(testing.allocator, v).times(4.0).divide(2.0).eq(@as(f64, 6)).required();
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 2.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -6.0), c.expression.constant);
}

test "negate flips coefficients and constant" {
    const v: VariableId = @enumFromInt(0);
    // -(v + 4) == 0  →  -v - 4 == 0
    var c = try expr(testing.allocator, v).plus(@as(f64, 4)).negate().eq(@as(f64, 0)).required();
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, -1.0), c.expression.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -4.0), c.expression.constant);
}
