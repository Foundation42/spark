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
const util = @import("util.zig");
const builder_mod = @import("builder.zig");

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

    // ── addConstraint pathway ───────────────────────────────────────

    /// Insert a constraint into the solver, returning its handle.
    /// The solver clones the constraint internally; the caller
    /// retains ownership of the input and is responsible for its
    /// `deinit`.
    pub fn addConstraint(
        self: *Solver,
        constraint: Constraint,
    ) errors.AddConstraintError!ConstraintId {
        // Clone into solver-owned storage so we control freeing.
        var c = try constraint.clone(self.alloc);
        var c_owned = true;
        errdefer if (c_owned) c.deinit(self.alloc);

        var tag = Tag{};
        const row_ptr = try self.createRow(c, &tag);
        var row_owned = true;
        errdefer if (row_owned) {
            row_ptr.deinit(self.alloc);
            self.alloc.destroy(row_ptr);
        };

        var subject = chooseSubject(row_ptr.*, tag);

        // A redundant required equality lands as an all-dummies row
        // with constant zero. If the constant is non-zero, the
        // required constraint is contradictory.
        if (subject.isInvalid() and allDummies(row_ptr.*)) {
            if (!util.nearZero(row_ptr.constant)) {
                return error.UnsatisfiableConstraint;
            }
            subject = tag.marker;
        }

        if (subject.isInvalid()) {
            const success = try self.addWithArtificialVariable(row_ptr.*);
            // The row was consumed by clone-into-art; free our copy.
            row_ptr.deinit(self.alloc);
            self.alloc.destroy(row_ptr);
            row_owned = false;
            if (!success) return error.UnsatisfiableConstraint;
        } else {
            row_ptr.solveFor(subject);
            try self.substitute(subject, row_ptr.*);
            try self.rows.put(self.alloc, subject, row_ptr);
            row_owned = false; // ownership moved to rows map
        }

        try self.optimize(self.objective);

        const id: ConstraintId = @enumFromInt(self.next_constraint_id);
        self.next_constraint_id += 1;
        try self.constraints.put(self.alloc, id, .{ .constraint = c, .tag = tag });
        c_owned = false;

        return id;
    }

    /// Construct a tableau Row from a Constraint, minting slack /
    /// error / dummy symbols as needed and populating `tag`. Soft
    /// constraints simultaneously stuff error coefficients into the
    /// objective (so the objective minimises their violation).
    /// Mirrors `SolverImpl::createRow` (`solverimpl.h`).
    fn createRow(
        self: *Solver,
        constraint: Constraint,
        tag: *Tag,
    ) (errors.AddConstraintError || std.mem.Allocator.Error)!*Row {
        const row_ptr = try self.alloc.create(Row);
        errdefer self.alloc.destroy(row_ptr);
        row_ptr.* = Row.init(constraint.expression.constant);
        errdefer row_ptr.deinit(self.alloc);

        // Substitute any basic external variables; insert
        // non-basic ones with their coefficient.
        for (constraint.expression.terms.items) |term| {
            if (util.nearZero(term.coefficient)) continue;
            const sym = try self.getVarSymbol(term.variable);
            if (self.rows.get(sym)) |basic_row| {
                try row_ptr.insertRow(self.alloc, basic_row.*, term.coefficient);
            } else {
                try row_ptr.insertSymbol(self.alloc, sym, term.coefficient);
            }
        }

        switch (constraint.op) {
            .lt_eq, .gt_eq => {
                const coeff: f64 = if (constraint.op == .lt_eq) 1.0 else -1.0;
                const slack: Symbol = .{ .id = self.nextSymbolId(), .kind = .slack };
                tag.marker = slack;
                try row_ptr.insertSymbol(self.alloc, slack, coeff);
                if (constraint.strength < strength_mod.required) {
                    const err_sym: Symbol = .{ .id = self.nextSymbolId(), .kind = .err };
                    tag.other = err_sym;
                    try row_ptr.insertSymbol(self.alloc, err_sym, -coeff);
                    try self.objective.insertSymbol(self.alloc, err_sym, constraint.strength);
                }
            },
            .eq => {
                if (constraint.strength < strength_mod.required) {
                    const errplus: Symbol = .{ .id = self.nextSymbolId(), .kind = .err };
                    const errminus: Symbol = .{ .id = self.nextSymbolId(), .kind = .err };
                    tag.marker = errplus;
                    tag.other = errminus;
                    try row_ptr.insertSymbol(self.alloc, errplus, -1.0);
                    try row_ptr.insertSymbol(self.alloc, errminus, 1.0);
                    try self.objective.insertSymbol(self.alloc, errplus, constraint.strength);
                    try self.objective.insertSymbol(self.alloc, errminus, constraint.strength);
                } else {
                    const dummy: Symbol = .{ .id = self.nextSymbolId(), .kind = .dummy };
                    tag.marker = dummy;
                    try row_ptr.insertSymbol(self.alloc, dummy, 1.0);
                }
            },
        }

        // Convention: the row's constant must be non-negative so
        // the standard simplex form holds.
        if (row_ptr.constant < 0.0) row_ptr.reverseSign();

        return row_ptr;
    }

    /// Pick the subject of `row` — the symbol to make basic.
    /// Prefer External (user variables) so they're directly
    /// readable; otherwise fall back to a negative-coefficient
    /// slack/error marker; otherwise return invalid. The caller
    /// decides what to do when invalid is returned (the addConstraint
    /// path may resort to addWithArtificialVariable).
    fn chooseSubject(row: Row, tag: Tag) Symbol {
        for (row.cells.keys()) |sym| {
            if (sym.kind == .external) return sym;
        }
        if (tag.marker.kind == .slack or tag.marker.kind == .err) {
            if (row.coefficientFor(tag.marker) < 0.0) return tag.marker;
        }
        if (tag.other.kind == .slack or tag.other.kind == .err) {
            if (row.coefficientFor(tag.other) < 0.0) return tag.other;
        }
        return Symbol.invalid;
    }

    fn allDummies(row: Row) bool {
        for (row.cells.keys()) |sym| {
            if (sym.kind != .dummy) return false;
        }
        return true;
    }

    fn anyPivotableSymbol(row: Row) Symbol {
        for (row.cells.keys()) |sym| {
            if (sym.kind == .slack or sym.kind == .err) return sym;
        }
        return Symbol.invalid;
    }

    /// Phase-1 simplex. Mint an artificial slack, install a copy
    /// of the row keyed by it, run a temporary objective that
    /// minimises the artificial, then either succeeds (and strips
    /// the artificial) or returns false (constraint is
    /// unsatisfiable).
    fn addWithArtificialVariable(
        self: *Solver,
        row: Row,
    ) (errors.AddConstraintError || std.mem.Allocator.Error)!bool {
        const art: Symbol = .{ .id = self.nextSymbolId(), .kind = .slack };

        // Install row-clone keyed by `art`.
        {
            const copy_a = try self.alloc.create(Row);
            errdefer self.alloc.destroy(copy_a);
            copy_a.* = try row.clone(self.alloc);
            errdefer copy_a.deinit(self.alloc);
            try self.rows.put(self.alloc, art, copy_a);
        }

        // Install Phase-1 objective = clone of row.
        {
            const art_obj = try self.alloc.create(Row);
            errdefer self.alloc.destroy(art_obj);
            art_obj.* = try row.clone(self.alloc);
            self.artificial = art_obj;
        }

        try self.optimize(self.artificial.?);
        const success = util.nearZero(self.artificial.?.constant);

        // Drop Phase-1 objective.
        self.artificial.?.deinit(self.alloc);
        self.alloc.destroy(self.artificial.?);
        self.artificial = null;

        // Pivot artificial out if it's still basic.
        if (self.rows.fetchOrderedRemove(art)) |kv| {
            const ptr = kv.value;
            if (ptr.cells.count() == 0) {
                ptr.deinit(self.alloc);
                self.alloc.destroy(ptr);
            } else {
                const entering = anyPivotableSymbol(ptr.*);
                if (entering.isInvalid()) {
                    ptr.deinit(self.alloc);
                    self.alloc.destroy(ptr);
                    return false;
                }
                try ptr.solveForLhsRhs(self.alloc, art, entering);
                try self.substitute(entering, ptr.*);
                try self.rows.put(self.alloc, entering, ptr);
            }
        }

        // Strip the artificial from every remaining row and the
        // objective.
        var it = self.rows.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.remove(art);
        }
        self.objective.remove(art);

        return success;
    }

    /// Substitute `symbol` with `row` across every row, the
    /// objective, and (if active) the artificial objective.
    /// Rows whose constant goes negative under the substitution
    /// get flagged for `dualOptimize` revisit (used by
    /// suggestValue's restoration path).
    fn substitute(
        self: *Solver,
        symbol: Symbol,
        row: Row,
    ) std.mem.Allocator.Error!void {
        var it = self.rows.iterator();
        while (it.next()) |entry| {
            const row_ptr: *Row = entry.value_ptr.*;
            try row_ptr.substitute(self.alloc, symbol, row);
            if (entry.key_ptr.kind != .external and row_ptr.constant < 0.0) {
                try self.infeasible_rows.append(self.alloc, entry.key_ptr.*);
            }
        }
        try self.objective.substitute(self.alloc, symbol, row);
        if (self.artificial) |a| {
            try a.substitute(self.alloc, symbol, row);
        }
    }

    /// Run the simplex until the given objective hits its
    /// optimum (no negative-coefficient symbol to enter).
    /// Pivots: pick an entering symbol; pick the most-restricting
    /// row; pivot; substitute; repeat.
    fn optimize(
        self: *Solver,
        objective: *Row,
    ) error{ InternalSolverError, OutOfMemory }!void {
        while (true) {
            const entering = getEnteringSymbol(objective.*);
            if (entering.isInvalid()) return;

            // Find the leaving row.
            var leaving_idx: ?usize = null;
            var ratio: f64 = std.math.floatMax(f64);
            for (self.rows.keys(), self.rows.values(), 0..) |sym, row_ptr, i| {
                if (sym.kind != .external) {
                    const coeff = row_ptr.coefficientFor(entering);
                    if (coeff < 0.0) {
                        const temp_ratio = -row_ptr.constant / coeff;
                        if (temp_ratio < ratio) {
                            ratio = temp_ratio;
                            leaving_idx = i;
                        }
                    }
                }
            }

            const idx = leaving_idx orelse return error.InternalSolverError;

            const leaving_sym = self.rows.keys()[idx];
            const kv = self.rows.fetchOrderedRemove(leaving_sym);
            std.debug.assert(kv != null);
            const row_ptr = kv.?.value;

            try row_ptr.solveForLhsRhs(self.alloc, leaving_sym, entering);
            try self.substitute(entering, row_ptr.*);
            try self.rows.put(self.alloc, entering, row_ptr);
        }
    }

    /// First symbol in the objective with a negative coefficient
    /// (skipping dummy symbols, which can't enter). Returns
    /// Symbol.invalid when the objective is at its optimum.
    fn getEnteringSymbol(objective: Row) Symbol {
        for (objective.cells.keys(), objective.cells.values()) |sym, coeff| {
            if (sym.kind != .dummy and coeff < 0.0) return sym;
        }
        return Symbol.invalid;
    }

    // ── removeConstraint pathway ────────────────────────────────────

    /// Remove a previously-added constraint by handle. Restores
    /// the tableau to a valid state and re-optimizes. Returns
    /// `UnknownConstraint` if the handle was never produced by
    /// `addConstraint` (or was already removed).
    pub fn removeConstraint(
        self: *Solver,
        c_id: ConstraintId,
    ) errors.RemoveConstraintError!void {
        const removed = self.constraints.fetchOrderedRemove(c_id) orelse return error.UnknownConstraint;
        var owned_cn = removed.value.constraint;
        defer owned_cn.deinit(self.alloc);
        const tag = removed.value.tag;
        const strength = owned_cn.strength;

        try self.removeConstraintEffects(tag, strength);

        // Remove the marker — either it's basic (a row keyed by
        // the marker, drop the row) or it's non-basic (pivot it
        // out using `getMarkerLeavingRow`'s three-bucket
        // precedence).
        if (self.rows.fetchOrderedRemove(tag.marker)) |kv| {
            kv.value.deinit(self.alloc);
            self.alloc.destroy(kv.value);
        } else {
            const idx = self.getMarkerLeavingRow(tag.marker) orelse
                return error.InternalSolverError;
            const leaving_sym = self.rows.keys()[idx];
            const lkv = self.rows.fetchOrderedRemove(leaving_sym);
            std.debug.assert(lkv != null);
            const row_ptr = lkv.?.value;
            defer {
                row_ptr.deinit(self.alloc);
                self.alloc.destroy(row_ptr);
            }
            try row_ptr.solveForLhsRhs(self.alloc, leaving_sym, tag.marker);
            try self.substitute(tag.marker, row_ptr.*);
        }

        try self.optimize(self.objective);
    }

    /// Pull the soft-constraint error contributions out of the
    /// objective when removing the constraint.
    fn removeConstraintEffects(
        self: *Solver,
        tag: Tag,
        strength: Strength,
    ) std.mem.Allocator.Error!void {
        if (tag.marker.kind == .err) {
            try self.removeMarkerEffects(tag.marker, strength);
        }
        if (tag.other.kind == .err) {
            try self.removeMarkerEffects(tag.other, strength);
        }
    }

    fn removeMarkerEffects(
        self: *Solver,
        marker: Symbol,
        strength: Strength,
    ) std.mem.Allocator.Error!void {
        if (self.rows.get(marker)) |row_ptr| {
            try self.objective.insertRow(self.alloc, row_ptr.*, -strength);
        } else {
            try self.objective.insertSymbol(self.alloc, marker, -strength);
        }
    }

    /// Three-bucket precedence pivot selector used when removing
    /// a constraint whose marker isn't basic. Bucket 1:
    /// negative-coefficient non-external rows, min-ratio.
    /// Bucket 2: positive-coefficient non-external rows, min-
    /// ratio. Bucket 3: any External row with a non-zero
    /// coefficient — last one wins. Mirrors C++ kiwi precisely;
    /// this is the load-bearing detail flagged in the recon doc.
    fn getMarkerLeavingRow(self: *Solver, marker: Symbol) ?usize {
        var r1: f64 = std.math.floatMax(f64);
        var r2: f64 = std.math.floatMax(f64);
        var first_idx: ?usize = null;
        var second_idx: ?usize = null;
        var third_idx: ?usize = null;

        for (self.rows.keys(), self.rows.values(), 0..) |sym, row_ptr, i| {
            const c = row_ptr.coefficientFor(marker);
            if (c == 0.0) continue;
            if (sym.kind == .external) {
                third_idx = i;
            } else if (c < 0.0) {
                const r = -row_ptr.constant / c;
                if (r < r1) {
                    r1 = r;
                    first_idx = i;
                }
            } else {
                const r = row_ptr.constant / c;
                if (r < r2) {
                    r2 = r;
                    second_idx = i;
                }
            }
        }

        if (first_idx) |x| return x;
        if (second_idx) |x| return x;
        return third_idx;
    }

    // ── Dual optimization (feasibility restoration) ────────────────

    /// Restore primal feasibility after a constraint constant
    /// change. Drains `infeasible_rows`; each entry whose row is
    /// still negative-constant gets a dual pivot. Used by
    /// `suggestValue` (and silently after `removeConstraint`'s
    /// substitute step, via the next call that drains the list).
    fn dualOptimize(
        self: *Solver,
    ) error{ InternalSolverError, OutOfMemory }!void {
        while (self.infeasible_rows.items.len > 0) {
            const leaving = self.infeasible_rows.pop().?;
            const row_ptr = self.rows.get(leaving) orelse continue;
            if (row_ptr.constant >= 0.0) continue; // already feasible

            const entering = self.getDualEnteringSymbol(row_ptr.*);
            if (entering.isInvalid()) return error.InternalSolverError;

            const kv = self.rows.fetchOrderedRemove(leaving);
            std.debug.assert(kv != null);
            const ptr = kv.?.value;
            try ptr.solveForLhsRhs(self.alloc, leaving, entering);
            try self.substitute(entering, ptr.*);
            try self.rows.put(self.alloc, entering, ptr);
        }
    }

    /// Symbol with the smallest objective-coefficient / row-
    /// coefficient ratio among the row's positive-coefficient,
    /// non-dummy cells. The dual variant of `getEnteringSymbol`.
    fn getDualEnteringSymbol(self: *const Solver, row: Row) Symbol {
        var entering: Symbol = Symbol.invalid;
        var ratio: f64 = std.math.floatMax(f64);
        for (row.cells.keys(), row.cells.values()) |sym, coeff| {
            if (coeff > 0.0 and sym.kind != .dummy) {
                const obj_coeff = self.objective.coefficientFor(sym);
                const r = obj_coeff / coeff;
                if (r < ratio) {
                    ratio = r;
                    entering = sym;
                }
            }
        }
        return entering;
    }

    // ── Edit variables (per-frame reactive path) ───────────────────

    /// Register a variable as editable. The solver inserts a
    /// synthetic soft equality constraint (`v == 0` at the given
    /// strength); later `suggestValue` calls drive the variable's
    /// target via a fast delta path without re-pivoting most of
    /// the tableau.
    ///
    /// `strength` is clipped to `[0, required]`; required-strength
    /// is rejected with `BadRequiredStrength` (the whole point of
    /// edit variables is they're soft).
    pub fn addEditVariable(
        self: *Solver,
        v: VariableId,
        strength: Strength,
    ) errors.AddEditVariableError!void {
        if (self.edits.contains(v)) return error.DuplicateEditVariable;

        const clipped = strength_mod.clip(strength);
        if (clipped == strength_mod.required) return error.BadRequiredStrength;

        var c = constraint_mod.Constraint{
            .expression = try @import("expression.zig").Expression.initTerm(
                self.alloc,
                @import("term.zig").Term.of(v),
            ),
            .op = .eq,
            .strength = clipped,
        };
        defer c.deinit(self.alloc); // addConstraint clones internally

        const c_id = self.addConstraint(c) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // A simple `v == 0` soft equality can't really fail
            // with the other variants on a well-formed solver
            // state, but propagate them as InternalSolverError if
            // they do.
            error.DuplicateConstraint,
            error.UnsatisfiableConstraint,
            error.InternalSolverError,
            => return error.InternalSolverError,
        };

        const entry = self.constraints.get(c_id).?;
        try self.edits.put(self.alloc, v, .{
            .tag = entry.tag,
            .constraint = c_id,
            .constant = 0.0,
        });
    }

    /// Forget an edit variable; tears down the underlying
    /// synthetic constraint.
    pub fn removeEditVariable(
        self: *Solver,
        v: VariableId,
    ) errors.RemoveEditVariableError!void {
        const info_kv = self.edits.fetchOrderedRemove(v) orelse return error.UnknownEditVariable;
        self.removeConstraint(info_kv.value.constraint) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownConstraint, error.InternalSolverError => return error.InternalSolverError,
        };
    }

    /// Suggest a new value for an edit variable. The solver
    /// applies the delta to the marker row (or other / all rows
    /// if the marker isn't basic) and then runs `dualOptimize`
    /// to restore primal feasibility. This is the per-frame fast
    /// path — typical cost is single-digit microseconds.
    pub fn suggestValue(
        self: *Solver,
        v: VariableId,
        value_in: f64,
    ) errors.SuggestValueError!void {
        const info_ptr = self.edits.getPtr(v) orelse return error.UnknownEditVariable;

        const delta = value_in - info_ptr.constant;
        info_ptr.constant = value_in;
        const tag = info_ptr.tag;

        // Apply the delta. The delta-walk path can fail (OOM
        // appending to infeasible_rows); we capture and defer to
        // after dualOptimize.
        var apply_err: ?errors.SuggestValueError = null;
        self.applyEditDelta(tag, delta) catch |e| switch (e) {
            error.OutOfMemory => apply_err = error.OutOfMemory,
        };

        // RAII-style: always run dualOptimize so the tableau ends
        // in a valid state. If dualOptimize itself fails, surface
        // its error (the more specific one).
        self.dualOptimize() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InternalSolverError => return error.InternalSolverError,
        };

        if (apply_err) |e| return e;
    }

    /// Apply the suggest-delta to the tableau. Three cases per
    /// kiwi's `suggestValue`: marker basic, other basic, neither
    /// basic (walk all rows applying delta * marker-coeff).
    fn applyEditDelta(
        self: *Solver,
        tag: Tag,
        delta: f64,
    ) std.mem.Allocator.Error!void {
        if (self.rows.get(tag.marker)) |row_ptr| {
            if (row_ptr.add(-delta) < 0.0) {
                try self.infeasible_rows.append(self.alloc, tag.marker);
            }
            return;
        }
        if (self.rows.get(tag.other)) |row_ptr| {
            if (row_ptr.add(delta) < 0.0) {
                try self.infeasible_rows.append(self.alloc, tag.other);
            }
            return;
        }
        for (self.rows.keys(), self.rows.values()) |sym, row_ptr| {
            const coeff = row_ptr.coefficientFor(tag.marker);
            if (coeff != 0.0) {
                if (row_ptr.add(delta * coeff) < 0.0 and sym.kind != .external) {
                    try self.infeasible_rows.append(self.alloc, sym);
                }
            }
        }
    }

    // ── Public read path ────────────────────────────────────────────

    /// Refresh the cached `value()` of every variable from the
    /// current row constants. External variables that are basic
    /// (key in `rows`) take the row's constant; non-basic
    /// externals are 0. Mirrors kiwi's `Solver::updateVariables`.
    pub fn updateVariables(self: *Solver) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            const var_id = entry.key_ptr.*;
            if (self.var_symbols.get(var_id)) |sym| {
                if (self.rows.get(sym)) |row_ptr| {
                    entry.value_ptr.value = row_ptr.constant;
                } else {
                    entry.value_ptr.value = 0.0;
                }
            }
        }
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

// ── End-to-end tests (addConstraint + updateVariables + value) ──────

const expr = builder_mod.expr;

/// Build, transfer ownership to the solver, and clean up the
/// caller-side handle. Used by the tests below.
fn buildAndAdd(
    s: *Solver,
    alloc: std.mem.Allocator,
    c: Constraint,
) errors.AddConstraintError!ConstraintId {
    var owned = c;
    defer owned.deinit(alloc);
    return s.addConstraint(owned);
}

test "addConstraint: smoke (v == 10 required)" {
    // From corpus: smoke_single_equality_to_constant.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable("v");
    const c = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(v), 1e-9);
}

test "addConstraint: two-var equality + anchor (v1 + v2 == 0; v1 == 10)" {
    // From corpus: smoke_equality_between_two_vars → v1=10, v2=-10.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v1 = try s.addVariable("v1");
    const v2 = try s.addVariable("v2");

    const c1 = try expr(testing.allocator, v1).plus(v2).eq(@as(f64, 0)).required();
    _ = try buildAndAdd(&s, testing.allocator, c1);

    const c2 = try expr(testing.allocator, v1).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c2);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(v1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10), s.value(v2), 1e-9);
}

test "addConstraint: three-variable chain (x1+x2+x3 == 30; x1=5; x2=10)" {
    // From corpus: smoke_three_variable_chain → x3=15.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const x1 = try s.addVariable("x1");
    const x2 = try s.addVariable("x2");
    const x3 = try s.addVariable("x3");

    const c_sum = try expr(testing.allocator, x1).plus(x2).plus(x3).eq(@as(f64, 30)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_sum);

    const c_x1 = try expr(testing.allocator, x1).eq(@as(f64, 5)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_x1);

    const c_x2 = try expr(testing.allocator, x2).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_x2);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 5), s.value(x1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(x2), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 15), s.value(x3), 1e-9);
}

test "addConstraint: lower bound is tight (v >= 10 required → v == 10)" {
    // From corpus: ineq_lower_bound_only. Variables default to a
    // weak stay-near-zero preference, so the lower bound is the
    // minimum-movement solution.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable("v");
    const c = try expr(testing.allocator, v).geq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(v), 1e-9);
}

test "addConstraint: required overrides weak (v == 10 req + v == 20 weak)" {
    // From corpus: strength_required_overrides_weak.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable("v");

    const c_req = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_req);
    const c_weak = try expr(testing.allocator, v).eq(@as(f64, 20)).weak();
    _ = try buildAndAdd(&s, testing.allocator, c_weak);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(v), 1e-9);
}

test "addConstraint: unsatisfiable required pair returns error" {
    // Two contradictory required equalities → UnsatisfiableConstraint.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable("v");

    const c1 = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c1);

    const c2 = try expr(testing.allocator, v).eq(@as(f64, 20)).required();
    try testing.expectError(error.UnsatisfiableConstraint, buildAndAdd(&s, testing.allocator, c2));
}

test "addConstraint: returned id is tracked via hasConstraint" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    const c = try expr(testing.allocator, v).eq(@as(f64, 0)).required();
    const id = try buildAndAdd(&s, testing.allocator, c);

    try testing.expect(s.hasConstraint(id));

    const other: ConstraintId = @enumFromInt(@intFromEnum(id) + 999);
    try testing.expect(!s.hasConstraint(other));
}

test "removeConstraint: hasConstraint becomes false" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    const c = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    const id = try buildAndAdd(&s, testing.allocator, c);
    try testing.expect(s.hasConstraint(id));

    try s.removeConstraint(id);
    try testing.expect(!s.hasConstraint(id));
}

test "removeConstraint: unknown id returns error" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const bogus: ConstraintId = @enumFromInt(999);
    try testing.expectError(error.UnknownConstraint, s.removeConstraint(bogus));
}

test "remove then re-add yields the same value" {
    // From corpus: remove_then_readd_idempotent.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable("v");

    const c1 = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    const id1 = try buildAndAdd(&s, testing.allocator, c1);
    s.updateVariables();
    const val1 = s.value(v);

    try s.removeConstraint(id1);

    const c2 = try expr(testing.allocator, v).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c2);
    s.updateVariables();
    const val2 = s.value(v);

    try testing.expectApproxEqAbs(val1, val2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), val2, 1e-9);
}

// ── Edit-variable tests ─────────────────────────────────────────────

test "addEditVariable + suggestValue drives the variable" {
    // From corpus: edit_managing_lifecycle / edit_suggest_value_weak_equality.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable("v");
    try s.addEditVariable(v, strength_mod.medium);
    try s.suggestValue(v, 42.0);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 42), s.value(v), 1e-9);
}

test "addEditVariable rejects required strength" {
    // From corpus: strength_required_edit_var_is_error.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    try testing.expectError(
        error.BadRequiredStrength,
        s.addEditVariable(v, strength_mod.required),
    );
}

test "addEditVariable twice returns DuplicateEditVariable" {
    // From corpus: error_duplicate_edit_variable.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    try s.addEditVariable(v, strength_mod.medium);
    try testing.expectError(
        error.DuplicateEditVariable,
        s.addEditVariable(v, strength_mod.medium),
    );
}

test "suggestValue on unknown variable returns error" {
    // From corpus: error_unknown_edit_variable.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    try testing.expectError(error.UnknownEditVariable, s.suggestValue(v, 5));
}

test "removeEditVariable forgets it; further suggestValue errors" {
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    try s.addEditVariable(v, strength_mod.medium);
    try testing.expect(s.hasEditVariable(v));

    try s.removeEditVariable(v);
    try testing.expect(!s.hasEditVariable(v));
    try testing.expectError(error.UnknownEditVariable, s.suggestValue(v, 5));
}

test "repeated suggestValue updates incrementally (the per-frame path)" {
    // From corpus: edit_repeated_suggest_reuses_pivots. We don't
    // measure pivot reuse here, but verify that successive
    // suggestions all reach the asked-for value.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const v = try s.addVariable(null);
    try s.addEditVariable(v, strength_mod.strong);

    try s.suggestValue(v, 10.0);
    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(v), 1e-9);

    try s.suggestValue(v, 100.0);
    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 100), s.value(v), 1e-9);

    try s.suggestValue(v, -5.0);
    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, -5), s.value(v), 1e-9);
}

test "suggested value reflows dependent variables" {
    // The killer-demo flow in miniature: pin a derived variable
    // via a required equation, edit the input, watch the derived
    // value follow.
    //   out == 2*in + 3  (required)
    //   addEditVariable(in, strong); suggestValue(in, 5);  → out = 13
    //   suggestValue(in, 10);                              → out = 23
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const in = try s.addVariable("in");
    const out = try s.addVariable("out");

    const c = try expr(testing.allocator, out).minus(expr(testing.allocator, in).times(2.0)).eq(@as(f64, 3)).required();
    _ = try buildAndAdd(&s, testing.allocator, c);

    try s.addEditVariable(in, strength_mod.strong);

    try s.suggestValue(in, 5.0);
    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 5), s.value(in), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 13), s.value(out), 1e-9);

    try s.suggestValue(in, 10.0);
    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 10), s.value(in), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 23), s.value(out), 1e-9);
}

test "remove preserves other constraints" {
    // From corpus: add_remove_preserves_other_constraints.
    // Pin two vars; remove one constraint; the other still holds.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const a = try s.addVariable("a");
    const b = try s.addVariable("b");

    const c_a = try expr(testing.allocator, a).eq(@as(f64, 5)).required();
    const id_a = try buildAndAdd(&s, testing.allocator, c_a);
    const c_b = try expr(testing.allocator, b).eq(@as(f64, 7)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_b);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 5), s.value(a), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7), s.value(b), 1e-9);

    try s.removeConstraint(id_a);
    s.updateVariables();

    // b's constraint remains in force.
    try testing.expectApproxEqAbs(@as(f64, 7), s.value(b), 1e-9);
}

test "addConstraint: difference constraint (mid = (a+b)/2; a=10; b=30)" {
    // Builder doesn't fold (a+b)/2 in one step; we express as
    // 2*mid == a + b, which is equivalent.
    var s = try Solver.init(testing.allocator);
    defer s.deinit();

    const a = try s.addVariable("a");
    const b = try s.addVariable("b");
    const mid = try s.addVariable("mid");

    // 2*mid == a + b  →  2*mid - a - b == 0
    const c_mid = try expr(testing.allocator, mid).times(2.0).minus(a).minus(b).eq(@as(f64, 0)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_mid);

    const c_a = try expr(testing.allocator, a).eq(@as(f64, 10)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_a);
    const c_b = try expr(testing.allocator, b).eq(@as(f64, 30)).required();
    _ = try buildAndAdd(&s, testing.allocator, c_b);

    s.updateVariables();
    try testing.expectApproxEqAbs(@as(f64, 20), s.value(mid), 1e-9);
}
