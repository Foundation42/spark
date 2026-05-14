//! Public Zig-module surface for embedding text_engine — a Vulkan-
//! compute-driven rich-text rendering library — in a host engine
//! (matryoshka HUD, the future terminal app, in-game UI, editors).
//! Build-side this is the `text_engine` module exposed by `build.zig`;
//! consumers `@import("text_engine")` and reach the styled-text
//! pipeline plus the SPIR-V shader blobs.
//!
//! Deliberately narrow. No window management, no swapchain, no Vulkan
//! instance ownership. The host owns its `VkDevice` and per-frame
//! command buffer; the cooperative attach surface records draw work
//! into them. Same policy as `valkyr_gpu` in tripvulkan — keeps link
//! config singular when one host embeds several cooperative libraries
//! (Vulkan, FreeType, HarfBuzz are linked by the host exe, not here).
//!
//! Surface is intentionally empty right now — Phase 0 is just the
//! build skeleton. Each phase grows this file by one or two
//! `pub const` lines.

// Re-exports will appear here as we land each phase. Roughly:
//
//   pub const gpu      = @import("gpu/mod.zig");      // Phase 1: device + swapchain
//   pub const font     = @import("font/mod.zig");     // Phase 2: FreeType + atlas
//   pub const shape    = @import("shape/mod.zig");    // Phase 3: HarfBuzz + layout
//   pub const draw     = @import("draw/mod.zig");     // Phase 3: per-glyph SSBO + pipeline
//   pub const span     = @import("span/mod.zig");     // Phase 4: styled spans
//   pub const fx       = @import("fx/mod.zig");       // Phase 6: MSDF + per-glyph attention
//
// Kept here as a roadmap comment, not yet wired, so future sessions
// can pick up without re-reading the project memory.

/// Compiled SPIR-V blobs. Anonymous module wired in by `build.zig`;
/// each field is an `align(4) []const u8`-shaped @embedFile of one
/// shader stage (e.g. `shaders.text_vert`, `shaders.text_frag`).
pub const shaders = @import("shaders");
