//! `Expression` — a linear combination of Terms plus a scalar
//! constant. The middle layer of the constraint algebra: every
//! Constraint carries one Expression to compare against zero.
//!
//! Owns an `ArrayListUnmanaged(Term)` — caller passes the
//! allocator on mutating operations. Construction goes through
//! `init` / `initConstant` / `initTerm` for the trivial cases
//! and through the builder DSL (`builder.zig`) for the common
//! `expr(x).plus(y).times(3).geq(z)` path.

const std = @import("std");
const types = @import("types.zig");
const term_mod = @import("term.zig");

const Term = term_mod.Term;

pub const Expression = struct {
    terms: std.ArrayListUnmanaged(Term) = .{},
    constant: f64 = 0.0,

    /// Empty expression equal to 0.
    pub fn init() Expression {
        return .{};
    }

    /// Expression that is exactly a scalar constant.
    pub fn initConstant(c: f64) Expression {
        return .{ .constant = c };
    }

    /// Expression that is a single Term (no constant). Allocates
    /// the terms slice.
    pub fn initTerm(alloc: std.mem.Allocator, t: Term) std.mem.Allocator.Error!Expression {
        var e = Expression{};
        try e.terms.append(alloc, t);
        return e;
    }

    pub fn deinit(self: *Expression, alloc: std.mem.Allocator) void {
        self.terms.deinit(alloc);
        self.* = undefined;
    }

    /// Deep-copy. Caller owns the result and must `deinit` it.
    pub fn clone(self: Expression, alloc: std.mem.Allocator) std.mem.Allocator.Error!Expression {
        var out: Expression = .{ .constant = self.constant };
        try out.terms.appendSlice(alloc, self.terms.items);
        return out;
    }

    /// Negate every term's coefficient and the constant. In
    /// place; reuses the existing allocation.
    pub fn negate(self: *Expression) void {
        for (self.terms.items) |*t| t.coefficient = -t.coefficient;
        self.constant = -self.constant;
    }

    /// Append a Term to the expression's terms list. Does NOT
    /// combine duplicates; the solver canonicalises when the
    /// expression hits the tableau. (kiwi's `Row::insert` is the
    /// canonicaliser — we keep raw Terms here so the builder
    /// doesn't pay an O(n) lookup on every `.plus`.)
    pub fn addTerm(self: *Expression, alloc: std.mem.Allocator, t: Term) std.mem.Allocator.Error!void {
        try self.terms.append(alloc, t);
    }

    /// Multiply every coefficient and the constant by `k`.
    /// Useful for `expr.times(2)` lowered out of the builder.
    pub fn scale(self: *Expression, k: f64) void {
        for (self.terms.items) |*t| t.coefficient *= k;
        self.constant *= k;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "init makes an empty zero expression" {
    var e = Expression.init();
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), e.terms.items.len);
    try testing.expectEqual(@as(f64, 0.0), e.constant);
}

test "initConstant carries the scalar" {
    var e = Expression.initConstant(3.5);
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), e.terms.items.len);
    try testing.expectEqual(@as(f64, 3.5), e.constant);
}

test "initTerm produces a one-term expression" {
    const v: types.VariableId = @enumFromInt(1);
    var e = try Expression.initTerm(testing.allocator, Term.scaled(v, 2.0));
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), e.terms.items.len);
    try testing.expectEqual(@as(f64, 2.0), e.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, 0.0), e.constant);
}

test "addTerm appends without canonicalising" {
    const v: types.VariableId = @enumFromInt(0);
    var e = Expression.init();
    defer e.deinit(testing.allocator);

    try e.addTerm(testing.allocator, Term.of(v));
    try e.addTerm(testing.allocator, Term.scaled(v, 3.0));

    // Two raw terms; canonicalisation is the solver's job.
    try testing.expectEqual(@as(usize, 2), e.terms.items.len);
    try testing.expectEqual(@as(f64, 1.0), e.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, 3.0), e.terms.items[1].coefficient);
}

test "negate flips every coefficient and the constant" {
    const v0: types.VariableId = @enumFromInt(0);
    const v1: types.VariableId = @enumFromInt(1);

    var e = Expression.initConstant(5.0);
    defer e.deinit(testing.allocator);
    try e.addTerm(testing.allocator, Term.scaled(v0, 2.0));
    try e.addTerm(testing.allocator, Term.scaled(v1, -1.5));

    e.negate();
    try testing.expectEqual(@as(f64, -5.0), e.constant);
    try testing.expectEqual(@as(f64, -2.0), e.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, 1.5), e.terms.items[1].coefficient);
}

test "scale multiplies every coefficient and the constant" {
    const v: types.VariableId = @enumFromInt(0);
    var e = Expression.initConstant(2.0);
    defer e.deinit(testing.allocator);
    try e.addTerm(testing.allocator, Term.scaled(v, 3.0));

    e.scale(0.5);
    try testing.expectEqual(@as(f64, 1.0), e.constant);
    try testing.expectEqual(@as(f64, 1.5), e.terms.items[0].coefficient);
}

test "clone produces an independent deep copy" {
    const v: types.VariableId = @enumFromInt(0);
    var src = Expression.initConstant(10.0);
    defer src.deinit(testing.allocator);
    try src.addTerm(testing.allocator, Term.scaled(v, 2.0));

    var dst = try src.clone(testing.allocator);
    defer dst.deinit(testing.allocator);

    // Mutating dst must not affect src.
    dst.negate();
    try testing.expectEqual(@as(f64, 10.0), src.constant);
    try testing.expectEqual(@as(f64, 2.0), src.terms.items[0].coefficient);
    try testing.expectEqual(@as(f64, -10.0), dst.constant);
    try testing.expectEqual(@as(f64, -2.0), dst.terms.items[0].coefficient);
}
