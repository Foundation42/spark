//! A clip inside an effect — gated on a real device, against real
//! pixels.
//!
//! **The bug.** `dispatchOffscreenPasses` recorded every quad and glyph
//! draw with `scissor_px = null`. A subtree routed into an offscreen
//! target — which is what `:::frosted_glass`, `:::drop_shadow` and
//! `:::liquid_glass` do to their children — therefore lost every clip
//! inside it, while the identical document at document top level clipped
//! correctly. Captured in matryoshka on 2026-09-10: a `hud graph` panel
//! whose `:::nodegraph` canvas is wrapped, with a heading and a footer,
//! in one `:::drop_shadow` — the node straddling the canvas edge paints
//! its body straight over the footer and out past the panel's rounded
//! corner. Its wires cut exactly right, and that is the tell: the
//! nodegraph clips its link segments on the CPU (there is no
//! `tri_clips`), so only quads and glyphs ever leaned on the scissor.
//!
//! **Why these gates render.** The fix that landed the hour before this
//! one carried gates that walked the element tree and checked clip
//! indices in the drawlist. They were green while the bug was live, and
//! they had to be: the indices were always right. What threw them away
//! was the RECORDING — `vkCmdSetScissor` never saw them. Nothing short
//! of a rendered frame can see that, so these read back pixels.
//!
//! **Why the fixture straddles, and why that is asserted.** A node
//! wholly inside its clip proves nothing, and is exactly how this
//! survived a device-backed nodegraph gate already: the fifty-node
//! fixture in `nodegraph_render.zig` is packed so every node is on
//! screen. So each gate below asserts, from the drawlist, that its
//! content really does cross the clip boundary before it looks at a
//! single pixel.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const vk = spark.vk;
const fixture = @import("fixture.zig");

const c = vk.c;

/// `R8G8B8A8_UNORM` for the reason `display_transform.zig` gives: an
/// `_SRGB` target would apply its own EOTF on write and the readback
/// would be measuring two transforms stacked. Big enough that the panel,
/// its window and everything the overspill could land on are all several
/// pixels tall.
const TARGET_W: u32 = 320;
const TARGET_H: u32 = 240;
const TARGET_FORMAT = c.VK_FORMAT_R8G8B8A8_UNORM;

/// Where the document is laid out inside the target, and how the frame
/// is scrolled under it. A gate that never scrolls cannot see whether
/// the world→screen half of `Spark.offscreenScissor` is there at all —
/// at `scroll = 0, zoom = 1` world and screen coords are the same
/// numbers, and deleting the transform is a mutation the frame would
/// route straight around.
const Frame = struct {
    origin: [2]f32 = .{ 8, 8 },
    scroll: [2]f32 = .{ 0, 0 },
};
const DEFAULT_FRAME: Frame = .{};

// ── The fixtures ───────────────────────────────────────────────────
//
// One shape, two effects, so both Phase 1 arms are covered:
// `:::frosted_glass` is a `.chain` dispatch (the arm matryoshka's panel
// actually takes) and `:::liquid_glass` is a `.single_source` one. The
// effects are turned down to as near an identity as their grammars
// allow — zero blur, zero tint, zero refraction — because the assertion
// is about WHERE colour lands, and a wash over everything would make a
// clean band and an overspilled one differ only in degree.
//
// The shape: a blue lid, a short clipping window holding something far
// taller than it, and a blue base. Both lids are INSIDE the effect, and
// that is the load-bearing part of the fixture — the effect's target is
// therefore taller than the window, so the overspill has somewhere to
// land that the target's own framebuffer bounds do NOT cut. Put the
// window flush to the effect's bounds instead and every gate here
// passes with the scissor still missing, because the clip volume did
// the cutting.
//
// Blue lids rather than white ones so that a glyph escaping onto a lid
// is a bright pixel on a dark one, rather than near-white ink on
// white.

const chain_doc =
    \\:::frosted_glass {blur=0 tint=#00000000}
    \\:::box {color=#2040ffff width=120 height=24 radius=0}
    \\:::
    \\:::clip {#win height=24 width=200}
    \\:::box {color=#ff2020ff width=200 height=120 radius=0}
    \\:::
    \\:::
    \\:::box {color=#2040ffff width=120 height=24 radius=0}
    \\:::
    \\:::
    \\
;

const single_source_doc =
    \\:::liquid_glass {radius=0 refraction=0 rim_brightness=0 edge_softness=0 tint=#00000000}
    \\:::box {color=#2040ffff width=120 height=24 radius=0}
    \\:::
    \\:::clip {#win height=24 width=200}
    \\:::box {color=#ff2020ff width=200 height=120 radius=0}
    \\:::
    \\:::
    \\:::box {color=#2040ffff width=120 height=24 radius=0}
    \\:::
    \\:::
    \\
;

/// The same shape with TEXT in the window instead of a box. Glyphs go
/// through a different pipeline and a different `recordDrawRange`, and
/// they were the other half of what matryoshka lost — node LABELS over
/// the panel title, not just node bodies.
const glyph_doc =
    \\:::frosted_glass {blur=0 tint=#00000000}
    \\:::box {color=#2040ffff width=120 height=24 radius=0}
    \\:::
    \\:::clip {#win height=22 width=200}
    \\ONE
    \\
    \\TWO
    \\
    \\THREE
    \\:::
    \\:::box {color=#2040ffff width=120 height=24 radius=0}
    \\:::
    \\:::
    \\
;

// ── The gates ──────────────────────────────────────────────────────

test "a clip inside a chain effect cuts the overspill, not the panel around it" {
    // **The mutation, executed: put `null` back** at the chain arm's
    // quad and glyph `recordDrawRange` calls in `phase1ProcessChain`
    // (`src/spark.zig`) — the code exactly as it shipped. Red at
    // `expectNoRedOutsideTheWindow`, `expected 0, found 3320`: the box
    // runs on past the window, over the base lid and off the bottom of
    // the effect's target.
    //
    // A weaker fix this also refuses, executed: one scissor per dispatch
    // rather than one per clipped run — `offscreenScissor` taking clip
    // slot 1 for every run instead of `run.clip`, which is what one rect
    // for the whole target amounts to. That cuts the overspill AND the
    // two lids, and `expectLidsSurvive` is what goes red. It is the
    // reason this gate asserts what must SURVIVE as well as what must be
    // cut, and the answer to "do the offscreen arms need `clippedRuns`
    // or would one rect do" — they need it.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const r = try render(allocator, &fx, chain_doc, DEFAULT_FRAME);
    defer r.deinit(allocator);

    try r.expectLastDispatch(.chain);
    try r.expectStraddles();
    try r.expectWindowStillShowsTheBox();
    try r.expectNoRedOutsideTheWindow();
    try r.expectLidsSurvive();
}

test "a clip inside a single_source effect cuts the overspill too" {
    // The other Phase 1 arm — `phase1ProcessSingleSource`. Both arms are
    // reachable from a document, so neither is excused: half a fix here
    // leaves `:::liquid_glass` and `:::gbuffer` broken while
    // `:::drop_shadow` works, which is worse than either.
    //
    // Mutation: `null` at the single_source arm's two calls. Red the
    // same way — `expected 0, found 3320`.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const r = try render(allocator, &fx, single_source_doc, DEFAULT_FRAME);
    defer r.deinit(allocator);

    try r.expectLastDispatch(.single_source);
    try r.expectStraddles();
    try r.expectWindowStillShowsTheBox();
    try r.expectNoRedOutsideTheWindow();
    try r.expectLidsSurvive();
}

test "glyphs inside an effect are cut by the same scissor as quads" {
    // Both halves of what matryoshka lost. The bodies were quads and the
    // labels were glyphs, and they escaped through two different
    // `recordDrawRange`s that each passed `null` — fixing one and not
    // the other would put the node boxes back inside the canvas and
    // leave their names floating over the panel title.
    //
    // Mutation, executed: `null` at the GLYPH call only, in both arms.
    // The quad gates above stay green — five of six pass — and this one
    // goes red at `expected 0, found 220`: `TWO` and `THREE` printed on
    // the base lid and on the ground below it.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const r = try render(allocator, &fx, glyph_doc, DEFAULT_FRAME);
    defer r.deinit(allocator);

    try r.expectLastDispatch(.chain);
    // The fixture straddles: there are clipped glyphs, and some of them
    // hang a whole line below the window's bottom edge. Three lines in a
    // 22-pixel window, so this is true by construction — asserted anyway,
    // because "by construction" is what a font-metric change quietly
    // undoes.
    try testing.expect(r.clipped_glyphs > 6);
    try testing.expect(r.glyph_overhang > 16);
    try r.expectNoInkOutsideTheWindow();
    try r.expectLidsSurvive();
}

test "the scissor follows the scroll, because Phase 1 records before the transform" {
    // **The half of `offscreenScissor` the other gates cannot see.** The
    // clip table is in WORLD coords while Phase 1 records — `endFrame`
    // transforms it afterwards — but `vkCmdSetScissor` bakes its numbers
    // in on the spot. At `scroll = 0` world and screen are the same
    // numbers and the missing transform is invisible; scrolled, it is a
    // scissor 40 pixels away from the window it is supposed to be
    // cutting.
    //
    // Mutation, executed: drop the `drawlist_needs_transform` branch in
    // `Spark.offscreenScissor` and use `rect` as-is. Every other gate in
    // this file stays green — that is the point of it — and this one
    // goes red at `expectWindowStillShowsTheBox`: the scissor sits 40
    // pixels below the window, so the window shows almost nothing and
    // the box shows through where it should not.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const still = try render(allocator, &fx, chain_doc, .{ .origin = .{ 8, 48 } });
    defer still.deinit(allocator);
    const r = try render(allocator, &fx, chain_doc, .{ .origin = .{ 8, 48 }, .scroll = .{ 0, 40 } });
    defer r.deinit(allocator);

    // The scroll really moved something. Without this the gate is a
    // second copy of the first one, passing for the reason that one
    // passes — and a `FrameInfo` field that silently stopped being read
    // would never be noticed here.
    try testing.expectEqual(still.window.?.y - 40, r.window.?.y);
    try r.expectStraddles();
    try r.expectWindowStillShowsTheBox();
    try r.expectNoRedOutsideTheWindow();
    try r.expectLidsSurvive();
}

test "an effect's own subtree is still unclipped where nothing clipped it" {
    // The other half of the claim, and the one a scissor bug of the
    // opposite sign would break: a subtree inside an effect that clips
    // NOTHING must come out whole. `NO_CLIP` has no entry in the clip
    // table, `DrawList.clipRect` answers null for it, and
    // `offscreenScissor` passes that null through as "the whole target".
    //
    // Mutation: have `offscreenScissor` return the target's extent inset
    // by a pixel on every side instead of null. It compiles, the panel
    // loses its border row, and this goes red — invisible to both gates
    // above, whose assertions all sit well inside their rects.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const r = try render(allocator, &fx,
        \\:::frosted_glass {blur=0 tint=#00000000}
        \\:::box {color=#ffffffff width=200 height=72 radius=0}
        \\:::
        \\:::
        \\
    , DEFAULT_FRAME);
    defer r.deinit(allocator);

    const box = r.quads[0];
    try testing.expectEqual(@as(u16, spark.element.NO_CLIP), box.clip);
    try testing.expect(box.target != spark.element.MAIN_TARGET);

    // Every row of the box, at both edge columns — the first and last
    // column and the first and last row are exactly what a one-pixel
    // inset would eat.
    const left: u32 = @intFromFloat(box.x);
    const right: u32 = @intFromFloat(box.x + box.w - 1);
    var y: u32 = @intFromFloat(box.y);
    const bottom: u32 = @intFromFloat(box.y + box.h);
    while (y < bottom) : (y += 1) {
        try testing.expect(r.isWhite(left, y));
        try testing.expect(r.isWhite(right, y));
    }
}

// ── Harness ────────────────────────────────────────────────────────

/// One offscreen colour attachment, the host-visible buffer its pixels
/// are copied into, and one real Spark frame recorded against it.
///
/// Local to this file for the same reason `buffer_growth.zig` and
/// `display_transform.zig` keep their own: spark has no readback path,
/// because nothing but a gate has ever wanted one.
const Rendered = struct {
    /// `TARGET_W * TARGET_H * 4` bytes, caller-owned.
    pixels: []u8,
    /// What the pass graph produced, so a gate can say which ARM it is
    /// standing on rather than trusting the document to have picked one.
    dispatch_kinds: []const std.meta.Tag(spark.element.PassDispatch),
    /// The drawlist's quads, in the screen-space coords `endFrame` left
    /// them in, each with the routing tag and clip index it was recorded
    /// under. Every band this file samples is derived from these rather
    /// than from arithmetic on the document — the first draft added up
    /// heights by hand, forgot markdown's inter-block spacing, and
    /// sampled a band eight pixels off the one it named.
    quads: []const QuadInfo,
    /// The window's rect, screen-space: the clip that `#win` pushed.
    /// Slot 0 of the clip table is the unclipped sentinel and every
    /// fixture here pushes exactly one clip, so slot 1 is it.
    window: ?spark.element.ClipRect,
    /// How far the clipped GLYPHS reach below the window, in pixels, and
    /// how many of them there are. The straddle claim for the text
    /// fixture, which has no clipped quad to ask.
    clipped_glyphs: usize,
    glyph_overhang: f32,

    const QuadInfo = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        clip: u16,
        target: u32,
        /// One of the two blue lids — the parts of the effect's subtree
        /// that nothing clipped and that must therefore survive whole.
        lid: bool,

        fn cx(self: QuadInfo) u32 {
            return @intFromFloat(self.x + self.w / 2);
        }
        fn cy(self: QuadInfo) u32 {
            return @intFromFloat(self.y + self.h / 2);
        }
    };

    fn deinit(self: Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.dispatch_kinds);
        allocator.free(self.quads);
    }

    fn at(self: Rendered, x: u32, y: u32) [4]u8 {
        const i = (@as(usize, y) * TARGET_W + x) * 4;
        return .{ self.pixels[i], self.pixels[i + 1], self.pixels[i + 2], self.pixels[i + 3] };
    }

    /// Red-dominant: the box's `#ff2020`, however the effect's blend and
    /// the RGBA16F round-trip have nudged it. A threshold rather than an
    /// equality because the pixel has been through a filter shader and a
    /// composite, and an exact-match gate on that would be a gate on the
    /// blend maths instead of on the scissor.
    fn isRed(self: Rendered, x: u32, y: u32) bool {
        const p = self.at(x, y);
        const r: i32 = p[0];
        const g: i32 = p[1];
        const b: i32 = p[2];
        return r > 96 and r - g > 48 and r - b > 48;
    }

    /// The lids' blue, which is what an overspill would be covering.
    fn isLidBlue(self: Rendered, x: u32, y: u32) bool {
        const p = self.at(x, y);
        const r: i32 = p[0];
        const b: i32 = p[2];
        return b > 150 and b - r > 48;
    }

    /// Glyph ink: the theme's near-white body colour. Nothing else in
    /// the glyph fixture is bright — the lids are blue and the ground is
    /// cleared to transparent — so a bright pixel outside the window is
    /// a letter that got away.
    fn isInk(self: Rendered, x: u32, y: u32) bool {
        const p = self.at(x, y);
        return p[0] > 150 and p[1] > 150 and p[2] > 150;
    }

    /// Plain white, for the one fixture that uses it.
    fn isWhite(self: Rendered, x: u32, y: u32) bool {
        const p = self.at(x, y);
        return p[0] > 180 and p[1] > 180 and p[2] > 180;
    }

    fn expectLastDispatch(self: Rendered, want: std.meta.Tag(spark.element.PassDispatch)) !void {
        try testing.expect(self.dispatch_kinds.len > 0);
        try testing.expectEqual(want, self.dispatch_kinds[self.dispatch_kinds.len - 1]);
    }

    /// The fixture is doing what it claims: there is a clipped quad, it
    /// is routed into an OFFSCREEN target (the main attachment has
    /// always clipped fine, and a fixture that quietly landed there
    /// would be watching the wrong path), and it hangs well below the
    /// window that is supposed to cut it.
    ///
    /// Without this the file could go no-op without anyone noticing — an
    /// attribute rename, a default height, a layout change, and the box
    /// fits inside its window and every pixel line below passes for the
    /// wrong reason.
    fn expectStraddles(self: Rendered) !void {
        const win = self.window orelse return error.FixturePushedNoClip;
        const box = self.clippedQuad() orelse return error.FixtureHasNoClippedQuad;
        try testing.expect(box.target != spark.element.MAIN_TARGET);
        try testing.expect(box.y + box.h > win.y + win.h + 32);
    }

    /// The window still shows the box. A scissor that cut EVERYTHING
    /// would pass every "no red outside" line on its own.
    fn expectWindowStillShowsTheBox(self: Rendered) !void {
        const win = self.window.?;
        var n: usize = 0;
        var y: u32 = @intFromFloat(win.y + 2);
        const y1: u32 = @intFromFloat(win.y + win.h - 2);
        while (y < y1) : (y += 1) {
            var x: u32 = @intFromFloat(win.x + 2);
            const x1: u32 = @intFromFloat(win.x + win.w - 2);
            while (x < x1) : (x += 1) {
                if (self.isRed(x, y)) n += 1;
            }
        }
        try testing.expect(n > 1000);
    }

    /// The whole claim, in one sweep of the frame: not one red pixel
    /// anywhere outside the window's rect. A band check would only look
    /// where someone thought to look; the overspill can land on a lid,
    /// past the panel, or off the bottom of the target.
    fn expectNoRedOutsideTheWindow(self: Rendered) !void {
        const win = self.window.?;
        var escaped: usize = 0;
        var y: u32 = 0;
        while (y < TARGET_H) : (y += 1) {
            var x: u32 = 0;
            while (x < TARGET_W) : (x += 1) {
                const fx_: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const inside = fx_ >= win.x - 1 and fx_ <= win.x + win.w and
                    fy >= win.y - 1 and fy <= win.y + win.h;
                if (!inside and self.isRed(x, y)) escaped += 1;
            }
        }
        try testing.expectEqual(@as(usize, 0), escaped);
    }

    /// Everything in the effect that was NOT clipped is untouched. This
    /// is the line that refuses one-rect-per-dispatch: that cuts the
    /// overspill and takes the lids with it.
    fn expectLidsSurvive(self: Rendered) !void {
        var lids: usize = 0;
        for (self.quads) |q| {
            if (!q.lid or q.clip != spark.element.NO_CLIP) continue;
            lids += 1;
            try testing.expect(self.isLidBlue(q.cx(), q.cy()));
        }
        // Both of them — a fixture that stopped emitting one would make
        // the loop above vacuous.
        try testing.expectEqual(@as(usize, 2), lids);
    }

    /// The glyph half of the same claim. Counted rather than sampled,
    /// because a letter is mostly holes and a point check on one would
    /// be a coin toss.
    fn expectNoInkOutsideTheWindow(self: Rendered) !void {
        const win = self.window.?;
        var inside: usize = 0;
        var escaped: usize = 0;
        var y: u32 = 0;
        while (y < TARGET_H) : (y += 1) {
            var x: u32 = 0;
            while (x < TARGET_W) : (x += 1) {
                if (!self.isInk(x, y)) continue;
                const fx_: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                if (fx_ >= win.x - 1 and fx_ <= win.x + win.w and
                    fy >= win.y - 1 and fy <= win.y + win.h)
                {
                    inside += 1;
                } else escaped += 1;
            }
        }
        // The first line is still legible in the window — otherwise a
        // scissor that cut every glyph would pass the line below.
        try testing.expect(inside > 40);
        try testing.expectEqual(@as(usize, 0), escaped);
    }

    fn clippedQuad(self: Rendered) ?QuadInfo {
        for (self.quads) |q| if (q.clip != spark.element.NO_CLIP) return q;
        return null;
    }
};

/// Stand up a whole Spark on the fixture's device, drive one real frame
/// of `source` — `attachCmd`, `beginFrame`, `layoutAndRender`,
/// `dispatchOffscreenPasses`, the host's `vkCmdBeginRendering`,
/// `endFrame` — and hand back the pixels alongside what the drawlist
/// said.
///
/// The whole cycle, not a subset: the scissor under test is recorded in
/// Phase 1 and consumed by a Phase 2 composite, so a harness that
/// skipped either would be gating a different program.
fn render(allocator: std.mem.Allocator, fx: *fixture.Fixture, source: []const u8, frame_opts: Frame) !Rendered {
    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var host_state = spark.State.init(allocator);
    defer host_state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = TARGET_FORMAT,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &host_state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var doc = try sp.loadDocument(source, .{ .shared_state = &host_state });
    defer doc.deinit();

    var rb = try Readback.init(&fx.ctx);
    defer rb.deinit();
    try rb.frame(&sp, &doc, frame_opts);

    // Read the layout back BEFORE the Spark goes away, and AFTER
    // `endFrame` — so quads and clips are both in screen space, the same
    // pass with the same numbers, and directly comparable to a pixel
    // coordinate without redoing the transform here.
    const kinds = try allocator.alloc(std.meta.Tag(spark.element.PassDispatch), sp.pass_dispatches.items.len);
    errdefer allocator.free(kinds);
    for (sp.pass_dispatches.items, 0..) |pd, i| kinds[i] = std.meta.activeTag(pd);

    const quads = try allocator.alloc(Rendered.QuadInfo, sp.drawlist.quads.items.len);
    errdefer allocator.free(quads);
    for (sp.drawlist.quads.items, 0..) |q, i| {
        quads[i] = .{
            .x = q.dst_pos[0],
            .y = q.dst_pos[1],
            .w = q.dst_size[0],
            .h = q.dst_size[1],
            .clip = sp.drawlist.quad_clips.items[i],
            .target = sp.drawlist.quad_targets.items[i],
            .lid = q.color[2] > 0.9 and q.color[0] < 0.3,
        };
    }

    const window: ?spark.element.ClipRect = sp.drawlist.clipRect(1);
    var clipped_glyphs: usize = 0;
    var overhang: f32 = 0;
    if (window) |win| {
        for (sp.drawlist.glyphs.items, 0..) |g, i| {
            if (sp.drawlist.glyph_clips.items[i] == spark.element.NO_CLIP) continue;
            clipped_glyphs += 1;
            overhang = @max(overhang, g.dst_pos[1] + g.dst_size[1] - (win.y + win.h));
        }
    }

    return .{
        .pixels = try rb.copyPixels(allocator),
        .dispatch_kinds = kinds,
        .quads = quads,
        .window = window,
        .clipped_glyphs = clipped_glyphs,
        .glyph_overhang = overhang,
    };
}

const Readback = struct {
    ctx: *const vk.Context,
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    buffer: c.VkBuffer = null,
    buffer_memory: c.VkDeviceMemory = null,
    pool: c.VkCommandPool = null,

    const bytes: u64 = @as(u64, TARGET_W) * TARGET_H * 4;

    fn init(ctx: *const vk.Context) !Readback {
        var self = Readback{ .ctx = ctx };
        errdefer self.deinit();
        const dev = ctx.device;

        var ici = std.mem.zeroes(c.VkImageCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = c.VK_IMAGE_TYPE_2D;
        ici.format = TARGET_FORMAT;
        ici.extent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ici.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        ici.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try vk.check(c.vkCreateImage(dev, &ici, null, &self.image));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, self.image, &req);
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(ctx, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.memory));
        try vk.check(c.vkBindImageMemory(dev, self.image, self.memory, 0));

        var vci = std.mem.zeroes(c.VkImageViewCreateInfo);
        vci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vci.image = self.image;
        vci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        vci.format = TARGET_FORMAT;
        vci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        try vk.check(c.vkCreateImageView(dev, &vci, null, &self.view));

        var bci = std.mem.zeroes(c.VkBufferCreateInfo);
        bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = bytes;
        bci.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try vk.check(c.vkCreateBuffer(dev, &bci, null, &self.buffer));

        c.vkGetBufferMemoryRequirements(dev, self.buffer, &req);
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(
            ctx,
            req.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.buffer_memory));
        try vk.check(c.vkBindBufferMemory(dev, self.buffer, self.buffer_memory, 0));

        var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        cpci.queueFamilyIndex = ctx.queue_family;
        try vk.check(c.vkCreateCommandPool(dev, &cpci, null, &self.pool));

        return self;
    }

    fn deinit(self: *Readback) void {
        const dev = self.ctx.device;
        _ = c.vkDeviceWaitIdle(dev);
        if (self.pool != null) c.vkDestroyCommandPool(dev, self.pool, null);
        if (self.buffer != null) c.vkDestroyBuffer(dev, self.buffer, null);
        if (self.buffer_memory != null) c.vkFreeMemory(dev, self.buffer_memory, null);
        if (self.view != null) c.vkDestroyImageView(dev, self.view, null);
        if (self.image != null) c.vkDestroyImage(dev, self.image, null);
        if (self.memory != null) c.vkFreeMemory(dev, self.memory, null);
        self.* = undefined;
    }

    fn frame(self: *Readback, sp: *spark.Spark, doc: *const spark.Document, opts: Frame) !void {
        const dev = self.ctx.device;
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = self.pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try vk.check(c.vkAllocateCommandBuffers(dev, &ai, &cmd));
        defer c.vkFreeCommandBuffers(dev, self.pool, 1, &cmd);

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        );

        sp.attachCmd(cmd, 0, 0);
        try sp.beginFrame(.{
            .extent = .{ .width = TARGET_W, .height = TARGET_H },
            .scroll_offset = opts.scroll,
        }, .{});
        _ = try sp.layoutAndRender(doc, opts.origin, .{ .max_w = TARGET_W - 16 });
        try sp.dispatchOffscreenPasses(cmd);

        var att = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        att.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        att.imageView = self.view;
        att.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        att.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        att.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        var ri = std.mem.zeroes(c.VkRenderingInfo);
        ri.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = TARGET_W, .height = TARGET_H } };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &att;
        c.vkCmdBeginRendering(cmd, &ri);
        try sp.endFrame();
        c.vkCmdEndRendering(cmd);

        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_ACCESS_TRANSFER_READ_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        region.imageExtent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        c.vkCmdCopyImageToBuffer(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.buffer,
            1,
            &region,
        );
        try vk.check(c.vkEndCommandBuffer(cmd));

        var si = std.mem.zeroes(c.VkSubmitInfo);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        try vk.check(c.vkQueueSubmit(self.ctx.queue, 1, &si, null));
        try vk.check(c.vkQueueWaitIdle(self.ctx.queue));
    }

    fn copyPixels(self: *Readback, allocator: std.mem.Allocator) ![]u8 {
        const dev = self.ctx.device;
        var raw: ?*anyopaque = null;
        try vk.check(c.vkMapMemory(dev, self.buffer_memory, 0, bytes, 0, &raw));
        defer c.vkUnmapMemory(dev, self.buffer_memory);
        const px: [*]const u8 = @ptrCast(raw.?);
        const out = try allocator.alloc(u8, bytes);
        @memcpy(out, px[0..bytes]);
        return out;
    }
};

fn barrier(
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    old: c.VkImageLayout,
    new: c.VkImageLayout,
    src_access: c.VkAccessFlags,
    dst_access: c.VkAccessFlags,
    src_stage: c.VkPipelineStageFlags,
    dst_stage: c.VkPipelineStageFlags,
) void {
    var b = std.mem.zeroes(c.VkImageMemoryBarrier);
    b.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    b.oldLayout = old;
    b.newLayout = new;
    b.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    b.subresourceRange = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
}

fn findMemoryType(ctx: *const vk.Context, type_bits: u32, required: c.VkMemoryPropertyFlags) !u32 {
    var props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &props);
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if ((type_bits & bit) == 0) continue;
        if ((props.memoryTypes[i].propertyFlags & required) == required) return i;
    }
    return error.NoSuitableMemoryType;
}



