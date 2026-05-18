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
    _ = @import("component.zig");
    _ = @import("components/badge.zig");
    _ = @import("components/box.zig");
    _ = @import("components/button.zig");
    _ = @import("components/chart.zig");
    _ = @import("components/embedded_document.zig");
    _ = @import("components/flex.zig");
    _ = @import("components/grid.zig");
    _ = @import("components/input.zig");
    _ = @import("components/llm_stream.zig");
    _ = @import("components/svg.zig");
    _ = @import("components/svg_stream.zig");
    _ = @import("components/image_stream.zig");
    _ = @import("components/slider.zig");
    _ = @import("asset_cache.zig");
    _ = @import("dotenv.zig");
    _ = @import("io_channel.zig");
    _ = @import("jobs.zig");
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
}
