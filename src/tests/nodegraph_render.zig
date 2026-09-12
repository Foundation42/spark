//! `:::nodegraph` through the real thing — a Spark with a real font
//! registry, a real document parse, and a real layout pass.
//!
//! The component's own gates are device-free on purpose: the transform,
//! the inverse, hit testing, curve flattening and pin layout are pure
//! maths and should be watched as such. Two things are not, and they are
//! here.
//!
//! **What a graph COSTS.** Glyph emission needs a font, so the only
//! honest count of a fifty-node graph comes from a pass that has one.
//! The numbers are asserted rather than printed, because a budget
//! nobody checks is a budget that has already been spent — the
//! self-sizing draw buffers landed today and made a big graph merely
//! expensive instead of fatal, which is exactly the condition under
//! which a cost quietly triples.
//!
//! **That labels stop at a zoom floor.** It is the level-of-detail rule
//! that makes the zoomed-out case cheap, and it is invisible to every
//! device-free gate because a device-free gate cannot emit a glyph.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const fixture = @import("fixture.zig");

/// Fifty nodes, three pins each, forty-nine links: the shape the brief
/// asked to be costed. Five to a row, packed so that EVERY node is on
/// screen at zoom 1 — a cost measured through the cull is a cost for
/// however many nodes happened to be in shot, which is not a number
/// anyone can budget against.
fn fiftyNodeDoc(allocator: std.mem.Allocator, view_line: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll(":::nodegraph {#g width=1200 height=800}\n");
    try w.print("{s}\n", .{view_line});
    for (0..50) |i| {
        const col: f32 = @floatFromInt(i % 5);
        const row: f32 = @floatFromInt(i / 5);
        try w.print(
            "node id=n{d} x={d} y={d} label=\"node {d}\"\n",
            .{ i, col * 230, row * 78, i },
        );
        try w.print("pin node=n{d} id=a dir=in label=\"a\"\n", .{i});
        try w.print("pin node=n{d} id=b dir=in label=\"b\"\n", .{i});
        try w.print("pin node=n{d} id=v dir=out label=\"v\"\n", .{i});
    }
    for (0..49) |i| {
        try w.print("link from=n{d}.v to=n{d}.a\n", .{ i, i + 1 });
    }
    try w.writeAll(":::\n");
    return buf.toOwnedSlice();
}

const Counts = struct {
    glyphs: usize,
    quads: usize,
    tris: usize,
    tri_indices: usize,
    hits: usize,
};

fn renderDoc(allocator: std.mem.Allocator, fx: *fixture.Fixture, doc_src: []const u8) !Counts {
    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var doc = try sp.loadDocument(doc_src, .{ .shared_state = &state });
    defer doc.deinit();

    try sp.beginFrame(
        .{ .extent = .{ .width = 1280, .height = 900 }, .zoom = 1.0, .scroll_offset = .{ 0, 0 } },
        .{ .reset = true },
    );
    _ = try sp.layoutAndRender(&doc, .{ 20, 20 }, .{ .max_w = 1240 });

    return .{
        .glyphs = sp.drawlist.glyphs.items.len,
        .quads = sp.drawlist.quads.items.len,
        .tris = sp.drawlist.tris.items.len,
        .tri_indices = sp.drawlist.tri_indices.items.len,
        .hits = sp.drawlist.hits.items.len,
    };
}

test "nodegraph: a bright chip's label goes DARK, and the canvas is what wires that up" {
    // `labelOn` has its own gates in the component; this one exists
    // because they were not enough. A mutation that simply stopped
    // CALLING it — `const ink = style.color;` — passed the entire suite,
    // because every gate tested the function and none tested the wiring.
    // A full-strength yellow chip then wears the theme's near-white
    // letters on it and the label is gone.
    //
    // It needs a real font, so it is here rather than beside `labelOn`:
    // the component's device-free gates hand `drawCanvas` an
    // uninitialised LayoutCtx that no glyph path may touch, which is
    // also why they all run under the label-zoom floor.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const doc =
        \\:::nodegraph {#g width=600 height=300 zoom=1}
        \\node id=sun x=0 y=0 label="YELLOW" tint=#f2e02f ring=#c2c8d4
        \\node id=deep x=0 y=120 label="BLUE" tint=#4169e1 ring=#c2c8d4
        \\pin node=sun id=o0 dir=out
        \\pin node=deep id=o0 dir=out
        \\:::
        \\
    ;

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var d = try sp.loadDocument(doc, .{ .shared_state = &state });
    defer d.deinit();
    try sp.beginFrame(
        .{ .extent = .{ .width = 1280, .height = 900 }, .zoom = 1.0, .scroll_offset = .{ 0, 0 } },
        .{ .reset = true },
    );
    _ = try sp.layoutAndRender(&d, .{ 20, 20 }, .{ .max_w = 1240 });

    // Luminance of every glyph drawn. Two labels, two answers: the
    // yellow bar's letters are dark and the royal blue bar's are not.
    var dark: usize = 0;
    var light: usize = 0;
    for (sp.drawlist.glyphs.items) |g| {
        const l = 0.2126 * g.color[0] + 0.7152 * g.color[1] + 0.0722 * g.color[2];
        if (l < 0.3) dark += 1 else light += 1;
    }
    try testing.expect(dark > 0);
    try testing.expect(light > 0);
}

test "nodegraph: fifty nodes cost what the report says they cost" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const src = try fiftyNodeDoc(allocator, "view pan=0,0 zoom=1");
    defer allocator.free(src);
    const c = try renderDoc(allocator, &fx, src);

    // Measured 2026-09-12, all fifty on screen at zoom 1:
    //
    //   quads   300     = 3 per node (ring, body, header) + 1 per pin.
    //   tris    1584    = 4 ground + 4 per grid rule + one RIBBON per
    //                     link: 4 vertices per flattened point, plus two
    //                     end caps.
    //   indices 5466    = 6 ground + 6 per rule + 18 per ribbon span.
    //   glyphs  440     = a node title plus three one-character pin
    //                     labels each, spaces excluded (a space has no
    //                     bitmap, so `appendShapedRun` emits nothing).
    //
    // **This was 6132 tris and 20208 indices the day before**, when a
    // wire was N separate `relief.stroke` calls at 16 vertices each. A
    // quarter of the cost, and the wires are smoother: the flattening
    // is adaptive now, and these links are short and nearly straight,
    // so they are worth a handful of points each instead of a fixed ten
    // segments. See `flattenCubic`.
    //
    // These are envelopes, not fingerprints: a colour change or one more
    // rule of grid must not fail a cost gate. A doubling must.
    try testing.expect(c.quads > 150 and c.quads < 450);
    try testing.expect(c.tris > 800 and c.tris < 4_000);
    try testing.expect(c.tri_indices > 2_500 and c.tri_indices < 14_000);
    try testing.expect(c.glyphs > 300 and c.glyphs < 2_000);

    // One hit for the whole canvas, and it is the component's own —
    // `emits_own_hits` with nothing appended would be a canvas that
    // cannot be clicked, which no count above would notice.
    try testing.expect(c.hits >= 1);
}

test "nodegraph: zooming out drops the labels, and most of the cost with them" {
    // The level-of-detail rule, which no device-free gate can see
    // because a device-free gate cannot emit a glyph in the first place.
    //
    // Mutation: delete the `if (z >= LABEL_MIN_ZOOM)` guard around
    // `drawLabels`. Red here by 1500 glyphs — and on screen it is that
    // many illegible ones, each rasterised at a size that earns its own
    // font face. (The component's device-free gates abort on the same
    // mutation, because they hand `drawCanvas` an uninitialised
    // LayoutCtx that no glyph path may touch. Two reds; this is the one
    // with a message.)
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const near = try fiftyNodeDoc(allocator, "view pan=0,0 zoom=1");
    defer allocator.free(near);
    const far = try fiftyNodeDoc(allocator, "view pan=0,0 zoom=0.25");
    defer allocator.free(far);

    const c_near = try renderDoc(allocator, &fx, near);
    const c_far = try renderDoc(allocator, &fx, far);

    // Zoomed out past the floor, the canvas draws no label at all. The
    // document around it still has its own prose, so this is a
    // comparison and not an expectation of zero.
    try testing.expect(c_far.glyphs < c_near.glyphs);
    try testing.expect(c_far.glyphs * 4 < c_near.glyphs);

    // **There is deliberately no triangle assertion here.** There used
    // to be one — "each wire is worth fewer segments at a quarter of
    // the scale" — and it passed for two days while measuring something
    // else: at zoom 1 most of a fifty-node graph is off-canvas and
    // rejected by a rect test, and at 0.25 it all fits. The old count
    // was expensive enough per wire to swamp that; the adaptive one is
    // not, and the measured totals went 1584 near against 2012 far.
    // More wires, each cheaper.
    //
    // The per-wire claim is real and is gated where it can be measured
    // alone: `nodegraph: flatness is measured on the SCREEN curve, so
    // zoom pays for itself`. A total over a canvas cannot see it.
}

/// One node, one input label and one output label, and nothing else in
/// the document — so every glyph in the frame belongs to the graph.
const one_node_doc =
    \\:::nodegraph {#g width=600 height=300}
    \\node id=n x=0 y=0 label="T"
    \\pin node=n id=in dir=in label="iiiiii"
    \\pin node=n id=out dir=out label="oooooo"
    \\:::
    \\
;

test "nodegraph: an output pin's label is right-aligned INSIDE its node" {
    // Both labels belong inside the node — an input set in from the
    // left edge, an output set in from the right. Hanging the output
    // outside instead (the first draft) puts it straight across the wire
    // leaving that very pin, which is what the picture showed.
    //
    // This is here and not beside the component because it needs real
    // shaped glyphs: the right edge of a run is only knowable from the
    // advance a font gives back. Mutation: `const shift: f32 = 0;` in
    // `appendLabel` — green against every device-free gate in the
    // component, red here.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var doc = try sp.loadDocument(one_node_doc, .{ .shared_state = &state });
    defer doc.deinit();

    try sp.beginFrame(
        .{ .extent = .{ .width = 900, .height = 600 }, .zoom = 1.0, .scroll_offset = .{ 0, 0 } },
        .{ .reset = true },
    );
    _ = try sp.layoutAndRender(&doc, .{ 20, 20 }, .{ .max_w = 860 });

    // The canvas's own hit box IS its rect — no other component in this
    // document registers one — so the origin comes back out of the
    // drawlist rather than being guessed from the layout.
    try testing.expectEqual(@as(usize, 1), sp.drawlist.hits.items.len);
    const origin_x = sp.drawlist.hits.items[0].box.x;
    const right_edge = origin_x + spark.components.nodegraph.NODE_W;

    try testing.expect(sp.drawlist.glyphs.items.len > 6);
    for (sp.drawlist.glyphs.items) |g| {
        // A glyph past the node's right edge is an output label hanging
        // outside it. One pixel of slack for the rounding
        // `appendShapedRun` does on every pen position.
        try testing.expect(g.dst_pos[0] + g.dst_size[0] <= right_edge + 1.0);
        try testing.expect(g.dst_pos[0] >= origin_x - 1.0);
    }
}

/// A document with a graph in the middle of it and eighty paragraphs of
/// prose around it — the shape the redraw question is actually asked in.
/// A graph alone in a document cannot show what a redraw costs the rest
/// of the page, which is the whole worry about redrawing during a drag.
fn graphInProseDoc(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll("# A document with a graph in it\n\n");
    for (0..40) |i| {
        try w.print(
            "Paragraph {d} — prose that has to be shaped, wrapped and turned\ninto glyphs before any of it can be drawn.\n\n",
            .{i},
        );
    }
    try w.writeAll(
        \\:::nodegraph {#g width=600 height=300}
        \\node id=a x=0 y=0 label="A"
        \\node id=b x=220 y=40 label="B"
        \\pin node=a id=out dir=out label="v"
        \\pin node=b id=in dir=in label="a"
        \\link from=a.out to=b.in
        \\:::
        \\
        \\
    );
    for (40..80) |i| {
        try w.print("Paragraph {d} — more prose under the canvas, so blocks are\nre-walked on both sides of it or on neither.\n\n", .{i});
    }
    return buf.toOwnedSlice();
}

test "nodegraph: a drag redraws every frame and re-shapes nothing but the canvas" {
    // The cost of the redraw fix, measured rather than argued. A drag
    // now asks the host for a frame on every move (`takeRedrawRequest`),
    // and the fear that buys is "so a drag re-lays-out the whole
    // document sixty times a second". It does re-WALK it — there is no
    // partial-drawlist path, `beginFrame(.reset = false)` replays the
    // previous frame verbatim or not at all — and the walk costs
    // nothing, because every block around the canvas comes out of the
    // block cache. This gate is that sentence executed.
    //
    // Two mutations, both executed:
    //
    //  * delete the `defer noteRedraw(sp, hit, before)` in
    //    `Spark.dispatchHit` — 0 frames instead of 30, red, and that is
    //    the bug Christian reported.
    //  * `self.layout_cache.clear()` on `beginFrame`'s reset path, the
    //    "reset means reset" symmetry the drawlist and pass_dispatches
    //    already have — 2430 misses instead of 0, red. Every paragraph
    //    on the page re-shaped for a node moving one pixel.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const src = try graphInProseDoc(allocator);
    defer allocator.free(src);

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();
    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var doc = try sp.loadDocument(src, .{ .shared_state = &state });
    defer doc.deinit();

    const fi = spark.FrameInfo{
        .extent = .{ .width = 1280, .height = 900 },
        .zoom = 1.0,
        .scroll_offset = .{ 0, 0 },
    };
    const origin: [2]f32 = .{ 20, 20 };
    const constraints: spark.Constraints = .{ .max_w = 1240 };

    // Frame one is cold: eighty-odd blocks, every one a miss. Asserted
    // so the zero below means "the cache absorbed it" and not "the cache
    // was never asked".
    try sp.beginFrame(fi, .{ .reset = true });
    _ = try sp.layoutAndRender(&doc, origin, constraints);
    try testing.expect(sp.layout_cache.misses > 50);

    // The canvas's own hit is the only one in the document, so the
    // press lands on the graph without guessing where it ended up.
    const canvas = sp.drawlist.hits.items[0].box;
    try sp.dispatchMouseButtonN(canvas.x + 20, canvas.y + 10, true, 0);
    _ = sp.takeRedrawRequest();

    var frames: usize = 0;
    var misses: u64 = 0;
    var hits: u64 = 0;
    for (1..31) |i| {
        const step: f32 = @floatFromInt(i);
        try sp.dispatchMouseMove(canvas.x + 20 + step, canvas.y + 10);
        if (!sp.takeRedrawRequest()) continue;
        frames += 1;
        sp.layout_cache.resetStats();
        try sp.beginFrame(fi, .{ .reset = true });
        _ = try sp.layoutAndRender(&doc, origin, constraints);
        misses += sp.layout_cache.misses;
        hits += sp.layout_cache.hits;
    }

    // Every move drew. This is the reported bug's gate at full scale.
    try testing.expectEqual(@as(usize, 30), frames);
    // And not one block of prose was re-shaped in any of the thirty.
    // (Measured 2026-09-09: 4860 hits, 0 misses, ~0.21 ms a frame for
    // this document. The canvas itself sets `disable_cache` and re-walks
    // every frame on purpose — the camera is invisible to a cache key.)
    try testing.expectEqual(@as(u64, 0), misses);
    try testing.expect(hits > 100);

    // The other half: let go, take the pointer off the graph, and a
    // pointer wandering over prose asks for nothing at all. The first
    // move off the canvas is a real change — it unlights the node the
    // pointer left — so it is taken before the count starts.
    try sp.dispatchMouseButtonN(canvas.x + 50, canvas.y + 10, false, 0);
    try sp.dispatchHover(origin[0] + 10, origin[1] + 10);
    _ = sp.takeRedrawRequest();

    var idle: usize = 0;
    for (0..30) |i| {
        const step: f32 = @floatFromInt(i);
        try sp.dispatchHover(origin[0] + 10 + step, origin[1] + 10);
        if (sp.takeRedrawRequest()) idle += 1;
    }
    try testing.expectEqual(@as(usize, 0), idle);
}

// ── The panel's own chrome must not swallow the canvas's scissor ────

/// The `hud graph roaches` panel, cut down to the four blocks the bug
/// needs: a **cacheable** effect wrapper, a title, a canvas zoomed far
/// enough that its nodes hang past its own edge, and a footer under it.
///
/// The wrapper is the whole point. `:::nodegraph` sets
/// `disable_cache`, so it re-walks every frame and pushes its clip
/// every frame — which is why spark's own `src/nodegraph.md`, where the
/// canvas sits at document top level, clips correctly and always did.
/// `:::frosted_glass` does NOT set it, so from the second frame on the
/// whole panel comes out of the block cache, and whatever the cache
/// fails to carry is simply not in the frame.
const PANEL_DOC =
    \\:::frosted_glass {backdrop blur=16 radius=12 tint=#2b2f3aD0 padding="10 14 14 14" align=start text_align=left}
    \\
    \\## roaches
    \\
    \\22 nodes, 19 wires, on the row plane
    \\
    \\:::nodegraph {#g width=420 height=150}
    \\view pan=-20,-16 zoom=2.4
    \\node id=a x=0   y=0   label="spawn1"
    \\pin node=a id=o dir=out label="v"
    \\node id=b x=0   y=76  label="gravity1"
    \\pin node=b id=i dir=in  label="g"
    \\node id=c x=0   y=152 label="collide1"
    \\pin node=c id=i dir=in  label="at"
    \\link from=a.o to=b.i
    \\:::
    \\
    \\Generated from kernels/roaches.rill.
    \\
    \\:::
    \\
;

/// Every quad of one frame as `(rect it draws, rect it is scissored
/// to)`. Copied out because `beginFrame(.{ .reset = true })` clears the
/// drawlist under us.
const ClippedQuad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    clip: ?spark.element.ClipRect,
};

fn frameQuads(allocator: std.mem.Allocator, sp: *spark.Spark) ![]ClippedQuad {
    const dl = &sp.drawlist;
    // The tail of the frame is unsealed until the draw loop asks; do
    // here what `endFrame` does, so a quad emitted last is not read as
    // unclipped just because nobody has looked yet.
    try dl.sealClips(spark.element.NO_CLIP);
    const out = try allocator.alloc(ClippedQuad, dl.quads.items.len);
    for (dl.quads.items, 0..) |q, i| {
        out[i] = .{
            .x = q.dst_pos[0],
            .y = q.dst_pos[1],
            .w = q.dst_size[0],
            .h = q.dst_size[1],
            .clip = dl.clipRect(dl.quad_clips.items[i]),
        };
    }
    return out;
}

test "nodegraph: a canvas inside a cached panel is still scissored on the second frame" {
    // Christian, 2026-09-10, `hud graph roaches` zoomed in: *"when
    // zoomed there is a compositing/clipping problem. The graph paints
    // on top of its container."* Node bodies and their labels over the
    // panel's title, over its footer, past its left edge — and the wires
    // cut exactly right, because `:::nodegraph` clips its link segments
    // by hand (there is no `tri_clips`; the scissor never sees a
    // triangle). Everything that relied on the GPU scissor escaped.
    //
    // The cause was one array the block cache did not carry. A clip is
    // an INDEX into a per-frame table; `blitEntry` replayed the quads
    // and the glyphs and neither the indices nor the table, so
    // `DrawList.clips` was EMPTY for the whole frame and no scissor was
    // ever set. Invisible at zoom 1 because nothing straddled the
    // canvas edge — hence a fixture here that does.
    //
    // Mutation: `entry.clips = &.{}` in `snapshotEntry`, or drop the
    // `else` arm of `blitEntry`'s clip replay. Frame 1 is unaffected
    // (it is the walk) and frame 2 loses every clip — which is the
    // shape of the bug and the reason one frame could never catch it.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var state = spark.State.init(allocator);
    defer state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var doc = try sp.loadDocument(PANEL_DOC, .{ .shared_state = &state });
    defer doc.deinit();

    var frames: [2][]ClippedQuad = undefined;
    var hits_on_second: u64 = 0;
    for (0..2) |f| {
        try sp.beginFrame(
            .{ .extent = .{ .width = 1280, .height = 720 }, .zoom = 1.0, .scroll_offset = .{ 0, 0 } },
            .{ .reset = true },
        );
        const before_hits = sp.layout_cache.hits;
        _ = try sp.layoutAndRender(&doc, .{ 40, 60 }, .{ .max_w = 520 });
        if (f == 1) hits_on_second = sp.layout_cache.hits - before_hits;
        frames[f] = try frameQuads(allocator, &sp);
    }
    defer for (frames) |f| allocator.free(f);

    // The gate is on the CACHED path, so say so: a run where the second
    // frame re-walked everything would pass every line below while
    // testing nothing.
    try testing.expect(hits_on_second > 0);
    try testing.expectEqual(frames[0].len, frames[1].len);

    // Frame 1 is the live walk and is the reference. It must contain a
    // quad that is scissored AND hangs outside its scissor — the zoomed
    // node past the canvas edge. Without this the fixture could sit
    // wholly inside its own clip and the comparison below would be
    // watching nothing at all; that is exactly how this bug survived
    // two repos' gates and was found by eye.
    var straddlers: usize = 0;
    for (frames[0]) |q| {
        const c = q.clip orelse continue;
        if (q.y + q.h > c.y + c.h or q.x + q.w > c.x + c.w or q.y < c.y or q.x < c.x) straddlers += 1;
    }
    try testing.expect(straddlers > 0);

    // And the second frame — the one that comes out of the cache — must
    // scissor every quad exactly where the first one did.
    for (frames[0], frames[1]) |a, b| {
        try testing.expectEqual(a.x, b.x);
        try testing.expectEqual(a.y, b.y);
        try testing.expectEqual(a.clip == null, b.clip == null);
        if (a.clip) |ca| {
            const cb = b.clip.?;
            try testing.expectEqual(ca.x, cb.x);
            try testing.expectEqual(ca.y, cb.y);
            try testing.expectEqual(ca.w, cb.w);
            try testing.expectEqual(ca.h, cb.h);
        }
    }
}
