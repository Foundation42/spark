# text_engine — architecture

A Zig + Vulkan rich-text rendering library. The core does styled text →
GPU-ready glyph instances; everything terminal-shaped or LM-shaped
layers on top.

## Three-tier plan

```
┌───────────────────────────────────────────────────────────┐
│  tier 3  LM / semantic plugins                            │
│          read buffer, write attention through the SSBO    │
├───────────────────────────────────────────────────────────┤
│  tier 2  terminal emulator + ANSI parser + PTY            │
│          plus markdown layout engine (composable)         │
├───────────────────────────────────────────────────────────┤
│  tier 1  text_engine (this) — rendering library           │
│          spans → atlas → instanced draw                   │
└───────────────────────────────────────────────────────────┘
```

We're at tier 1, with the SSBO channels (`attention`, `hot_color`,
`fx_kind`) already wired so tier 3 can plug in without core changes.

## Source layout

```
src/
├── font/
│   ├── face.zig         FreeType: face, metrics, raster, FT_LOAD_COLOR
│   ├── shape.zig        HarfBuzz: shape UTF-8 → glyph stream
│   ├── registry.zig     FontRegistry — multi (file, px, lane) entries
│   └── sdf.zig          Single-channel SDF from a grayscale bitmap
├── text/
│   ├── layout.zig       Span/Line/Paragraph + 3-layer append API
│   └── glyph_cache.zig  (font_id, glyph_id) → atlas rect + kind
├── gpu/
│   ├── vk.zig           Context — instance/device/surface/queue
│   ├── atlas.zig        R8 or RGBA8, shelf packer, zero-cleared
│   ├── text_pipeline.zig  Pipeline + SSBO + descriptor set
│   ├── swapchain.zig    (demo)
│   └── renderer.zig     (demo) frame loop, frames-in-flight, present
├── window.zig           (demo) glfw wrapper
├── lib.zig              public surface marker
└── main.zig             demo entry
shaders/
├── text.vert            instanced quad, SSBO read
└── text.frag            three lanes: mono / colour / SDF
```

## Data flow

```
Paragraph
  ├─ Line
  │   ├─ Span { font_id, color, hot_color, attention }
  │   ├─ Span { ... }
  │   └─ ...
  └─ Line { ... }
```

1. `layoutParagraph` walks lines.
2. Per line: first pass scans `max(ascender)` over the fonts used →
   resolves baseline (lifted from Makepad's turtle row-finish).
3. Per span: HarfBuzz shapes UTF-8 → glyph stream with advances,
   offsets, cluster info.
4. Per glyph: `GlyphCache.getOrRasterize`. Miss path goes to FT
   (mono / BGRA bitmap) or `sdf.generate` (radius-8 brute force on
   a pre-padded mono bitmap). Packs into the appropriate atlas.
5. Layout emits a `GlyphInstance` into a caller-owned `ArrayList`,
   with pen-relative position computed from cached bearings + HB
   offsets, scaled by `FontRegistry.scale(font_id)` so emoji strikes
   shrink inline with body text.
6. `pipeline.writeGlyphs(slice)` memcpys into the host-coherent SSBO.
7. Frame loop: `recordDraw(cmd, extent, n_glyphs)` issues
   `vkCmdDraw(6, n, 0, 0)`. One submit per frame for the whole
   paragraph.

## Atlas lanes

| Lane    | Image format         | Stored data                          | Fragment math                                |
|---------|----------------------|--------------------------------------|----------------------------------------------|
| `mono`  | `R8_UNORM`           | hinted-grayscale coverage 0..1       | `coverage = sample.r`                        |
| `color` | `R8G8B8A8_UNORM`     | premultiplied RGBA (CBDT/sbix)       | `sample.rgba` direct                         |
| `sdf`   | `R8_UNORM` (shared)  | signed distance, 0.5 = boundary      | `smoothstep` around `threshold` with `aa`    |

Mono and SDF share the R8 atlas — the fragment shader's `tex_select`
branch decides whether to read R as coverage or distance. Avoids a
third sampler binding.

## GlyphInstance — SSBO entry (std430, 80 bytes)

```
offset  type    field          notes
   0    vec2    dst_pos        top-left pixel
   8    vec2    dst_size       pixel size
  16    vec2    uv_min         atlas UV (half-texel inset)
  24    vec2    uv_max
  32    vec4    color          base tint, premultiplied at output
  48    vec4    hot_color      attention=1 lerp target
  64    uint    tex_select     0=mono, 1=colour, 2=sdf
  68    float   attention      0..1 LM signal
  72    uint    fx_kind        reserved for effect-type dispatch
  76    uint    _pad           std430 stride to 80 bytes
```

Stride is `multiple of 16` because of the vec4 alignment.
`fx_kind` is reserved for Phase 7+ — discrete effects like
underline / size-pulse / shimmer dispatched per-glyph.

## Cooperative-embed shape

The library is built to be embedded in another Zig/Vulkan engine.
Same policy as `valkyr_gpu` in `~/dev/tripvulkan`: the library does
not own a window, instance, device, swapchain, or surface. The host
hands it a `VkDevice` + per-frame `VkCommandBuffer`; the library
records draw work into them. Vulkan / FreeType / HarfBuzz / glfw
are linked by the host exe, not by the library.

Currently this is conceptual — `lib.zig` documents the surface but
nothing reaches through it. When matryoshka becomes the second
consumer, the library/demo split becomes real and the cooperative-
attach API ships.

## Key design choices (and why)

- **Per-line baseline resolution** lifted from Makepad's `Turtle.finish_row`. Makes
  mixed-size content land cleanly without re-layout.
- **Colour deliberately out of the cache.** Tinting is per-Span, not
  per-glyph, so one cached glyph serves any number of tints. Matches
  Makepad's `LaidoutGlyph` design.
- **Colour-atlas glyphs ignore attention.** Emoji artwork should
  never be tinted by the LM signal — that's how `tex_select == 1`
  doesn't take the hue lerp.
- **`FontRegistry.scale`** decouples the FT actual size (the strike
  for CBDT, the requested size for scalable) from the display size.
  Lets emoji strikes inline with body text.
- **Premultiplied-alpha blend** in the pipeline — both mono and
  colour lanes emit premultiplied output so one `srcFactor = ONE`
  blend setting works for everything.
- **Pre-padding the SDF source bitmap** (Phase 6 fix). FT bitmaps
  are tight-bounded, putting every outside pixel within 1–4 px of
  the letter — without pre-padding, SDF values cluster in 0.3–0.5
  and any halo / glow band fires across the whole rect.

## Known limitations (parked)

| Issue                          | When it bites                       | Plan                                        |
|--------------------------------|-------------------------------------|---------------------------------------------|
| Resize bug                     | Drag the window edge                | Reposition glyphs in NDC space, or re-layout on resize |
| No atlas overflow recovery     | Long sessions with many glyphs      | LRU eviction or grow+recreate-descriptor    |
| No gamma correction            | Body text at ≤ 14 px                | sRGB encode in fragment shader              |
| No font fallback               | "Hello 🎉" in one span              | Split spans by font coverage at shape time  |
| Single-channel SDF (not MSDF)  | Sharp corners under extreme zoom    | Swap in `msdfgen` system dep if needed      |

## See also

- [`../README.md`](../README.md) — build instructions + phase status
- [`../chat.md`](../chat.md) — original brainstorm transcript
- [`journey.md`](journey.md) — session 1 narrative (how we got here)
- [`roadmap.md`](roadmap.md) — what's next
