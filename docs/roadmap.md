# text_engine — roadmap

Where this goes next. Session 2 closed with the element contract +
markdown rendering live; agreed direction is **session 3 = quad/line
primitives → ANSI engine → retained mode**.

## Next session — quad/line draw primitives

The contract grew `DrawList` to be extensible from day one (see
[`architecture.md`](architecture.md)). Time to fill it. The visible
improvements waiting on this:

- **Code-block backgrounds** — markdown's ` ```zig ``` ` fences want
  a subtle background panel. Quad primitive with a rounded corner
  radius parameter.
- **Blockquote left bars** — the conventional "vertical accent bar
  at the indent" that distinguishes quotes from "just an indented
  paragraph." Thin tall quad.
- **Thematic break** — currently a 12px spacer; should render as a
  horizontal rule across the available width. Thin wide quad.
- **Link underlines** — markdown links pick up the `link_color` and
  the `link` semantic flag rides along on Style. Add a line
  primitive driven by `fx_kind = 1` so the renderer can decide
  per-glyph whether to emit an underline.
- **Selection / highlight rectangles** — eventually, but the same
  quad primitive covers it.

Engineering shape:

- New pipeline (`quad_pipeline.zig`) with its own SPIR-V pair
  (`quad.vert` + `quad.frag`). Instanced rect with optional rounded
  corners + colour.
- `gpu/atlas.zig` mostly untouched — quads don't atlas. (Eventually
  they might for textured panels / images, but not now.)
- `DrawList.quads` field becomes live. Walker handlers for
  `quote` and `code_block` grow background/bar emit lines. `link`
  cascade flag drives a line-primitive emit during inline emit.
- New ssbo binding for quad instances; or push-constant if the
  count is small. Probably ssbo for symmetry with glyphs.

Open question: one pipeline per primitive kind (glyph, quad, line)
or one mega-pipeline that branches on a `prim_kind` field? Lean
toward separate pipelines — each is simple, and the cmd buffer
records them in known order anyway.

## Then — ANSI layout engine

Christian's tier-2 target from session 1. Now that markdown is the
proven first consumer of the contract, ANSI is the next producer.

What it does: consume a stream of UTF-8 + ANSI escape codes (SGR for
colour/style, cursor movement, scrollback), produce Element trees.

Two API shapes possible:

1. **Batch parser**: takes a string of terminal output, produces a
   `code_block { content: sub_block: *Element }` tree that markdown's
   ` ```ansi ``` ` fence can host directly. This is the composability
   bit — markdown fences with `ansi` language route through the ANSI
   engine and stash the result in `CodeContent.sub_block`.
2. **Streaming terminal**: maintains a cell-grid model, applies
   escape codes incrementally, exposes the grid as Elements for
   rendering. This is the terminal-app shape.

Both are worth building. (1) is the simpler starting point and
directly closes the markdown↔ANSI composition loop. (2) is what the
eventual terminal app needs.

Existing prior art: `~/dev/ac/src/terminal.zig` has the ANSI parser
state machine (1,900 LOC); the layout engine is fresh.

## Then — Retained mode + document model

Currently every frame re-walks the entire Element tree. Fine for a
small demo, wasteful for a terminal scrollback or a long markdown
document. Need:

- **`Document` type** owning a retained Element tree, with
  invalidation regions when content changes.
- **Per-line cached glyph emission** — the wrap pass shapes atoms
  every frame; for content that hasn't changed, the shaped + placed
  glyphs should be cached.
- **Viewport-aware emit** — only re-shape lines visible in the
  scroll viewport. Critical for ANSI scrollback (millions of lines
  potentially).
- **Scroll offset** as a separate property, not a re-layout trigger.

This is the foundation for the actual terminal app and a markdown
reader app. Out of scope for the library itself until consumers
demand it.

## Eventually — richer LM effects

`fx_kind` is reserved in `GlyphInstance` for per-glyph effect
dispatch. The inline cascade flags on `Style` (emphasis, strong,
code_inline, link) are semantic markers waiting for visual fx hooks.
Natural additions:

- `fx_kind = 1` **underline** driven by attention OR by `link` flag.
- `fx_kind = 2` **size pulse** — attention scales `dst_size`,
  layout re-runs per frame. The "alive" version of the current
  SDF weight wave.
- `fx_kind = 3+` **per-character PBR materials** — long-term — each
  glyph as a 3D-ish quad with material properties. Slots in
  naturally when text_engine ports into matryoshka's renderer.

## Eventually — LM connection (tier 3)

Once the rendering channels (`attention`, `hot_color`, `fx_kind`)
are stable, plug in real LM signals:

- valkyr or another model produces per-token importance / sentiment
  / entity type
- A semantic plugin maps that to per-glyph `attention` + `hot_color`
  + `fx_kind`
- Text "lives" — important tokens visibly weighted, anomalies
  flagged, semantic regions colour-coded

This is the closing of the loop from `chat.md`'s original vision.
By the time we get here the rendering is a solved problem; the work
is in the semantic mapping.

## Library / demo boundary

Today the split is **conceptual** — `lib.zig` documents the surface
but nothing reaches through it. Real separation happens when
matryoshka starts consuming `text_engine` via the cooperative-attach
API. That session forces real decisions about what crosses the
module boundary.

## Parked rendering issues

Captured in [`memory/project_known_issues.md`](../../../.claude/projects/-home-chrisbe-dev-terminal/memory/project_known_issues.md). Surface when relevant:

- **Resize bug** — glyphs don't reposition when the window resizes.
- **Atlas overflow** — `error.AtlasFull` after enough unique glyphs.
- **Gamma correction** — fine at 20 px, matters at 14 px.
- **Font fallback** — `"Hello 🎉"` in one text run loses the emoji
  because DejaVu's glyph for U+1F389 is `.notdef`. Stage 3b
  workaround: emoji absent from `demo.md`.
- **Single-channel SDF** — corners slightly soft under extreme zoom.

## Parked layout issues

- **Break-anywhere wrap** — a single word wider than `max_w` overflows
  rather than breaking mid-word. Character-level break fallback when
  no whitespace is available.
- **Tab + Unicode whitespace** — tokenizer splits on ASCII space only.
- **Bidirectional text** — HB shapes each run correctly, but line
  composition assumes LTR. Bidi reordering across runs deferred.
- **Body-relative cascade** — emphasis inside a heading swaps to body
  italic font. Per-block font families fix it.

## Parked test polish

cmark ships ~600 CommonMark spec test cases. Worth hooking into our
mapper to catch edge cases we don't think about (link reference
definitions, list tightness, hard vs soft break boundaries, etc.).
Not urgent — the torture demo + parsed `demo.md` catch the obvious
bugs, and the spec compliance level is what cmark gives us anyway.
