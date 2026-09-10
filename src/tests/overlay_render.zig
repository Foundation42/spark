//! **The overlay actually RENDERED**, which is the half `spark.zig`'s
//! overlay gates said out loud they were not covering: *"Its RENDER is
//! not gated anywhere: walking a document needs fonts, an atlas and a
//! device."* This file has all three — `fixture.Fixture` stands up a
//! hidden-window Vulkan context — so the walk is exercised for real.
//!
//! It exists because of a bug that lived entirely inside that gap.
//! Chris, 2026-09-10, on matryoshka's palette menu: the menu's
//! `:::button`s painted over the bare 3D scene with **no panel ground
//! behind them at all**, and a plain `:::box {color=#ff0000}` dropped
//! into the same overlay document painted perfectly. Quads and glyphs
//! from an overlay reached the screen; every EFFECT in it painted
//! nothing.
//!
//! The mechanism is the BLOCK CACHE, not the overlay, and it is worth
//! stating in that order. An overlay is laid out twice per frame and the
//! first walk is a measure walk; that walk used to be handed
//! `pass_dispatches = null`. It still populates the cache, and
//! `layoutAndRenderCached` builds `Entry.pass_dispatches` out of
//! `ctx.pass_dispatches[pd_start..]` — so a null one snapshots an EMPTY
//! list, and an entry that says "this block emits no passes" is
//! indistinguishable from one telling the truth. The real walk that
//! follows hits that entry and replays quads, glyphs and hits with the
//! effect gone. Broken on the first frame and forever after, because the
//! poisoned entry is what every later walk of either kind hits too.
//!
//! Two fixes, at both ends of the wire: the measure walk now has its own
//! real list (`Overlay.scratch_pd`), so the entry it mints is complete
//! and the real walk's cache hit replays the dispatches at the placed
//! origin; and `layoutAndRenderCached` refuses to SNAPSHOT at all from a
//! walk whose `pass_dispatches` is null, so the trap cannot be re-armed.
//!
//! **What is NOT fixed, and is pinned below.** The double walk survives
//! only because the second walk is a cache hit — the solver note in
//! `Spark.layoutAndRenderOverlay` has the measurement and the trigger.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const fixture = @import("fixture.zig");

/// The shape matryoshka's palette menu actually has: a chain effect
/// (`:::drop_shadow`) wrapping a second chain effect
/// (`:::frosted_glass`) wrapping the menu's content. Two nested
/// effects, because one of the two candidate mechanisms — a pass being
/// considered "already registered" on the second walk — would have
/// shown differently for nested passes than for a single one, and a
/// fixture with one effect could not tell them apart.
const menu_with_chrome =
    \\:::drop_shadow {offset_y=4 blur=12 color=#0008}
    \\:::frosted_glass {blur=18 radius=8 tint=#22262eF2 padding="8 10 10 10"}
    \\:::box {color=#ff0000 height=40 radius=4}
    \\:::
    \\:::
    \\:::
    \\
;

/// The control Chris used, and the reason the bug was diagnosable at
/// all: a plain quad in the same overlay. It has no pass of its own, so
/// it paints on both the broken and the fixed build — which is what
/// makes it a control and not a second copy of the assertion.
const menu_plain_box =
    \\:::box {color=#ff0000 height=40 radius=4}
    \\:::
    \\
;

/// Ordinary page content under the menu — one `layoutAndRender` before
/// the overlay's, so the overlay is not the frame's only paint layer
/// and its dispatch range is not trivially `[0, n)`.
const page =
    \\Some page prose.
    \\
;

const Harness = struct {
    fx: fixture.Fixture,
    fonts: fixture.Fonts,
    theme: spark.Theme,
    state: spark.State,
    sp: spark.Spark,

    fn init(allocator: std.mem.Allocator, out: *Harness) !void {
        out.fx = try fixture.Fixture.init(allocator);
        out.fonts = try fixture.makeFonts(allocator, out.fx.ft);
        out.theme = fixture.makeTheme(out.fonts);
        out.state = spark.State.init(allocator);
        out.sp = try spark.Spark.init(allocator, .{
            .vk_ctx = &out.fx.ctx,
            .color_format = out.fx.swapchain.format,
            .theme = &out.theme,
            .fonts = out.fonts.registry,
            .host_state = &out.state,
        });
        out.sp.attachToRegistry();
        try spark.installCoreComponents(&out.sp);
    }

    fn deinit(self: *Harness, allocator: std.mem.Allocator) void {
        self.sp.deinit();
        allocator.destroy(self.fonts.registry);
        self.state.deinit();
        self.fx.deinit();
    }
};

/// How many dispatches this frame's OVERLAY layer owns. Read off the
/// paint layer rather than off `pass_dispatches.items.len`, because the
/// page could in principle contribute some and the claim is about the
/// menu's.
fn overlayDispatchCount(sp: *const spark.Spark) usize {
    for (sp.paint_layers.items) |l| {
        if (l.overlay) return l.dispatches[1] - l.dispatches[0];
    }
    return 0;
}

test "overlay render: an effect in a menu emits its pass, and keeps emitting it" {
    // The bug, stated as a gate. Two nested chain effects in an overlay
    // document must put two dispatches in the frame — on the FIRST
    // frame and on every one after it, because the two failure modes
    // differ: a measure walk that emitted into the live list would give
    // four on frame one, and the poisoned-cache bug gives zero forever.
    //
    // Mutation, and it takes BOTH halves of the fix to restore the bug
    // exactly — which is itself the finding, so it is written out:
    //
    //   * `.pass_dispatches = null` back in `layoutAndRenderOverlay`'s
    //     `measure_lc`, plus the `if (ctx.pass_dispatches == null)
    //     return box;` guard deleted from `layoutAndRenderCached`. That
    //     IS the 2026-09-10 code. Compiles. `expected 2, found 0`, red
    //     on the first expectEqual, on frame one. Watched.
    //
    //   * The null on its own, guard left in place, does NOT reproduce
    //     the bug — it produces `error.UnsatisfiableConstraint` out of
    //     `kiwi.Solver.addConstraint`, on this gate and on both others.
    //     Also watched, and it is the measurement behind the solver note
    //     in `Spark.layoutAndRenderOverlay`: with nothing cached by the
    //     measure walk, the real walk re-walks the `:::box` and asks the
    //     solver for `x_min == 0` and `x_min == 200`, both required.
    //     Loud beats silent, so the guard stays — but it means the
    //     double walk is standing on the cache, and that is not fixed.
    //
    // Three frames, not one, because the two failure modes differ in
    // time: a measure walk that emitted into the LIVE list would give
    // four on frame one and two after, and the poisoned entry gives
    // zero forever.
    const allocator = testing.allocator;
    var h: Harness = undefined;
    try Harness.init(allocator, &h);
    defer h.deinit(allocator);

    var page_doc = try h.sp.loadDocument(page, .{ .shared_state = &h.state });
    defer page_doc.deinit();

    try h.sp.openOverlay(menu_with_chrome, .{ 200, 150 }, .top_left, .{});
    defer h.sp.closeOverlay();

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        try h.sp.beginFrame(
            .{ .extent = .{ .width = 800, .height = 600 } },
            .{ .reset = true },
        );
        _ = try h.sp.layoutAndRender(&page_doc, .{ 20, 20 }, .{ .max_w = 720 });
        try h.sp.layoutAndRenderOverlay();

        // `:::drop_shadow` and `:::frosted_glass` are both chains, so
        // the count is exact rather than "more than zero" — a fix that
        // ran the measure walk into the live list would give four here
        // and this line would catch it.
        try testing.expectEqual(@as(usize, 2), overlayDispatchCount(&h.sp));
    }
}

test "overlay render: the menu's ground is drawn where the menu is" {
    // A dispatch in the list is not yet a panel on the screen: the
    // compose region is what says WHERE the glass lands, and a measure
    // walk's cached copy carries the measure origin (0, 0) rather than
    // the placed one. So this asserts the region, not just the count.
    //
    // Mutation: in `blitEntry`'s chain arm, drop the
    // `c.compose_region.x += ox_i32` / `.y += oy_i32` translation.
    // Compiles, and every cached chain composites at the origin it was
    // snapshotted at — the menu's glass appears in the top-left corner
    // of the surface while its buttons sit at (200, 150). Red on
    // `found_at_menu`, and the other three gates in this file stay
    // green, which is what makes this one worth its own test. Watched.
    const allocator = testing.allocator;
    var h: Harness = undefined;
    try Harness.init(allocator, &h);
    defer h.deinit(allocator);

    var page_doc = try h.sp.loadDocument(page, .{ .shared_state = &h.state });
    defer page_doc.deinit();

    try h.sp.openOverlay(menu_with_chrome, .{ 200, 150 }, .top_left, .{});
    defer h.sp.closeOverlay();

    // Two frames, and the second is the one asserted. Frame one is
    // already a hit on the real walk — the measure walk minted the
    // entry moments earlier — but frame two is the fully warm case
    // where BOTH walks blit, and it is the one that would catch a
    // translation applied once and then re-applied.
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        // **The surface is 1280 wide so the menu is NOT at a flip.** This
        // gate's subject is the TRANSLATION of a cached compose region,
        // not the placement — but it asserts a literal (200, 150), so a
        // surface narrow enough for `overlay.place` to flip the menu
        // makes it fail for a reason it is not about. At 800 wide it did
        // exactly that the moment `OVERLAY_MAX_W` went from 260 to 680:
        // 200 + 680 overhangs, `place` flips to the left edge, and the
        // region lands at 0. A gate that breaks when an unrelated
        // constant moves is a gate that will be "fixed" by loosening its
        // assertion. Room on both axes at any plausible width instead.
        try h.sp.beginFrame(
            .{ .extent = .{ .width = 1280, .height = 720 } },
            .{ .reset = true },
        );
        _ = try h.sp.layoutAndRender(&page_doc, .{ 20, 20 }, .{ .max_w = 720 });
        try h.sp.layoutAndRenderOverlay();
    }

    const layer = blk: {
        for (h.sp.paint_layers.items) |l| {
            if (l.overlay) break :blk l;
        }
        return error.NoOverlayLayer;
    };
    var found_at_menu = false;
    for (h.sp.pass_dispatches.items[layer.dispatches[0]..layer.dispatches[1]]) |d| {
        const r = switch (d) {
            .chain => |c| c.compose_region,
            else => continue,
        };
        // The overlay was anchored top-left at (200, 150) with room on
        // both axes at this surface size, so `overlay.place` leaves it
        // there — see the extent above.
        if (r.x == 200 and r.y == 150) found_at_menu = true;
        try testing.expect(r.w > 0 and r.h > 0);
    }
    try testing.expect(found_at_menu);
}

test "overlay render: a plain quad in a menu is unaffected by the effect fix" {
    // The control, and — since it is a menu whose only block is a
    // `:::box` — the pin on the invariant the double walk is standing
    // on. `:::box` is the one component that registers with the kiwi
    // solver, and the only reason the second walk does not register it
    // a second time at a different origin is that it never reaches the
    // solver: `layoutAndRenderCached` answers it out of the entry the
    // measure walk just minted. Break that and this goes red with
    // `error.UnsatisfiableConstraint` rather than being discovered in
    // matryoshka.
    //
    // Mutation: the full 2026-09-10 code — `.pass_dispatches = null` in
    // `measure_lc` AND the snapshot guard deleted. This gate stays
    // GREEN, which is the point of it being here. The quad painted
    // throughout the bug, which is why Chris's red box was the control
    // that localised the fault to the offscreen path rather than to the
    // overlay's placement or its paint layer. A gate that went red on
    // the bug would not be a control; it would be a second copy of the
    // gate above. Watched: 2 of 4 passed under that mutation, and this
    // was one of the two.
    //
    // It does NOT survive the null on its own (guard kept) — that is
    // `error.UnsatisfiableConstraint` from the `:::box` below reaching
    // the solver on both walks. Same measurement as the first gate's,
    // and the same note it points at.
    const allocator = testing.allocator;
    var h: Harness = undefined;
    try Harness.init(allocator, &h);
    defer h.deinit(allocator);

    try h.sp.openOverlay(menu_plain_box, .{ 200, 150 }, .top_left, .{});
    defer h.sp.closeOverlay();

    try h.sp.beginFrame(
        .{ .extent = .{ .width = 800, .height = 600 } },
        .{ .reset = true },
    );
    try h.sp.layoutAndRenderOverlay();

    const layer = blk: {
        for (h.sp.paint_layers.items) |l| {
            if (l.overlay) break :blk l;
        }
        return error.NoOverlayLayer;
    };
    try testing.expect(layer.quads[1] > layer.quads[0]);
    try testing.expectEqual(@as(usize, 0), overlayDispatchCount(&h.sp));
}
