# text_engine — roadmap

Where this goes next, in rough priority order.

## Next session — composable layout engines

Christian's flagged direction. Current `text/layout.zig` has one fixed
model: paragraph of lines of spans, with explicit line breaks and one
style per span. Fine for the demo, won't carry to the terminal app or
to a markdown viewer.

The idea: the text_engine stays focused on its current job —
**styled spans → glyph instances on screen**. Higher-level *layout
engines* are pluggable producers that consume their own input
syntax and emit a representation the text_engine can render. Two
concrete targets:

- **ANSI layout engine** — consumes UTF-8 + ANSI escape codes (SGR
  for colour/style, cursor movement, scrollback). Christian's
  existing `~/dev/ac/src/terminal.zig` (~1,900 LOC) is the starting
  point for the ANSI parser; the layout side is fresh. Eventually
  backs the terminal app at tier 2.
- **Markdown layout engine** — consumes markdown source, emits
  block elements (headers, paragraphs, code blocks, lists, tables)
  + inline styles (bold, italic, code, links).

The **composable** bit is the interesting part: an ANSI
sub-sequence inside a markdown code block (rendering coloured shell
output in a doc); a markdown document scrolling through the terminal's
scrollback; rich-text inputs to either engine flowing through the
other.

Open questions to think through before coding:

- **Immediate-mode vs retained.** Today's API is immediate — each
  `layoutParagraph` call produces a fresh `GlyphInstance` list.
  A retained `Document` type that tracks invalidation buys per-line
  re-shape cost amortisation but adds significant state. Probably
  retained is right for the terminal (scrollback survives frames)
  and immediate is right for HUD overlays. Maybe both.

- **Span stream vs typed AST.** Spans are flat; a markdown block
  tree has nesting (lists in quotes in headers). The cheap version
  is "flatten the tree into a stream of styled spans + break
  markers." The structured version is a typed AST that knows
  paragraph vs heading vs code block.

- **Composition surface.** What's the API contract between layout
  engines and the text_engine? Lowest common denominator is
  `Paragraph` (which we already have). Slightly richer is something
  like a `Block { kind: BlockKind, content: []const Span | []const Block }`
  recursive type. We probably want both — `Paragraph` for plain
  flows, `Block` for structured documents.

- **Where does word-wrap live?** Definitely not in the text_engine
  itself — that locks us to one wrap policy. But the layout engines
  need access to glyph advances to make wrap decisions, and those
  come from shape. Probably: each layout engine owns its wrap, and
  the text_engine exposes the metrics it needs.

## Parked rendering issues

Saved in [`memory/project_known_issues.md`](../../../.claude/projects/-home-chrisbe-dev-terminal/memory/project_known_issues.md). Pick up when relevant:

- **Resize bug** — glyphs don't reposition when the window resizes.
  Probably wants a re-layout-on-resize pass; the per-frame cost is
  cheap enough (~6k fps Debug suggests budget headroom).
- **Atlas overflow** — `error.AtlasFull` after enough unique glyphs.
  Needs LRU eviction or grow-and-recreate-descriptor.
- **Gamma correction** — fine at 22 px, will matter at 14 px. Apply
  sRGB encode in the fragment shader before the `srcFactor=ONE`
  blend.
- **Font fallback** — `"Hello 🎉"` in one span loses the emoji
  because DejaVu's glyph for U+1F389 is `.notdef`. Need to split
  spans by font coverage at shape time, possibly via fontconfig
  for the fallback chain.
- **Single-channel SDF** — corners are slightly soft under extreme
  zoom. True MSDF via msdfgen is a swap-in if needed; not urgent.

## Richer LM-driven effects

`fx_kind` is reserved in `GlyphInstance` for routing different
effect types per-glyph. Currently `0 = pass-through`. Natural
additions:

- `fx_kind == 1` **underline** driven by attention (clean visual
  indicator, no layout impact).
- `fx_kind == 2` **size pulse** — attention scales `dst_size`,
  layout re-runs per frame. The "alive" version of the current
  weight wave.
- `fx_kind == 3+` **per-character PBR materials** — long-term —
  each glyph as a 3D-ish quad with material properties, attention
  drives roughness / metallic / emission. Fits naturally when this
  gets ported into matryoshka's renderer.

## Library / demo boundary

Today the split is **conceptual** — `lib.zig` documents the surface
but nothing reaches through it. Real separation happens when
matryoshka starts consuming `text_engine` via the cooperative-attach
API. That session forces real decisions about what crosses the
module boundary.

## Document model

After layout engines are in: a `Document` type that tracks
invalidation, viewports, scroll offsets. Foundation for the
terminal app at tier 2 and for a markdown reader as a separate
app.

## LM connection

Tier 3, last. Once the rendering channels (`attention`,
`hot_color`, `fx_kind`) are stable, plug in real LM signals:

- valkyr or another model produces per-token importance / sentiment
  / entity type
- A semantic plugin maps that to per-glyph `attention` + `hot_color`
  + `fx_kind`
- Text "lives" — important tokens visibly weighted, anomalies
  flagged, semantic regions colour-coded

This is the closing of the loop from `chat.md`'s original vision.
By the time we get here the rendering is a solved problem; the
work is in the semantic mapping.
