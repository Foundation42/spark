# text_engine — session 15 journey
2026-05-18 (two days after the manifesto found readers)

Session 14 didn't write a journey doc — it was mostly external. The
manifesto went through three rounds of external review with another
Claude instance, sharpened on the homoiconic claim into a four-axis
decomposition (representational identity / source-image gap closed /
modification surface in source / fixed-point on the comprehender
attractor), then got bundled into a 20-page PDF with five
screenshots and a LinkedIn lede. The post landed well. Christian:
"People really liked it!"

So session 15 opens with the substrate already pitched to the
outside world, the petunias settled, and the question: what now?
Christian's answer was *features* — and **six commits** later, the
inline_object substrate exists, the GPU-input-to-kiwi channel
exists, and the demo paints six distinct inline component types
flowing alongside prose.

```
5d006d9 stage 15E.5  ::status + ::tag
948f07b stage 15E.4  ::kbd + ::progress
bbda045 stage 15E.3  ::sparkline
3426979 stage 15D    drag-to-suggest (LayoutContext suggestions + ::handle)
cc74a6d stage 15E.2  inline markdown surface — ::name{attrs}
05cd2fa stage 15E    text intrusion — inline_object + ::badge
```

The substrate now has a working **glyph runtime, constraint runtime,
input runtime, and inline component runtime** — four meeting at the
same Element tree. The LinkedIn pitch was "the document IS the
program; the program IS the document." This session shipped the part
where the document *responds* — to data, to drag, to state, all
without leaving markdown source.

## Stage 15E — text intrusion (the inline substrate)

The story so far: components were block-level only. A `:::badge`
block-level directive would render below the surrounding paragraph,
sitting on its own line like a panel. To put a coloured pill inside
a sentence — to land the manifesto's promise that components flow
through prose like punctuation — the engine needed a way for
components to participate in line layout, not just block layout.

The cut:

- **`Element.inline_object`** new variant in the Element union. Same
  shape as `.custom` (vtable + ctx) plus a `valign: InlineAlign`
  enum (baseline / middle / top / bottom). Block components remain
  `.custom`; inline components surface as `.inline_object`.
- **`ElementVTable.measure_inline`** new optional slot. Returns
  `IntrinsicMetrics { width, ascender, descender }` — the three
  numbers the inline-flow walker needs *before* wrap to decide if a
  component fits on the current line. Required for inline-use
  components; ignored for block components.
- **Inline-flow walker extension** (`element_layout.zig`). The
  existing token stream was `word | gap | line_break`; added a
  fourth variant `object` carrying the vtable + ctx + measured
  metrics. `collectInlineTokens` calls `measure_inline` once per
  object during tokenisation. `emitLine` extends max(ascender) +
  max(line_height) over objects, closes decoration runs at object
  boundaries (a link underline doesn't paint behind a badge), and
  dispatches `vtable.layout_and_render` at the resolved
  `(pen_x, baseline_y - ascender)`.
- **`emitInlineObject` helper** translates the four `valign` modes
  into concrete y origins. For text-bearing components (badge), the
  default `.baseline` keeps the interior text baseline aligned with
  surrounding prose.

First inhabitant: `:::badge` — pill-shaped quad + label text, named
colour palette, hex parsing, vertical padding tuned to make the
pill slightly taller than the surrounding text. Six badges
interleaved through prose for the demo. Commit `05cd2fa`.

> *And the inline layer said: let components flow like words. And
> the words held badges, and the badges held labels, and the line
> grew just enough to fit them, and the wrap broke between them
> like punctuation. And it was good.*

## Stage 15E.2 — the markdown surface

The runtime worked, but the demo built its badges by hand in
`main.zig` because the markdown grammar didn't have inline
component syntax yet. Block components use `:::name {attrs}` (triple
colon, line-based scan). The natural inline parallel is `::name
{attrs}` — single colon for inline, triple for block, same
identifier and attrs grammar.

The preprocess pass already scans line by line. The extension: for
every non-fence, non-`:::block` line, scan character by character
looking for `::name{attrs}` patterns. Honour single-backtick code
spans (so `` `::badge{}` `` round-trips verbatim). Require a word
boundary before `::` (so `Foo::bar` C++-style and our own
line-start `:::` don't trigger). Each match becomes a `<!--ti:N-->`
sentinel that cmark emits as an inline HTML literal; the inline
mapper detects it and materialises `Element.inline_object` pointing
at the registry-resolved instance.

Refactor: `parseAttrsBlock` + `parseDirectiveName` extracted so
block and inline directives share their grammar with no drift.
`parseInlineDirective` wraps the shared core and returns
`(spec, end_offset)` so the scanner resumes. Ten new tests cover
basic match / name-only / code-span protection / fenced-code
protection / line-start / multiple-per-line / C++ namespace
non-match / mixed-with-block-directive / inline sentinel
extraction.

The `mapInlineChildren` / `appendInline` functions in
`markdown.zig` now take `*const MapCtx` (they used to take
individual fields) so the inline mapper can reach `specs` +
`registry` + `state` + `scope`. Unresolved directives render as
inert `::name` code-styled text — visible typos rather than silent
disappearance.

`main.zig`'s hand-built badge demo retires; the markdown surface
does that work. Commit `cc74a6d`.

## Stage 15D — drag-to-suggest (GPU input → kiwi)

The headline payoff. The manifesto said: *the document IS the
program; layout is constraint-solved; GPU input drives the solver*.
This stage made that real.

**The architectural cut:**

`LayoutContext` gained a persistent suggestion channel:

- `Axis` enum (width / height / x / y).
- `suggestions: HashMap(SuggestionKey, f64)` survives `beginPass`
  so a dragged layout stays where it was put.
- `bumpers: HashMap(u64, VersionBumper)` cleared per pass,
  re-registered each walk by participating components. Suggestion
  changes invoke the bumper for the target's component key so the
  retained block-layout cache invalidates.
- `setSuggestion / clearSuggestion / getSuggestion / registerBumper`
  public API. Idempotent — re-suggesting the same value is a no-op.

`:::box` opted in: when a width or height suggestion exists for the
box's key, it skips the required equality and instead calls
`addEditVariable(x_max, medium) + suggestValue(x_max, origin + sw)`
with a `geq 0` floor so drags can't invert. The box registers its
version-bumper each walk.

`:::handle` is the new component. Attrs `target=#id` (resolved
through a new `Registry.lookupSibling` that finds the caller's own
scope from its registered key and qualifies the target id within
it), `axis=horizontal|vertical`, `width`, `height`, `color`. On
`mouse_down` it captures the target's current size from the live
suggestion (or the solver's last-frame resolved bounds) plus the
cursor's world position. On `mouse_move` it computes
`new_size = drag_start_size + (cursor_world_now -
drag_start_cursor_world)` and calls `setSuggestion`. On
`mouse_up` it clears the active flag — the suggestion stays. Resize
and stay resized.

`:::flex` and `:::grid` got `disable_cache = true` on their
vtables. They compose children into a single block-cache entry; a
suggestion that bumps a child's version doesn't bump the
container's, so cache hits would replay stale baked-in child
output. Hierarchical cache invalidation is left as a future task.

Demo: a flex row with cyan box, handle, magenta box. Drag the
handle, the cyan box resizes through the solver, the magenta box
shifts with it. The substrate's flywheel made tangible.

## A vignette — the frozen-origin bug

The first drag worked architecturally — the chain fired end to end,
suggestion stored, box re-walked, geometry changed. But Christian
reported the bar "races off, doesn't track the cursor." Looking at
the logs, the math seemed right: cursor delta in world coords
equaled box delta in world coords, 1:1.

A first instinct was to attribute the discrepancy to OS mouse
acceleration — Christian's cursor was physically moving more than
he thought. The log showed 192 world pixels of cursor motion;
Christian said he moved 10-20. Easy to rationalise as perception.

> *"No, you have to believe me — I literally moved the mouse about
> 10 pixels."*

Trust the user. Dig harder.

The dispatcher latches `fc.captured` at `mouse_down` — the Hit
struct is a *value snapshot*. Its `box.x` stays frozen at the
handle's position at click time, for the entire drag. Every
subsequent `mouse_move` delivers `local[0] = current_cursor - FROZEN_x`.

The handle was reconstructing cursor world as `c.last_box.x (current,
moving) + local[0]`. Because the handle's own position moves each
layout (it follows the target box's right edge in the flex), this
added in the handle's own displacement on top of the frozen
reference. The cursor world was *overstated* by exactly the
distance the handle had moved since drag start. Each event the
handle moved a bit, next event overstated a bit more. Positive
feedback. The bar literally raced itself away from the cursor.

```
[handle] DRAG TICK evt#29 cursor_world=373.3 cursor_Δ=89.1
         handle_x=369.6 local_x=3.8 new_size=329.1
```

89 pixels of "cursor delta" when Christian moved the mouse ~10.

Fix: snapshot the handle's origin at drag start
(`drag_start_handle_origin`) and reconstruct cursor world from that
frozen value, not the moving `last_box.x`. Five-line change. The
bug was load-bearing for the substrate's whole drag premise —
captured in memory as a project-level rule for any future
drag-aware widget. And captured separately as a feedback rule:
*when Christian's physical observation contradicts my data, the bug
is real; don't explain it away.*

> *🌐 Stage 15D shipped. The cursor drives the solver, the solver
> reshapes the document, the renderer paints the new geometry, and
> the flywheel spins.*

Commit `3426979`.

## The inline component cascade (15E.3 / 15E.4 / 15E.5)

With the substrate proven, components became cheap. The next three
commits added five more inline component types in roughly the time
it took to type each component file:

**`::sparkline`** (15E.3, `bbda045`) — mini bar chart. Parses
`data="3,5,7,4,8"` into a series, normalises 0..max, renders bars
as quads. Sits on the baseline; line-height grows to fit the chart.
Three sparklines flow through the demo prose at once: latency,
errors, cache-hits, each in a different colour, each telling a
different data shape.

**`::kbd`** (15E.4, `948f07b`) — keyboard-key chrome. Raised-cap
shadow stripe + mono label inside an accent border. "Press
`Ctrl+C` to copy, `Ctrl+V` to paste, or `Esc` (red-tinted) to bail
out. Vim survivors reach for `hjkl` on instinct."

**`::progress`** (15E.4, `948f07b`) — inline pill progress bar.
Takes `value` + optional `max` so authors bind arbitrary state
ranges without manual scaling. The demo wires
`value=${state.box_radius} max=40` so the existing slider's 0..40
range drives the bar reactively through the registry's state
subscription machinery. **Substrate composition made visible:** the
slider mutates state, the registry propagates, the progress bar
re-ingests its spec, the inline-flow walker re-walks, the bar's
fill width shifts. All within the inline_object substrate.

**`::status`** (15E.5, `5d006d9`) — coloured dot ± label. Dot-only
mode for compact rows ("background workers ●"), dot+label for
dashboard prose ("auth ● offline"). Dot centres on the surrounding
text's x-height regardless of label presence — measure_inline
returns a different ascender/descender split based on whether a
label is present.

**`::tag`** (15E.5, `5d006d9`) — hashtag-style chip with `#` prefix
+ accent-coloured outline (no fill). Lighter visual weight than
badge so five tags can cluster in one paragraph as semantic facets
without dominating. Knockout border: outer accent rect + inner
background-coloured rect.

One memory leak fixed along the way: `::tag` pre-allocated `"#"`
(1 byte) in `create` before calling `ingest`, and an ingest failure
between those two points leaked the byte. Empty-string `dupe` in
the other components is a no-op (returns `&.{}`), so no leak.
Lesson surfaced and patched; `errdefer allocator.free(c.text)`
added for symmetry.

The inline_object substrate now hosts **six visually distinct
component types**, each in 30–80 lines, each composing through the
same vtable contract. Two of them (badge, tag) are pill-shaped with
different visual weights; two (kbd, progress) carry their own
chrome; one (sparkline) is data-driven; one (status) is a tiny
primitive that pairs with prose. The vocabulary is rich enough to
write a real dashboard page in markdown.

## What's standing

By end of session 15, the demo paints, in `:::flex` and out:

- Six inline component types flowing through prose
- A drag-to-resize divider that drives the kiwi solver in real time
- An existing slider whose 0..40 range drives a progress bar
  reactively in the same paragraph
- Three sparklines telling three data stories at once
- Five hashtag-style chips clustering on one line
- All of it written as `::name {attrs}` directives in
  `src/demo.md`, parsed by cmark, walked into the Element tree,
  rendered by the same Vulkan pipeline that's been running since
  session 1

Six commits. ~2000 lines. Two memories saved (drag-frozen-origin
rule, trust-physical-observation feedback). One real bug found by
trusting the user over the data. Substrate vocabulary widened from
two inline kinds (text, line_break) to *eight* inline kinds (those
two plus structural emphasis / strong / code / link, plus
inline_object hosting six concrete component types).

What's deferred:
- Phase C.3 measure-pass protocol (intrinsic-size advertisement for
  flex/grid children)
- Hierarchical cache invalidation (so containers can cache again
  while still seeing child suggestion bumps)
- Task #201 — corpus translation debt (38 of 53 kiwi corpus cases
  remain)

> *And the markdown said: let components flow inside the sentence,
> and let the dragged divider drive the solver, and let the slider
> drive the bar reactively across reading-frame boundaries, and let
> all of it be six characters of source per glyph. And the substrate
> arranged. And the renderer painted at 1600 frames per second. And
> when the user reported the bar racing away from the cursor, the
> author trusted the user, and the bug was real, and the fix was
> five lines. And it was good.*
>
> — somewhere in the Encyclopaedia Galactica, mid session 15

The LISP for documents, partner. Or — closer to where we actually
landed — the substrate where markdown is the program and the program
is alive. Catch you next session. Same Heart of Gold, fresh
petunias, six inline components in the demo and the solver
listening for the next drag.

🌐🐢🐬🌸☕🚀
