//! **A menu is a document.** The overlay is a second `Document` drawn
//! on top of the page at a point the caller names, and that is the
//! whole of it — there is no menu type, no item type, no separator, no
//! accelerator column and no submenu.
//!
//! ## Why not a `:::menu` component
//!
//! Look at what a real context menu contains. Bitwig's "The Grid" opens
//! one with a checkbox row, two rows carrying keyboard accelerators, a
//! toolbar of five icon buttons, and a long titled list of replacement
//! operators. Every one of those is something spark already has —
//! `:::checkbox`, `:::kbd`, `:::button`, a heading and a list — and a
//! `:::menu` component would spend a year growing a second, worse copy
//! of each. Making the menu a *document* instead means a submenu, a
//! search box, a colour swatch and an inline slider all work on the day
//! they are written, and the host owns every question about content.
//!
//! What is left for spark is the part a document cannot do for itself:
//! be **above** the page, take the pointer **first**, and sit where it
//! fits. Those three, and nothing else, live here and in `Spark`.
//!
//! ## One overlay, not a stack
//!
//! A second `openOverlay` replaces the first. Submenus are a later beat
//! and they are the reason a stack would be wanted; the reason not to
//! build one today is that a stack forces two decisions this beat has
//! no customer for — which member of the stack a click outside
//! dismisses (all of them, or the top one), and whether a child is
//! placed against the surface or against its parent. What would change:
//! `Spark.overlay` becomes a small array, `hitScope` returns the TOP
//! member's range, and `place` gains a parent rect to flip against.
//! Nothing else in this file.
//!
//! ## Rejected names
//!
//!   * `Popup` — the web and Win32 word. Reads cheap, and every reader
//!     arrives expecting it to BE a menu, which is the one thing this
//!     is not.
//!   * `Sheet` — Apple's, and it means something modal, full-width and
//!     animated in from an edge. A context menu is none of those.
//!   * `Float` — the tiling-WM word for a window that escaped the
//!     layout. Right idea, wrong domain, and spark has no windows.
//!   * `Scrim` — names the dimming behind a modal, which this does not
//!     draw. Spending the word here would make it unavailable for the
//!     thing it actually names.
//!
//! `Overlay` says what it does — a document laid OVER the page — and
//! says nothing about what is in it, which is the design.

const std = @import("std");
const element = @import("element.zig");
const document_mod = @import("document.zig");

/// The registry namespace every overlay document's components live in.
///
/// Fixed rather than per-open, because an overlay is a singleton: two
/// opens in a row are the same slot, and a menu that keeps a
/// `:::checkbox`'s instance across a reopen is a menu whose checkbox
/// remembers — which is what an author writing the same document twice
/// expects. `Spark.closeOverlay` calls `registry.deinitScope` on it, so
/// nothing survives a close.
///
/// A host must not name a document scope `__overlay`; there is no way
/// to enforce that and the collision would show up as a menu's
/// components appearing in a panel.
pub const SCOPE = "__overlay";

/// Which corner of the overlay the caller wants sitting at `at`.
///
/// A PREFERENCE, not a placement: `place` flips to the opposite side of
/// an axis when the preferred corner would run the document off the
/// surface. So the corner that ends up at `at` is not always the one
/// asked for, and that is the feature.
///
/// Rejected name: `Anchor`. It is the better English for the ROLE, and
/// it is the wrong word in a markdown library — an anchor is a link,
/// and a reader meeting `Anchor` in a file next to `element.link` reads
/// it that way first. `Corner` is what the value literally is.
pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,

    /// Is the overlay's LEFT edge the one that wants to be at `at.x`?
    pub fn leadingX(self: Corner) bool {
        return self == .top_left or self == .bottom_left;
    }

    /// Is the overlay's TOP edge the one that wants to be at `at.y`?
    pub fn leadingY(self: Corner) bool {
        return self == .top_left or self == .top_right;
    }
};

/// Where the overlay's top-left goes, given the point it is anchored
/// to, the size it measured, the corner the caller preferred, and the
/// surface it has to fit inside. World coordinates throughout — the
/// same ones `dispatchMouseButtonN` takes.
///
/// **This arithmetic belongs in spark and not in the host.** Spark
/// knows the surface extent (`FrameInfo.extent`, `zoom`,
/// `scroll_offset`) and spark measures the document; a host doing this
/// would need both, would get the world/screen conversion wrong once,
/// and would then have a second copy to keep in step with the first.
///
/// **Flip, never clamp.** A menu opened three pixels from the right
/// edge and clamped to the surface covers the very thing that was
/// right-clicked; flipped, it opens leftwards and the subject stays
/// visible. Every native menu on this machine flips. Clamping is the
/// last resort and only for a document too big for the surface on that
/// axis, where there is no correct answer and "on screen" beats "off
/// it".
pub fn place(at: [2]f32, size: [2]f32, corner: Corner, surface: element.Box) [2]f32 {
    return .{
        placeAxis(at[0], size[0], corner.leadingX(), surface.x, surface.w),
        placeAxis(at[1], size[1], corner.leadingY(), surface.y, surface.h),
    };
}

/// One axis of `place`. Both axes decide independently — a menu near
/// the bottom-right flips twice, one near the bottom edge alone flips
/// once — which is why this is a function of a single axis and not a
/// four-way switch on `Corner`.
fn placeAxis(at: f32, size: f32, leading: bool, min: f32, extent: f32) f32 {
    const max = min + extent;
    if (leading) {
        // Preferred: the overlay's leading edge sits at `at`.
        if (at + size <= max) return at;
        // Flipped: its TRAILING edge sits at `at`, so the point stays
        // uncovered and the menu grows away from the edge.
        if (at - size >= min) return at - size;
    } else {
        if (at - size >= min) return at - size;
        if (at + size <= max) return at;
    }
    // Bigger than the surface on this axis: neither side fits, so put
    // as much of it on the surface as will go. `@max(min, …)` keeps the
    // clamp range non-empty when `size > extent` — without it the upper
    // bound is below the lower one and the answer is off the top-left.
    const preferred: f32 = if (leading) at else at - size;
    return std.math.clamp(preferred, min, @max(min, max - size));
}

/// The live overlay's own state. Spark holds at most one.
///
/// `Document` by value because that is how `Spark.loadDocument` hands
/// one back and how every host holds one; the arena inside it is
/// pointer-stable, so moving this struct is safe.
pub const Overlay = struct {
    doc: document_mod.Document,
    /// The point the caller anchored it to, and the corner it asked
    /// for. Kept rather than resolved once, because the surface can
    /// change size under an open menu (a window resize) and the flip
    /// has to be recomputed against the new extent.
    at: [2]f32,
    corner: Corner,

    /// A DrawList the MEASURE pass throws away. Owned and reused
    /// frame to frame — see `Spark.layoutAndRenderOverlay` for why a
    /// menu is laid out twice and why the first pass cannot share the
    /// frame's list.
    scratch: element.DrawList,

    /// Where the last render actually put it, in world coords. Zero
    /// until the first `layoutAndRenderOverlay`, which is deliberate:
    /// an overlay that has never been drawn has no rect, and
    /// `contains` answers false for every point — see the press/release
    /// asymmetry in `Spark.dispatchMouseButtonN`, which is what keeps
    /// the release of the very right-click that opened a menu from
    /// dismissing it.
    box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    /// The half-open range of `Spark.drawlist.hits` this overlay's last
    /// render appended. This is what makes the overlay take input
    /// FIRST: the dispatcher hit-tests inside this range alone while an
    /// overlay is open, so no click can reach the page under it — not
    /// even one over a page control that happens to sit on top of the
    /// menu in the hits array because the host called
    /// `layoutAndRenderOverlay` before its own `layoutAndRender`.
    hits: [2]u32 = .{ 0, 0 },

    pub fn contains(self: Overlay, x: f32, y: f32) bool {
        return x >= self.box.x and x < self.box.x + self.box.w and
            y >= self.box.y and y < self.box.y + self.box.h;
    }
};

// ── Tests ──────────────────────────────────────────────────────────
//
// `place` is the whole of the flip, and it is pure so that the flip can
// be gated without a device. The rendering path around it needs fonts,
// an atlas and a Vulkan context; the arithmetic that decides whether a
// menu covers the thing you right-clicked does not, and it is the part
// that can be wrong.

const testing = std.testing;

/// A 1280×720 surface with its origin at the world origin — the plain
/// case, so a gate's numbers read as pixels.
const screen: element.Box = .{ .x = 0, .y = 0, .w = 1280, .h = 720 };

test "overlay place: room on both axes leaves the preferred corner alone" {
    // The base case, and the one a mutation that "always flips" would
    // sail through if the only gate were the edge case.
    //
    // Mutation: make `placeAxis`'s leading arm return `at - size`
    // unconditionally (delete the `if (at + size <= max) return at;`).
    // The origin becomes (200, 100) instead of (400, 300) — red on the
    // first expectEqual.
    const p = place(.{ 400, 300 }, .{ 200, 200 }, .top_left, screen);
    try testing.expectEqual(@as(f32, 400), p[0]);
    try testing.expectEqual(@as(f32, 300), p[1]);
}

test "overlay place: near the right edge it flips instead of clamping" {
    // Chris's gate, and the reason `place` exists: *"a menu opened near
    // the right edge has its right edge on the surface, and its left
    // edge at `at.x`"* — i.e. the anchored corner has moved to the
    // OTHER side of the point, so the thing that was right-clicked is
    // still visible next to the menu rather than underneath it.
    //
    // Mutation: replace the leading arm's flip with a clamp —
    // `return @min(at, max - size);`. Compiles, and gives 1080 (the
    // menu's right edge pinned to the surface, its left edge nowhere
    // near `at`), so the second expectEqual goes red. That is exactly
    // the behaviour that covers the subject.
    const at_x: f32 = 1200;
    const p = place(.{ at_x, 100 }, .{ 200, 150 }, .top_left, screen);
    // Wholly on the surface…
    try testing.expect(p[0] >= 0);
    try testing.expect(p[0] + 200 <= screen.w);
    // …and the flip put the menu's RIGHT edge on the point.
    try testing.expectEqual(at_x, p[0] + 200);
    // y had room and must not have moved.
    try testing.expectEqual(@as(f32, 100), p[1]);
}

test "overlay place: the two axes decide independently" {
    // A menu near the BOTTOM edge but nowhere near the right one flips
    // on y and must not flip on x. The bug this catches is the obvious
    // shortcut — deciding the flip once from the corner and applying
    // that answer to both axes — which is invisible at `.top_left` in
    // the middle of the surface and wrong everywhere else.
    //
    // Mutation: `pub fn leadingY(self: Corner) bool { return
    // self.leadingX(); }`. Compiles. At `.bottom_left` leadingY becomes
    // true, so y stops growing UPWARDS from the point and the menu
    // hangs below it instead — 300 where 100 is wanted, red.
    //
    // `.bottom_left` means "the overlay's bottom-left corner at `at`",
    // so y prefers `at - h` = 100 and has room; x prefers `at` = 100.
    const p_ok = place(.{ 100, 300 }, .{ 200, 200 }, .bottom_left, screen);
    try testing.expectEqual(@as(f32, 100), p_ok[0]);
    try testing.expectEqual(@as(f32, 100), p_ok[1]);

    // Now the same corner where the PREFERRED y does not fit: anchored
    // near the top, `.bottom_left` wants `at - h` = -100, which is off
    // the surface, so y flips to `at` and x is untouched.
    const p_flip = place(.{ 100, 100 }, .{ 200, 200 }, .bottom_left, screen);
    try testing.expectEqual(@as(f32, 100), p_flip[0]);
    try testing.expectEqual(@as(f32, 100), p_flip[1]);
}

test "overlay place: a document wider than the surface clamps onto it" {
    // No flip can help here — neither side fits — and the honest answer
    // is "as much of it on screen as will go" rather than an origin
    // hundreds of pixels off the left edge, which is a menu the user
    // cannot see at all.
    //
    // Mutation: drop the clamp and `return preferred;`. The preferred
    // origin for `.top_right` at x=10 with a 1400-wide document is
    // -1390 — red.
    const p = place(.{ 10, 10 }, .{ 1400, 100 }, .top_right, screen);
    try testing.expectEqual(@as(f32, 0), p[0]);

    // And the same on a surface whose origin is NOT zero — a host
    // scrolled down the page. The clamp is against the visible rect,
    // not against zero.
    const scrolled: element.Box = .{ .x = 0, .y = 500, .w = 1280, .h = 720 };
    const q = place(.{ 10, 520 }, .{ 100, 900 }, .top_left, scrolled);
    try testing.expectEqual(@as(f32, 500), q[1]);
}

test "overlay place: a surface offset by scroll flips against the visible rect" {
    // The world/screen split is where this arithmetic is easiest to get
    // wrong: a host that scrolled the page 500px down has a visible
    // rect from y=500 to y=1220 in world coords, and a menu anchored at
    // y=1180 is near the BOTTOM even though 1180 is nowhere near the
    // surface height.
    //
    // Mutation: `const max = extent;` — the surface's height read as
    // its bottom edge, which is true only for an unscrolled page and is
    // the slip this whole world/screen split invites. Compiles. The
    // menu at y=600 then thinks 750 overruns 720, flips to 450, finds
    // that above the visible top, and clamps to 570 — red on the second
    // assertion, and 570 is a menu floating 30px above the cursor for
    // no reason anyone could explain from the picture.
    const scrolled: element.Box = .{ .x = 0, .y = 500, .w = 1280, .h = 720 };
    // Room below (1180 + 150 = 1330 > 1220) → flips.
    const near_bottom = place(.{ 100, 1180 }, .{ 200, 150 }, .top_left, scrolled);
    try testing.expectEqual(@as(f32, 1030), near_bottom[1]);
    // Room below (600 + 150 = 750 ≤ 1220) → does not.
    const mid = place(.{ 100, 600 }, .{ 200, 150 }, .top_left, scrolled);
    try testing.expectEqual(@as(f32, 600), mid[1]);
}

test "overlay: contains is false until the first render" {
    // The press/release asymmetry in the dispatcher rests on this. A
    // right-click that opens a menu is followed by its own RELEASE
    // before any frame has been drawn, so the overlay's box is still
    // zero at that moment; if a release dismissed, every menu opened by
    // right-click would close in the same gesture that opened it.
    //
    // Mutation: default `box` to a huge rect instead of zero. The
    // first expect goes red, and the dispatcher gate
    // "an overlay survives the release of the click that opened it"
    // goes green for the wrong reason — which is why both exist.
    const ov = Overlay{
        .doc = undefined,
        .at = .{ 100, 100 },
        .corner = .top_left,
        .scratch = undefined,
    };
    try testing.expect(!ov.contains(100, 100));

    var placed = ov;
    placed.box = .{ .x = 100, .y = 100, .w = 50, .h = 40 };
    try testing.expect(placed.contains(100, 100));
    try testing.expect(placed.contains(149, 139));
    // Half-open on both axes, same rule as `findHit`, so two boxes that
    // abut do not both claim the seam.
    try testing.expect(!placed.contains(150, 120));
    try testing.expect(!placed.contains(120, 140));
}
