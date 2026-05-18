//! `LayoutContext` — the integration handshake between spark and
//! the kiwi constraint solver.
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

/// Axis-aligned rectangle excluded from inline flow (stage 15 Phase E
/// text exclusion / shape-outside). Pixel coords in the document's
/// display space — the same frame the inline-flow walker thinks in.
/// `side` records which edge the rect hugs; the inline-flow wrap
/// query uses it to decide whether the rect shrinks the line from the
/// left or the right.
pub const ExclusionSide = enum { left, right };

pub const ExclusionRect = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
    side: ExclusionSide,
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

    /// Persistent version-bumper registrations. `setSuggestion`
    /// invokes the registered bumper for the suggestion's component
    /// key so the block-layout cache invalidates and the next walk
    /// picks up the change. Stage 15 Phase C.4 (hierarchical cache
    /// invalidation): bumpers persist across `beginPass` so that
    /// components which were cache-hit (and therefore didn't
    /// re-register during the walk) still get their version bumped
    /// when a suggestion lands. Lifecycle is now register-once on
    /// first walk, unregister at component deinit via
    /// `unregisterBumper`.
    bumpers: std.AutoHashMapUnmanaged(u64, VersionBumper) = .{},

    /// Persistent post-layout size cache (stage 15 Phase C.4). Each
    /// constraint-participating component writes its resolved `(w, h)`
    /// here after every walk (cache hit or miss) via the
    /// `ElementVTable.on_layout_complete` hook. Drag handlers read
    /// from here when the per-pass `bounds_map` is empty — which
    /// happens whenever the target was cache-hit and therefore
    /// didn't re-add itself to the solver this frame. Survives
    /// `beginPass`; cleared on explicit `clearAllSizes` or implicitly
    /// when a component overwrites its entry.
    last_sizes: std.AutoHashMapUnmanaged(u64, [2]f32) = .{},

    /// Active rect exclusions for the current pass (stage 15 Phase E —
    /// text exclusion / shape-outside, v1). Cleared on `beginPass`;
    /// repopulated as floated components are walked. The inline-flow
    /// wrap loop queries `lineBounds` per line to shrink usable
    /// x-range; the cache-key seed (`exclusionsHash`) folds into
    /// paragraph cache keys so a float arriving above a paragraph
    /// invalidates the paragraph's cached wrap.
    ///
    /// V1 is rect-only and assumes floats hug the column's left/right
    /// edge. Polygons + per-line spans are v2/v3 territory.
    exclusions: std.ArrayListUnmanaged(ExclusionRect) = .{},

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
        self.last_sizes.deinit(self.alloc);
        self.exclusions.deinit(self.alloc);
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
        // Exclusions are per-pass *outputs* — floated components
        // re-register their rect every walk (cache hit and miss alike,
        // via `on_layout_complete`). The list is rebuilt fresh each
        // pass so a float that disappeared from the document doesn't
        // leave a phantom hole in following paragraphs.
        self.exclusions.clearRetainingCapacity();
        // Bumpers and last_sizes are persistent — they survive across
        // beginPass. Bumpers get unregistered explicitly on component
        // deinit; last_sizes are overwritten on each walk that records
        // a new size. Persistence is what lets cache-hit components
        // still respond to suggestion changes and lets drag handlers
        // read sizes without forcing a re-walk.
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
    /// participating component on first walk. `bump` is invoked
    /// synchronously inside `setSuggestion` / `clearSuggestion` when
    /// the stored value for `key` actually changes; the typical
    /// implementation bumps the component's `version` counter so the
    /// retained layout cache treats the next walk as a fresh miss.
    ///
    /// Persistent across `beginPass` — `put` overwrites the same key
    /// on every re-registration, so idempotent re-calls during
    /// subsequent walks are cheap. Components MUST call
    /// `unregisterBumper` in their deinit so the stored function
    /// pointer + ctx don't outlive the component.
    pub fn registerBumper(self: *LayoutContext, key: u64, bumper: VersionBumper) std.mem.Allocator.Error!void {
        try self.bumpers.put(self.alloc, key, bumper);
    }

    /// Remove a previously-registered bumper. Components call this in
    /// their deinit so the bumper's stored ctx pointer doesn't dangle
    /// past the component's lifetime. No-op when nothing's registered.
    pub fn unregisterBumper(self: *LayoutContext, key: u64) void {
        _ = self.bumpers.remove(key);
    }

    /// Record a component's resolved size for the persistent
    /// post-layout size cache. Called from the
    /// `ElementVTable.on_layout_complete` hook on every walk (cache
    /// hit or miss). Drag handlers and other size-sensitive consumers
    /// read this via `lastSize` when the per-pass `bounds_map` is
    /// empty (which happens whenever the target was cache-hit).
    pub fn recordSize(self: *LayoutContext, key: u64, w: f32, h: f32) std.mem.Allocator.Error!void {
        try self.last_sizes.put(self.alloc, key, .{ w, h });
    }

    /// Read back the last-recorded size for `key`, or null when
    /// nothing's been recorded. Cheap (one hash lookup); drag
    /// handlers consult this in their fallback chain.
    pub fn lastSize(self: *const LayoutContext, key: u64) ?[2]f32 {
        return self.last_sizes.get(key);
    }

    /// Drop a component's size entry. Called by components in their
    /// deinit so stale sizes don't linger across re-creations.
    pub fn clearSize(self: *LayoutContext, key: u64) void {
        _ = self.last_sizes.remove(key);
    }

    /// Register a rectangular exclusion for the current pass (stage 15
    /// Phase E text exclusion). Floated components call this from their
    /// `on_layout_complete` hook so the exclusion survives cache hits.
    /// The inline-flow wrap loop consults `lineBounds` per candidate
    /// line and shrinks the usable x-range when an exclusion overlaps.
    pub fn registerExclusion(self: *LayoutContext, rect: ExclusionRect) std.mem.Allocator.Error!void {
        try self.exclusions.append(self.alloc, rect);
    }

    /// Resolve the usable inline-flow x-range for a line at `y` of
    /// height `line_height`. `(x_min, x_max)` is the paragraph's
    /// declared column. Each active exclusion (one whose y-range
    /// overlaps `[y, y + line_height]`) shrinks the column from its
    /// declared side. Returns `[line_left, line_right]` ready for the
    /// wrap loop.
    ///
    /// V1 only handles left + right edge floats (the common case);
    /// stacked floats on the same side compose by taking the
    /// rightmost / leftmost edge.
    pub fn lineBounds(
        self: *const LayoutContext,
        y: f32,
        line_height: f32,
        x_min: f32,
        x_max: f32,
    ) [2]f32 {
        var left = x_min;
        var right = x_max;
        const line_bottom = y + line_height;
        for (self.exclusions.items) |r| {
            const overlap_y = (r.y_min < line_bottom) and (r.y_max > y);
            if (!overlap_y) continue;
            switch (r.side) {
                .left => if (r.x_max > left) {
                    left = r.x_max;
                },
                .right => if (r.x_min < right) {
                    right = r.x_min;
                },
            }
        }
        if (left > right) left = right;
        return .{ left, right };
    }

    /// One-shot hash of the active exclusion list — folded into
    /// paragraph cache keys so a float entering / leaving the document
    /// invalidates dependent paragraph wraps. Cheap (one pass over
    /// usually <10 rects); same exclusions across frames produce the
    /// same hash so cached paragraphs keep hitting once the float
    /// settles.
    pub fn exclusionsHash(self: *const LayoutContext) u64 {
        var h: u64 = 0x517CC1B727220A95;
        for (self.exclusions.items) |r| {
            const x0: u32 = @bitCast(r.x_min);
            const y0: u32 = @bitCast(r.y_min);
            const x1: u32 = @bitCast(r.x_max);
            const y1: u32 = @bitCast(r.y_max);
            h ^= @as(u64, x0);
            h *%= 0x9E3779B97F4A7C15;
            h ^= @as(u64, y0);
            h *%= 0xBF58476D1CE4E5B9;
            h ^= @as(u64, x1);
            h *%= 0x94D049BB133111EB;
            h ^= @as(u64, y1);
            h *%= 0xD6E8FEB86659FD93;
            h ^= @intFromEnum(r.side);
        }
        return h;
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

test "beginPass preserves bumpers + suggestions (stage 15 Phase C.4)" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const Stub = struct {
        fn bump(_: *anyopaque) void {}
    };
    var d: u8 = 0;
    try ctx.registerBumper(1, .{ .bump = Stub.bump, .ctx = &d });
    try ctx.setSuggestion(1, .width, 100.0);

    ctx.beginPass();

    // Both bumpers AND suggestions survive beginPass now — bumpers
    // need to fire for cache-hit components, suggestions need to
    // outlive frames so drags resume correctly.
    try testing.expect(ctx.bumpers.contains(1));
    try testing.expectEqual(@as(?f64, 100.0), ctx.getSuggestion(1, .width));
}

test "unregisterBumper removes the entry" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    const Stub = struct {
        fn bump(_: *anyopaque) void {}
    };
    var d: u8 = 0;
    try ctx.registerBumper(5, .{ .bump = Stub.bump, .ctx = &d });
    try testing.expect(ctx.bumpers.contains(5));

    ctx.unregisterBumper(5);
    try testing.expect(!ctx.bumpers.contains(5));

    // Idempotent — unregister of a missing key is a no-op.
    ctx.unregisterBumper(5);
}

test "recordSize / lastSize roundtrip" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(ctx.lastSize(7) == null);

    try ctx.recordSize(7, 200, 80);
    const s = ctx.lastSize(7) orelse unreachable;
    try testing.expectEqual(@as(f32, 200), s[0]);
    try testing.expectEqual(@as(f32, 80), s[1]);

    // Overwrite.
    try ctx.recordSize(7, 320, 120);
    const s2 = ctx.lastSize(7) orelse unreachable;
    try testing.expectEqual(@as(f32, 320), s2[0]);

    // clearSize removes the entry.
    ctx.clearSize(7);
    try testing.expect(ctx.lastSize(7) == null);
}

test "exclusion: register + lineBounds shrinks from left and right (stage 15 Phase E)" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.registerExclusion(.{ .x_min = 0, .y_min = 0, .x_max = 100, .y_max = 200, .side = .left });
    try ctx.registerExclusion(.{ .x_min = 500, .y_min = 50, .x_max = 600, .y_max = 150, .side = .right });

    // Line at y=80 height=20: both exclusions active.
    const a = ctx.lineBounds(80, 20, 0, 600);
    try testing.expectEqual(@as(f32, 100), a[0]);
    try testing.expectEqual(@as(f32, 500), a[1]);

    // Line at y=160 height=20: only the left exclusion is active.
    const b = ctx.lineBounds(160, 20, 0, 600);
    try testing.expectEqual(@as(f32, 100), b[0]);
    try testing.expectEqual(@as(f32, 600), b[1]);

    // Line at y=210 height=20: no exclusion active; full column.
    const c = ctx.lineBounds(210, 20, 0, 600);
    try testing.expectEqual(@as(f32, 0), c[0]);
    try testing.expectEqual(@as(f32, 600), c[1]);
}

test "exclusion: beginPass clears exclusions" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.registerExclusion(.{ .x_min = 0, .y_min = 0, .x_max = 50, .y_max = 50, .side = .left });
    try testing.expectEqual(@as(usize, 1), ctx.exclusions.items.len);

    ctx.beginPass();
    try testing.expectEqual(@as(usize, 0), ctx.exclusions.items.len);
}

test "exclusion: hash changes when list changes, stable when identical" {
    var a = try LayoutContext.init(testing.allocator);
    defer a.deinit();
    var b = try LayoutContext.init(testing.allocator);
    defer b.deinit();

    try testing.expectEqual(a.exclusionsHash(), b.exclusionsHash());

    try a.registerExclusion(.{ .x_min = 10, .y_min = 20, .x_max = 110, .y_max = 220, .side = .left });
    try testing.expect(a.exclusionsHash() != b.exclusionsHash());

    try b.registerExclusion(.{ .x_min = 10, .y_min = 20, .x_max = 110, .y_max = 220, .side = .left });
    try testing.expectEqual(a.exclusionsHash(), b.exclusionsHash());

    // Differing side bumps the hash.
    try a.registerExclusion(.{ .x_min = 300, .y_min = 0, .x_max = 400, .y_max = 100, .side = .right });
    try b.registerExclusion(.{ .x_min = 300, .y_min = 0, .x_max = 400, .y_max = 100, .side = .left });
    try testing.expect(a.exclusionsHash() != b.exclusionsHash());
}

test "last_sizes survives beginPass" {
    var ctx = try LayoutContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.recordSize(42, 100, 50);
    ctx.beginPass();
    const s = ctx.lastSize(42) orelse unreachable;
    try testing.expectEqual(@as(f32, 100), s[0]);
    try testing.expectEqual(@as(f32, 50), s[1]);
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
