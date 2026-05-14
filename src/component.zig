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
const state_mod = @import("state.zig");

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
/// `binding` is non-null only when the directive's attrs reference
/// at least one `${path}` — it holds the templated form + the State
/// subscriber pointers we'll unsubscribe at gc time.
const Entry = struct {
    instance: Instance,
    parses_unused: u32,
    factory_name: []const u8,
    binding: ?*Binding = null,
};

/// Reactive-state plumbing for one cached component instance.
/// Allocated separately from the Entry so the Subscriber callback
/// can hold a stable `*Binding` ctx even if the registry's instance
/// map reallocates. Lifetime: created on the first resolve where
/// the templated attrs contain `${}`; destroyed when the parent
/// Entry is GC'd.
const Binding = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.State,
    factory: Factory,
    instance_ctx: *anyopaque,
    /// Templated attrs (with `${...}` literals), arena-duped into
    /// `allocator`. The Subscriber callback re-substitutes against
    /// the current state on every mutation.
    templated_attrs: []components.Attr,
    /// Subscription handles, one per distinct path referenced by
    /// `templated_attrs`. Owned by the State; we hold the pointers
    /// so we can `unsubscribe` at gc.
    subscriptions: []*state_mod.Subscriber,

    fn refire(self: *Binding) anyerror!void {
        // Build a fresh substituted Spec in a scratch arena that
        // dies when this fire returns. The factory only needs the
        // values during its `update` callback — anything it wants
        // to retain it copies into its own state.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const fresh_attrs = try a.alloc(components.Attr, self.templated_attrs.len);
        for (self.templated_attrs, 0..) |t, i| {
            fresh_attrs[i] = .{
                .key = t.key,
                .value = try components.substituteState(a, t.value, self.state),
            };
        }
        const fresh_spec = components.Spec{
            .name = "",
            .id = null,
            .attrs = fresh_attrs,
            .body = "",
        };
        if (self.factory.update) |u| try u(self.instance_ctx, &fresh_spec);
    }

    fn callback(ctx: *anyopaque) anyerror!void {
        const b: *Binding = @ptrCast(@alignCast(ctx));
        return b.refire();
    }

    fn destroy(self: *Binding) void {
        for (self.subscriptions) |sub| self.state.unsubscribe(sub);
        self.allocator.free(self.subscriptions);
        for (self.templated_attrs) |attr| {
            self.allocator.free(attr.key);
            self.allocator.free(attr.value);
        }
        self.allocator.free(self.templated_attrs);
        const alloc = self.allocator;
        alloc.destroy(self);
    }
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
            if (e.binding) |b| b.destroy();
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
    ///
    /// `spec` is expected to carry **templated** attribute values
    /// (with `${path}` still literal). The registry substitutes
    /// them against `state` before invoking factory.create /
    /// factory.update, and — when `${}` references exist — sets up
    /// a Binding so subsequent state mutations refire update
    /// automatically.
    pub fn resolve(
        self: *Registry,
        spec: *const components.Spec,
        sentinel_idx: usize,
        state: ?*state_mod.State,
    ) !?Resolved {
        const factory = self.factories.get(spec.name) orelse return null;

        var id_buf: [64]u8 = undefined;
        const id: []const u8 = if (spec.id) |id|
            id
        else
            std.fmt.bufPrint(&id_buf, "auto:{d}", .{sentinel_idx}) catch unreachable;

        const gop = try self.instances.getOrPut(self.allocator, id);
        if (gop.found_existing) {
            // Cache hit. Factory-name change → destroy + recreate.
            if (!std.mem.eql(u8, gop.value_ptr.factory_name, spec.name)) {
                if (self.factories.get(gop.value_ptr.factory_name)) |old_factory| {
                    if (old_factory.deinit) |d|
                        d(gop.value_ptr.instance.ctx, self.allocator);
                }
                if (gop.value_ptr.binding) |b| b.destroy();
                gop.value_ptr.* = try self.buildEntry(factory, spec, state);
                return .{
                    .vtable = gop.value_ptr.instance.vtable,
                    .ctx = gop.value_ptr.instance.ctx,
                };
            }
            // Same factory — update path. Build a fresh substituted
            // spec, hand to factory.update.
            try self.invokeUpdate(factory, gop.value_ptr.instance.ctx, spec, state);
            gop.value_ptr.parses_unused = 0;
            return .{
                .vtable = gop.value_ptr.instance.vtable,
                .ctx = gop.value_ptr.instance.ctx,
            };
        }

        // Cache miss. Stable id, then full create + (maybe) binding.
        const stable_id = self.allocator.dupe(u8, id) catch |err| {
            _ = self.instances.remove(id);
            return err;
        };
        gop.key_ptr.* = stable_id;
        gop.value_ptr.* = self.buildEntry(factory, spec, state) catch |err| {
            self.allocator.free(stable_id);
            _ = self.instances.remove(stable_id);
            return err;
        };
        return .{
            .vtable = gop.value_ptr.instance.vtable,
            .ctx = gop.value_ptr.instance.ctx,
        };
    }

    /// Substitute `spec.attrs` against `state` into a scratch arena
    /// and call `factory.update`. Used on the cache-hit path so the
    /// cached instance learns about templated attr changes between
    /// parses without being destroyed.
    fn invokeUpdate(
        self: *Registry,
        factory: Factory,
        ctx: *anyopaque,
        spec: *const components.Spec,
        state: ?*state_mod.State,
    ) !void {
        const u = factory.update orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const fresh = try buildSubstitutedSpec(a, spec, state);
        try u(ctx, &fresh);
    }

    /// Build a fresh Entry from scratch: substitute spec.attrs,
    /// call factory.create, and (when the templated attrs reference
    /// any `${path}`) construct a Binding that subscribes the
    /// callback to each path. Caller stores the returned Entry in
    /// the instances map.
    fn buildEntry(
        self: *Registry,
        factory: Factory,
        spec: *const components.Spec,
        state: ?*state_mod.State,
    ) !Entry {
        // First create the instance with substituted attrs in a
        // scratch arena — same shape as invokeUpdate.
        var create_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer create_arena.deinit();
        const ca = create_arena.allocator();
        const fresh = try buildSubstitutedSpec(ca, spec, state);
        const inst = try factory.create(self.allocator, &fresh);

        var entry: Entry = .{
            .instance = inst,
            .parses_unused = 0,
            .factory_name = self.factories.getKey(spec.name).?,
            .binding = null,
        };

        // If the spec has no `${}` references — or no state to
        // resolve against — we're done. Static directives skip the
        // entire reactive plumbing.
        if (state == null) return entry;

        // Inspect templated attrs for `${path}` references; only
        // build a Binding if there's at least one.
        var path_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer path_arena.deinit();
        const paths = try components.collectReferencedPaths(path_arena.allocator(), spec.attrs);
        if (paths.len == 0) return entry;

        // Dupe templated attrs into long-lived registry storage so
        // the subscriber callback can re-substitute on any future
        // mutation.
        const templated = try self.allocator.alloc(components.Attr, spec.attrs.len);
        errdefer self.allocator.free(templated);
        for (spec.attrs, 0..) |src, i| {
            templated[i] = .{
                .key = try self.allocator.dupe(u8, src.key),
                .value = try self.allocator.dupe(u8, src.value),
            };
        }

        const binding = try self.allocator.create(Binding);
        binding.* = .{
            .allocator = self.allocator,
            .state = state.?,
            .factory = factory,
            .instance_ctx = inst.ctx,
            .templated_attrs = templated,
            .subscriptions = &.{},
        };

        var subs = try self.allocator.alloc(*state_mod.Subscriber, paths.len);
        var i: usize = 0;
        errdefer {
            for (subs[0..i]) |s| state.?.unsubscribe(s);
            self.allocator.free(subs);
        }
        while (i < paths.len) : (i += 1) {
            subs[i] = try state.?.subscribe(paths[i], Binding.callback, @ptrCast(binding));
        }
        binding.subscriptions = subs;

        entry.binding = binding;
        return entry;
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
            if (entry.value.binding) |b| b.destroy();
            if (self.factories.get(entry.value.factory_name)) |f| {
                if (f.deinit) |d| d(entry.value.instance.ctx, self.allocator);
            }
            self.allocator.free(entry.key);
        }
    }
};

/// Allocate a fresh `Spec` whose attrs are `templated.attrs` with
/// every `${path}` resolved against `state`. The returned Spec
/// borrows the allocator; caller-supplied arenas are the natural
/// choice because the substituted attrs are consumed inside
/// factory.create / factory.update and don't outlive that call.
fn buildSubstitutedSpec(
    allocator: std.mem.Allocator,
    templated: *const components.Spec,
    state: ?*state_mod.State,
) !components.Spec {
    const fresh_attrs = try allocator.alloc(components.Attr, templated.attrs.len);
    for (templated.attrs, 0..) |src, i| {
        fresh_attrs[i] = .{
            .key = src.key,
            .value = try components.substituteState(
                allocator,
                src.value,
                if (state) |s| @as(*const state_mod.State, s) else null,
            ),
        };
    }
    return .{
        .name = templated.name,
        .id = templated.id,
        .attrs = fresh_attrs,
        .body = templated.body,
    };
}

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
    allocator: std.mem.Allocator,
    last_color: []u8,
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
    // Real components own their state — copy the value into our own
    // allocator-owned memory. The Spec's strings live in scratch
    // memory the registry frees after `create` returns.
    state.* = .{
        .allocator = allocator,
        .last_color = try allocator.dupe(u8, pickColor(spec) orelse ""),
    };
    return .{ .vtable = &test_vtable, .ctx = @ptrCast(state) };
}
fn testUpdate(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    t_updates += 1;
    const state: *TestState = @ptrCast(@alignCast(ctx));
    if (pickColor(spec)) |c| {
        state.allocator.free(state.last_color);
        state.last_color = try state.allocator.dupe(u8, c);
    }
}
fn testDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    t_deinits += 1;
    const state: *TestState = @ptrCast(@alignCast(ctx));
    allocator.free(state.last_color);
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
    const r1 = try registry.resolve(&spec, 0, null);
    try testing.expect(r1 != null);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_updates);

    registry.beginParse();
    const r2 = try registry.resolve(&spec, 0, null);
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
    const r = try registry.resolve(&spec, 0, null);
    try testing.expect(r == null);
}

test "auto-id is order-based" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register("box", test_factory);

    const a: components.Spec = .{ .name = "box" }; // no id → auto:5
    const r1 = try registry.resolve(&a, 5, null);
    registry.beginParse();
    const r2 = try registry.resolve(&a, 5, null);
    try testing.expectEqual(r1.?.ctx, r2.?.ctx);

    // Different sentinel idx with same name → different cache slot.
    const r3 = try registry.resolve(&a, 6, null);
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
    _ = try registry.resolve(&spec, 0, null);
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

    _ = try registry.resolve(&spec, 0, null);
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
    _ = try registry.resolve(&as_box, 0, null);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_deinits);

    registry.beginParse();
    const as_chart: components.Spec = .{ .name = "chart" };
    _ = try registry.resolve(&as_chart, 0, null);
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
    const r1 = try registry.resolve(&spec_red, 0, null);
    {
        const state: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("red", state.last_color);
    }

    registry.beginParse();
    const attrs_blue = [_]components.Attr{.{ .key = "color", .value = "blue" }};
    const spec_blue: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs_blue };
    _ = try registry.resolve(&spec_blue, 0, null);
    {
        const state: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("blue", state.last_color);
    }
}

test "reactive: state.set fires factory.update on bound component" {
    resetCounters();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    try st.set("box_color", "red");

    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    try registry.register("box", test_factory);

    const attrs = [_]components.Attr{.{ .key = "color", .value = "${state.box_color}" }};
    const spec: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs };

    // Initial resolve substitutes — factory.create sees "red".
    const r1 = try registry.resolve(&spec, 0, &st);
    {
        const tst: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("red", tst.last_color);
    }
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_updates);

    // State mutation fires the binding's subscriber → factory.update.
    try st.set("box_color", "green");
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 1), t_updates);
    {
        const tst: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("green", tst.last_color);
    }

    // An unrelated path mutation doesn't fire.
    try st.set("unrelated", "x");
    try testing.expectEqual(@as(u32, 1), t_updates);
}

test "reactive: gc unsubscribes the binding" {
    resetCounters();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    try st.set("c", "red");

    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    registry.sweep_threshold = 0; // die after one unused parse
    try registry.register("box", test_factory);

    const attrs = [_]components.Attr{.{ .key = "color", .value = "${c}" }};
    const spec: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs };
    _ = try registry.resolve(&spec, 0, &st);
    try testing.expectEqual(@as(u32, 1), t_creates);

    // Parse without re-resolving → entry hits sweep, gc destroys it
    // including the binding (and its subscription).
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 1), t_deinits);

    // State mutation no longer fires anything (subscription was
    // soft-deleted at gc).
    try st.set("c", "blue");
    try testing.expectEqual(@as(u32, 0), t_updates);
}
