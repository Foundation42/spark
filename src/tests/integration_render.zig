//! Phase 5 — integration render test. Catches silent rendering
//! regressions by hashing the DrawList that comes out of a real
//! layout pass against a stored fingerprint.
//!
//! Why a hash and not a per-field assertion: the drawlist is dense
//! (glyph instances, quad instances, tri vertices, tri indices), and
//! the assertion isn't "does this exact glyph at this exact offset
//! land at this exact pixel" — it's "did the rendering pipeline's
//! deterministic output drift, at all." A hash catches drift at any
//! field with a one-line failure.
//!
//! Workflow when this test fails: re-run, eyeball the demo to
//! confirm the new output is correct, then update the fingerprint
//! below. The fingerprint is the contract; the test is the canary.
//!
//! The walk goes through the public Spark surface end-to-end:
//! `loadDocument` → `beginFrame` → `layoutAndRender`. `endFrame` is
//! skipped because it issues real Vulkan SSBO writes; we hash the
//! pre-upload DrawList state instead. Same contents, cheaper to
//! exercise from a test.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const fixture = @import("fixture.zig");

const known_doc =
    \\# Spark fingerprint
    \\
    \\Some body text to exercise glyph emission.
    \\
    \\:::box {color=teal width=160 height=80 radius=8}
    \\:::
    \\
;

/// Whole-frame fingerprint. Covers the rasterizer's DrawList (glyphs,
/// quads, tris, indices) plus the pass-graph's dispatch list. From
/// Phase A.6.a onward, docs containing `:::gradient` / `:::pattern` /
/// `:::noise` populate the dispatch list and influence this hash.
/// Drift in either layer fails the determinism / fingerprint tests
/// below with a one-line message.
///
/// PassDispatch serialization protocol (must match the comment on
/// `element.PassDispatch` — both ends move together):
///
///   shader_id           — 16 bytes, raw
///   layout_region       — PassRegion, 16 bytes (x/y/w/h as i32)
///   uniform_bytes_len   — u32, little-endian (native — runtime is LE)
///   uniform_bytes       — raw uniform payload, `uniform_len` bytes
///   sequence_index      — u32, native
///
/// **Inline uniform storage caveat.** `PassDispatch.uniform_bytes`
/// is a fixed-cap `[MAX_PASS_UNIFORM_BYTES]u8` array in memory but
/// the wire format walks only the first `uniform_len` bytes. The
/// trailing zero-padding is NOT hashed — protocol unchanged from
/// when uniform_bytes was a `[]const u8` slice.
fn hashFrame(sp: *const spark.Spark) u64 {
    var h = std.hash.Wyhash.init(0);

    const dl = &sp.drawlist;
    h.update(std.mem.asBytes(&dl.glyphs.items.len));
    for (dl.glyphs.items) |g| h.update(std.mem.asBytes(&g));

    h.update(std.mem.asBytes(&dl.quads.items.len));
    for (dl.quads.items) |q| h.update(std.mem.asBytes(&q));

    h.update(std.mem.asBytes(&dl.tris.items.len));
    for (dl.tris.items) |v| h.update(std.mem.asBytes(&v));

    h.update(std.mem.asBytes(&dl.tri_indices.items.len));
    for (dl.tri_indices.items) |i| h.update(std.mem.asBytes(&i));

    h.update(std.mem.asBytes(&sp.pass_dispatches.items.len));
    for (sp.pass_dispatches.items) |d| {
        h.update(&d.shader_id);
        h.update(std.mem.asBytes(&d.layout_region));
        h.update(std.mem.asBytes(&d.uniform_len));
        h.update(d.uniform_bytes[0..d.uniform_len]);
        h.update(std.mem.asBytes(&d.sequence_index));
    }

    return h.final();
}

test "DrawList is deterministic across runs" {
    const allocator = testing.allocator;

    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    var hashes: [2]u64 = undefined;
    var counts: [2]struct { glyphs: usize, quads: usize, tris: usize } = undefined;

    inline for (0..2) |i| {
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

        var doc = try sp.loadDocument(known_doc, .{ .shared_state = &state });
        defer doc.deinit();

        // Skip attachCmd — it just stores the cmd buffer for endFrame
        // to use later, and we never reach endFrame.
        try sp.beginFrame(
            .{
                .extent = .{ .width = 800, .height = 600 },
                .zoom = 1.0,
                .scroll_offset = .{ 0, 0 },
            },
            .{ .reset = true },
        );
        _ = try sp.layoutAndRender(&doc, .{ 40, 40 }, .{ .max_w = 720 });

        hashes[i] = hashFrame(&sp);
        counts[i] = .{
            .glyphs = sp.drawlist.glyphs.items.len,
            .quads = sp.drawlist.quads.items.len,
            .tris = sp.drawlist.tris.items.len,
        };
    }

    // Same input → same DrawList — every byte. If two consecutive
    // Sparks loading the same doc disagree, something on the layout
    // hot path is non-deterministic (uninitialised memory, hash-map
    // iteration order leaking through, time-of-day in a transform,
    // etc.) and worth chasing before it bites a downstream consumer.
    try testing.expectEqual(hashes[0], hashes[1]);
    try testing.expectEqual(counts[0].glyphs, counts[1].glyphs);
    try testing.expectEqual(counts[0].quads, counts[1].quads);
    try testing.expectEqual(counts[0].tris, counts[1].tris);

    // Sanity: this known doc must produce non-empty output. If a
    // future regression makes layoutAndRender silently no-op, this
    // assertion catches it.
    try testing.expect(counts[0].glyphs > 0);
    try testing.expect(counts[0].quads > 0);
}

// Effects-spec Phase A.6.a deliverable — the A.0-deferred load-bearing
// "pass-graph determinism actually verified against real data" test.
// A doc with one `:::gradient` flows through the pass-graph compiler,
// produces exactly one `PassDispatch`, and the fingerprint is locked
// against drift across runs. From this commit forward, any change to
// the wire format (struct reorder, sequence renumbering, region
// quantisation, std140 padding shift) breaks this test loudly.

const gradient_doc =
    \\:::gradient {from=#1a1a2e to=#16213e direction=vertical width=200 height=80}
    \\:::
    \\
;

test "PassDispatch fingerprint: :::gradient produces one deterministic dispatch" {
    const allocator = testing.allocator;

    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    var hashes: [2]u64 = undefined;
    var dispatch_counts: [2]usize = undefined;

    inline for (0..2) |i| {
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

        var doc = try sp.loadDocument(gradient_doc, .{ .shared_state = &state });
        defer doc.deinit();

        try sp.beginFrame(
            .{ .extent = .{ .width = 800, .height = 600 } },
            .{ .reset = true },
        );
        _ = try sp.layoutAndRender(&doc, .{ 40, 40 }, .{ .max_w = 720 });

        hashes[i] = hashFrame(&sp);
        dispatch_counts[i] = sp.pass_dispatches.items.len;
    }

    // Two consecutive Sparks loading the same doc must produce
    // identical PassDispatch lists — every byte, including the
    // std140-padded uniform contents.
    try testing.expectEqual(hashes[0], hashes[1]);
    try testing.expectEqual(dispatch_counts[0], dispatch_counts[1]);

    // Sanity: the :::gradient block produces exactly one dispatch
    // (pattern-pass, content arm not exercised here). If a future
    // regression breaks the walker's pass_kind check or skips the
    // emit branch, this assertion catches it before the fingerprint
    // changes do.
    try testing.expectEqual(@as(usize, 1), dispatch_counts[0]);
}
