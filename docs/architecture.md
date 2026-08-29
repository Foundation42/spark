# spark — architecture

A Zig + Vulkan rich-text rendering library with an in-tree CommonMark
parser. Designed library-first as the foundation for matryoshka HUD,
a future terminal app, and (long-term) Dear ImGui-shaped game UI —
all flowing through one Element contract.

## Three-tier plan

```
┌───────────────────────────────────────────────────────────────────┐
│  tier 3  LM / semantic plugins                                    │
│          read buffer, write attention through the SSBO            │
├───────────────────────────────────────────────────────────────────┤
│  tier 2  layout engines: markdown ✅, ANSI terminal (next),       │
│          syntax highlighter, valkyr token streams, ImGui widgets  │
├───────────────────────────────────────────────────────────────────┤
│  tier 1  spark — Element contract + walker + rendering      │
│          Element tree → atlas-aware shaped glyphs → SSBO          │
└───────────────────────────────────────────────────────────────────┘
```

Tier 1 is complete. Markdown is the first concrete tier-2 consumer,
proving the contract. ANSI engine lands next; ImGui shape is the
long-term destination Christian flagged in session 2.

## The Element contract

Every producer hands the engine an `Element` tree. The walker
consumes that, ignorant of where it came from. Same shape for
markdown, ANSI, hand-crafted UI trees, and future widgets.

```
Element = union(enum) {
    // inline leaves
    text { content, style }
    line_break

    // inline structural containers (render-time transparent —
    // cascade resolution lives in the producer, not the walker)
    emphasis | strong | code  : []const Element
    link { target, content }

    // block kinds
    paragraph                 : []const Element
    heading { level, content }
    container { layout, children, gap }
    spacer { height }
    list { ordered, items, start }
    list_item { children }
    quote { children }
    code_block { content: CodeContent }

    // open escape hatch — future widgets, custom game UI elements
    custom { vtable, ctx }
};

CodeContent = union(enum) {
    raw       : { text, style }           // plain preformatted text
    sub_block : *const Element            // composability hook —
                                          // ANSI inside ```ansi
                                          // fence, etc.
};
```

Closed union for dispatch speed + pattern-match clarity, plus
`custom` as the open extension point. Inline structural kinds
(`emphasis`/`strong`/`code`/`link`) are render-time transparent —
the walker recurses through them but doesn't transform anything;
the visual cascade lives in the descendant `text` leaves' `Style`,
written there by the producer at construction time via `theme.apply*`.

## Source layout

```
src/
├── element.zig             Element union, Style, Theme, Constraints,
│                           Box, DrawList, LayoutCtx, ContainerLayout,
│                           CodeContent, ElementVTable
├── element_layout.zig      The walker: layoutAndRender + per-kind
│                           handlers; inline-flow tokenizer + wrap
├── markdown.zig            cmark AST → Element tree (vendored cmark)
├── demo.md                 What the demo renders
├── font/
│   ├── face.zig            FreeType: face, metrics, raster
│   ├── shape.zig           HarfBuzz: shape UTF-8 → glyph stream
│   ├── registry.zig        FontRegistry — multi (file, px, lane)
│   └── sdf.zig             Single-channel SDF from a mono bitmap
├── text/
│   ├── layout.zig          appendShapedRun + Span/Line/Paragraph
│   │                       (legacy entry points; walker delegates
│   │                       to appendShapedRun for per-glyph emit)
│   └── glyph_cache.zig     (font_id, glyph_id) → atlas rect + kind
├── gpu/
│   ├── vk.zig              Context — instance/device/surface/queue
│   ├── atlas.zig           R8 or RGBA8 atlas, shelf packer
│   ├── text_pipeline.zig   Pipeline + SSBO + descriptor set
│   ├── swapchain.zig       (demo)
│   └── renderer.zig        (demo) frame loop, frames-in-flight
├── window.zig              (demo) glfw wrapper
├── lib.zig                 public surface marker
└── main.zig                demo entry
shaders/
├── text.vert               instanced quad, SSBO read
└── text.frag               three lanes: mono / colour / SDF
vendor/
└── cmark/                  CommonMark reference parser, vendored
                            from 0.31.2 (BSD-2). Built as a static
                            archive via build.zig.
```

## Theme

Visual policy bundled in one struct, separable from the contract.
Two roles:

* **Walker reads** layout constants (indents, gaps) and a few block
  defaults (`list_marker`).
* **Producer reads** baseline styles (`body`, `heading[6]`,
  `code_block`) and cascade helpers — `applyEmphasis`, `applyStrong`,
  `applyCodeInline`, `applyLink` — when constructing tree leaves.

```
Theme = {
    body                : Style
    heading[6]          : Style          // h1..h6
    code_block          : Style
    list_marker         : Style

    emphasis_font_id    : FontId         // italic variant
    strong_font_id      : FontId         // bold variant
    bold_italic_font_id : FontId         // for emph-inside-strong
    code_inline_font_id : FontId

    code_inline_color   : [4]f32
    link_color          : [4]f32

    list_marker_indent  : f32 = 8
    list_content_indent : f32 = 32
    list_item_gap       : f32 = 2
    quote_indent        : f32 = 20
    block_child_gap     : f32 = 4

    applyEmphasis(s) → Style
    applyStrong(s)   → Style
    applyCodeInline(s) → Style
    applyLink(s)     → Style
};
```

The cascade flags ride along on `Style` (`emphasis`, `strong`,
`code_inline`, `link` booleans) for future fx_kind effects that need
to distinguish inline run types.

**Body-relative cascade caveat:** applying emphasis to a heading
style swaps to the body italic font. The fix is per-block font
families — future stage when nested emphasis inside headings becomes
a visible concern.

## Data flow

```
markdown source                   hand-built Elements
       │                                    │
       ▼                                    │
   cmark.parse_document  ──┐                │
       │                   │                │
       ▼                   │                │
   markdown.parse  ◄───────┴ (Theme.apply*  │
       │                     resolved here) │
       └──────────► Element tree ◄──────────┘
                          │
                          ▼
              element_layout.layoutAndRender
                          │
                          ▼
                      DrawList
                          │
                          ▼
              text_pipeline.writeGlyphs
                          │
                          ▼
                  vkCmdDraw(6, n, 0, 0)
```

The walker doesn't know how the Element tree got there. Markdown is
one producer. ANSI parser (next session's tier 2) will be another.
Future ImGui-shaped widget code will be a third.

## Layout & wrap

Element walker is single-pass: `layoutAndRender(elem, origin,
constraints, ctx, out) → Box`. Each block element places itself at
`origin`, recurses for children, and returns the `Box` it occupied.

Indented containers (`quote`, `list`) shrink `constraints.max_w` for
their children, so wrap decisions inside a nested quote happen on
the narrower available width — not the full document width.

Inline-flow wrap pass:

1. **Tokenize** children into Word / Gap / LineBreak atoms. ASCII-
   space splits; UTF-8 word content. Tabs / NBSP / Unicode whitespace
   classes deferred until content needs them.
2. **Shape** each atom via HarfBuzz, cache width + ascender +
   line_height. Arena-allocated for the layoutInlineFlow call.
3. **Greedy line build**: wrap before a word when `pen_x + width >
   max_w` and the line has content. Strip trailing gaps at wrap
   points; drop leading gaps on new lines.
4. **Per-line emit**: `max(ascender)` baseline resolve across atoms
   on the line, then `appendShapedRun` for each.

Single oversized word still overflows — break-anywhere fallback is
future work. LTR-only line composition.

Per-line baseline resolution is the Makepad-turtle pattern lifted in
session 1. Mixed-size content shares a baseline cleanly.

`code_block` *bypasses* the inline-flow tokenizer — preformatted
text needs leading whitespace preserved and wrap disabled, both
inverted from prose. Each physical line is shaped as one HB run and
emitted directly.

## Atlas lanes

| Lane    | Image format         | Stored data                          | Fragment math                                |
|---------|----------------------|--------------------------------------|----------------------------------------------|
| `mono`  | `R8_UNORM`           | hinted-grayscale coverage 0..1       | `coverage = sample.r`                        |
| `color` | `R8G8B8A8_UNORM`     | premultiplied RGBA (CBDT/sbix)       | `sample.rgba` direct                         |
| `sdf`   | `R8_UNORM` (shared)  | signed distance, 0.5 = boundary      | `smoothstep` around `threshold` with `aa`    |

Mono and SDF share the R8 atlas — the fragment `tex_select` branch
decides whether to read R as coverage or distance.

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

`fx_kind` is reserved for effects like underline, size-pulse,
per-character PBR materials. Inline cascade flags on `Style` will
drive `fx_kind` choices when those land.

## DrawList — growth path

Currently glyph-only. Slots reserved for primitive kinds that arrive
with widget chrome:

```
DrawList = {
    glyphs:  ArrayList(GlyphInstance)     // stage 1+ — live
    quads:   ArrayList(QuadInstance)      // stage 4 — code-block
                                          // backgrounds, quote bars,
                                          // widget chrome
    lines:   ArrayList(LineInstance)      // link underlines,
                                          // thematic breaks
    images:  ArrayList(ImageInstance)     // markdown images,
                                          // widget icons
};
```

Element implementations grow into new fields as their visual needs
mature — no contract changes needed when a new primitive lands.

## Cooperative-embed shape

The library is built to be embedded in another Zig + Vulkan engine
(matryoshka HUD next). Same policy as `valkyr_gpu` in
`~/dev/tripvulkan`: the library does not own a window, instance,
device, swapchain, or surface. The host hands it a `VkDevice` +
per-frame `VkCommandBuffer`; the library records draw work into
them. Vulkan / FreeType / HarfBuzz / glfw / cmark are linked by the
host exe (with the cmark static archive bundled in the host's
build), not by the library.

Currently this is conceptual — `lib.zig` documents the surface but
nothing reaches through it. When matryoshka becomes the second
consumer, the library/demo split becomes real and the cooperative-
attach API ships.

## Markdown parser

`src/markdown.zig` wraps cmark via Zig's `@cImport`. Public entry:

```
pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const Theme,
) !Element
```

Strategy: recursive walk of cmark's AST with a `cascade: Style`
parameter threaded through descent. Each node maps to one Element
variant (or zero — IMAGE flattens alt text into surrounding flow).
Every TEXT leaf emits with the cascade-resolved Style baked in;
inline structural kinds (`emphasis`/`strong`/`code`/`link`) are
emitted purely for semantic preservation.

All slices + strings duped into the caller-supplied arena. cmark AST
is freed before `parse()` returns — the Element tree references no
cmark-owned memory.

Soft breaks become single-space text (CommonMark convention);
linebreaks become `line_break`. Thematic breaks emit a 12px spacer
until line primitives ship. HTML blocks / inline HTML render as
preformatted code so the source is visible rather than silently
dropped.

## Key design choices

- **Per-line baseline resolution** lifted from Makepad's
  `Turtle.finish_row`. Makes mixed-size content land cleanly.
- **Producer-side cascade**, not walker-side. Tree leaves carry
  pre-resolved styles; walker stays dumb. Re-theming = re-parse,
  which is cheap.
- **Colour is per-Span (now per-text-leaf), not per-glyph.** One
  cached glyph serves any number of tints.
- **Colour-atlas glyphs ignore attention.** Emoji artwork should
  never be tinted by the LM signal.
- **Premultiplied-alpha blend.** Both lanes emit premultiplied
  output so one `srcFactor = ONE` blend setting works for everything.
- **Pre-padding the SDF source bitmap.** FT bitmaps are tight-bound;
  unpadded SDFs produce glow bands across the whole rect. Pre-pad
  by SDF_PAD=6 before generating.
- **Vendor cmark, don't link system.** Reproducible builds, no
  version drift, swap to roll-our-own later without changing the
  API surface.
- **Single oversized words overflow** rather than break anywhere —
  break-anywhere fallback when content forces it.
- **Code blocks bypass inline-flow.** Preformatted text needs
  whitespace preservation + no wrap, both inverted from prose.

## Known limitations (parked)

| Issue                          | When it bites                       | Plan                                        |
|--------------------------------|-------------------------------------|---------------------------------------------|
| Resize bug                     | Drag the window edge                | Re-layout on resize                         |
| No atlas overflow recovery     | Long sessions with many glyphs      | LRU eviction or grow + recreate descriptor  |
| No gamma correction            | Body text at ≤ 14 px                | sRGB encode in fragment shader              |
| No font fallback               | "Hello 🎉" in one text run          | Split runs by font coverage at shape time   |
| Single-channel SDF             | Sharp corners under extreme zoom    | Swap in msdfgen if needed                   |
| No break-anywhere wrap         | A single word wider than max_w      | Char-level fallback when whitespace absent  |
| Body-relative cascade          | Emphasis inside heading             | Per-block font family abstraction           |
| Tab + Unicode whitespace       | Tab-indented prose, NBSP, etc.      | Extend whitespace tokenizer                 |
| No bidi                        | RTL text                            | HB shapes correctly; line composition needs work |
| No thematic break visual       | `---` in markdown                   | When quad/line primitives land              |
| No code block background       | Markdown code blocks                | When quad primitive lands                   |
| No link underline / hover      | Markdown links                      | When fx_kind dispatch + input handling land |

## See also

- [`../README.md`](../README.md) — build instructions + stage status
- [`../chat.md`](../chat.md) — original brainstorm transcript
- [`journey-session-1.md`](journey-session-1.md) — session 1 narrative
- [`journey-session-2.md`](journey-session-2.md) — session 2 narrative
- [`roadmap.md`](roadmap.md) — what's next
