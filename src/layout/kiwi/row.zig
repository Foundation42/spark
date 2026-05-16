//! Internal: one row of the simplex tableau.
//!
//! A Row is `(symbol₁·c₁ + symbol₂·c₂ + ... + constant)`. Rows
//! represent both constraints (during construction) and the
//! solved expression of one basic variable in terms of others
//! (during solving). The solver's `m_rows` map stores one Row
//! per basic Symbol.
//!
//! Mirrors kiwi C++'s `impl::Row` (header `row.h`). The C++
//! version uses an `AssocVector` (sorted std::vector of pairs)
//! for the cell map; we use `AutoArrayHashMapUnmanaged` to
//! preserve deterministic insertion-order iteration without
//! paying the O(log N) lookup cost of a sorted container at the
//! sizes the solver works with (typically <30 cells per row).
//!
//! Methods exposed: insertSymbol / insertRow / remove /
//! reverseSign / solveFor / solveForLhsRhs / substitute /
//! coefficientFor — every operation the simplex pivoter needs.

const std = @import("std");
const sym_mod = @import("symbol.zig");
const util = @import("util.zig");

const Symbol = sym_mod.Symbol;

/// Per-row cell map: symbol → coefficient. Insertion-order
/// iteration for deterministic tie-breaking in the solver.
pub const CellMap = std.AutoArrayHashMapUnmanaged(Symbol, f64);

pub const Row = struct {
    cells: CellMap = .{},
    constant: f64 = 0.0,

    pub fn init(constant: f64) Row {
        return .{ .constant = constant };
    }

    pub fn deinit(self: *Row, alloc: std.mem.Allocator) void {
        self.cells.deinit(alloc);
        self.* = undefined;
    }

    /// Deep-copy. Caller owns the result.
    pub fn clone(self: Row, alloc: std.mem.Allocator) std.mem.Allocator.Error!Row {
        var out: Row = .{ .constant = self.constant };
        try out.cells.ensureTotalCapacity(alloc, self.cells.count());
        var it = self.cells.iterator();
        while (it.next()) |entry| {
            out.cells.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
        }
        return out;
    }

    /// Add `v` to the constant. Returns the new value.
    pub fn add(self: *Row, v: f64) f64 {
        self.constant += v;
        return self.constant;
    }

    /// Coefficient for `sym` in this row, or 0 if absent.
    pub fn coefficientFor(self: Row, sym: Symbol) f64 {
        return self.cells.get(sym) orelse 0.0;
    }

    /// Add `coeff` to the entry for `sym`, creating it if
    /// absent. If the resulting coefficient is near zero, the
    /// cell is removed. Mirrors `Row::insert(Symbol, double)`.
    pub fn insertSymbol(
        self: *Row,
        alloc: std.mem.Allocator,
        sym: Symbol,
        coeff: f64,
    ) std.mem.Allocator.Error!void {
        const gop = try self.cells.getOrPut(alloc, sym);
        if (gop.found_existing) {
            gop.value_ptr.* += coeff;
            if (util.nearZero(gop.value_ptr.*)) {
                // ordered remove preserves iteration order.
                _ = self.cells.orderedRemove(sym);
            }
        } else if (util.nearZero(coeff)) {
            // Empty cell + a near-zero contribution: drop it.
            _ = self.cells.orderedRemove(sym);
        } else {
            gop.value_ptr.* = coeff;
        }
    }

    /// Add `coeff * other` into self — both cells and constant.
    /// Mirrors `Row::insert(const Row&, double)`.
    pub fn insertRow(
        self: *Row,
        alloc: std.mem.Allocator,
        other: Row,
        coeff: f64,
    ) std.mem.Allocator.Error!void {
        self.constant += other.constant * coeff;
        var it = other.cells.iterator();
        while (it.next()) |entry| {
            try self.insertSymbol(alloc, entry.key_ptr.*, entry.value_ptr.* * coeff);
        }
    }

    /// Remove a symbol from the row, if present.
    pub fn remove(self: *Row, sym: Symbol) void {
        _ = self.cells.orderedRemove(sym);
    }

    /// Negate every coefficient and the constant.
    pub fn reverseSign(self: *Row) void {
        self.constant = -self.constant;
        var it = self.cells.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.* = -entry.value_ptr.*;
        }
    }

    /// Reshape the row so it expresses `sym = -(rest)` — i.e.,
    /// divide every coefficient and the constant by the
    /// negation of `sym`'s coefficient, then remove `sym`.
    /// Mirrors `Row::solveFor(Symbol)`. Caller asserts that
    /// `sym` is present.
    pub fn solveFor(self: *Row, sym: Symbol) void {
        const coeff = self.cells.get(sym) orelse {
            @panic("solveFor: symbol not in row");
        };
        const inv = -1.0 / coeff;
        _ = self.cells.orderedRemove(sym);
        self.constant *= inv;
        var it = self.cells.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.* *= inv;
        }
    }

    /// Combined-form solveFor: insert `lhs` into the row with
    /// coefficient −1 (so the row reads `... + (-lhs) = 0`),
    /// then solve for `rhs`. Mirrors `Row::solveFor(Symbol,
    /// Symbol)` — used in `addConstraint` when the user-supplied
    /// marker isn't the row's natural subject.
    pub fn solveForLhsRhs(
        self: *Row,
        alloc: std.mem.Allocator,
        lhs: Symbol,
        rhs: Symbol,
    ) std.mem.Allocator.Error!void {
        try self.insertSymbol(alloc, lhs, -1.0);
        self.solveFor(rhs);
    }

    /// Substitute `sym` with `row` everywhere in self. If sym
    /// isn't in self, no-op. Mirrors `Row::substitute`.
    pub fn substitute(
        self: *Row,
        alloc: std.mem.Allocator,
        sym: Symbol,
        row: Row,
    ) std.mem.Allocator.Error!void {
        if (self.cells.fetchOrderedRemove(sym)) |kv| {
            try self.insertRow(alloc, row, kv.value);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn ext(id: u32) Symbol {
    return .{ .id = id, .kind = .external };
}

test "default row is zero-constant, no cells" {
    var r = Row.init(0);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.0), r.constant);
    try testing.expectEqual(@as(usize, 0), r.cells.count());
}

test "add accumulates onto the constant" {
    var r = Row.init(0);
    defer r.deinit(testing.allocator);
    _ = r.add(3.0);
    _ = r.add(-1.5);
    try testing.expectEqual(@as(f64, 1.5), r.constant);
}

test "insertSymbol creates and accumulates cells" {
    const alloc = testing.allocator;
    var r = Row.init(0);
    defer r.deinit(alloc);

    try r.insertSymbol(alloc, ext(1), 3.0);
    try testing.expectEqual(@as(f64, 3.0), r.coefficientFor(ext(1)));

    try r.insertSymbol(alloc, ext(1), 2.0);
    try testing.expectEqual(@as(f64, 5.0), r.coefficientFor(ext(1)));
}

test "insertSymbol drops a cell when the sum hits near-zero" {
    const alloc = testing.allocator;
    var r = Row.init(0);
    defer r.deinit(alloc);

    try r.insertSymbol(alloc, ext(1), 3.0);
    try r.insertSymbol(alloc, ext(1), -3.0);
    try testing.expectEqual(@as(usize, 0), r.cells.count());
    try testing.expectEqual(@as(f64, 0.0), r.coefficientFor(ext(1)));
}

test "insertSymbol with near-zero into an empty cell stays absent" {
    const alloc = testing.allocator;
    var r = Row.init(0);
    defer r.deinit(alloc);

    try r.insertSymbol(alloc, ext(1), 1e-10);
    try testing.expectEqual(@as(usize, 0), r.cells.count());
}

test "insertRow folds another row in with scaling" {
    const alloc = testing.allocator;
    var a = Row.init(2.0);
    defer a.deinit(alloc);
    var b = Row.init(1.0);
    defer b.deinit(alloc);
    try a.insertSymbol(alloc, ext(1), 1.0);
    try b.insertSymbol(alloc, ext(2), 2.0);

    // a += 3 * b
    try a.insertRow(alloc, b, 3.0);
    try testing.expectEqual(@as(f64, 5.0), a.constant); // 2 + 3*1
    try testing.expectEqual(@as(f64, 1.0), a.coefficientFor(ext(1)));
    try testing.expectEqual(@as(f64, 6.0), a.coefficientFor(ext(2))); // 0 + 3*2
}

test "reverseSign flips constant and every cell" {
    const alloc = testing.allocator;
    var r = Row.init(5.0);
    defer r.deinit(alloc);
    try r.insertSymbol(alloc, ext(1), 2.0);
    try r.insertSymbol(alloc, ext(2), -3.0);

    r.reverseSign();
    try testing.expectEqual(@as(f64, -5.0), r.constant);
    try testing.expectEqual(@as(f64, -2.0), r.coefficientFor(ext(1)));
    try testing.expectEqual(@as(f64, 3.0), r.coefficientFor(ext(2)));
}

test "solveFor pivots a symbol out, scaling by -1/coeff" {
    const alloc = testing.allocator;
    // Row: 2*x + 6*y + 4 ... solveFor(x) ⇒ row becomes (-1/2) of
    // the others: x = -3y - 2.
    var r = Row.init(4.0);
    defer r.deinit(alloc);
    try r.insertSymbol(alloc, ext(1), 2.0); // x
    try r.insertSymbol(alloc, ext(2), 6.0); // y

    r.solveFor(ext(1));
    try testing.expectEqual(@as(f64, -2.0), r.constant);
    try testing.expectEqual(@as(f64, -3.0), r.coefficientFor(ext(2)));
    try testing.expectEqual(@as(f64, 0.0), r.coefficientFor(ext(1)));
}

test "solveForLhsRhs inserts lhs at -1 then pivots rhs" {
    const alloc = testing.allocator;
    // Row: 6y + 4. solveForLhsRhs(x, y) ⇒
    //   step 1: insert x with -1 → -x + 6y + 4
    //   step 2: solveFor(y) → y = (1/6)*x - (4/6)
    var r = Row.init(4.0);
    defer r.deinit(alloc);
    try r.insertSymbol(alloc, ext(2), 6.0);

    try r.solveForLhsRhs(alloc, ext(1), ext(2));
    // y = (1/6) x - 2/3
    try testing.expectApproxEqAbs(@as(f64, -2.0 / 3.0), r.constant, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), r.coefficientFor(ext(1)), 1e-12);
    try testing.expectEqual(@as(f64, 0.0), r.coefficientFor(ext(2)));
}

test "substitute replaces sym with another row scaled by sym's coefficient" {
    const alloc = testing.allocator;
    var self_row = Row.init(0);
    defer self_row.deinit(alloc);
    var sub_row = Row.init(1.0);
    defer sub_row.deinit(alloc);

    // self: 5x
    try self_row.insertSymbol(alloc, ext(1), 5.0);
    // sub: y + 1 (the substitution for x)
    try sub_row.insertSymbol(alloc, ext(2), 1.0);

    try self_row.substitute(alloc, ext(1), sub_row);
    // After: 5*(y + 1) = 5y + 5
    try testing.expectEqual(@as(f64, 5.0), self_row.constant);
    try testing.expectEqual(@as(f64, 5.0), self_row.coefficientFor(ext(2)));
    try testing.expectEqual(@as(f64, 0.0), self_row.coefficientFor(ext(1)));
}

test "substitute no-ops when the symbol isn't present" {
    const alloc = testing.allocator;
    var self_row = Row.init(7.0);
    defer self_row.deinit(alloc);
    try self_row.insertSymbol(alloc, ext(1), 3.0);

    var sub_row = Row.init(1.0);
    defer sub_row.deinit(alloc);
    try sub_row.insertSymbol(alloc, ext(2), 1.0);

    try self_row.substitute(alloc, ext(99), sub_row);
    // Unchanged.
    try testing.expectEqual(@as(f64, 7.0), self_row.constant);
    try testing.expectEqual(@as(f64, 3.0), self_row.coefficientFor(ext(1)));
    try testing.expectEqual(@as(f64, 0.0), self_row.coefficientFor(ext(2)));
}

test "remove drops a cell" {
    const alloc = testing.allocator;
    var r = Row.init(0);
    defer r.deinit(alloc);
    try r.insertSymbol(alloc, ext(1), 1.0);
    try r.insertSymbol(alloc, ext(2), 2.0);

    r.remove(ext(1));
    try testing.expectEqual(@as(usize, 1), r.cells.count());
    try testing.expectEqual(@as(f64, 0.0), r.coefficientFor(ext(1)));
    try testing.expectEqual(@as(f64, 2.0), r.coefficientFor(ext(2)));
}

test "clone produces an independent copy" {
    const alloc = testing.allocator;
    var src = Row.init(2.0);
    defer src.deinit(alloc);
    try src.insertSymbol(alloc, ext(1), 3.0);

    var dst = try src.clone(alloc);
    defer dst.deinit(alloc);

    dst.reverseSign();
    try testing.expectEqual(@as(f64, 2.0), src.constant);
    try testing.expectEqual(@as(f64, 3.0), src.coefficientFor(ext(1)));
    try testing.expectEqual(@as(f64, -2.0), dst.constant);
    try testing.expectEqual(@as(f64, -3.0), dst.coefficientFor(ext(1)));
}
