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

test "nodegraph: fifty nodes cost what the report says they cost" {
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const src = try fiftyNodeDoc(allocator, "view pan=0,0 zoom=1");
    defer allocator.free(src);
    const c = try renderDoc(allocator, &fx, src);

    // Measured 2026-09-09, all fifty on screen at zoom 1:
    //
    //   quads   300     = 3 per node (ring, body, header) + 1 per pin.
    //   tris    6132    = 4 ground + 4 per grid rule + 16 per link
    //                     SEGMENT. The wires are ~5900 of it; the grid
    //                     and the ground are the rest.
    //   indices 20208   = 6 ground + 6 per rule + 54 per segment.
    //   glyphs  440     = a node title plus three one-character pin
    //                     labels each, spaces excluded (a space has no
    //                     bitmap, so `appendShapedRun` emits nothing).
    //
    // One link is ~10 segments here, so ~160 vertices — which is why the
    // segment count comes off the SCREEN chord and not the graph one
    // (`segmentCount`), and why the labels have a zoom floor. Both are
    // the difference between a graph that gets cheaper as you pull back
    // and one that does not.
    //
    // These are envelopes, not fingerprints: a colour change or one more
    // rule of grid must not fail a cost gate. A doubling must.
    try testing.expect(c.quads > 150 and c.quads < 450);
    try testing.expect(c.tris > 3_000 and c.tris < 14_000);
    try testing.expect(c.tri_indices > 10_000 and c.tri_indices < 48_000);
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
    // And each wire is worth fewer segments at a quarter of the scale.
    try testing.expect(c_far.tris < c_near.tris);
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
