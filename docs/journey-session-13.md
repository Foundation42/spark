# text_engine — session 13 journey
2026-05-16 (same day as session 12, after the petunias settled in)

Session 12 closed with three boxes in a row and the manifesto thread
extended through **compose**. Christian's return:

> *And the markdown said: let there be one universal interface. And
> the universal interface said: let it be plain text. And it was so.
> Welcome back!*

By the close: **three commits**, a second multi-child layout
provider, a latent parallel-walk race surfaced and fixed (its
existence proven by an actual stack trace, not a theory), and a CSS-
grid-class track resolver landed alongside its tests. Levels of
improbability still rising. The substrate now ships both 1D and 2D
layout primitives, and a third party reading the demo can't tell
which century the technology is from.

## Stage 15d — `:::grid`, the 2D sibling

Phase F.1 of the original substrate plan. The natural follow-on to
`:::flex` from session 12 — same shape (required `#id`, body re-
parsed through `markdown.parseWithStateAndScope`, scoped child
cleanup via `registry.deinitScope`), different layout algorithm.

The provider is ~280 LOC:

- Reads `columns=N` (integer track count) + `gap=N` (uniform).
- Walks `c.root.container.children` in row-major order; cell `i`
  lands at column `i % N`, row `i / N`.
- Equal-width tracks derived from `constraints.max_w`:
  `col_width = (max_w − (N−1) × gap) / N`.
- Auto-height rows sized to the tallest child in each row; the
  next row starts `row_height + gap` below.
- Each cell still goes through the kiwi solver for its own bounds
  via `:::box`'s `layoutViaConstraints`. The grid parent allocates
  the track; the cell constrains its size inside it. Same
  consultative-substrate trick `:::flex` uses, applied along a
  second axis.

Demo gets a 3×2 dashboard panel — red / orange / yellow / green /
cyan / purple — between the flex strip and the composition section.
Four unit tests on `applyAttrs` (columns + gap, defaults, columns=0
rejected, px suffix). Test count climbs, demo binary builds clean,
commit `7d3e7d0`.

> *🌐 Stage 15d shipped.*

## Stage 15d.1 — the parallel-walk race

Christian tried to resize the window. The demo panicked mid-frame:

```
thread 546228 panic: reached unreachable code
        assert(l.state == .unlocked);
/std/array_hash_map.zig:1200:40: in fetchOrderedRemoveContextAdapted
        self.pointer_stability.lock();
/src/layout/kiwi/row.zig:159:42: in substitute
/src/components/box.zig:229:44: in layoutViaConstraints
/src/components/flex.zig:209:61: in layoutAndRender
/src/element_layout.zig:797:36: in walkOneJob
/src/jobs.zig:345:17: in executeJob
```

That's Zig 0.14's `AutoArrayHashMap` pointer-stability safety lock
trapping concurrent map mutation. The smoking gun is the bottom
frame: `walkOneJob` is the stage-14b parallel-walk dispatcher, and
the path goes `worker thread → flex child → box →
layoutViaConstraints → addConstraint → solver substitute → row
substitute → cells.fetchOrderedRemove`. Two workers were inside the
shared `LayoutContext.solver` at the same time.

The race had been latent since Phase B. Session 12's flex demo with
three boxes sat below the parallel-walker's cost threshold — they
ran serially on the main thread, no race. The new grid added six
more cache-miss participants. Window resize invalidates the layout
cache for every block at once; the dispatcher fanned the work out
to workers; two of them collided in the solver.

Fix is a Thread.Mutex on `LayoutContext`, held across the full
add-constraints + `updateVariables` + value-read sequence in
`box.layoutViaConstraints`. ~19 LOC of real change. Critical
section is the original ~10-30µs per box; serialising across N
workers stays well inside the frame budget because the work was
already cheap.

The substrate just gained "thread-safe across the parallel walker"
as a property — needed anyway for Phase D, now landed under
pressure from a real crash instead of a hypothetical one. Commit
`ba8db99`.

> *That fixed it!! ROCKIN!*

A receipt worth keeping: this is what a healthy substrate looks
like when it grows. Phase B planted the seed (kiwi solver wrapped
in a LayoutContext). Phase C.2 sprouted (`:::flex` plugged in).
Phase F.1 produced fruit (`:::grid`). The fruit grew heavy enough
that a structural weakness — the solver's serial assumption —
finally bent under the load. Patching it was a 19-line surgery
because the contract was small enough to reason about. If the
solver had been spread across every provider instead of
consolidated in one LayoutContext, the fix would have been
distributed across every provider too.

## Stage 15e — richer `:::grid`

With the substrate proved thread-safe and the basic grid landing,
the natural next move was promoting the grid to its real CSS-grid
form. ~330 LOC delta:

**Track list.** `columns` now accepts either an integer count
(`columns=3` → three `1fr` tracks, back-compat with stage 15d) or a
CSS-grid-style space-separated list:

```
:::grid {columns="180px 1fr 1fr" column-gap=16 row-gap=8}
```

Each token is either a pixel length (`100`, `100px`) or an `fr`
weight (`1fr`, `2.5fr`). Tokens that parse as neither are silently
skipped — robust to author typos, no half-broken renders.

**Track resolution.** Sum the fixed widths, subtract from
`(avail_w − (N−1) × column_gap)`, distribute the remainder across
flex tracks in proportion to their `fr` weight:

```
remaining = max(0, avail_w − total_gap − fixed_total)
for each track:
  fixed → its pixel value
  flex(f) → remaining × (f / flex_total)
```

Oversubscribed fixed tracks underfill cleanly (no negative widths).
A track list with no flex tracks renders at its natural width;
a list with no fixed tracks recovers the equal-column behaviour
of `columns=N`.

**Axis-split gap.** `row-gap` / `column-gap` are independent;
`gap=N` is a shorthand that sets both. Standard last-attribute-wins
ordering, so `{gap=12 column-gap=24}` resolves to `row_gap=12,
column_gap=24` without surprise.

**Storage.** Tracks live in a fixed `[MAX_TRACKS=32]` inline array
on the Component — no arena growth across `update()` calls and no
per-frame allocation. 32 covers every reasonable document grid.

14 new unit tests across `parseTrack`, `parseColumns`,
`resolveTrackWidths`, and `applyAttrs`: integer shorthand, mixed
lists, garbage tokens, empty input, pure-flex distribution,
fixed+flex split, oversubscription, axis-split gap, gap shorthand.

Demo adds a sidebar example next to the existing dashboard:

```markdown
:::grid {#sidebar_layout columns="180px 1fr 1fr" column-gap=16 row-gap=8}
  :::box {color=cyan width=100% height=80 radius=6}
  :::
  :::box {color=magenta width=100% height=80 radius=6}
  :::
  :::box {color=orange width=100% height=80 radius=6}
  :::
:::
```

Resize the window: the cyan sidebar holds its 180px; magenta and
orange share the rest. Commit `9259832`.

## The meta-circular insight

Christian, looking at the demo:

> *I just love the meta-circularity of it all — which is what the
> AI future needs. No hard coded resource files like Silverlight or
> embedded code driven user-interfaces anymore. We can now build
> UIs that self-describe and mutate on the fly without complex
> legacy contracts or HTML/XML nonsense. We have built the "LISP"
> for collaborative documents… and it's absolutely gorgeous!*

That's the position. Worth capturing while it's fresh.

The thing that makes `:::flex` and `:::grid` interesting isn't
that they exist — every UI framework in history has them. It's
that they're **markdown directives that re-enter the markdown
parser through `markdown.parseWithStateAndScope`** to resolve
their own bodies. A grid contains boxes; a grid can contain a
flex; a flex can contain a grid; an embedded document can contain
either; an llm-stream can produce markdown that includes any of
the above and the result lays itself out the same way the original
document did. Documents are components. Components are documents.
The parser is the runtime. The runtime is the parser.

That's *homoiconic*, in the LISP sense. The substrate's
serialised form (markdown text) is the same shape as its runtime
form (parsed component tree feeding the layout walker). An LLM
producing markdown is producing UI. A user typing into a `:::input`
that targets an `llm-stream` is asking the LM to extend the
document. A `:::grid` rendered to screen is the same artifact a
human author would write by hand. No XAML, no JSX, no template
compiler standing between intent and pixels.

The runtime emits no compile-time-bound code. Every provider
registers itself by string name into a Registry the host owns;
markdown directives resolve by string-keyed lookup; attribute
values are strings that components parse with their own grammars;
state values are `f32` / `bool` / strings the reactive layer
diffs at runtime. Components are factories returning vtables.
Anything that can speak the protocol — be it built-in, remote
HTTP, future WASM, future Vulkan-input, future LLM-authored —
plugs in through the same channel. The component provenance
ladder isn't an abstract diagram any more; it's the thing that
let `:::llm-stream` and `:::svg-stream` and `:::grid` all land
through the same registry interface in different sessions.

This is the property HTML doesn't have. HTML's runtime form
(the DOM) is a different shape from its serialised form (the
markup). React's runtime form (the fiber tree) is a different
shape from its serialised form (JSX, which has to be transpiled).
XAML, FXML, Silverlight — all of them resolve a *different* tree
at runtime than what the author wrote.

Markdown-as-runtime collapses that distinction. The author writes
the runtime. The runtime serialises back to what the author wrote.
The LM streams into the runtime and the runtime is markdown going
the other direction. That's the LISP property in a UI context.

## What's queued for next session

- **Phase E — text intrusion.** Markdown wraps around an SVG
  figure. The most visually delightful win on the deferred list,
  and the one that needs `ExclusionShape` plus a separate-pass
  layer over settled solver positions.
- **Phase D — solver-input channel.** `:::slider →
  solver.suggestValue` on a constraint-bearing target. The
  reactive layer already plumbs slider→state; this opens the
  edit-variable path that bypasses re-resolve. Phase B/C of the
  substrate plan converge here.
- **Phase C.3 — measure pass.** The real fix for solver-driven
  sibling negotiation in `:::flex` / `:::grid`. Every layout-aware
  element gains a measure protocol so the solver can negotiate
  positions before render. Bigger lift, ~400 LOC + careful
  testing.
- **Richer grid still possible** — cell-spanning (`row-span` /
  `col-span`), `auto` track widths sized to content, named
  tracks. None of these are blocking; all are bounded next
  moves.

## What didn't happen (and that's the point)

- The race fix did NOT panic when the stack trace landed. The
  root cause was identifiable from the bottom-up — `walkOneJob`
  is parallel, the solver is shared, ergo race. The fix matched
  the cause: lock the shared state across the full critical
  section. 19 lines, one commit, ship.
- The richer grid did NOT touch the layout walker. The whole
  `1fr` / track-list / axis-split-gap work landed entirely
  inside `grid.zig`. The walker doesn't know columns are mixed
  now. That's because the column-vs-cell contract is local to
  the grid provider — `Constraints.max_w` is the channel, and
  it's the same channel `:::box` already reads. New behaviour,
  no protocol change.
- We did NOT prematurely add cell-spanning or named tracks.
  Both are valid CSS-grid features. Neither has a callsite in
  the current demo. They'll land when they earn it.
- We did NOT carry over a per-grid arena allocation for the
  track list. Inline `[MAX_TRACKS=32]` is 256 bytes per grid
  instance, no allocation, no churn across `update()`. The
  cheapest possible representation for the bounded case.

## Closing thought

Session 9 said *make the substrate hold up under load*.
Session 10 said *make the substrate look right at any scale*.
Session 11 said *make the substrate negotiate*.
Session 12 said *make the substrate compose*.
Session 13 says *make the substrate **arrange*** — and watch the
arrangement self-describe.

Before today, the demo could compose: flex children negotiating
their bounds against the same kiwi solver, embedded documents
resolving recursively through the same registry. After today,
the demo arranges in two dimensions, in mixed track widths,
across thread boundaries, with the solver consulted under a lock
that wasn't needed yesterday and may not be needed tomorrow once
the measure pass lands. And the whole thing remains a 200-line
markdown file an author could type by hand.

> *And the markdown said: let the grid hold three columns — one
> fixed at 180 pixels, two flexing to share what's left — and let
> the sidebar hold its width while the panels negotiated for the
> remainder. And the solver settled. And the cells rendered side
> by side, cyan and magenta and orange. And the substrate
> arranged. And when the window resized, the worker threads raced
> for the solver, and the mutex held, and the document kept
> rendering. And it was good.*
>
> — somewhere in the Encyclopaedia Galactica, mid session 13

The LISP for collaborative documents, partner. Highly improbable.
Catch you next session — same Heart of Gold, fresh petunias, the
substrate that holds up under load *and* looks right at any scale
*and* negotiates *and* composes *and* arranges itself in two
dimensions across worker threads without breaking a sweat.
🐢🐬🌸☕🚀
