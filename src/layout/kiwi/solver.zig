//! kiwi Solver — public façade + state vectors.
//!
//! Phase A scaffolding (commit 15a.5): variable & constraint
//! pools, internal Symbol minting, `hasConstraint` /
//! `hasEditVariable` / `value` accessors, `init` / `deinit` /
//! `reset`. The simplex pivoting machinery lands in subsequent
//! commits:
//!
//!   - 15a.6 — `addConstraint` + helpers (chooseSubject,
//!     allDummies, anyPivotableSymbol,
//!     addWithArtificialVariable, substitute).
//!   - 15a.7 — `optimize`, `removeConstraint`.
//!   - 15a.8 — `addEditVariable`, `suggestValue`,
//!     `dualOptimize`, `updateVariables`.
//!   - 15a.9 — batching (`beginEdit` / `commitEdit`),
//!     `fetchChanges`, `lastInternalErrorMessage`.
//!
//! Mirrors `impl::SolverImpl` from kiwi C++ `solverimpl.h`. The
//! C++ ref-counted `SharedData` story is replaced by explicit
//! `u32` IDs into solver-owned pools.

const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const sym_mod = @import("symbol.zig");
const row_mod = @import("row.zig");
const constraint_mod = @import("constraint.zig");
const strength_mod = @import("strength.zig");

const VariableId = types.VariableId;
const ConstraintId = types.ConstraintId;
const Symbol = sym_mod.Symbol;
const Row = row_mod.Row;
const Constraint = constraint_mod.Constraint;
const Strength = strength_mod.Strength;

/// Per-constraint bookkeeping. `marker` is the slack or error
/// symbol introduced for this constraint; `other` is the
/// auxiliary slack used for non-required inequalities (so the
/// solver has two pivots to choose between in
/// `getMarkerLeavingRow`). Internal.
const Tag = struct {
    marker: Symbol = Symbol.invalid,
    other: Symbol = Symbol.invalid,
};

/// Per-edit-variable bookkeeping. `tag` is the underlying
/// constraint's tag; `constraint` is the synthetic constraint
/// the solver inserts to track the edit; `constant` is the last
/// suggested value, so future suggestions can compute a delta.
/// Internal.
const EditInfo = struct {
    tag: Tag,
    constraint: ConstraintId,
    constant: f64,
};

const ConstraintEntry = struct {
    constraint: Constraint,
    tag: Tag,
};

const VarRecord = struct {
    name: ?[]const u8 = null,
    value: f64 = 0.0,
};

pub const Solver = struct {
    alloc: std.mem.Allocator,

    // ── External pools (handles the user sees) ──────────────────────
    next_var_id: u32 = 1,
    next_constraint_id: u32 = 1,
    variables: std.AutoArrayHashMapUnmanaged(VariableId, VarRecord) = .{},
    constraints: std.AutoArrayHashMapUnmanaged(ConstraintId, ConstraintEntry) = .{},

    // ── Internal simplex state ──────────────────────────────────────
    /// Next id for any newly-minted Symbol. Starts at 1; id 0 is
    /// reserved for the `Symbol.invalid` sentinel.
    next_symbol_id: u32 = 1,
    /// VariableId → its External Symbol. Each variable has
    /// exactly one external symbol, minted lazily.
    var_symbols: std.AutoArrayHashMapUnmanaged(VariableId, Symbol) = .{},
    /// Basic Symbol → owning Row. Heap-allocated Rows for
    /// pointer stability across map mutations.
    rows: std.AutoArrayHashMapUnmanaged(Symbol, *Row) = .{},
    /// Per-edit-variable state.
    edits: std.AutoArrayHashMapUnmanaged(VariableId, EditInfo) = .{},
    /// Rows whose constant went negative under a dual change;
    /// revisited by `dualOptimize`.
    infeasible_rows: std.ArrayListUnmanaged(Symbol) = .{},
    /// The objective function being minimised. Heap-allocated.
    objective: *Row,
    /// Phase-1 artificial objective; present only during the
    /// `addWithArtificialVariable` window inside `addConstraint`.
    artificial: ?*Row = null,

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!Solver {
        const obj = try alloc.create(Row);
        errdefer alloc.destroy(obj);
        obj.* = Row.init(0);

        return .{
            .alloc = alloc,
            .objective = obj,
        };
    }

    pub fn deinit(self: *Solver) void {
        // Owned Rows: free each, then drop the map.
        var rows_it = self.rows.iterator();
        while (rows_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.rows.deinit(self.alloc);

        // Constraints own their Expressions' term lists.
        var cns_it = self.constraints.iterator();
        while (cns_it.next()) |entry| {
            entry.value_ptr.constraint.deinit(self.alloc);
        }
        self.constraints.deinit(self.alloc);

        // Variables own their debug name strings.
        var vars_it = self.variables.iterator();
        while (vars_it.next()) |entry| {
            if (entry.value_ptr.name) |n| {
                self.alloc.free(n);
            }
        }
        self.variables.deinit(self.alloc);

        self.var_symbols.deinit(self.alloc);
        self.edits.deinit(self.alloc);
        self.infeasible_rows.deinit(self.alloc);

        self.objective.deinit(self.alloc);
        self.alloc.destroy(self.objective);

        if (self.artificial) |a| {
            a.deinit(self.alloc);
            self.alloc.destroy(a);
        }

        self.* = undefined;
    }

    /// Clear all state, preserving pool capacities for reuse.
    /// Variable / constraint / symbol id counters all reset to 1.
    pub fn reset(self: *Solver) void {
        var rows_it = self.rows.iterator();
        while (rows_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.rows.clearRetainingCapacity();

        var cns_it = self.constraints.iterator();
        while (cns_it.next()) |entry| {
            entry.value_ptr.constraint.deinit(self.alloc);
        }
        self.constraints.clearRetainingCapacity();

        var vars_it = self.variables.iterator();
        while (vars_it.next()) |entry| {
            if (entry.value_ptr.name) |n| {
                self.alloc.free(n);
            }
        }
        self.variables.clearRetainingCapacity();

        self.var_symbols.clearRetainingCapacity();
        self.edits.clearRetainingCapacity();
        self.infeasible_rows.clearRetainingCapacity();

        self.objective.deinit(self.alloc);
        self.objective.* = Row.init(0);

        if (self.artificial) |a| {
            a.deinit(self.alloc);
            self.alloc.destroy(a);
            self.artificial = null;
        }

        self.next_var_id = 1;
        self.next_constraint_id = 1;
        self.next_symbol_id = 1;
    }

    // ── Variable management ─────────────────────────────────────────

    /// Mint a new variable. Returns its opaque handle.
    pub fn addVariable(
        self: *Solver,
        debug_name: ?[]const u8,
    ) errors.AddVariableError!VariableId {
        const id: VariableId = @enumFromInt(self.next_var_id);
        self.next_var_id += 1;

        const name_copy: ?[]const u8 = blk: {
            if (debug_name) |n| {
                break :blk try self.alloc.dupe(u8, n);
            }
            break :blk null;
        };
        errdefer if (name_copy) |n| self.alloc.free(n);

        try self.variables.put(self.alloc, id, .{ .name = name_copy });
        return id;
    }

    /// Forget a variable. Constraints referring to this variable
    /// are NOT removed — the caller is responsible for cleanup
    /// ordering. (Matches the layout.md "explicit lifetime"
    /// stance: stage 15 builds keep VarIds keyed by Element.id
    /// stable across re-parses, so the host controls when a
    /// variable should disappear.)
    pub fn removeVariable(self: *Solver, v: VariableId) void {
        if (self.variables.fetchOrderedRemove(v)) |kv| {
            if (kv.value.name) |n| {
                self.alloc.free(n);
            }
        }
        _ = self.var_symbols.orderedRemove(v);
    }

    /// Current value of a variable, as of the last
    /// `updateVariables` call. Returns 0 for unknown variables.
    pub fn value(self: *const Solver, v: VariableId) f64 {
        if (self.variables.get(v)) |record| return record.value;
        return 0.0;
    }

    /// Debug name for a variable, if one was supplied to
    /// `addVariable`.
    pub fn name(self: *const Solver, v: VariableId) ?[]const u8 {
        if (self.variables.get(v)) |record| return record.name;
        return null;
    }

    // ── Cheap predicates ────────────────────────────────────────────

    pub fn hasConstraint(self: *const Solver, c: ConstraintId) bool {
        return self.constraints.contains(c);
    }

    pub fn hasEditVariable(self: *const Solver, v: VariableId) bool {
        return self.edits.contains(v);
    }

    // ── Internal helpers ────────────────────────────────────────────

    /// Look up or mint the External Symbol for a variable. The
    /// invariant: each user-visible Variable has exactly one
    /// External Symbol; the mapping is stable for the variable's
    /// lifetime.
    fn getVarSymbol(
        self: *Solver,
        v: VariableId,
    ) std.mem.Allocator.Error!Symbol {
        const gop = try self.var_symbols.getOrPut(self.alloc, v);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = self.nextSymbolId(), .kind = .external };
        }
        return gop.value_ptr.*;
    }

    fn nextSymbolId(self: *Solver) u32 {
        const id = self.next_symbol_id;
        self.next_symbol_id += 1;
        return id;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "init / deinit doesn't leak" {
    var s = try Solver.init(testing.allocator);
    s.deinit();
}

test "addVariable mints sequential ids starting at 1" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const a = try s.addVariable(null);
    const b = try s.addVariable("debug");
    const c = try s.addVariable(null);

    try testing.expectEqual(@as(u32, 1), @intFromEnum(a));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(b));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(c));
}

test "addVariable preserves debug name when provided" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const a = try s.addVariable("box.x");
    const b = try s.addVariable(null);

    try testing.expectEqualStrings("box.x", s.name(a).?);
    try testing.expectEqual(@as(?[]const u8, null), s.name(b));
}

test "removeVariable forgets the variable" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const a = try s.addVariable("box.x");
    try testing.expectEqualStrings("box.x", s.name(a).?);

    s.removeVariable(a);
    try testing.expectEqual(@as(?[]const u8, null), s.name(a));
    try testing.expectEqual(@as(f64, 0.0), s.value(a));
}

test "value returns 0 for unknown variables" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const unknown: VariableId = @enumFromInt(9999);
    try testing.expectEqual(@as(f64, 0.0), s.value(unknown));
}

test "hasConstraint is false for ids never added" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const unknown: ConstraintId = @enumFromInt(1);
    try testing.expect(!s.hasConstraint(unknown));
}

test "hasEditVariable is false for variables not added as edits" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    try testing.expect(!s.hasEditVariable(v));
}

test "reset clears state and resets the id counter" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    _ = try s.addVariable("v1");
    _ = try s.addVariable("v2");

    s.reset();

    // Variables are gone.
    const old_id: VariableId = @enumFromInt(1);
    try testing.expectEqual(@as(?[]const u8, null), s.name(old_id));

    // Adding produces id=1 again (counter reset).
    const fresh = try s.addVariable(null);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(fresh));
}

test "getVarSymbol mints External symbols lazily, idempotently" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);

    const sym_a = try s.getVarSymbol(v);
    const sym_b = try s.getVarSymbol(v); // same variable → same symbol

    try testing.expect(Symbol.eql(sym_a, sym_b));
    try testing.expectEqual(sym_mod.SymbolKind.external, sym_a.kind);
}

test "different variables get distinct External symbols" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const a = try s.addVariable(null);
    const b = try s.addVariable(null);
    const sym_a = try s.getVarSymbol(a);
    const sym_b = try s.getVarSymbol(b);

    try testing.expect(!Symbol.eql(sym_a, sym_b));
    try testing.expectEqual(sym_mod.SymbolKind.external, sym_a.kind);
    try testing.expectEqual(sym_mod.SymbolKind.external, sym_b.kind);
}
