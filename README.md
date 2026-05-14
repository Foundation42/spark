# text_engine

Rich-text rendering for Zig + Vulkan host engines. Built to power
matryoshka HUD/in-game UI first, with a scriptable LM-aware terminal
layered on top later.

## Three-tier plan

1. **text_engine (this repo)** — styled-text rendering library.
   Font management, HarfBuzz shaping, glyph atlas (hinted grayscale for
   body text, MSDF for any glyph that scales or animates), layout
   (incl. BiDi + grapheme clusters), styled spans, hit-testing, inline
   objects, per-glyph animatable attributes for downstream effects.
2. **Terminal emulator** — PTY + ANSI parser + scrollback, consuming
   this library. The ANSI parser in `~/dev/ac/src/terminal.zig` is the
   starting point.
3. **LM / semantic plugins** — read the buffer, write per-token
   attention / sentiment / entity metadata back through the
   library's per-glyph attribute channel. Drives heatmap colouring,
   semantic folding, predictive completion. Last, not first.

Library-first because matryoshka and other engines need rich text
*now*; proving the API against a non-terminal surface first prevents
shape-locking around grids.

## Cooperative-embed surface

Same policy as `valkyr_gpu` in `~/dev/tripvulkan`: the library does
not own a Vulkan instance, device, surface, or swapchain. The host
hands the library its `VkDevice` + per-frame `VkCommandBuffer` and
the library records draw work into them. Vulkan, FreeType, HarfBuzz,
glfw are linked by the host exe, not by the library module.

The standalone `text_engine_demo` exe in `src/main.zig` is a dogfood
surface — owns its own window and exercises the library through the
same module a host engine would.

## Build

```sh
zig build         # produces zig-out/bin/text_engine_demo
zig build run     # build + run the demo
```

Requires Zig ≥ 0.14.1, `glslc`, and system FreeType / HarfBuzz / glfw /
Vulkan (loader + headers).

## Phase status

- [x] **Phase 0** — build skeleton, shader compile + embed pipeline,
  narrow public module surface.
- [x] **Phase 1a** — glfw window + Vulkan 1.3 instance/device/swapchain,
  validation layer in Debug, debug-utils messenger. Validation clean.
- [x] **Phase 1b** — clear-color frame loop via dynamic rendering +
  synchronization2 barriers, frames-in-flight, swapchain recreate on
  OUT_OF_DATE / SUBOPTIMAL. ~7600 fps uncapped at 1280×720.
- [ ] **Phase 2** — FreeType-rasterised first glyph, textured quad.
- [ ] **Phase 3** — HarfBuzz shaping, per-glyph SSBO, instanced draw,
  crisp body text. v1 "rich text on screen" milestone.
- [ ] **Phase 4** — styled spans, multiple sizes/weights.
- [ ] **Phase 5** — emoji (COLRv1 + sbix fallback).
- [ ] **Phase 6** — MSDF lane + per-glyph attention attribute hooked
  to the fragment threshold.
