//! Test entry point. `zig build test` uses this as its root so the
//! module root is `src/`, which lets test files in subdirectories
//! (`src/components/...`) reach up to `src/element.zig` and other
//! sibling modules via relative imports without hitting Zig's
//! "import of file outside module path" guard.
//!
//! Add new test-bearing files here as they land.

test {
    _ = @import("markdown_components.zig");
    _ = @import("component.zig");
    _ = @import("components/box.zig");
    _ = @import("components/slider.zig");
    _ = @import("state.zig");
    _ = @import("update.zig");
}
