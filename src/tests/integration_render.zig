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
/// PassDispatch serialization protocol **v3** (Phase B.7 — host_slot
/// arm joins). Must match the comment on `element.PassDispatch` —
/// both ends move together. Per dispatch the hasher writes an arm
/// tag byte first, then arm-specific fields in canonical order:
///
///   arm tag             — u8: 0 = pattern, 1 = single_source, 2 = host_slot
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
///   HostSlotStep (arm 2):
///     target_size         — [2]u32 (w, h)
///     composite_shader_id — 16 bytes
///     compose_region      — PassRegion
///     sequence_index      — u32
///     (NOTE: `invocation` is NOT hashed — function pointers aren't
///     stable across builds/processes and would defeat determinism.
///     Same exclusion category as `*_uniforms` trailing zero padding.)
///
/// **Inline uniform storage caveat.** `*_uniforms` are fixed-cap
/// `[MAX_PASS_UNIFORM_BYTES]u8` arrays in memory; the wire format
/// walks only the first `*_uniforms_len` bytes. Trailing zero
/// padding is not hashed.
///
/// **Exhaustive switch as structural-fingerprint guard.** The
/// per-arm dispatch below is exhaustive over PassDispatch; if a
/// fourth arm lands (Phase C `.chain`, future Phase E variants), the
/// compiler fires a non-exhaustive-switch error here. Don't add a
/// `_ => {}` catch-all — silently dropping arms from the fingerprint
/// is exactly the regression class this gate exists to prevent.
///
/// **v3 mint.** The host_slot arm joined at B.7; any doc that
/// exercises `:::placeholder_scene` (or Phase D's `:::3d-scene`)
/// would shift fingerprint vs. v2. Existing Phase A docs that
/// produce only pattern/single_source dispatches hash IDENTICALLY
/// under v3 — the new arm is purely additive.
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
            .host_slot => |hs| {
                h.update(&[_]u8{2}); // arm tag
                h.update(std.mem.asBytes(&hs.target_size));
                h.update(&hs.composite_shader_id);
                h.update(std.mem.asBytes(&hs.compose_region));
                h.update(std.mem.asBytes(&hs.sequence_index));
                // hs.invocation excluded by protocol — see header comment.
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
///
/// B.6 note: cache-layer changes that added `*_targets` to `Entry`
/// don't touch the wire format itself — the hasher reads the live
/// DrawList + pass_dispatches, not cache internals. The existing
/// gradient doc's path doesn't exercise `blitEntry` (one fresh Spark
/// per iteration, no second walk), so the baseline is invariant.
/// The new nested test below is what exercises the cache replay
/// path and earns its own assertion.
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

// Phase B.6 — cache-layer replay-with-offset.
//
// Two sequential walks in ONE Spark of a doc whose cacheable subtree
// contains a `.single_source` effect (`:::drop_shadow`). The first
// walk snapshots `drop_shadow`'s entry (including the wrapped
// `:::box`'s quad tagged with the drop_shadow's local pd index 0).
// The second walk hits the cache and replays through `blitEntry`,
// which is the codepath this phase fixed.
//
// Without the fix, `blitEntry` re-tagged every blitted primitive
// with the outer walker's `current_target_dispatch_index` (MAIN_TARGET
// at top level) — the wrapped box's quad drew on the main attachment
// AND the drop_shadow compose dispatch sampled an empty offscreen
// target. The `disable_cache = true` workaround on the drop_shadow
// vtable was the band-aid; this test ratifies removing it.
//
// Two load-bearing assertions:
//   1. Hash equality across walks — full determinism survives the
//      snapshot → blit round-trip.
//   2. At least one cached quad's target tag, after replay, equals
//      the live `single_source` dispatch's `sequence_index` — proves
//      the wrapped box routed to drop_shadow's offscreen target on
//      the cache-hit walk, not MAIN_TARGET. This is the literal bug
//      pre-B.6 — without the fix the quad's target would be
//      MAIN_TARGET and the count would be 0.

const cached_effect_doc =
    \\Some text above.
    \\
    \\:::drop_shadow {blur=8 offset_y=4}
    \\:::box {color=teal width=160 height=80 radius=8}
    \\:::
    \\:::
    \\
    \\Some text below.
    \\
;

test "cache replay: cached drop_shadow subtree preserves target routing" {
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

    var doc = try sp.loadDocument(cached_effect_doc, .{ .shared_state = &state });
    defer doc.deinit();

    var walk_hashes: [2]u64 = undefined;
    for (&walk_hashes) |*h| {
        try sp.beginFrame(
            .{ .extent = .{ .width = 800, .height = 600 } },
            .{ .reset = true },
        );
        _ = try sp.layoutAndRender(&doc, .{ 40, 40 }, .{ .max_w = 720 });
        h.* = hashFrame(&sp);
    }

    // (1) Determinism across the snapshot → blit round-trip.
    try testing.expectEqual(walk_hashes[0], walk_hashes[1]);

    // Confirm the cache was actually exercised on walk 2 (otherwise
    // this test silently degrades to two cache-miss walks and the
    // replay path is never hit).
    try testing.expect(sp.layout_cache.hits > 0);

    // (2) Find the single_source dispatch (drop_shadow) and assert
    // at least one quad routes to its offscreen target. Pre-B.6,
    // blitEntry would have re-tagged every cached quad to MAIN_TARGET
    // and this count would be 0.
    var ss_seq: ?u32 = null;
    for (sp.pass_dispatches.items) |d| {
        switch (d) {
            .single_source => |ss| {
                ss_seq = ss.sequence_index;
                break;
            },
            else => {},
        }
    }
    const seq = ss_seq orelse return error.NoSingleSourceDispatchEmitted;

    var routed_quad_count: u32 = 0;
    for (sp.drawlist.quad_targets.items) |t| {
        if (t == seq) routed_quad_count += 1;
    }
    try testing.expect(routed_quad_count > 0);
}

// Effects-spec Phase B.7 — `.host_slot` PassShape arm lit up
// end-to-end via the `:::placeholder_scene` stub factory. The
// factory is registered ONLY on this test's Spark — NOT by
// `installCoreComponents` (spec D#11 exception: stubs aren't
// vocabulary). Two load-bearing assertions:
//
//   1. A doc with `:::placeholder_scene` produces exactly one
//      PassDispatch and it's the `.host_slot` arm with the correct
//      composite_shader_id + non-null vtable-resolved invocation.
//      Pre-B.7 the walker had no `pass_kind == 4` case and would
//      hit the `unreachable`; this test trips on regression.
//   2. Hash deterministic across two consecutive Sparks. Wire
//      format v3 excludes `invocation` from the hash (function
//      pointers aren't stable across processes); this test ratifies
//      that exclusion — if a future refactor accidentally folds
//      invocation into the hash, two consecutive Sparks will
//      disagree (different vtable instance addresses each Spark)
//      and the assertion trips.

const placeholder_scene = @import("placeholder_scene.zig");

const placeholder_doc =
    \\:::placeholder_scene {width=200 height=120 color=#1a1a2e}
    \\:::
    \\
;

test "PassDispatch: :::placeholder_scene emits one host_slot dispatch deterministically" {
    const allocator = testing.allocator;

    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    var hashes: [2]u64 = undefined;
    var dispatch_counts: [2]usize = undefined;
    var dispatch_shapes: [2]struct {
        target_size: [2]u32,
        composite_shader_id: [16]u8,
        callback_nonnull: bool,
    } = undefined;

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
        // Test-only registration — the stub factory is NEVER in
        // installCoreComponents; tests opt in explicitly.
        try placeholder_scene.install(&sp);

        var doc = try sp.loadDocument(placeholder_doc, .{ .shared_state = &state });
        defer doc.deinit();

        try sp.beginFrame(
            .{ .extent = .{ .width = 800, .height = 600 } },
            .{ .reset = true },
        );
        _ = try sp.layoutAndRender(&doc, .{ 40, 40 }, .{ .max_w = 720 });

        hashes[i] = hashFrame(&sp);
        dispatch_counts[i] = sp.pass_dispatches.items.len;
        switch (sp.pass_dispatches.items[0]) {
            .host_slot => |hs| {
                dispatch_shapes[i] = .{
                    .target_size = hs.target_size,
                    .composite_shader_id = hs.composite_shader_id,
                    .callback_nonnull = @intFromPtr(hs.invocation.callback) != 0,
                };
            },
            else => return error.ExpectedHostSlotArm,
        }
    }

    // Exactly one dispatch — the :::placeholder_scene block emits
    // its host_slot arm; no other content in the doc to add
    // dispatches.
    try testing.expectEqual(@as(usize, 1), dispatch_counts[0]);
    try testing.expectEqual(@as(usize, 1), dispatch_counts[1]);

    // Shape: composite shader matches the placeholder factory's
    // declaration; target size matches the doc's width × height
    // (200 × 120). Callback is non-null (walker resolved via the
    // vtable hook; absent hook would have errored at layout time
    // with HostSlotElementMissingInvokeHook).
    try testing.expectEqual(@as(u32, 200), dispatch_shapes[0].target_size[0]);
    try testing.expectEqual(@as(u32, 120), dispatch_shapes[0].target_size[1]);
    try testing.expectEqual(placeholder_scene.SHADER_ID, dispatch_shapes[0].composite_shader_id);
    try testing.expect(dispatch_shapes[0].callback_nonnull);

    // Determinism across two Sparks. Each Spark constructs its own
    // vtable instance and its own Component allocation, so
    // `invocation.callback` and `invocation.user_data` are DIFFERENT
    // pointers between iterations. The fingerprint must still match
    // — proves the v3 hasher excludes the `invocation` field per
    // protocol. If a future refactor folds invocation into the hash,
    // this assertion trips deterministically.
    try testing.expectEqual(hashes[0], hashes[1]);
}
