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

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!LayoutContext {
        return .{
            .alloc = alloc,
            .solver = try kiwi.Solver.init(alloc),
        };
    }

    pub fn deinit(self: *LayoutContext) void {
        self.bounds_map.deinit(self.alloc);
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
