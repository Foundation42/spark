//! `LayoutContext` — the integration handshake between text_engine
//! and the kiwi constraint solver.
//!
//! Phase B (the first integration) keeps this thin: it owns one
//! `kiwi.Solver`, exposes `beginPass` to reset it before each
//! layout pass, and that's it. Components reach into `ctx.solver`
//! directly to mint variables and add constraints; the abstraction
//! layer (`boundsFor(elem_id)` etc.) lands once more than one
//! component participates.
//!
//! Lifetime: created once by the host (peer to `layout_cache`),
//! deinit'd on shutdown. The solver's pools retain their
//! allocations across `beginPass` (via `Solver.reset` /
//! `clearRetainingCapacity`), so a 1000-block layout that's
//! 90% cache-hit still pays the per-frame variable mint cost
//! only on cache-miss blocks.

const std = @import("std");
pub const kiwi = @import("kiwi/root.zig");

/// Four-variable bounding box for a layout-participating element.
/// `(x_min, y_min)` is the top-left corner; `(x_max, y_max)` is
/// bottom-right. The walker reads positions back via
/// `solver.value(x)` after each pass settles.
pub const ElementBounds = struct {
    x_min: kiwi.VariableId,
    x_max: kiwi.VariableId,
    y_min: kiwi.VariableId,
    y_max: kiwi.VariableId,
};

/// Which dimension of a participating element a suggestion targets.
/// Phase D ships `width` + `height` (the two channels a drag handle
/// drives); `x` / `y` are anchor-position suggestions that future
/// move-handles will use. The axis selects which solver variable
/// the suggestion translates to: `width` → edit-var on `x_max`
/// (with `x_min` still anchored); `height` → edit-var on `y_max`;
/// `x` → edit-var on `x_min` (and `x_max` follows from any width
/// constraint); `y` → edit-var on `y_min`.
pub const Axis = enum { width, height, x, y };

/// Stable key for one suggestion. `component_key` is whatever the
/// component used to mint its bounds (typically
/// `@intFromPtr(ctx)`); `axis` disambiguates the dimension. The
/// host's drag handler stores a suggestion against this key; the
/// target component's layout pass reads it back via
/// `getSuggestion`. The pair is densely packed into a u96-style
/// struct hashable directly.
pub const SuggestionKey = struct {
    component_key: u64,
    axis: Axis,
};

/// Per-key version bumper. Suggestion mutations bump the target
/// component's content version through this callback so the
/// retained block-layout cache invalidates and the next walk picks
/// up the new value. Each participating component registers one
/// during its first layout pass; the registration is cleared by
/// `beginPass` and re-established on every walk, keeping stale
/// entries from outliving their owners. Suggestions, by contrast,
/// persist across `beginPass` so dragged layouts stay put.
pub const VersionBumper = struct {
    bump: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const LayoutContext = struct {
    alloc: std.mem.Allocator,
    solver: kiwi.Solver,
    /// Per-pass element → bounds map. Keyed by an opaque u64 the
    /// caller chooses (typically `@intFromPtr(component_ctx)`,
    /// which is unique per live component instance). Cleared on
    /// `beginPass`. Phase C `:::flex` reaches in via the parent's
    /// walker to constrain `child[i+1].x_min == child[i].x_max +
    /// gap` without the children needing to expose their VarIds.
    bounds_map: std.AutoHashMapUnmanaged(u64, ElementBounds) = .{},
    /// Guards all solver + bounds_map mutation. The stage-14b
    /// parallel walker dispatches cache-miss `:::box` blocks onto
    /// worker threads, and every such block currently runs the
    /// constraint-path (`box.layoutViaConstraints`) which mints
    /// variables, adds constraints, solves, and reads back values.
    /// The kiwi solver's internal `AutoArrayHashMap`s carry Zig's
    /// pointer-stability safety lock, which trips the moment two
    /// workers touch the solver concurrently. We lock the whole
    /// add-constraints + updateVariables + value-read sequence so
    /// each worker's per-box pattern is atomic w.r.t. the others.
    /// Critical section is ~10-30µs per box — well within the
    /// frame budget even when serialising across N workers.
    mutex: std.Thread.Mutex = .{},

    /// Persistent suggestions from outside the layout pass (drag
    /// handlers, future scripted layouts, etc.). Survives every
    /// `beginPass` — only explicit `clearSuggestion` or
    /// `clearAllSuggestions` removes entries. Components consult
    /// this during their layout pass and translate present
    /// suggestions into kiwi `addEditVariable` + `suggestValue`
    /// calls at medium strength.
    suggestions: std.AutoHashMapUnmanaged(SuggestionKey, f64) = .{},

    /// Per-pass version-bumper registrations. Cleared by
    /// `beginPass` and re-registered by participating components on
    /// each walk. `setSuggestion` invokes the registered bumper for
    /// the suggestion's component key so the block-layout cache
    /// invalidates and the next walk picks up the change. Cleared
    /// per-pass (rather than persisting like `suggestions`) so
    /// stale entries from deinit'd components can't be dispatched.
    bumpers: std.AutoHashMapUnmanaged(u64, VersionBumper) = .{},

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!LayoutContext {
        return .{
            .alloc = alloc,
            .solver = try kiwi.Solver.init(alloc),
        };
    }

    pub fn deinit(self: *LayoutContext) void {
        self.bounds_map.deinit(self.alloc);
        self.suggestions.deinit(self.alloc);
        self.bumpers.deinit(self.alloc);
        self.solver.deinit();
        self.* = undefined;
    }

    /// Reset the solver and clear the bounds map for a fresh
    /// layout pass. Pool allocations stay (capacities retained);
    /// the variable / constraint / row / bounds maps clear;
    /// counters reset to 1. Cheap (microseconds) compared to
    /// re-running layout against the document tree.
    ///
    /// Phase B keeps this simple by resetting *every* pass —
    /// constraints don't persist across frames. A later phase
    /// converts to persistent variables across frames so the
    /// retained-layout-cache hit rate carries into the solver.
    pub fn beginPass(self: *LayoutContext) void {
        self.solver.reset();
        self.bounds_map.clearRetainingCapacity();
        // Bumpers are per-walk — drop them all so a component that
        // disappeared between frames can't get re-dispatched.
        // Participating components re-register during their layout
        // pass via `registerBumper`.
        self.bumpers.clearRetainingCapacity();
    }

    /// Store a suggestion for `(key, axis)` at the given value.
    /// Participating components consult `getSuggestion` during their
    /// next layout pass and translate present suggestions into
    /// `addEditVariable + suggestValue` against their bounds. If a
    /// version bumper is registered for `key`, it fires immediately
    /// so the block-layout cache invalidates and the next walk
    /// actually picks up the change.
    ///
    /// Idempotent: re-suggesting the same value is a no-op (no bump
    /// fires) so drag handlers can call this on every mouse_move
    /// without paying re-layout cost when the cursor hasn't moved.
    pub fn setSuggestion(self: *LayoutContext, key: u64, axis: Axis, value: f64) std.mem.Allocator.Error!void {
        const sk: SuggestionKey = .{ .component_key = key, .axis = axis };
        const gop = try self.suggestions.getOrPut(self.alloc, sk);
        const changed = !gop.found_existing or gop.value_ptr.* != value;
        gop.value_ptr.* = value;
        if (changed) {
            if (self.bumpers.get(key)) |b| b.bump(b.ctx);
        }
    }

    /// Drop the suggestion for `(key, axis)`. If a suggestion was
    /// present, fires the registered bumper so the target re-walks
    /// without it. No-op when there's nothing to clear.
    pub fn clearSuggestion(self: *LayoutContext, key: u64, axis: Axis) void {
        const sk: SuggestionKey = .{ .component_key = key, .axis = axis };
        if (self.suggestions.remove(sk)) {
            if (self.bumpers.get(key)) |b| b.bump(b.ctx);
        }
    }

    /// Read back the stored suggestion for `(key, axis)`, or null
    /// when nothing's been set. Cheap — callers walk the four axes
    /// of their bounds every pass.
    pub fn getSuggestion(self: *const LayoutContext, key: u64, axis: Axis) ?f64 {
        const sk: SuggestionKey = .{ .component_key = key, .axis = axis };
        return self.suggestions.get(sk);
    }

    /// Wipe every suggestion. Reserved for explicit "reset layout"
    /// actions; not called by `beginPass`. No bumpers fire — the
    /// caller is expected to have already torn down whatever was
    /// driving the suggestions.
    pub fn clearAllSuggestions(self: *LayoutContext) void {
        self.suggestions.clearRetainingCapacity();
    }

    /// Register a version bumper for `key`. Called by each
    /// participating component during its layout pass — the
    /// registration is cleared on the next `beginPass`. `bump` is
    /// invoked synchronously inside `setSuggestion` /
    /// `clearSuggestion` when the stored value for `key` actually
    /// changes; the typical implementation bumps the component's
    /// `version` counter so the retained layout cache treats the
    /// next walk as a fresh miss.
    pub fn registerBumper(self: *LayoutContext, key: u64, bumper: VersionBumper) std.mem.Allocator.Error!void {
        try self.bumpers.put(self.alloc, key, bumper);
    }

    /// Mint (or return) the four bounds variables for an
    /// element. Same key in the same pass returns the same
    /// variables — the lookup is idempotent. Both the element
    /// itself (when adding its width/height constraints) and any
    /// parent provider (when adding sibling-relationship
    /// constraints) call this with the same key to negotiate
    /// against the same vars.
    ///
    /// Typical key choice: `@intFromPtr(component_ctx)`. Stable
    /// for the lifetime of the component instance, unique among
    /// concurrent components, no allocation needed.
    pub fn getBounds(self: *LayoutContext, key: u64) std.mem.Allocator.Error!ElementBounds {
        const gop = try self.bounds_map.getOrPut(self.alloc, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .x_min = try self.solver.addVariable(null),
                .x_max = try self.solver.addVariable(null),
                .y_min = try self.solver.addVariable(null),
                .y_max = try self.solver.addVariable(null),
            };
        }
        return gop.value_ptr.*;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "LayoutContext init / deinit does not leak" {
    var ctx = try LayoutContext.init(testing.allocator);
    ctx.deinit();
}

test "beginPass clears solver state but preserves the context" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    _ = try ctx.solver.addVariable("scratch");
    ctx.beginPass();

    // After beginPass, the previously-minted variable should be
    // gone; the next variable mint starts at id=1 again.
    const fresh = try ctx.solver.addVariable(null);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(fresh));
}

test "getBounds is idempotent — same key returns same vars" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const b1 = try ctx.getBounds(42);
    const b2 = try ctx.getBounds(42);

    try testing.expectEqual(b1.x_min, b2.x_min);
    try testing.expectEqual(b1.x_max, b2.x_max);
    try testing.expectEqual(b1.y_min, b2.y_min);
    try testing.expectEqual(b1.y_max, b2.y_max);
}

test "getBounds: different keys get distinct variable sets" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const a = try ctx.getBounds(1);
    const b = try ctx.getBounds(2);

    try testing.expect(@intFromEnum(a.x_min) != @intFromEnum(b.x_min));
    try testing.expect(@intFromEnum(a.x_max) != @intFromEnum(b.x_max));
}

test "beginPass clears the bounds map; ids re-mint after" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const before = try ctx.getBounds(99);
    const first_var_id = @intFromEnum(before.x_min);
    try testing.expectEqual(@as(u32, 1), first_var_id);

    ctx.beginPass();

    const after = try ctx.getBounds(99);
    // beginPass resets the variable id counter; re-mint starts at 1.
    try testing.expectEqual(@as(u32, 1), @intFromEnum(after.x_min));
}

test "two sibling boxes share a flex-style gap constraint" {
    // The Phase C pattern in miniature: a parent allocates bounds
    // for two children + an inter-sibling gap constraint.
    // box1.x = 0, box1.width = 100; box2.x_min = box1.x_max + 20;
    // box2.width = 100 — settles to box2 at x=120..220.
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const a = try ctx.getBounds(@intFromPtr(&ctx)); // arbitrary key A
    const b = try ctx.getBounds(@intFromPtr(&ctx) + 1); // arbitrary key B

    var c1 = try kiwi.expr(testing.allocator, a.x_min).eq(@as(f64, 0)).required();
    defer c1.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c1);

    var c2 = try kiwi.expr(testing.allocator, a.x_max).minus(a.x_min).eq(@as(f64, 100)).required();
    defer c2.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c2);

    var c3 = try kiwi.expr(testing.allocator, b.x_min).minus(a.x_max).eq(@as(f64, 20)).required();
    defer c3.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c3);

    var c4 = try kiwi.expr(testing.allocator, b.x_max).minus(b.x_min).eq(@as(f64, 100)).required();
    defer c4.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c4);

    ctx.solver.updateVariables();

    try testing.expectApproxEqAbs(@as(f64, 0), ctx.solver.value(a.x_min), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100), ctx.solver.value(a.x_max), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 120), ctx.solver.value(b.x_min), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 220), ctx.solver.value(b.x_max), 1e-9);
}

test "suggestion: set / get / clear roundtrip" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(ctx.getSuggestion(42, .width) == null);

    try ctx.setSuggestion(42, .width, 250.0);
    try testing.expectEqual(@as(?f64, 250.0), ctx.getSuggestion(42, .width));
    try testing.expect(ctx.getSuggestion(42, .height) == null);
    try testing.expect(ctx.getSuggestion(43, .width) == null);

    ctx.clearSuggestion(42, .width);
    try testing.expect(ctx.getSuggestion(42, .width) == null);
}

test "suggestion: survives beginPass" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.setSuggestion(99, .width, 180.0);
    ctx.beginPass();
    try testing.expectEqual(@as(?f64, 180.0), ctx.getSuggestion(99, .width));
}

test "suggestion: changed value fires the registered bumper" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const Counter = struct {
        var hits: u32 = 0;
        fn bump(_: *anyopaque) void {
            hits += 1;
        }
    };
    Counter.hits = 0;

    var dummy: u8 = 0;
    try ctx.registerBumper(7, .{ .bump = Counter.bump, .ctx = &dummy });

    // First set — bumper fires (new entry).
    try ctx.setSuggestion(7, .width, 100.0);
    try testing.expectEqual(@as(u32, 1), Counter.hits);

    // Re-set same value — bumper does NOT fire (idempotent).
    try ctx.setSuggestion(7, .width, 100.0);
    try testing.expectEqual(@as(u32, 1), Counter.hits);

    // Change value — bumper fires.
    try ctx.setSuggestion(7, .width, 200.0);
    try testing.expectEqual(@as(u32, 2), Counter.hits);

    // Clear — bumper fires.
    ctx.clearSuggestion(7, .width);
    try testing.expectEqual(@as(u32, 3), Counter.hits);
}

test "beginPass clears bumpers but not suggestions" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const Stub = struct {
        fn bump(_: *anyopaque) void {}
    };
    var d: u8 = 0;
    try ctx.registerBumper(1, .{ .bump = Stub.bump, .ctx = &d });
    try ctx.setSuggestion(1, .width, 100.0);

    ctx.beginPass();

    try testing.expect(!ctx.bumpers.contains(1));
    try testing.expectEqual(@as(?f64, 100.0), ctx.getSuggestion(1, .width));
}

test "the box-style four-var pattern settles to anchor + size" {
    // Phase B's box.layoutAndRender does exactly this: mint four
    // bounds variables, add four required equalities, read back
    // the resolved positions. Verify the pattern produces what
    // the existing imperative path would.
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const x_min = try ctx.solver.addVariable("box.x_min");
    const x_max = try ctx.solver.addVariable("box.x_max");
    const y_min = try ctx.solver.addVariable("box.y_min");
    const y_max = try ctx.solver.addVariable("box.y_max");

    // origin=(10, 20), w=200, h=80
    var c1 = try kiwi.expr(testing.allocator, x_min).eq(@as(f64, 10)).required();
    defer c1.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c1);
    var c2 = try kiwi.expr(testing.allocator, y_min).eq(@as(f64, 20)).required();
    defer c2.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c2);
    var c3 = try kiwi.expr(testing.allocator, x_max).minus(x_min).eq(@as(f64, 200)).required();
    defer c3.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c3);
    var c4 = try kiwi.expr(testing.allocator, y_max).minus(y_min).eq(@as(f64, 80)).required();
    defer c4.deinit(testing.allocator);
    _ = try ctx.solver.addConstraint(c4);

    ctx.solver.updateVariables();

    try testing.expectApproxEqAbs(@as(f64, 10), ctx.solver.value(x_min), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), ctx.solver.value(y_min), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 210), ctx.solver.value(x_max), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100), ctx.solver.value(y_max), 1e-9);
}
