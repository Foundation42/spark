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
/// PassDispatch serialization protocol **v2** (Phase B.3 — tagged
/// union mint). Must match the comment on `element.PassDispatch` —
/// both ends move together. Per dispatch the hasher writes an arm
/// tag byte first, then arm-specific fields in canonical order:
///
///   arm tag             — u8: 0 = pattern, 1 = single_source
///
///   PatternStep (arm 0):
///     shader_id           — 16 bytes, raw
///     layout_region       — PassRegion, 16 bytes (x/y/w/h as i32)
///     uniform_bytes_len   — u32, little-endian (native — runtime is LE)
///     uniform_bytes       — raw uniform payload, `uniform_len` bytes
///     sequence_index      — u32, native
///
///   SingleSourceStep (arm 1):
///     target_size         — [2]u32 (w, h)
///     filter_shader_id    — 16 bytes
///     compose_region      — PassRegion
///     filter_uniforms_len — u32
///     filter_uniforms     — raw uniform payload, `filter_uniforms_len` bytes
///     subtree_dispatch_range — [2]u32 (start, end)
///     sequence_index      — u32
///
/// **Inline uniform storage caveat.** `*_uniforms` are fixed-cap
/// `[MAX_PASS_UNIFORM_BYTES]u8` arrays in memory; the wire format
/// walks only the first `*_uniforms_len` bytes. Trailing zero
/// padding is not hashed.
///
/// **v2 mint.** The arm tag byte didn't exist in v1 (Phase A.6.a),
/// so any Phase A doc's fingerprint changes when B.3 lands — the
/// EXPECTED_GRADIENT_HASH constant below was regenerated against
/// the v2 walk. From this commit forward, the constant is the
/// contract; any future protocol change breaks the test loudly.
fn hashFrame(sp: *const spark.Spark) u64 {
    var h = std.hash.Wyhash.init(0);

    const dl = &sp.drawlist;
    // Phase B.4.a: parallel `*_targets` arrays length-locked to
    // their primitive siblings; hashed in lockstep — drift in
    // either array (item content OR routing tag) flips the
    // fingerprint loudly.
    h.update(std.mem.asBytes(&dl.glyphs.items.len));
    for (dl.glyphs.items) |g| h.update(std.mem.asBytes(&g));
    for (dl.glyph_targets.items) |t| h.update(std.mem.asBytes(&t));

    h.update(std.mem.asBytes(&dl.quads.items.len));
    for (dl.quads.items) |q| h.update(std.mem.asBytes(&q));
    for (dl.quad_targets.items) |t| h.update(std.mem.asBytes(&t));

    h.update(std.mem.asBytes(&dl.tris.items.len));
    for (dl.tris.items) |v| h.update(std.mem.asBytes(&v));
    for (dl.tri_targets.items) |t| h.update(std.mem.asBytes(&t));

    h.update(std.mem.asBytes(&dl.tri_indices.items.len));
    for (dl.tri_indices.items) |i| h.update(std.mem.asBytes(&i));

    h.update(std.mem.asBytes(&dl.images.items.len));
    for (dl.images.items) |im| h.update(std.mem.asBytes(&im));
    for (dl.image_targets.items) |t| h.update(std.mem.asBytes(&t));

    h.update(std.mem.asBytes(&sp.pass_dispatches.items.len));
    for (sp.pass_dispatches.items) |d| {
        switch (d) {
            .pattern => |p| {
                h.update(&[_]u8{0}); // arm tag
                h.update(&p.shader_id);
                h.update(std.mem.asBytes(&p.layout_region));
                h.update(std.mem.asBytes(&p.uniform_len));
                h.update(p.uniform_bytes[0..p.uniform_len]);
                h.update(std.mem.asBytes(&p.sequence_index));
            },
            .single_source => |s| {
                h.update(&[_]u8{1}); // arm tag
                h.update(std.mem.asBytes(&s.target_size));
                h.update(&s.filter_shader_id);
                h.update(std.mem.asBytes(&s.compose_region));
                h.update(std.mem.asBytes(&s.filter_uniforms_len));
                h.update(s.filter_uniforms[0..s.filter_uniforms_len]);
                h.update(std.mem.asBytes(&s.subtree_dispatch_range));
                h.update(std.mem.asBytes(&s.sequence_index));
            },
        }
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

/// Wire-format v3 baseline (Phase B.4.a mint). The exact 64-bit hash
/// a `:::gradient` doc through the full layout + emission path
/// produces under the v3 protocol (tagged-union PassDispatch + per-
/// primitive parallel target-routing arrays). Any drift here is a
/// deliberate protocol change — regenerate this constant only when
/// the spec table moves and both ends of the protocol comment in
/// `hashFrame` are updated together.
///
/// Version trail:
///   v1 (A.6.a) — single PassDispatch struct, no routing.
///   v2 (B.3)   — tagged-union PassDispatch (pattern + single_source).
///   v3 (B.4.a) — adds parallel `*_targets` arrays per primitive.
const EXPECTED_GRADIENT_HASH_V3: u64 = 0xE1E0_6B9A_CD1A_814C;

test "PassDispatch wire-format v3: stored baseline hash" {
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

    var doc = try sp.loadDocument(gradient_doc, .{ .shared_state = &state });
    defer doc.deinit();

    try sp.beginFrame(
        .{ .extent = .{ .width = 800, .height = 600 } },
        .{ .reset = true },
    );
    _ = try sp.layoutAndRender(&doc, .{ 40, 40 }, .{ .max_w = 720 });

    const actual = hashFrame(&sp);
    try testing.expectEqual(EXPECTED_GRADIENT_HASH_V3, actual);
}
