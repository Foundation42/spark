//! Test entry point. `zig build test` uses this as its root so the
//! module root is `src/`, which lets test files in subdirectories
//! (`src/components/...`) reach up to `src/element.zig` and other
//! sibling modules via relative imports without hitting Zig's
//! "import of file outside module path" guard.
//!
//! Add new test-bearing files here as they land.

test {
    _ = @import("ansi.zig");
    _ = @import("markdown.zig");
    _ = @import("markdown_components.zig");
    _ = @import("params.zig");
    _ = @import("pass/graph.zig");
    _ = @import("pass/shader_resolver.zig");
    _ = @import("pass/target_pool.zig");
    _ = @import("pass/pattern_pipeline.zig");
    _ = @import("components/effects/gradient.zig");
    _ = @import("components/effects/drop_shadow.zig");
    _ = @import("components/effects/pattern.zig");
    _ = @import("components/effects/noise.zig");
    _ = @import("component.zig");
    _ = @import("components/badge.zig");
    _ = @import("components/box.zig");
    _ = @import("components/button.zig");
    _ = @import("components/chart.zig");
    _ = @import("components/embedded_document.zig");
    _ = @import("components/flex.zig");
    _ = @import("components/grid.zig");
    _ = @import("components/handle.zig");
    _ = @import("components/grip.zig");
    _ = @import("components/input.zig");
    _ = @import("components/kbd.zig");
    _ = @import("components/progress.zig");
    _ = @import("extras/llm_stream.zig");
    _ = @import("components/svg.zig");
    _ = @import("extras/svg_stream.zig");
    _ = @import("extras/image_stream.zig");
    _ = @import("components/slider.zig");
    // The grading widgets: shared maths, then the two views of it.
    _ = @import("components/color.zig");
    _ = @import("components/relief.zig");
    _ = @import("components/trackball.zig");
    _ = @import("components/color_bars.zig");
    _ = @import("components/color_wheel.zig");
    _ = @import("components/sparkline.zig");
    _ = @import("components/status.zig");
    _ = @import("components/tag.zig");
    _ = @import("components/trend.zig");
    _ = @import("components/value.zig");
    _ = @import("components/rating.zig");
    _ = @import("components/dot.zig");
    _ = @import("components/commit.zig");
    _ = @import("components/price.zig");
    _ = @import("components/diff.zig");
    _ = @import("components/gh_ref.zig");
    _ = @import("components/ago.zig");
    _ = @import("extras/asset_cache.zig");
    _ = @import("extras/dotenv.zig");
    _ = @import("extras/embedded_document_http.zig");
    _ = @import("io_channel.zig");
    // jobs moved to `common`, which runs its own suite (`zig build test`
    // there). Re-importing it here would run those tests twice and report
    // coverage this repo does not own.
    _ = @import("layout_cache.zig");
    _ = @import("layout/kiwi/strength.zig");
    _ = @import("layout/kiwi/term.zig");
    _ = @import("layout/kiwi/expression.zig");
    _ = @import("layout/kiwi/constraint.zig");
    _ = @import("layout/kiwi/builder.zig");
    _ = @import("layout/kiwi/util.zig");
    _ = @import("layout/kiwi/symbol.zig");
    _ = @import("layout/kiwi/row.zig");
    _ = @import("layout/kiwi/solver.zig");
    _ = @import("layout/context.zig");
    _ = @import("state.zig");
    _ = @import("svg.zig");
    _ = @import("svg_tessellate.zig");
    _ = @import("update.zig");
    _ = @import("spark.zig");

    // Phase 5 library-boundary tests
    _ = @import("tests/library_lifecycle.zig");
    _ = @import("tests/two_instances.zig");
    _ = @import("tests/two_documents.zig");
    _ = @import("tests/integration_render.zig");
    _ = @import("tests/single_source_dispatch.zig");
    _ = @import("tests/placeholder_scene.zig");
    _ = @import("tests/display_transform.zig");
}
