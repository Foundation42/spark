//! Phase 5 — two-instances State isolation test.
//!
//! Headline correctness lock for the library-spec. Phase 1 (session 18,
//! commit d6f2f4b) purged every `_ref` module-global from the
//! component layer; Phase 3 (cece52d) inverted Spark ownership so each
//! Spark constructs its own Registry / IoChannel / LayoutContext /
//! JobSystems / pipelines. Together those should make two `Spark`
//! instances in one process fully isolated — but neither commit
//! actually proved it with a test. This file does.
//!
//! If a future change re-introduces a process-global anywhere on the
//! component or engine path (shared cache, shared registry,
//! shared-by-accident State), one of the assertions below trips
//! deterministically.

const std = @import("std");
const testing = std.testing;
const text_engine = @import("../lib.zig");
const fixture = @import("fixture.zig");

const doc_a =
    \\:::box {#a color=teal width=120 height=60 radius=8}
    \\:::
    \\
;

const doc_b =
    \\:::box {#b color=magenta width=200 height=80 radius=12}
    \\:::
    \\
;

test "two Spark instances share no state" {
    const allocator = testing.allocator;

    // Both Sparks share one Vulkan context — same as a real host
    // (matryoshka) running two HUD overlays on one device. The
    // isolation we want is at the *library* layer (registry, state,
    // layout context, io_channel, pipelines), not the device layer.
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts_a = try fixture.makeFonts(allocator, fx.ft);
    const theme_a = fixture.makeTheme(fonts_a);
    var state_a = text_engine.State.init(allocator);
    defer state_a.deinit();

    var spark_a = try text_engine.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme_a,
        .fonts = fonts_a.registry,
        .host_state = &state_a,
    });
    defer {
        spark_a.deinit();
        allocator.destroy(fonts_a.registry);
    }
    spark_a.attachToRegistry();
    try text_engine.installCoreComponents(&spark_a);

    const fonts_b = try fixture.makeFonts(allocator, fx.ft);
    const theme_b = fixture.makeTheme(fonts_b);
    var state_b = text_engine.State.init(allocator);
    defer state_b.deinit();

    var spark_b = try text_engine.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme_b,
        .fonts = fonts_b.registry,
        .host_state = &state_b,
    });
    defer {
        spark_b.deinit();
        allocator.destroy(fonts_b.registry);
    }
    spark_b.attachToRegistry();
    try text_engine.installCoreComponents(&spark_b);

    // ── State isolation ──────────────────────────────────────────
    // Set a key on A's state, assert it's invisible on B's state and
    // vice versa. If anything's hiding a shared State pointer
    // module-globally, these reads cross-pollinate.
    try state_a.set("only_on_a", "alpha");
    try state_b.set("only_on_b", "bravo");

    try testing.expectEqualStrings("alpha", state_a.get("only_on_a").?);
    try testing.expectEqual(@as(?[]const u8, null), state_b.get("only_on_a"));

    try testing.expectEqualStrings("bravo", state_b.get("only_on_b").?);
    try testing.expectEqual(@as(?[]const u8, null), state_a.get("only_on_b"));

    // ── Registry isolation ───────────────────────────────────────
    // Each Spark has its own Registry. Both ran `installCoreComponents`
    // with the same factory names without collision — a shared
    // Registry would have errored on the second install with a
    // duplicate-name error. Confirm both back-pointers point home to
    // their own Spark, not to one another.
    try testing.expect(spark_a.registry != spark_b.registry);
    try testing.expect(spark_a.registry.spark.? == &spark_a);
    try testing.expect(spark_b.registry.spark.? == &spark_b);

    // ── Engine-resource isolation ────────────────────────────────
    // The Phase 3 heap-pointer fields (registry, layout_context,
    // io_channel, image_pipeline) all carve out per-Spark storage.
    // If a future refactor accidentally aliases any of them, these
    // pointer-distinctness checks trip.
    try testing.expect(spark_a.layout_context != spark_b.layout_context);
    try testing.expect(spark_a.io_channel != spark_b.io_channel);
    try testing.expect(spark_a.image_pipeline != spark_b.image_pipeline);

    // ── Document isolation ───────────────────────────────────────
    // Load distinct documents with distinct shared_state and verify
    // each Spark sees only its own document instance.
    var doc_a_handle = try spark_a.loadDocument(doc_a, .{ .shared_state = &state_a });
    defer doc_a_handle.deinit();
    var doc_b_handle = try spark_b.loadDocument(doc_b, .{ .shared_state = &state_b });
    defer doc_b_handle.deinit();

    try testing.expect(doc_a_handle.state.? == &state_a);
    try testing.expect(doc_b_handle.state.? == &state_b);
}

test "applying an update on A does not see B's state" {
    const allocator = testing.allocator;

    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts_a = try fixture.makeFonts(allocator, fx.ft);
    const theme_a = fixture.makeTheme(fonts_a);
    var state_a = text_engine.State.init(allocator);
    defer state_a.deinit();

    var spark_a = try text_engine.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme_a,
        .fonts = fonts_a.registry,
        .host_state = &state_a,
    });
    defer {
        spark_a.deinit();
        allocator.destroy(fonts_a.registry);
    }
    spark_a.attachToRegistry();
    try text_engine.installCoreComponents(&spark_a);

    const fonts_b = try fixture.makeFonts(allocator, fx.ft);
    const theme_b = fixture.makeTheme(fonts_b);
    var state_b = text_engine.State.init(allocator);
    defer state_b.deinit();

    var spark_b = try text_engine.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = fx.swapchain.format,
        .theme = &theme_b,
        .fonts = fonts_b.registry,
        .host_state = &state_b,
    });
    defer {
        spark_b.deinit();
        allocator.destroy(fonts_b.registry);
    }
    spark_b.attachToRegistry();
    try text_engine.installCoreComponents(&spark_b);

    // applyUpdate is the wire-format path the LM uses; it writes
    // through to host_state. Run an update on A targeting `shared_key`,
    // assert B's state never received it.
    const update_directive =
        \\:::update {target=state.shared_key}
        \\from-A
        \\:::
        \\
    ;
    _ = try spark_a.applyUpdate(update_directive);

    try testing.expectEqualStrings("from-A", state_a.get("shared_key").?);
    try testing.expectEqual(@as(?[]const u8, null), state_b.get("shared_key"));
}
