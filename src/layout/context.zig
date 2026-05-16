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

pub const LayoutContext = struct {
    solver: kiwi.Solver,

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!LayoutContext {
        return .{ .solver = try kiwi.Solver.init(alloc) };
    }

    pub fn deinit(self: *LayoutContext) void {
        self.solver.deinit();
        self.* = undefined;
    }

    /// Reset the solver for a fresh layout pass. Pool allocations
    /// stay; the variable / constraint / row maps clear; counters
    /// reset to 1. Cheap (microseconds) compared to re-running
    /// layout against the document tree.
    ///
    /// Phase B keeps this simple by resetting *every* pass —
    /// constraints don't persist across frames. Phase B.3 (later)
    /// converts to persistent variables keyed by element id so the
    /// retained-layout-cache hit rate carries into the solver.
    pub fn beginPass(self: *LayoutContext) void {
        self.solver.reset();
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
