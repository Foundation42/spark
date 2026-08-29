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
const spark = @import("../lib.zig");
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
    var state_a = spark.State.init(allocator);
    defer state_a.deinit();

    var spark_a = try spark.Spark.init(allocator, .{
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
    try spark.installCoreComponents(&spark_a);

    const fonts_b = try fixture.makeFonts(allocator, fx.ft);
    const theme_b = fixture.makeTheme(fonts_b);
    var state_b = spark.State.init(allocator);
    defer state_b.deinit();

    var spark_b = try spark.Spark.init(allocator, .{
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
    try spark.installCoreComponents(&spark_b);

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
    var state_a = spark.State.init(allocator);
    defer state_a.deinit();

    var spark_a = try spark.Spark.init(allocator, .{
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
    try spark.installCoreComponents(&spark_a);

    const fonts_b = try fixture.makeFonts(allocator, fx.ft);
    const theme_b = fixture.makeTheme(fonts_b);
    var state_b = spark.State.init(allocator);
    defer state_b.deinit();

    var spark_b = try spark.Spark.init(allocator, .{
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
    try spark.installCoreComponents(&spark_b);

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

test "two Spark instances own independent pattern pipeline caches" {
    // Effects-spec Phase A.6.b invariant — the pattern pipeline cache
    // is per-Spark (sibling field, not file-scope state). If a future
    // change accidentally shares a cache, this test trips: each Spark's
    // cache must be a distinct pointer + distinct VkPipeline handles
    // for the same shader_id (each Spark created its own pipelines via
    // its own `vkCreateGraphicsPipelines` call against the device).
    const allocator = testing.allocator;

    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts_a = try fixture.makeFonts(allocator, fx.ft);
    const theme_a = fixture.makeTheme(fonts_a);
    var state_a = spark.State.init(allocator);
    defer state_a.deinit();

    var spark_a = try spark.Spark.init(allocator, .{
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

    const fonts_b = try fixture.makeFonts(allocator, fx.ft);
    const theme_b = fixture.makeTheme(fonts_b);
    var state_b = spark.State.init(allocator);
    defer state_b.deinit();

    var spark_b = try spark.Spark.init(allocator, .{
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

    // Pipeline cache pointers differ (sibling-field-per-Spark).
    try testing.expect(&spark_a.pattern_pipelines != &spark_b.pattern_pipelines);

    // Same shader_id resolves to distinct VkPipeline handles in each
    // Spark — each instance ran its own vkCreateGraphicsPipelines.
    const gradient_id = spark.pass.shaderIdFromName("gradient.frag");
    const pipe_a = spark_a.pattern_pipelines.lookup(gradient_id, .main);
    const pipe_b = spark_b.pattern_pipelines.lookup(gradient_id, .main);
    try testing.expect(pipe_a != null);
    try testing.expect(pipe_b != null);
    try testing.expect(pipe_a.? != pipe_b.?);

    // Cross-instance leak check: nothing about A's deinit (deferred
    // above) should free B's pipelines. The defer order tears down
    // spark_b first, then spark_a — both must run cleanly without
    // double-free.
}

test "two Spark instances own independent effects substrate under effect-using docs" {
    // Effects-spec Phase B.8 — extends the per-Spark isolation
    // invariant beyond pattern pipelines (covered above) to the full
    // single_source substrate (target_pool, single_source_pipelines,
    // single_source_descriptor_pool) AND exercises it: each Spark
    // loads a doc containing a `:::drop_shadow`, lays it out, and
    // walks the pass-graph emission to populate pass_dispatches and
    // the drawlist's *_targets routing.
    //
    // Without per-Spark isolation, a shared target_pool would have
    // both Sparks racing on the same VkImage allocations; a shared
    // descriptor pool would interleave their compose sets unpredictably.
    // This test ratifies the sibling-field-per-Spark discipline holds
    // for the entire effects substrate — not just the pattern cache.
    const allocator = testing.allocator;

    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts_a = try fixture.makeFonts(allocator, fx.ft);
    const theme_a = fixture.makeTheme(fonts_a);
    var state_a = spark.State.init(allocator);
    defer state_a.deinit();

    var spark_a = try spark.Spark.init(allocator, .{
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
    try spark.installCoreComponents(&spark_a);

    const fonts_b = try fixture.makeFonts(allocator, fx.ft);
    const theme_b = fixture.makeTheme(fonts_b);
    var state_b = spark.State.init(allocator);
    defer state_b.deinit();

    var spark_b = try spark.Spark.init(allocator, .{
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
    try spark.installCoreComponents(&spark_b);

    // Per-Spark sibling-field invariant for the full single_source
    // substrate. Pointer-distinctness checks trip the moment any
    // future refactor accidentally aliases these fields across
    // Sparks (e.g. promoting one to a file-scope cache).
    try testing.expect(&spark_a.target_pool != &spark_b.target_pool);
    try testing.expect(&spark_a.single_source_pipelines != &spark_b.single_source_pipelines);
    try testing.expect(&spark_a.single_source_descriptor_pool != &spark_b.single_source_descriptor_pool);

    // Exercise the substrate: each Spark loads + walks a doc with a
    // `:::drop_shadow` wrapping a `:::box`. The walker populates
    // `pass_dispatches` with a `.single_source` arm and the drawlist
    // routes the wrapped quad to that dispatch's target. Without
    // executing the dispatch pass (which needs the host's
    // vkCmdBeginRendering scope), this still exercises every CPU-
    // side path: emission, target-routing tagging, cache snapshot.
    const effect_doc =
        \\:::drop_shadow {blur=8 offset_y=4}
        \\:::box {color=teal width=160 height=80 radius=8}
        \\:::
        \\:::
        \\
    ;

    var effect_doc_a = try spark_a.loadDocument(effect_doc, .{ .shared_state = &state_a });
    defer effect_doc_a.deinit();
    var effect_doc_b = try spark_b.loadDocument(effect_doc, .{ .shared_state = &state_b });
    defer effect_doc_b.deinit();

    try spark_a.beginFrame(
        .{ .extent = .{ .width = 800, .height = 600 } },
        .{ .reset = true },
    );
    _ = try spark_a.layoutAndRender(&effect_doc_a, .{ 40, 40 }, .{ .max_w = 720 });

    try spark_b.beginFrame(
        .{ .extent = .{ .width = 800, .height = 600 } },
        .{ .reset = true },
    );
    _ = try spark_b.layoutAndRender(&effect_doc_b, .{ 40, 40 }, .{ .max_w = 720 });

    // Both Sparks emitted independent pass_dispatches lists. Same
    // input doc → identical CPU-side dispatch count; the underlying
    // ArrayList storage is distinct memory.
    try testing.expectEqual(spark_a.pass_dispatches.items.len, spark_b.pass_dispatches.items.len);
    try testing.expect(spark_a.pass_dispatches.items.ptr != spark_b.pass_dispatches.items.ptr);

    // At least one effect dispatch in each — sanity that the doc
    // actually emitted what we wanted to exercise. `:::drop_shadow` is a
    // `.chain` since Effects-spec C.2, and a chain leans on MORE of the
    // per-Spark substrate than a single_source does (the ping-pong pool
    // acquires three targets, and `chain_pool_bases` is a second
    // per-Spark parallel array) — so it is a better doc for this test
    // than it was, not a worse one.
    var saw_effect_a = false;
    for (spark_a.pass_dispatches.items) |d| switch (d) {
        .single_source, .chain => saw_effect_a = true,
        else => {},
    };
    var saw_effect_b = false;
    for (spark_b.pass_dispatches.items) |d| switch (d) {
        .single_source, .chain => saw_effect_b = true,
        else => {},
    };
    try testing.expect(saw_effect_a);
    try testing.expect(saw_effect_b);

    // Defer order tears down spark_b first then spark_a. Both
    // deinits exercise the full effects substrate (target_pool
    // sweep, descriptor pool reset, pipeline cache destroy) — any
    // accidental cross-Spark aliasing trips a double-free or
    // use-after-free here.
}
