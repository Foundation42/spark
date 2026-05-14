# text_engine — session 2 journey
2026-05-14 (Thursday, same day as session 1)

How a single-shape text renderer became a markdown-rendering UI engine
foundation in one stretch. Session 1 built the rendering plumbing —
atlases, shaping, SDF, attention. Session 2 turned that into a real
contract that anything — markdown today, ANSI tomorrow, ImGui-style
widgets later — can flow through.

## Where we started

End of session 1: `Paragraph { Line { Span } }` was the only input
shape the engine accepted. Worked for the demo we had — heading +
mixed-size body + emoji + rainbow SDF — but obviously not the right
contract for markdown documents (nested blocks) or terminals (cell
grids) or ImGui widgets (anything that has children).

Christian's framing when picking session 2 back up: *"Next session I'd
like to dig into pluggable/composable layout engines. So I'm thinking
we have the ANSI terminal thing, but I'd also like us to do a markdown
layout engine, ideally the two should compose."*

And then, partway through the contract design, the framing widened:

> *"This is going to be our text and UI solution for a long time to
> come. Markdown and Terminals today, full Dear ImGui and game ready
> interfaces tomorrow. Happy to take it in stages, but that's the
> vision."*

That changed the weight class of the contract. We weren't designing
a markdown-block format — we were designing the **element contract**
that markdown blocks happen to be the first concrete implementer of.

## The forcing-gate principle

The whole approach for session 2 crystallised in one of Christian's
notes:

> *"Markdown provides us a forcing gate for handoff to other layouts
> and renderers, so it should guide the shape that we can use for
> nested elements."*

That is — design the contract for what markdown forces it to handle
(nested block kinds, recursive inline structure, multiple producers
of the same shape). If the contract survives markdown, it survives
ANSI, syntax highlighters, valkyr token streams, and game UI later.

So the order locked in: **contract first, then markdown, then ANSI**.
And: **don't optimise the contract for the case we already render —
generalise it so paragraph becomes one Element kind among many**.

## Stage 1 — element contract

`Element` as a tagged union: closed set of named block + inline kinds
for fast dispatch, plus a `custom { vtable, ctx }` escape hatch so
future widget kinds slot in without breaking the union. Stage 1
shipped just the minimum: `text`, `line_break`, `paragraph`,
`heading`, `container.stack_v`, `custom`.

`LayoutCtx` collects the engine's read-only handles (font registry,
glyph cache, atlases). `DrawList` is the output collector — glyph-only
this stage, designed to grow `quads` / `lines` / `images` fields when
widget chrome arrives. `Constraints` flows down, `Box` flows up — the
standard two-way layout-pass shape, even though stage 1 ran single-
pass.

The walker — `layoutAndRender(elem, origin, constraints, ctx, out) →
Box` — dispatched on the union, recursed into containers, and
delegated per-line work to `appendShapedRun` (still in
`text/layout.zig` from session 1) so the existing emit path stayed
load-bearing.

The validation move: re-render session 1's demo content through the
new contract. Same visual output, 117 glyphs vs 114 (subtitle text
changed), ~15k fps Release. Contract works.

## Stage 2a — block nesting

The markdown block vocabulary minus thematic_break (which needs the
quad/line pipeline we haven't built yet):

- `list { ordered, items, start }`
- `list_item { children }` — CommonMark allows multiple blocks per
  item, so this is a flat block list.
- `quote { children }` — left-bar visual deferred until line
  primitives arrive; indent alone distinguishes it for now.
- `code_block { content: CodeContent }` — preformatted text with a
  reserved `.sub_block` variant for composability (ANSI engine will
  hand us a sub-tree).
- `spacer { height }` — explicit vertical space, cleaner than the
  empty-paragraph hack.

`layoutQuote` indents children by `QUOTE_INDENT=20` and shrinks
`Constraints.max_w` correspondingly. `layoutList` renders a marker
(• for unordered, "N." for ordered) at `LIST_MARKER_INDENT=8` and
recurses item content at `LIST_CONTENT_INDENT=32`. Marker baseline
alignment with the first line of item content is *implicit*: both
lay out from the same y, and per-line baseline resolution lands them
on the same baseline when metrics match. `layoutCodeBlock` splits raw
text on `\n` and lays each line out at the supplied style.

The torture-test demo content exercised list-with-nested-ordered-list
inside a stack containing a quote and a code block. All rendered first
try. Bullet markers landed on the body baseline correctly. Bug-free
landing was a vote of confidence in the contract.

## Stage 2b — word wrap

The point where the contract earned its keep. `quote` shrinks `max_w`
through `Constraints`; without wrap, a long quoted paragraph would
run off the right edge. With wrap, the contract's "shrink max_w as
you indent" pattern actually pays off.

Rewrote `layoutInlineFlow` as a four-pass:

1. **Tokenize** children into a flat list of `Word` / `Gap` / `LineBreak`
   atoms. Whitespace splitting on ASCII space — CommonMark prose is
   dominated by space anyway; tab + NBSP + Unicode whitespace classes
   land when content needs them.
2. **Shape** each atom once via HarfBuzz into an arena that frees on
   return from layoutInlineFlow. Each atom carries its shaped run,
   cached width, ascender, line_height.
3. **Greedy line build**: wrap before a word when `pen_x + width > max_w`
   and the line already has content. Strip trailing gaps from the
   wrapped line (no hanging space at the right). Drop leading gaps at
   the new line's start.
4. **Per-line emit**: max(ascender) baseline resolve, then stream each
   atom's shaped glyphs through `appendShapedRun`.

Single oversized word still overflows — break-anywhere fallback will
land when content forces it. LTR-only line composition (HB shapes
each run correctly but bidi reordering across runs is deferred).

### The code-block indent regression

First run of the wrap pass produced unexpected output: the code
block's second line had lost its 4-space indent. Cause: `layoutCodeBlock`
routed each physical line through `layoutInlineFlow` (as a one-text-
run paragraph), so the wrap pass's "drop leading whitespace on a new
line" rule — correct for prose — kicked in on every code line that
started with whitespace.

Fix: `layoutCodeBlock` no longer goes through `layoutInlineFlow`. It
shapes each physical line as one HB run and emits directly via
`appendShapedRun`. Preformatted means no wrap and significant
whitespace, both inverted from prose.

Reminder of why the torture demo earns its keep: this bug would have
shown up immediately when CommonMark code blocks first rendered. We
caught it before the parser even existed.

## Stage 2c — Theme + inline structural kinds

The conversation about "this is going to be UI tomorrow too" changed
the contract weight class. The visual policy needed to be lifted out
of the walker into a thing parsers and hand-builders could consult,
because **a parser produces semantic structure; visual policy maps
that to fonts and colors**.

### Design choice: where does the cascade resolve?

Two paths considered:

- **Walker-side cascade**: walker maintains a Style stack, applies
  emphasis/strong/code modifiers as it descends, writes the resolved
  style onto text leaves at emit. Tree stays lean (no per-leaf
  style); re-themeing is a swap-and-rewalk.
- **Producer-side cascade**: parser/builder threads the cascade
  through tree construction, writes resolved Style onto every text
  leaf. Walker treats inline structural kinds as render-time
  transparent. Re-theming requires re-construction.

Picked **producer-side**. Reason: hand-built trees (the torture demos)
want direct control over text styles. Parser-built trees can pre-bake
the cascade trivially. And it keeps the walker dumb — render what's
in the tree, no style logic. Walker still descends through emphasis/
strong/code/link containers but doesn't transform anything; the
already-resolved leaves do the visual work.

Cost: re-theming requires re-parsing. Cheap, given parsers run in
microseconds against the document model we're building.

### Theme shape

`Theme` lives in `LayoutCtx` and bundles:

- **Named styles**: `body`, `heading[6]`, `code_block`, `list_marker`.
- **Cascade font IDs**: `emphasis_font_id`, `strong_font_id`,
  `bold_italic_font_id`, `code_inline_font_id`.
- **Cascade colors**: `code_inline_color`, `link_color`.
- **Layout constants**: list/quote indents, item gaps, block child
  gap. These moved out of file-level walker consts so the walker
  reads `ctx.theme.*` everywhere.
- **Cascade helpers**: `applyEmphasis`, `applyStrong`,
  `applyCodeInline`, `applyLink`. Each returns a modified Style with
  a semantic flag set and `font_id` recomputed via
  `resolveInlineFontId(s)`, which inspects active flags to pick
  regular / italic / bold / bold-italic.

Style grew four flags (emphasis, strong, code_inline, link) as
*semantic markers* — `font_id` + `color` still drive shape math, but
the flags let cascade helpers compose correctly (emphasis-inside-strong
→ bold-italic) and let future fx_kind effects distinguish runs
without re-parsing styles.

### Inline structural kinds

Added four new Element variants:

- `emphasis: []const Element`
- `strong: []const Element`
- `code: []const Element` (inline code)
- `link { target: []const u8, content: []const Element }`

All render-time transparent — the walker recurses through them
without changing anything. They exist so the semantic structure
survives in the tree for future hit-testing, theming refreshes, and
visual effects (link hover, code-span backgrounds).

### Body-relative cascade caveat

Applying `theme.applyEmphasis(theme.heading[1])` swaps to the body
italic font, not a heading-italic font. The cascade is body-relative.
Real fix needs a "font family" abstraction where each block style
declares which italic / bold / bold-italic to use. Stage-2c caveat;
parser in stage 3 can pick its battles, and almost nobody nests
emphasis inside markdown headings anyway.

### Demo update

Added an "Inline cascade" demo paragraph using emphasis + strong +
bold-italic + inline-code + link, all derived from `theme.body` via
`theme.apply*`. Visual confirmation that the cascade composes
correctly — bold-italic inside a strong-then-emphasis combination
rendered with the proper bold-italic font.

## Stage 3a — vendor cmark

The choice was roll-our-own vs use cmark. Christian's call: *"Let's
use cmark and focus on the mapper. We can always roll our own later
— vendor it in."*

Vendored cmark 0.31.2 (latest stable, MIT/BSD) under `vendor/cmark/`.
Pulled the whole `src/` minus `main.c` (the CLI). Hand-authored the
two CMake-generated headers:

- `cmark_export.h` — the export-visibility shim. For static linking,
  collapses to no-op macros via `CMARK_STATIC_DEFINE`.
- `cmark_version.h` — straight `#define CMARK_VERSION` and string.
  Bump in lockstep when we update the vendored tarball.

`build.zig` grew a static-library target compiling 19 cmark .c sources
with `-std=c99 -DCMARK_STATIC_DEFINE` plus warning suppressions for
upstream noise. Demo exe links the archive and adds `-Ivendor/cmark/`.

Smoke test in main.zig: `@cImport(cmark.h)`, parse a tiny markdown
fixture, walk top-level blocks. Got back "3 top-level blocks" for a
heading + paragraph + list — FFI works.

## Stage 3b — markdown → Element mapper

`src/markdown.zig` — recursive walk of cmark's AST emitting Element
variants. The shape is straightforward because the contract was
already designed for it:

| cmark node | Element |
|---|---|
| `DOCUMENT` | `container.stack_v` |
| `PARAGRAPH` | `paragraph` |
| `HEADING` | `heading { level, content }` (cascade swaps to `theme.heading[level-1]`) |
| `BLOCK_QUOTE` | `quote` |
| `LIST` | `list { ordered, items, start }` |
| `ITEM` | `list_item` |
| `CODE_BLOCK` / `HTML_BLOCK` | `code_block { raw }` |
| `THEMATIC_BREAK` | `spacer { 12 }` (visual line deferred) |
| `TEXT` | `text { content, style: cascade }` |
| `SOFTBREAK` | one-space text (CommonMark "newlines → spaces in paragraphs") |
| `LINEBREAK` | `line_break` |
| `EMPH` | `emphasis` (cascade applies `theme.applyEmphasis`) |
| `STRONG` | `strong` (`theme.applyStrong`) |
| `CODE` | `code` (`theme.applyCodeInline`) |
| `LINK` | `link { target, content }` (`theme.applyLink`) |
| `IMAGE` | alt text flattened into surrounding flow |
| `HTML_INLINE` | inline code (so source is visible, not silently dropped) |

The cascade — the *real* work — is the `cascade: Style` parameter
threaded through recursion. Each TEXT leaf emits with the resolved
Style baked in. Walker stays dumb.

All slices and strings duped into the caller-supplied arena; cmark
AST freed before `parse()` returns. Tree survives the cmark lifetime
cleanly.

### The .? on a non-optional

One Zig speedbump: `cmark_parse_document` returns `cmark_node *`
which Zig translates to `[*c]cmark_node` (a C pointer that can be
null). `orelse` against that gives a non-optional, so the `.?` I
reflexively wrote was a type error: *"expected optional type, found
'*cimport.struct_cmark_node'"*. Dropping it fixed it. The child-
iteration loops then needed the idiomatic optional-pattern:

```zig
var child: ?*cmark.cmark_node = cmark.cmark_node_first_child(parent);
while (child) |c| : (child = cmark.cmark_node_next(c)) {
    try mapBlock(arena, c, cascade, theme);
}
```

`[*c]T` ↔ `?*T` coercion gives this for free at the variable
declaration.

### Demo replaced

200+ lines of hand-built tree literals deleted. Replaced by:

```zig
const demo_md = @embedFile("demo.md");
// ...
var doc_arena = std.heap.ArenaAllocator.init(allocator);
defer doc_arena.deinit();
const top_stack = try markdown.parse(doc_arena.allocator(), demo_md, &theme);
```

`src/demo.md` is now the source of truth for what the demo shows.
23 lines of CommonMark exercising every block kind + every cascade
modifier. The SDF "ATTENTION" rainbow stays hand-built — it's the
one piece markdown can't express (per-glyph attention + per-glyph
hot_color animation).

## State at session 2 end

- **6 stage commits** (`stage 1` through `stage 3b`), plus the journey
  doc rename + this writeup.
- **~5,700 LOC of our own code** (Zig + GLSL + the tiny vendor
  authored headers) + cmark's ~20k LOC vendored under
  `vendor/cmark/`.
- **589 glyphs** rendering through the markdown pipeline at ~14k fps
  Release. Validation silent.
- The complete element contract: text, line_break, emphasis, strong,
  code (inline), link, paragraph, heading, container, spacer, list,
  list_item, quote, code_block, custom. Theme bundles visual policy.
- markdown source → cmark AST → mapper → Element tree → walker →
  GlyphInstance SSBO → one instanced draw call. Whole pipeline lives
  in ~1500 LOC of Zig.
- One forcing-gate framing — *"the shape markdown forces, every
  future producer adopts"* — that paid off six times in a row.

## What we learned

- **Contract design pays back compounding.** Markdown was a clean
  recursive walk because the contract anticipated nesting. ANSI's
  next; the contract anticipates it (same shape, just a different
  producer). When stage 4 lands quads, the layout side won't need
  changes — only DrawList grows a field and the relevant elements
  start filling it.
- **Vendoring beats bridging.** cmark was ~30 minutes to vendor +
  build + smoke-test. Less time than configuring a system dependency
  on three platforms. Reproducibility for free.
- **The torture demo earned its keep.** Every stage's bugs (code-
  block indent regression, cascade composition wrong for bold-italic,
  marker baseline alignment) showed up in the visual output of the
  hand-built nesting demo *before* the parser ever ran. Stage 3b's
  parser produced perfect output on first run.
- **Walker-time vs producer-time logic** is the real design question
  in a layout engine. We chose producer-time cascade for the same
  reason React chose immutable props: it's easier to reason about,
  cheaper to test, and the perf cost is negligible at parser speeds.
