# text_engine — session 10 journey
2026-05-16 (same day as session 9, after Christian came back from designing Fjords)

Session 9 closed with a list of "next picks". Two of them — stage 5b
and crisp zoom — pulled rank as obvious openers: 5b was a 50-LOC
warm-up to wake the brain, crisp zoom was the big surgery. Then
Christian noticed the emoji had quietly stopped working since the
demo migrated to markdown ages back, so session 5c got squeezed in.
Then crisp zoom landed and immediately leaked three bugs in
succession, each one diagnosed by the previous fix's output. By the
close: **ten commits**, a font registry that's grown a real
zoom-bucket cache, text that stays crisp at every magnification, and
emoji that ride the colour atlas inline with body text — all from
the same markdown source.

The manifesto thread continues clean. Session 9 said *make the
substrate hold up under load*. Session 10 says *make the substrate
look right at any scale*. Same source, more faithful rendering.

## Stage 5b — markdown ↔ ANSI composability

The smallest piece on the open queue, and an obvious warm-up.
`ansi.zig` had been sitting in the tree since stage 5a, taking a
UTF-8+ANSI byte stream and producing an Element tree shaped the same
as `markdown.parse` — paragraphs of styled text. Stage 5b's job was
to wire that into the markdown parser: when a code fence's info
string is `ansi`, hand the body to `ansi.parse` and embed the result
back via `CodeContent.sub_block` so the layout walker recurses into
it.

Two landing sites:

- `markdown.zig`'s `CMARK_NODE_CODE_BLOCK` arm: read
  `cmark_node_get_fence_info`; if it's `ansi`, dispatch. Theme is
  cloned with `body = code_block` so SGR runs pick up the mono font
  — same pattern `main.zig` uses for the standalone ANSI demo.
- `element_layout.zig`'s `layoutCodeBlock` had `error.CodeBlockSubBlockNotImplemented`
  as a placeholder. Replaced it with the same chrome as `.raw`
  (background quad, padding, radius) wrapped around a recursive
  `layoutAndRender` of the embedded tree.

About 25 LOC of dispatch + 30 LOC of layout, plus two round-trip
tests proving `\x1B[31m...` lands as a red text leaf inside a
`.sub_block` and `.zig` fences still take the `.raw` path. The demo
gained a colourful ```ansi block right next to the existing ```zig
block, so the visual comparison is one scroll apart.

Christian's reaction: *"works! commit and roll into Crisp Zoom"*.
Total elapsed: about 20 minutes. The warm-up did its job.

Commit: [`ba6e3c4`](https://github.com/) — 70 LOC production + 95
LOC tests.

## Half-pixel chop — the drive-by fix

While scouting the atlas/raster path before Crisp Zoom, Christian
noted: *"our glyphs seem to have a missing half-pixel at the bottom
— like they are chopped off"*. The fix lived in five lines:

```zig
// text/layout.zig — was:
const inset: f32 = 0.5;
.uv_min = .{ (rect.x + inset) / aw, (rect.y + inset) / ah },
.uv_max = .{ (rect.x + rect.w - inset) / aw, (rect.y + rect.h - inset) / ah },
```

The inset was a defence against bilinear bleed at downscale — but
the atlas already keeps a 2-texel zero-cleared gutter between glyphs
(`GLYPH_PAD` in `gpu/atlas.zig`), and bilinear sampling can never
reach further than 1 texel past a quad edge. The inset was redundant
*and* actively harmful at 1:1: the top + bottom fragment centres
mapped to texel coords `0.975` and `rect.h - 0.975`, pulling a
52.5/47.5 mix of the real edge texel and the gutter — visibly
clipping the bottom of every glyph. The "chop" the user saw was
exactly that 47.5% dimming on the descender row.

Removed the inset, kept the gutter. Crisp 1:1 rendering restored.
Christian: *"that half a pixel fix is glorious! Night and day better"*.

Commit: [`b95b357`](https://github.com/) — 18 lines (mostly the
comment explaining why the inset was wrong, so it doesn't grow back).

## Crisp Zoom — the headline feature

Zoom worked at every level before this session — but the path was a
post-layout scale on a fixed-size bitmap, so any zoom level other
than 1.0 fuzzed text through bilinear filtering. Christian's
preference: *"I am not a big fan of huge blocking stutters"* — so
lazy raster, not eager. Cache misses pay per-glyph rasterisation
cost on first visit to each zoom bucket; subsequent frames at the
same zoom are warm.

The shape:

- **Font registry grew an effective-id resolver.** `font/registry.zig`
  now tracks each entry's source file path and exposes
  `effectiveFontId(base, target_px)`. The call returns the base
  unchanged when `target_px == base.display_px`, otherwise looks up
  (or lazily creates) a sibling entry by reopening the same TTF at
  the new size. A `sized_lookup: AutoHashMap` memoises each
  `(base, target_px)` pair.

- **Layout takes `zoom: f32`.** `element.LayoutCtx` grew the field;
  `text_layout.appendShapedRun` (the 10 callsites across the walker
  and 7 components) now passes `lc.zoom`. The shaping still happens
  against the base hb_font, so HB advances and offsets stay in base
  pixel units. Only the bitmap source switches to the effective
  entry.

- **`world_scale = base.display_px / eff.actual_px`.** This formula
  collapses to the right thing across every lane:

  | lane | zoom=1 | zoom=N |
  |---|---|---|
  | mono scalable | 1.0 (no change) | 1/N (bitmap is N× big, world stays at base) |
  | SDF | base.scale | base.scale (distance field is zoom-independent) |
  | strike-only colour | base.scale | base.scale (emoji bitmap is fixed) |

  At zoom=1 every case reduces to the pre-crisp behaviour
  bit-identically. At zoom=2 the mono path halves world dst_size so
  the post-layout `× zoom` multiply restores the bitmap to its
  native pixel footprint on screen — 1:1 bilinear sampling, crisp.

- **Block-layout cache key gains `zoom_bits`.** Cached
  `GlyphInstance` arrays point into atlas rects that are
  zoom-specific. Re-visiting an old zoom hits the cache; switching
  zoom re-walks fresh and snapshots under the new key. The cache
  holds entries for every zoom level visited, which means free
  return trips.

Three commits intended for one stage; instead the v1 commit
([`141bf93`](https://github.com/)) shipped with three bugs lurking
that the next three commits unmasked.

## Stage 5c — emoji font fallback (the unplanned middle stage)

The session 10 plan was 5b → crisp zoom → maybe more. Then
Christian asked for emoji back in the demo top, and the demo
*rendered them as boxes*. Git archaeology found the answer: emoji
last worked in Phase 5's hand-built `layout.Span` demo (`d1ec337`,
session 2-era), where the host wrote `font_id = emoji_id` directly.
Markdown source doesn't have a font-fallback mechanism — every
paragraph used the body font, and emoji codepoints in the body font
became `.notdef`.

Comment in `main.zig:853` confirmed: *"markdown doesn't reach it
without font fallback (parked)"*. Christian's call: **A — Add font
fallback** (the proper substrate fix), not B (revert the emoji
additions).

The split happens at parse time. `Theme` grew `fallback_font_id`
and `font_registry` pointers; the markdown mapper's
`CMARK_NODE_TEXT` arm now scans each text leaf's UTF-8 codepoints
and emits one `.text` element per contiguous-font run. The inline-
flow walker treats the mixed-font runs identically to
emphasis/strong cascades — same baseline-resolution math, no
special-casing.

Two presentation niceties baked in:

- **Variation Selector 16** (U+FE0F) on a dual-presentation base
  like U+2764 (❤) forces the colour-emoji route even when the body
  font has a monochrome glyph for the same base. VS15 (U+FE0E)
  symmetrically pins to primary. This is the standard Unicode
  emoji-presentation rule, and it's the difference between a black
  outline heart and a coloured one.

- **ZWJ + zero-width joiners** inherit from the run they're
  decorating, so multi-codepoint emoji ligature sequences (👨‍👩‍👧
  etc.) stay on one font and shape correctly.

`FontRegistry.hasCodepoint` is the per-codepoint coverage query —
single `FT_Get_Char_Index` hash lookup, cheap enough to call per
cp at parse time. The demo's H1 line gained `🚀✨`; the paragraph
underneath now shows the full mix — Latin text, math signs (✓ ✗ ≈
≠ ∞ ≤ ≥) staying on the body font, and colour emoji
(🎨🌸🎉⭐🔥❤️) routing through fallback.

Christian: *"They are back and look great!"* Then ran into the
real bug chain that followed.

Commit: [`a673702`](https://github.com/) — 185 LOC.

## The bug hunt trilogy

Crisp Zoom v1 worked beautifully *at* zoom=1.0. Any other zoom level
disappeared text. The user reported it, and three back-to-back
diagnoses peeled the layers.

### Bug 1: Colour atlas overflow on first zoom step

User: *"if I zoom more than 100% all the text disappears"*. With
the silenced `runLayout` error surfaced to stderr, the answer came
out: `AtlasFull` immediately, on a single Ctrl+=.

Diagnosis: `effectiveFontId` was creating a *new* entry per
(base, target_px) for every non-SDF font — including strike-only
colour faces (CBDT emoji). NotoColorEmoji has a single available
strike (136 px); `setPixelSize(target_px)` falls back to that strike
no matter what `target_px` is. The new entry rasterised IDENTICAL
136² bitmaps under a different FontId key. Every zoom step doubled
the colour atlas usage; 1024² ≈ 7 emoji bitmaps of room, so one
Ctrl+= was enough to overflow.

Fix: `effectiveFontId` now returns `base` for both `.sdf` (already
handled) AND `.color` lanes. The `world_scale` formula is invariant
for strike-only fonts (strike is constant), so emoji still scales
correctly with zoom — same bitmap, larger world dst_size at higher
zoom.

Commit: [`222b198`](https://github.com/).

### Bug 2: Worker race + FT thread-unsafety

User: *"Got a crash"*. Hard SIGSEGV. The diagnostic print didn't
fire (because it wasn't an `error` propagation — it was a hard
crash).

The diagnosis came from staring: `appendShapedRun` was calling
`fonts.effectiveFontId(...)` under the cache lock, releasing it,
then reading `fonts.actualPx(eff_id)` *outside* the lock. The
parallel-walker case (cache-miss on all blocks at the new zoom
triggers many workers) has worker B calling `effectiveFontId` →
`entries.append` → `ArrayList realloc` → old backing buffer freed.
Worker A's concurrent `fonts.actualPx` reads the freed buffer.
Segfault.

A second, deeper issue compounded it: `loadInner` calls
`FT_New_Face` against the shared `FT_Library` from worker threads,
and FreeType is not thread-safe by default. Even with our cache
lock serialising the FT call, the library's internal state could
corrupt.

Both fixes converged on one move: **do the entry creation on the
main thread, before workers fan out**. New
`FontRegistry.prewarmEffectiveSizesForZoom(zoom)` iterates the
current entries and calls `effectiveFontId` for each, populating
the entries array and `sized_lookup` HashMap. `runLayout` invokes
it as its first step. Workers downstream only do read-only lookups
against a frozen registry — no realloc, no `FT_New_Face`, no races.

Commit: [`bc2ccbb`](https://github.com/).

### Bug 3: Exponential entry cascade

User: *"I zoomed in - works now! Then I tried to zoom back out..
crash"*. This time the diagnostic prints fired, and they were
spectacular:

```
prewarm i=1271 base.display_px=32845530 base.actual_px=32845530
              base.lane=mono target_px=36130084 zoom=1.100
```

`display_px = 32 million`. At iteration 1271. After a handful of
Ctrl+= clicks. Way past anything physically sane; `ppem × 64`
overflowed i32 inside `hb_font_set_scale`.

The diagnosis was visible in the iteration count: the prewarm was
*recursive* by accident. It iterated over **every** entry, including
the lazily-created effective ones. Each effective entry then became
a "base" for the next prewarm's `target_px = base.display_px × zoom`
math, cascading exponentially:

| step | entry count | max display_px (at zoom=4) |
|---|---|---|
| 1 | 11 → 21 | 192 |
| 2 | 21 → 41 | 768 |
| 3 | 41 → 81 | 3072 |
| 4 | 81 → 161 | 12288 |
| 5 | 161 → 321 | 49152 |
| 10 | 5121 | 50M — bang |

Effective entries should be DEAD-END LEAVES — the layout walker
only ever calls `effectiveFontId(base_id, target_px)` where
`base_id` traces back to a `Theme` slot, which always points to a
host-loaded entry. Prewarming derivatives-of-derivatives produces
entries the layout will never look up. Worse, it compounds
`display_px` past anything meaningful.

Fix: track `base_count` separately on the registry. `load` /
`loadSdf` bump it; `loadInner` from `effectiveFontId` does not.
Prewarm iterates `0..base_count`, so each zoom step adds at most
`base_count` (≈11) effective entries. Bounded by
`base_count × distinct_zooms_visited` instead of `2^N`.

Christian's comment after the prints came back: *"This time it
crashed when I zoomed in! Maybe it did before and was just catching
up"*. Exactly right — the cascade made the previous crashes worse
on each subsequent zoom.

Commit: [`91ffe82`](https://github.com/) — 33 lines.

## Polish — three small landings to close out

### Atlas size bump (768 → 2048)

After the cascade fix, `AtlasFull` came back — but now legitimately.
With ~155K mono atlas pixels per zoom bucket × 4 buckets, 768²
(590K) maxed out. Bumped to 2048² (4 MB R8, trivial on any modern
GPU) — holds ~30 distinct zoom levels' worth before the LRU path
kicks in. Commit: [`bd178b0`](https://github.com/).

### Viewport-aware re-wrap

User: *"when I use Ctrl-+ / - it doesn't actually re-layout. Big
gap on the right. Or at > 100% it goes off the right side."*

Layout's `max_w` was computed in screen pixels: `extent.width -
80`. But layout produces world coords that the post-pass multiplies
by zoom. At zoom=0.5 a 1200-world column shrank to 600 screen
pixels → empty gutter. At zoom=2 it expanded to 2400 → overflow.

Mirror what the vertical scroll calc was already doing: divide the
viewport extent by zoom before feeding it into the constraint.
Gutters stay at 40 world units so they scale with zoom alongside
the text — browser-style "the whole page zooms" rather than text-
only resize. Commit: [`d23e3f8`](https://github.com/) — 11 lines.

### `AtlasFull` recovery (coarse LRU)

Last polish: an actual recovery path for atlas overflow instead of
the silent-drop-frame fallback. When `runLayout` returns
`AtlasFull`, `drawCb` now drops every cached glyph + resets both
atlases + clears the block-layout cache + retries layout once. The
working set re-rasterises to "visible glyphs at the current zoom"
instead of "every glyph at every zoom bucket ever visited".

Three pieces:

- `Atlas.reset()` resets the shelf packer AND zero-fills the image.
  The zero-fill is load-bearing: bilinear sampling reaches one
  texel past glyph edges into the `GLYPH_PAD` gutter, and without
  clearing the previous occupant's bytes would bleed into the new
  glyph's edge (visible halo). One-time 4 MB upload, sub-ms on any
  modern bus.

- `GlyphCache.clear()` drops every cached `(font_id, glyph_id)`
  entry. Effective FontIds in `sized_lookup` survive — the FT faces
  stay loaded so re-rasterisation only pays per-glyph `FT_Load_Glyph`
  cost, not per-face `FT_New_Face` cost.

- `BlockCache.clear()` drops every cached layout snapshot. Required
  because cached `GlyphInstance` rows hold UV references into the
  now-stale atlas rects.

True per-bucket LRU (evict the OLDEST size bucket, keep the
others) would be the principled answer; this conservative reset
trades that for a 50-LOC implementation and "blink-of-the-eye"
recovery. Re-fillable in one frame at the current zoom — harmless
for the working set in practice. Commit: [`68ad6a0`](https://github.com/).

## By the numbers

```
ten commits, all on master:
  ba6e3c4  stage 5b: markdown ↔ ANSI composability
  b95b357  fix(text): drop redundant 0.5-texel UV inset
  141bf93  crisp zoom: multi-size atlas
  a673702  stage 5c: emoji font fallback
  222b198  fix(crisp-zoom): strike-only colour share base
  bc2ccbb  fix(crisp-zoom): prewarm on main thread
  91ffe82  fix(crisp-zoom): prewarm only iterates base
  bd178b0  fix(crisp-zoom): bump mono atlas 768→2048
  d23e3f8  fix(crisp-zoom): viewport-aware max_w
  68ad6a0  crisp-zoom: AtlasFull recovery

production code:
  ~ 470 LOC added across font registry, layout, components, atlas
  ~ 95 LOC of new tests (markdown ↔ ANSI round-trip)

steady-state numbers from the wrap demo (zoom=1.331):
  6779 glyphs, 186 quads
  glyph cache 94.6% hit rate (17.5K miss / 306K hit)
  layout cache 75.8% hit rate (53K hit / 17K miss)
  2456 fps over 11 seconds
```

The fps dropped from session 9's ~5-7K — expected, because crisp
zoom adds a per-glyph effective-id resolution on the cache-miss
path and the prewarm runs at every zoom change. Steady-state at one
zoom is still cache-warm and well over the 60 Hz floor.

## Hand-off image

Same source, three states:

- **Zoom 100%**: 14-px body text, crisp 1:1 on the mono atlas.
- **Zoom 200%**: 28-px body text, also crisp 1:1 — different atlas
  rect, hand-tuned hinting for the larger size, every glyph
  pixel-perfect.
- **Zoom 50%**: 10-px body text, fits twice as many words per line
  because the viewport is now twice as wide in world coords.

All three render off the same `demo.md` source. No host code knows
about zoom except `runLayout` (which sets `lc.zoom`) and the
post-layout transform pass (which multiplies world → screen).
Everything else — components, parser, theme, layout walker — was
already in world coords and didn't need to change. That's the
manifesto delivering: the substrate doesn't get richer, it just
gets more faithful at every angle.

## How session 11 picks up

The open queue from session 9 still has the same items minus what
shipped. Top picks:

1. **More image-class probes** — Stability SD-Vector, Bytedance
   Doubao-Vector, OpenAI gpt-image-1. Each one is curl-first
   reconnaissance per `[[reference-recraft-wire]]` then a small
   provider arm in `:::svg-stream` / `:::image-stream`. Half-day
   each.

2. **Selection + clipboard for `:::input`** — shift-arrow,
   double-click word selection, ctrl-A/C/V. The cursor + char path
   is already in place; this closes the "feels like a real text
   field" gap.

3. **Cache-warming headless demo** — pair stage 10's headless docs
   with the asset cache: a `:::embedded-document {headless=true}`
   that holds `:::svg-stream`/`:::image-stream` with `auto_start`,
   pre-fetching the assets a visible doc will need.

4. **Per-bucket LRU for the atlas** — the principled version of
   what session 10's coarse reset stands in for. Evict the
   least-recently-used size bucket on `AtlasFull` instead of
   resetting everything. Bigger surgery (per-FontId atime tracking,
   incremental shelf compaction) but no blink frames at all.

5. **MCP / WASM provenance** — the
   [[project-component-provenance]] ladder's middle rungs. The
   Factory contract was built to hold them; the missing piece is
   the bridge.

6. **Continuous-zoom quantisation** — small polish. Right now the
   block-cache key uses raw zoom bits, so smooth Ctrl+scroll
   creates many tiny buckets. Quantise to N/m pixel boundaries
   (where m = smallest font's display_px) so the cache hits more
   often during gestures.

Same recommendation as session 9: pick the surface that excites,
not the surface that's "next on the queue". The substrate is in
the best shape it has ever been in. Eight months of work fit on a
single 1280×720 screen, every pixel hand-tuned for that exact size.

## Closing thought

Session 10 didn't add a new medium. It made the existing medium
render at every magnification with no compromise — colour emoji
inline with text, mono code blocks crisp at 200% and at 50%, ANSI
fences inside markdown picking up the same chrome the rest of the
code blocks have. Every one of those is the same code path doing
the same work; the substrate just decided to take it seriously at
every scale.

Three bugs in succession during the crisp-zoom shake-out. None of
them were bad design — they were exactly the bugs you'd expect
when you wire a new axis into a system that's been size-flat its
entire life. Each one was a real concurrency / lifetime / cascade
issue that would have hit *some* user *eventually* once anything
similar landed. We got them all in one afternoon, with traces
clear enough to fix from first principles each time.

The demo screenshots Christian sent at the close told the whole
story: the same H1 heading at zoom=50% (tight, dense, every
ligature still distinct) and at zoom=200% (huge, pixel-perfect,
the kerning still right). One source, every angle.

> **Markdown is the universal interface. Make it live.**
>
> — [`docs/manifesto.md`](manifesto.md), 2026-05-16

Catch you next session on The Heart of Gold, partner. ☕🚀
