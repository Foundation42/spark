//! Two documents, ONE Spark — the panels campaign, beat 1.
//!
//! `two_instances.zig` proves two Sparks share nothing. This file
//! proves the other arrangement, which is the one a host actually
//! wants for a second panel: **one** Spark (one pipeline set, one
//! atlas pair, one job system) drawing **several** Documents.
//!
//! `document.zig`'s own header has claimed that shape since Phase 3
//! — *"Multiple Documents per Spark is the design intent — HUD
//! overlays, debug panels, AI scratch panels"* — but nothing loaded
//! two and looked. Doing so turns up the one thing genuinely shared
//! between Documents: the component **Registry**, which was a single
//! flat namespace. Two panels each holding `:::slider {#exposure}`
//! resolved to ONE slider instance drawn twice, and every document's
//! first unnamed directive was `auto:0`.
//!
//! `LoadOpts.scope` is the fix, and every test below is written the
//! same way: **first prove the unscoped world really does collapse
//! them**, then prove scopes separate it. Without that first half
//! these are assertions that two different things are different,
//! which would pass against a `scope` field that did nothing at all.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const fixture = @import("fixture.zig");

/// Two panels an author would plausibly write independently — the
/// collision is not contrived, it is what happens when the same
/// good name occurs to somebody twice.
const panel_a =
    \\:::slider {#exposure target=render/exposure min=0 max=4 value=1}
    \\:::
    \\
;

const panel_b =
    \\:::slider {#exposure target=render/gamma min=0 max=4 value=3}
    \\:::
    \\
;

/// Neither directive is named, so both land on `auto:0`.
const unnamed_a =
    \\:::box {color=teal width=120 height=60}
    \\:::
    \\
;

const unnamed_b =
    \\:::box {color=magenta width=200 height=80}
    \\:::
    \\
;

/// The one component instance a document's tree points at. Documents
/// here hold exactly one `:::` block, so "the first custom element"
/// is unambiguous.
///
/// Identity is the `ctx` POINTER rather than anything read out of the
/// component: two element trees holding the same ctx *are* one
/// instance drawn twice, which is precisely the defect, and the
/// pointer says so without reaching into a private struct.
fn onlyInstance(root: spark.element.Element) ?*anyopaque {
    return switch (root) {
        .custom => |cu| cu.ctx,
        .container => |co| for (co.children) |child| {
            if (onlyInstance(child)) |ctx| break ctx;
        } else null,
        .paragraph => |kids| for (kids) |child| {
            if (onlyInstance(child)) |ctx| break ctx;
        } else null,
        else => null,
    };
}

const Host = struct {
    fx: fixture.Fixture,
    fonts: fixture.Fonts,
    theme: spark.Theme,
    state: spark.State,
    inst: spark.Spark,

    fn init(allocator: std.mem.Allocator, self: *Host) !void {
        self.fx = try fixture.Fixture.init(allocator);
        errdefer self.fx.deinit();
        self.fonts = try fixture.makeFonts(allocator, self.fx.ft);
        self.theme = fixture.makeTheme(self.fonts);
        self.state = spark.State.init(allocator);
        errdefer self.state.deinit();
        self.inst = try spark.Spark.init(allocator, .{
            .vk_ctx = &self.fx.ctx,
            .color_format = self.fx.swapchain.format,
            .theme = &self.theme,
            .fonts = self.fonts.registry,
            .host_state = &self.state,
        });
        errdefer self.inst.deinit();
        self.inst.attachToRegistry();
        try spark.installCoreComponents(&self.inst);
    }

    fn deinit(self: *Host, allocator: std.mem.Allocator) void {
        self.inst.deinit();
        allocator.destroy(self.fonts.registry);
        self.state.deinit();
        self.fx.deinit();
    }
};

test "two documents in one Spark: an #id collides without a scope, and is separated by one" {
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);

    // ── The inequality this rests on (rule 1) ────────────────────
    // Unscoped, the two documents' sliders are ONE instance. If this
    // half ever stops holding, the scoped half below is asserting
    // that two unrelated pointers differ and would pass against a
    // `scope` field wired to nothing.
    {
        var a = try host.inst.loadDocument(panel_a, .{ .shared_state = &host.state });
        defer a.deinit();
        var b = try host.inst.loadDocument(panel_b, .{ .shared_state = &host.state });
        defer b.deinit();

        const ctx_a = onlyInstance(a.root) orelse return error.NoComponentInA;
        const ctx_b = onlyInstance(b.root) orelse return error.NoComponentInB;
        try testing.expect(ctx_a == ctx_b);
    }

    // Clear the collided instance out so the scoped pass below starts
    // from an empty cache rather than inheriting `exposure`.
    host.inst.registry.deinit();
    host.inst.registry.* = @TypeOf(host.inst.registry.*).init(allocator);
    host.inst.attachToRegistry();
    try spark.installCoreComponents(&host.inst);

    // ── And with scopes, two ─────────────────────────────────────
    var a = try host.inst.loadDocument(panel_a, .{ .shared_state = &host.state, .scope = "lab" });
    defer a.deinit();
    var b = try host.inst.loadDocument(panel_b, .{ .shared_state = &host.state, .scope = "debug" });
    defer b.deinit();

    const ctx_a = onlyInstance(a.root) orelse return error.NoComponentInA;
    const ctx_b = onlyInstance(b.root) orelse return error.NoComponentInB;
    try testing.expect(ctx_a != ctx_b);

    // Both keys are really in the cache under their own namespace —
    // distinct pointers alone would also be satisfied by a scope that
    // simply defeated caching, which would break hot reload instead.
    try testing.expect(host.inst.registry.instances.contains("lab/exposure"));
    try testing.expect(host.inst.registry.instances.contains("debug/exposure"));
}

test "two documents in one Spark: unnamed directives collide on auto:0 without a scope" {
    // The `#id` case above is the one an author notices. This is the
    // one nobody would ever suspect: give two documents no `#id` at
    // all and their FIRST directives both key on `auto:0`, so a
    // panel's box silently becomes the other panel's box. A fix that
    // only namespaced explicit ids would pass the test above and
    // leave this.
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);

    {
        var a = try host.inst.loadDocument(unnamed_a, .{ .shared_state = &host.state });
        defer a.deinit();
        var b = try host.inst.loadDocument(unnamed_b, .{ .shared_state = &host.state });
        defer b.deinit();
        try testing.expect(onlyInstance(a.root).? == onlyInstance(b.root).?);
    }

    host.inst.registry.deinit();
    host.inst.registry.* = @TypeOf(host.inst.registry.*).init(allocator);
    host.inst.attachToRegistry();
    try spark.installCoreComponents(&host.inst);

    var a = try host.inst.loadDocument(unnamed_a, .{ .shared_state = &host.state, .scope = "lab" });
    defer a.deinit();
    var b = try host.inst.loadDocument(unnamed_b, .{ .shared_state = &host.state, .scope = "debug" });
    defer b.deinit();
    try testing.expect(onlyInstance(a.root).? != onlyInstance(b.root).?);
    try testing.expect(host.inst.registry.instances.contains("lab/auto:0"));
    try testing.expect(host.inst.registry.instances.contains("debug/auto:0"));
}

test "a scope is stable across that document's own reloads — the slider survives a save" {
    // The other half of the contract, and the reason a scope must be
    // the panel's NAME rather than anything per-load. Reloading a
    // document re-parses it against the same scope, so its components
    // are cache HITS and keep their state — which is what makes a
    // save on `lab.md` leave the thumb where the author left it.
    //
    // A scope derived from the load (a counter, a pointer) would pass
    // both tests above and fail here.
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);

    var first = try host.inst.loadDocument(panel_a, .{ .shared_state = &host.state, .scope = "lab" });
    const ctx_first = onlyInstance(first.root) orelse return error.NoComponent;

    // The reload: same scope, a document whose text has changed.
    var second = try host.inst.loadDocument(
        \\:::slider {#exposure target=render/exposure min=0 max=8 value=1}
        \\:::
        \\
    , .{ .shared_state = &host.state, .scope = "lab" });
    defer second.deinit();
    const ctx_second = onlyInstance(second.root) orelse return error.NoComponent;

    // Same instance, carried across the save.
    try testing.expect(ctx_first == ctx_second);
    first.deinit();
}

test "a reload of one panel does not age the other's components toward the sweep" {
    // The multi-document hazard in `gc`, which is the front half of
    // the same shared-Registry problem. `beginParse` used to bump
    // EVERY cached instance, and `gc`'s licence — "no live Element
    // points at what is about to be freed" — is only ever true for
    // the document that just re-parsed. So panel A's slider aged on
    // every reload of panel B, touched nothing, and `sweep_threshold`
    // saves later `gc` freed a component A's live tree still pointed
    // at.
    //
    // Poisoned deliberately (rule 5): `sweep_threshold = 0` means one
    // unused parse is fatal, so a single reload of B is enough. At the
    // default 4 this test would pass against the bug for four of the
    // five reloads it takes to bite.
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);
    host.inst.registry.sweep_threshold = 0;

    var a = try host.inst.loadDocument(panel_a, .{ .shared_state = &host.state, .scope = "lab" });
    defer a.deinit();
    var b = try host.inst.loadDocument(panel_b, .{ .shared_state = &host.state, .scope = "debug" });
    defer b.deinit();

    const ctx_a = onlyInstance(a.root) orelse return error.NoComponentInA;
    try testing.expect(host.inst.registry.instances.contains("lab/exposure"));

    // B reloads. A is untouched by that parse and must not age.
    var b2 = try host.inst.loadDocument(panel_b, .{ .shared_state = &host.state, .scope = "debug" });
    defer b2.deinit();
    host.inst.registry.gc();

    // A's slider is still there, and still the same instance — `a.root`
    // is live and points straight at it.
    try testing.expect(host.inst.registry.instances.contains("lab/exposure"));
    try testing.expect(onlyInstance(a.root).? == ctx_a);

    // And the confinement did not cost the sweep its job: a document
    // that drops a component still loses it. Without this the test
    // would pass against a `beginParse` that had simply stopped
    // ageing anything at all.
    var a2 = try host.inst.loadDocument(
        \\just prose now, no directive at all
        \\
    , .{ .shared_state = &host.state, .scope = "lab" });
    defer a2.deinit();
    host.inst.registry.gc();
    try testing.expect(!host.inst.registry.instances.contains("lab/exposure"));
}

test "each document keeps its own State, and a stream update lands in the one it names" {
    // The state half of the same shared-Spark question. Component
    // instances collide on the Registry; state values collide on
    // `Spark.host_state`, and the fix is symmetric — each Document
    // gets its own State (the `loadDocument` default) and every path
    // that touches state has to honour that rather than reaching for
    // the root.
    //
    // Layout and input already did: `layoutAndRender` prefers
    // `doc.state`, and the walker stamps it onto every Hit. The
    // ingress did NOT — `applyUpdate` always wrote `host_state`, so a
    // stream binding feeding panel B's chart wrote into whatever
    // State the Spark held as root.
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);

    // No `shared_state`: each document owns its State, which is what a
    // host with two panels wants.
    var a = try host.inst.loadDocument(panel_a, .{ .scope = "lab" });
    defer a.deinit();
    var b = try host.inst.loadDocument(panel_b, .{ .scope = "debug" });
    defer b.deinit();

    // ── The inequality (rule 1) ──────────────────────────────────
    // Three distinct States, or everything below is asserting that
    // one State equals itself.
    try testing.expect(a.state.? != b.state.?);
    try testing.expect(a.state.? != &host.state);
    try testing.expect(b.state.? != &host.state);

    const update =
        \\:::update {target=state.warm}
        \\0.75
        \\:::
        \\
    ;

    // Aimed at A, it lands in A — and in NEITHER of the other two.
    // The "neither" half is the whole test: `applyUpdate` would have
    // put this in `host_state` and passed a check that only asked
    // whether the value arrived somewhere.
    try testing.expectEqual(@as(usize, 1), try host.inst.applyUpdateTo(a.state.?, update));
    try testing.expectEqualStrings("0.75", a.state.?.get("warm").?);
    try testing.expectEqual(@as(?[]const u8, null), b.state.?.get("warm"));
    try testing.expectEqual(@as(?[]const u8, null), host.state.get("warm"));

    // And the root path still goes to the root, unchanged — the new
    // function is a widening, not a redirection.
    try testing.expectEqual(@as(usize, 1), try host.inst.applyUpdate(update));
    try testing.expectEqualStrings("0.75", host.state.get("warm").?);
    try testing.expectEqual(@as(?[]const u8, null), b.state.?.get("warm"));
}

test "closing one panel's scope leaves the other panel's components standing" {
    // What an unmount has to do, and the reason it cannot simply be
    // `gc`. A panel that goes away must take ITS components with it —
    // the Spark outlives the panel, so leaving them behind leaks every
    // component that panel ever held and a remount under the same name
    // inherits the corpse — while touching nothing the panels still on
    // screen are pointing at.
    //
    // Gated HERE, deterministically, rather than by comparing two
    // captures in matryoshka's `repro-hud`. That comparison was tried
    // and it SURVIVED the mutation: tearing down the wrong scope leaves
    // the live document holding a dangling ctx whose freed bytes still
    // read as the old component, so the picture is identical and the
    // gate sees nothing. A use-after-free is not a pixel question.
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);

    var a = try host.inst.loadDocument(panel_a, .{ .shared_state = &host.state, .scope = "lab" });
    defer a.deinit();
    var b = try host.inst.loadDocument(panel_b, .{ .shared_state = &host.state, .scope = "debug" });
    defer b.deinit();

    // Rule 1: both really are in the cache, under distinct keys, before
    // anything is destroyed.
    try testing.expect(host.inst.registry.instances.contains("lab/exposure"));
    try testing.expect(host.inst.registry.instances.contains("debug/exposure"));
    const ctx_a = onlyInstance(a.root) orelse return error.NoComponentInA;

    host.inst.registry.deinitScope("debug");

    // Gone, and only it.
    try testing.expect(!host.inst.registry.instances.contains("debug/exposure"));
    try testing.expect(host.inst.registry.instances.contains("lab/exposure"));
    // And the survivor is the SAME instance the live tree points at —
    // not merely a key that still exists.
    try testing.expect(onlyInstance(a.root).? == ctx_a);
}

test "a panel's scope prefix does not swallow another whose name starts the same" {
    // `deinitScope` matches on `"{prefix}/"`, and the trailing slash is
    // the whole guard: closing `debug` must not take `debug2` with it.
    // Panel names come from a human typing `hud mount`, so `lab` and
    // `lab2` open on screen together the first time anybody wants to
    // compare two versions of a document — which is precisely when
    // losing one of them would be most confusing.
    const allocator = testing.allocator;
    var host: Host = undefined;
    try Host.init(allocator, &host);
    defer host.deinit(allocator);

    var a = try host.inst.loadDocument(panel_a, .{ .shared_state = &host.state, .scope = "lab" });
    defer a.deinit();
    var b = try host.inst.loadDocument(panel_b, .{ .shared_state = &host.state, .scope = "lab2" });
    defer b.deinit();

    try testing.expect(host.inst.registry.instances.contains("lab/exposure"));
    try testing.expect(host.inst.registry.instances.contains("lab2/exposure"));

    host.inst.registry.deinitScope("lab");
    try testing.expect(!host.inst.registry.instances.contains("lab/exposure"));
    try testing.expect(host.inst.registry.instances.contains("lab2/exposure"));
}
