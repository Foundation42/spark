//! Component registry + persistent instance cache. Stage 7b of the
//! live-documents staging path.
//!
//! Stage 7a parsed `:::name {attrs}\nbody\n:::` blocks into Specs and
//! emitted a `custom` Element backed by a fallback "missing component"
//! placeholder. This module supplies the runtime layer that
//! transforms those Specs into real per-instance state:
//!
//!   * **Factory** — host-supplied. One per directive name. Knows how
//!     to `create` a new instance from a Spec, optionally `update` an
//!     existing instance when its Spec attrs change between parses,
//!     and optionally `deinit` it when the registry GCs it.
//!
//!   * **Instance** — internal. A registry-owned bag holding the
//!     factory-provided vtable + ctx the Element points at, plus
//!     `parses_unused` bookkeeping for the sweep+GC pass.
//!
//!   * **Registry** — owns the factories map + the instance cache
//!     (keyed by `Spec.id`, or `"auto:N"` derived from the spec's
//!     appearance index when the author didn't supply an `#id`).
//!     Methods correspond to the parse lifecycle: `beginParse` bumps
//!     "unused" counters; `resolve` is called per `:::` block during
//!     parse and resets the counter on the matching instance;
//!     `gc` (called by the host when it's safe — typically right
//!     after the new Element tree has replaced the previous one)
//!     destroys instances that have been untouched for more than
//!     `sweep_threshold` parses.
//!
//! Stage-7b deliverable: this module exists, tests cover
//! create/update/cache-hit/cache-miss/gc, and `markdown.parse` will
//! consult the registry first before falling through to the
//! placeholder. Until a host registers a factory, the demo's visual
//! output is unchanged from 7a — the infrastructure is dormant,
//! ready for stage 7c (first concrete component).
//!
//! ### Auto-ID policy
//!
//! Order-based: a Spec without explicit `#id` is cached under
//! `"auto:N"` where N is its appearance index in the source
//! (i.e. the sentinel number `<!--te:N-->`). Stable across edits
//! that don't reorder existing `:::` blocks; **not** stable when a
//! new `:::` block is inserted before existing ones — every
//! subsequent block's auto-id shifts and its cached instance gets
//! GC'd at the next sweep. Position-in-tree IDs (parent + sibling
//! index) survive that edit pattern; we'll add them when LLM-driven
//! structural rewrites prove the simple scheme isn't enough.
//!
//! ### Lifecycle ordering
//!
//! The host must NOT call `gc()` while any Element tree referencing
//! cached instance ctx pointers is still alive. The intended flow:
//!
//!     registry.beginParse();
//!     const tree = try markdown.parse(arena, src, theme, &registry);
//!     // ... swap tree pointer, free previous tree's arena ...
//!     registry.gc();   // safe now — no live Element points at any
//!                      // instance the registry is about to free.
//!
//! `markdown.parse` itself calls `beginParse`. The host calls `gc`
//! when its parse-tree swap is complete.

const std = @import("std");
const element = @import("element.zig");
const components = @import("markdown_components.zig");

pub const Error = error{
    DuplicateFactory,
} || std.mem.Allocator.Error;

/// Component factory — host-supplied per directive name. `create` is
/// called on cache miss; `update` (if non-null) is called on cache
/// hit so the instance can react to attr changes between parses;
/// `deinit` (if non-null) runs when the registry GCs the instance.
///
/// `create`'s allocator is the registry's allocator (NOT the parse
/// arena) — instance state lives across many parses, so it must
/// outlive any single parse arena. `deinit` receives the same
/// allocator for symmetry.
pub const Factory = struct {
    create: *const fn (
        allocator: std.mem.Allocator,
        spec: *const components.Spec,
    ) anyerror!Instance,
    update: ?*const fn (
        ctx: *anyopaque,
        spec: *const components.Spec,
    ) anyerror!void = null,
    deinit: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) void = null,
};

/// What a factory produces — the (vtable, ctx) pair the Element
/// holds. `ctx` is whatever per-instance state the component
/// allocates in `Factory.create`; the registry remembers it
/// verbatim and hands it back through the `custom` Element.
pub const Instance = struct {
    vtable: *const element.ElementVTable,
    ctx: *anyopaque,
};

/// What `resolve` hands back to the caller — exactly the fields a
/// `custom` Element needs. The Instance itself stays inside the
/// registry; callers only see the pointers.
pub const Resolved = struct {
    vtable: *const element.ElementVTable,
    ctx: *anyopaque,
};

/// Per-cached-instance bookkeeping kept alongside the Instance the
/// factory produced. `parses_unused` is bumped at the start of each
/// parse by `beginParse`; `resolve` resets it to 0 on a cache hit.
/// `factory_name` lets `gc` find the right factory to call `deinit`.
const Entry = struct {
    instance: Instance,
    parses_unused: u32,
    factory_name: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    factories: std.StringHashMapUnmanaged(Factory) = .{},
    instances: std.StringHashMapUnmanaged(Entry) = .{},
    /// Max consecutive parses an instance can go untouched before
    /// `gc` destroys it. Default 4 — a few parses of slack so that
    /// transient edits (block reorderings, comment toggles) don't
    /// thrash component state.
    sweep_threshold: u32 = 4,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// Drop all factories + destroy all cached instances. Host
    /// calls this at shutdown.
    pub fn deinit(self: *Registry) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            if (self.factories.get(e.factory_name)) |f| {
                if (f.deinit) |d| d(e.instance.ctx, self.allocator);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.instances.deinit(self.allocator);

        var fit = self.factories.iterator();
        while (fit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.factories.deinit(self.allocator);

        self.* = undefined;
    }

    /// Register a factory for a directive name. The registry takes
    /// its own copy of `name` so the caller is free to pass a
    /// literal / borrowed slice. Errors if the name is already
    /// registered (re-registration would orphan instances of the old
    /// factory — explicit unregister later if it's ever needed).
    pub fn register(self: *Registry, name: []const u8, factory: Factory) Error!void {
        const gop = try self.factories.getOrPut(self.allocator, name);
        if (gop.found_existing) return error.DuplicateFactory;
        gop.key_ptr.* = try self.allocator.dupe(u8, name);
        gop.value_ptr.* = factory;
    }

    /// Bump `parses_unused` on every cached instance. `resolve` will
    /// reset it for the ones touched during this parse; `gc` (called
    /// after the parse tree swap) destroys the still-untouched.
    pub fn beginParse(self: *Registry) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| entry.value_ptr.parses_unused += 1;
    }

    /// Resolve a `:::` block to an Instance. Returns null when no
    /// factory matches `spec.name` (caller falls back to the
    /// placeholder visual). `sentinel_idx` is the per-document
    /// position of the block — used to fabricate an `auto:N` cache
    /// key when the author didn't supply `#id`.
    pub fn resolve(
        self: *Registry,
        spec: *const components.Spec,
        sentinel_idx: usize,
    ) !?Resolved {
        const factory = self.factories.get(spec.name) orelse return null;

        var id_buf: [64]u8 = undefined;
        const id: []const u8 = if (spec.id) |id|
            id
        else
            std.fmt.bufPrint(&id_buf, "auto:{d}", .{sentinel_idx}) catch unreachable;

        const gop = try self.instances.getOrPut(self.allocator, id);
        if (gop.found_existing) {
            // Cache hit. If the instance was cached under a different
            // factory name (auto-IDs can collide if `:::name {...}`
            // gets edited to `:::other {...}` at the same position),
            // destroy + recreate. Conservative; rare in practice.
            if (!std.mem.eql(u8, gop.value_ptr.factory_name, spec.name)) {
                if (self.factories.get(gop.value_ptr.factory_name)) |old_factory| {
                    if (old_factory.deinit) |d|
                        d(gop.value_ptr.instance.ctx, self.allocator);
                }
                const fresh = try factory.create(self.allocator, spec);
                gop.value_ptr.* = .{
                    .instance = fresh,
                    .parses_unused = 0,
                    .factory_name = self.factories.getKey(spec.name).?,
                };
                return .{ .vtable = fresh.vtable, .ctx = fresh.ctx };
            }
            if (factory.update) |u| try u(gop.value_ptr.instance.ctx, spec);
            gop.value_ptr.parses_unused = 0;
            return .{
                .vtable = gop.value_ptr.instance.vtable,
                .ctx = gop.value_ptr.instance.ctx,
            };
        }

        // Cache miss. Allocate a stable copy of the id; instantiate.
        const stable_id = self.allocator.dupe(u8, id) catch |err| {
            // Undo the getOrPut on failure.
            _ = self.instances.remove(id);
            return err;
        };
        gop.key_ptr.* = stable_id;
        const fresh = factory.create(self.allocator, spec) catch |err| {
            self.allocator.free(stable_id);
            _ = self.instances.remove(stable_id);
            return err;
        };
        // factory_name is a borrow from the factories map — its
        // backing string outlives every Entry because the factory
        // (and its name) must be registered before any instance can
        // exist, and entries get destroyed at gc / deinit before the
        // factory is.
        gop.value_ptr.* = .{
            .instance = fresh,
            .parses_unused = 0,
            .factory_name = self.factories.getKey(spec.name).?,
        };
        return .{ .vtable = fresh.vtable, .ctx = fresh.ctx };
    }

    /// Destroy every cached instance whose `parses_unused` exceeds
    /// `sweep_threshold`. Host calls this after swapping the new
    /// Element tree into place — at which point no live Element
    /// references the about-to-be-freed instance ctxs.
    pub fn gc(self: *Registry) void {
        // Two-pass: collect dead keys, then remove. Can't mutate the
        // map while iterating it.
        var dead = std.ArrayList([]const u8).init(self.allocator);
        defer dead.deinit();

        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.parses_unused > self.sweep_threshold) {
                dead.append(entry.key_ptr.*) catch continue;
            }
        }
        for (dead.items) |key| {
            const entry = self.instances.fetchRemove(key) orelse continue;
            if (self.factories.get(entry.value.factory_name)) |f| {
                if (f.deinit) |d| d(entry.value.instance.ctx, self.allocator);
            }
            self.allocator.free(entry.key);
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────
//
// Tests build a fake factory with file-scope counters (rather than
// closures over locals — Zig wants the captured pointers to be
// comptime-known) so each test can assert on create/update/deinit
// call counts. Counters are reset at the top of each test.

const testing = std.testing;

var t_creates: u32 = 0;
var t_updates: u32 = 0;
var t_deinits: u32 = 0;

const TestState = struct {
    last_color: []const u8,
};

fn testLayout(_: *anyopaque, _: [2]f32, _: element.Constraints, _: *element.LayoutCtx, _: *element.DrawList) anyerror!element.Box {
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}
const test_vtable: element.ElementVTable = .{ .layout_and_render = testLayout };

fn pickColor(spec: *const components.Spec) ?[]const u8 {
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "color")) return a.value;
    }
    return null;
}

fn testCreate(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!Instance {
    t_creates += 1;
    const state = try allocator.create(TestState);
    state.* = .{ .last_color = pickColor(spec) orelse "" };
    return .{ .vtable = &test_vtable, .ctx = @ptrCast(state) };
}
fn testUpdate(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    t_updates += 1;
    const state: *TestState = @ptrCast(@alignCast(ctx));
    state.last_color = pickColor(spec) orelse state.last_color;
}
fn testDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    t_deinits += 1;
    const state: *TestState = @ptrCast(@alignCast(ctx));
    allocator.destroy(state);
}
const test_factory: Factory = .{
    .create = testCreate,
    .update = testUpdate,
    .deinit = testDeinit,
};

fn resetCounters() void {
    t_creates = 0;
    t_updates = 0;
    t_deinits = 0;
}

test "register + resolve creates instance once" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    const r1 = try registry.resolve(&spec, 0);
    try testing.expect(r1 != null);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_updates);

    registry.beginParse();
    const r2 = try registry.resolve(&spec, 0);
    try testing.expect(r2 != null);
    try testing.expectEqual(r1.?.ctx, r2.?.ctx);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 1), t_updates);
}

test "resolve returns null for unregistered name" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    const spec: components.Spec = .{ .name = "nothing", .id = "x" };
    const r = try registry.resolve(&spec, 0);
    try testing.expect(r == null);
}

test "auto-id is order-based" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register("box", test_factory);

    const a: components.Spec = .{ .name = "box" }; // no id → auto:5
    const r1 = try registry.resolve(&a, 5);
    registry.beginParse();
    const r2 = try registry.resolve(&a, 5);
    try testing.expectEqual(r1.?.ctx, r2.?.ctx);

    // Different sentinel idx with same name → different cache slot.
    const r3 = try registry.resolve(&a, 6);
    try testing.expect(r1.?.ctx != r3.?.ctx);
    try testing.expectEqual(@as(u32, 2), t_creates);
}

test "gc destroys after sweep_threshold consecutive unused parses" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    registry.sweep_threshold = 2;
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    _ = try registry.resolve(&spec, 0);
    try testing.expectEqual(@as(u32, 1), t_creates);

    // Threshold=2 → instance dies on the third unused parse.
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 0), t_deinits);
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 0), t_deinits);
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 1), t_deinits);

    _ = try registry.resolve(&spec, 0);
    try testing.expectEqual(@as(u32, 2), t_creates);
}

test "factory name change destroys old + recreates" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register("box", test_factory);
    try registry.register("chart", test_factory);

    // Auto-id collision when the spec at sentinel 0 changes name
    // across parses — e.g. an edit turning `:::box` into `:::chart`.
    const as_box: components.Spec = .{ .name = "box" };
    _ = try registry.resolve(&as_box, 0);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_deinits);

    registry.beginParse();
    const as_chart: components.Spec = .{ .name = "chart" };
    _ = try registry.resolve(&as_chart, 0);
    try testing.expectEqual(@as(u32, 2), t_creates);
    try testing.expectEqual(@as(u32, 1), t_deinits);
}

test "update sees latest spec attrs" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register("box", test_factory);

    const attrs_red = [_]components.Attr{.{ .key = "color", .value = "red" }};
    const spec_red: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs_red };
    const r1 = try registry.resolve(&spec_red, 0);
    {
        const state: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("red", state.last_color);
    }

    registry.beginParse();
    const attrs_blue = [_]components.Attr{.{ .key = "color", .value = "blue" }};
    const spec_blue: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs_blue };
    _ = try registry.resolve(&spec_blue, 0);
    {
        const state: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("blue", state.last_color);
    }
}
