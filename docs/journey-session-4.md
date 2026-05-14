# text_engine — session 4 journey
2026-05-14 (Thursday, continuing from sessions 1-3 same day)

How a text renderer became a live-document runtime in one
sitting. Six stages shipped, the contract held through every one,
and by session's end the vision widened again — from "live
components in a markdown document" to "documents as components,
recursively, with headless variants and a network-effect
flywheel."

## Where we started

End of session 3 the vision crystallised but the substrate didn't
exist yet. `:::name {attrs}` was a sketch in `docs/vision.md`. The
demo rendered markdown with chrome and an ANSI fixture beautifully,
but every `:::` block in the source — if you'd written one —
would have been ignored. Session 4's job was to make the vision
real, stage by stage.

The path locked in at session-3 close:

1. **7a** — block extension parser (`:::name {attrs}` →
   `custom` Element via the registry).
2. **7b** — component registry + persistent cache.
3. **7c** — first concrete component.
4. **7d → 7e** — frontmatter state, then reactivity.
5. **7f** — input.
6. **8** — `:::update` micro-stream fast path (deferred).

Six commits later all of 1–5 had shipped.

## Stage 7a — block extension parser

The architectural question was *where* to recognise `:::`. cmark
doesn't have any concept of fenced divs. Three approaches were
on the table:

1. Walk cmark's output after the fact, detect `:::` lines
   inside paragraphs, reconstruct block boundaries.
2. Vendor cmark-gfm extension mechanism.
3. Pre-scan the source ourselves, extract `:::` blocks before
   cmark sees them, replace with a sentinel cmark passes through.

Option 1 is fragile — cmark's paragraph grouping splits `:::`
lines across nodes depending on blank-line layout. We'd be
fighting cmark's rules to reconstruct what we already know.

Option 3 wins on robustness: we own the `:::` lexer ourselves.
`markdown_components.preprocess` scans the source line by line,
finds opens (`:::name {...}` followed by a body and a `:::`
close), extracts each block to a sidecar `Spec` slice, and
replaces the byte range with `<!--te:N-->` — an HTML comment
cmark routes through verbatim as `CMARK_NODE_HTML_BLOCK`.

The mapper's existing HTML_BLOCK arm intercepts the sentinel,
matches `<!--te:N-->`, looks up Spec N in the sidecar, and emits
a `custom` Element. cmark stays untouched.

One bug surfaced and got fixed in-stage: `:::3d-scene` didn't
parse because `isIdentStart` rejected the leading `3`. Directive
names are tag-like, not programming identifiers — letters,
digits, and dashes are all fine. Added an `isNameStart` that
allows digit-leading, kept keys/ids on the stricter letter-
leading rule.

Stage 7a's deliverable was the parser + a placeholder vtable
that renders `missing component: NAME` as a red-bordered panel.
Three `:::` fixtures in `demo.md` (`:::box`, `:::3d-scene`,
`:::chart`) all flowed through and rendered as placeholders —
exactly the intended "registry exists, no factories yet" state.

## Stage 7b — registry + persistent cache

The runtime layer above the parser. `Factory { create, update?,
deinit? }` lets a host register factories per directive name;
`Registry { register, beginParse, resolve, gc }` owns the
factories + the instance cache.

Three design decisions baked in:

- **Order-based auto-IDs.** A Spec without `#id` is cached under
  `auto:N` where N is the sentinel index. Position-in-tree IDs
  (parent's ID + sibling index) survive structural reorders
  better but cost a tree-walk. For 7b the simpler order-based
  scheme suffices; revisit when an LLM is reordering blocks in
  real time.
- **Lifecycle = `parses_unused` counter + explicit `gc()`.**
  `beginParse` bumps every instance's counter at the top of a
  parse. `resolve` resets to 0 on cache hit (touched).
  `gc()` (called by the host after the new tree replaces the
  old one) destroys instances over `sweep_threshold` consecutive
  unused parses. Default threshold 4. The `gc` is explicit so
  the host can coordinate it against tree-pointer swap.
- **Factory `update` is optional.** Components that don't care
  about attr changes between parses leave it null.

Visible result at 7b: nothing. No factories registered means
every `:::` still hits the placeholder. The infrastructure is
dormant, ready for 7c.

## Stage 7c — first concrete component (`:::box`)

`src/components/box.zig`. Parses `color` (named or `#RGB` /
`#RRGGBB` / `#RRGGBBAA` hex), `width`/`height` (px or %), and
`radius` from `Spec.attrs`. Emits one rounded quad through the
existing quad pipeline. Missing-or-invalid color falls back to
opaque magenta so the author sees the typo immediately.

Test infrastructure incident: in-source `test { }` blocks in
subdirectory files (`src/components/box.zig`) couldn't reach
sibling modules through `../element.zig` — Zig's module-root
guard rejected the upward import when box.zig was its own test
root.

Fix: a single test entry point at `src/tests.zig` referencing
every test-bearing file via `_ = @import(...)`. Module root for
the test build becomes `src/`, so `../`-style relative imports
from subdirectory test files resolve cleanly. One `addTest` step
in `build.zig` now drives the whole library's tests.

Christian flagged that the red `:::box` looked too much like
another error placeholder. Demo's box is blue now. One-line fix
in `demo.md`; ran the contract loud and clear.

## Stage 7d — frontmatter state + static `${path}` interpolation

`src/state.zig` introduces `State` (a flat string→string map)
and `parseFrontmatter` (a hand-rolled YAML subset that lifts
`state: { key: value }` pairs at one indent level, with comments
+ quoted strings). `markdown.parseWithState` peels `---` ...
`---` off the source head, parses the inside into a temporary
State, and threads it down to attribute substitution.

Two scanner gotchas surfaced:

- Bare-value attribute scanner originally treated `}` as a
  terminator, so `color=${state.box_color}` truncated at the
  template's own closing brace. Fixed by making the scanner
  `${...}`-aware: depth-track on `${`, ignore `}` until depth
  returns to zero.
- Christian's directive `:::3d-scene` named with a digit-leading
  identifier — addressed back in 7a but worth re-flagging: the
  vision examples lean on tag-like names, not programming
  identifiers. We should expect more of these.

Demo's `:::box` block now sources `color`, `width`, `radius`,
and `height` from frontmatter via `${state.x}`. Editing the YAML
and rebuilding flows the new values through; visual output is
unchanged because the new values happen to match the literals
they replaced.

Unresolved `${path}` leaves the literal in place — louder than
silent emptiness, easier for authors / LLMs to notice typos.

## Stage 7e — reactive state

The "static interpolation" half from 7d makes editing easy but
doesn't react to mutations at runtime. 7e closes that gap:

- `State.subscribe(path, callback, ctx)` — heap-allocates a
  `Subscriber` for pointer stability.
- `State.set(path, value)` — sets + walks subscribers for that
  exact path + flips `state.dirty` so the host knows to relay
  out.
- `State.unsubscribe(sub)` — soft-delete (sets `active=false`).
  Peer subscribers' pointers stay valid mid-fire; no list
  compaction needed for 7e.

A key shape decision flipped here. Through stages 7a–7d,
`preprocess` substituted `${}` references inline so Spec.attrs
came out resolved. For reactivity we need the **templated**
form available for re-substitution. Two options:

A. Spec carries both `attrs` (substituted) and `attrs_templated`
   (raw).
B. `preprocess` doesn't substitute. The registry substitutes
   internally at resolve time, has the template ready for later
   re-substitution.

B is cleaner. Refactored: `preprocess` always passes `null`
state through to `parseDirectiveLine`, so `Spec.attrs` are
**templated** (with `${path}` literals). At
`registry.resolve(spec, sentinel_idx, state)`, the registry
substitutes attrs into a scratch arena and hands a fresh Spec to
factory.create / factory.update. If any attr references `${}`,
the registry also dupes the templated form into its own
allocator and registers a `Binding` — one per directive instance,
holding the templated attrs + subscriptions for each referenced
path. The Subscriber callback re-substitutes against current
state and calls factory.update with a fresh Spec.

Test factory lifetime gotcha along the way: the test factory
originally stored `Spec.attrs[i].value` as a raw pointer. After
the registry started substituting into a *scratch* arena that
got freed after `create` returned, those pointers dangled. Real
components (like `:::box`) parse values into owned state at
create time (`parseColor → [4]f32`) so they're unaffected; the
test factory now follows the same pattern and dupes the string.
Important note for future component authors: **components must
own anything they want to retain past `create` returning**. The
substituted Spec is scratch-arena-allocated by design.

Demo: drawCb cycles `box_color` through blue / green / orange /
purple / cyan every 1.5 seconds via `state.set`. The registry's
Binding subscriber fires factory.update on the cached `:::box`
instance, the box re-reads its color, `state.dirty` flips, the
next frame's drawCb re-runs layout, and the quad pipeline picks
up the new colour. ~13.3k fps Release through the cycle.

## Stage 7f — input handling, the loop closes

The vision-level moment. State has been the integration point for
everything so far; input is how humans get into the loop.

Three additions:

- **`ElementVTable.on_input`** — optional callback receiving the
  ctx, the event, and the host's `*State` opaque pointer. Most
  elements leave it null and never appear in hit-tests.
- **`DrawList.hits`** — a flat list of `Hit { box, vtable, ctx }`
  entries appended during layout for interactive elements only.
  Walked in reverse so the deepest hit wins.
- **`InputEvent`** — closed union over `mouse_down` / `mouse_up`
  / `mouse_move`. `MouseEvent.button_down` doubles `mouse_move`
  as a drag channel without a separate event kind.

`main.zig` polls glfw cursor + button state each frame, diffs
against the previous frame, and dispatches with **pointer
capture**: whichever hit received `mouse_down` keeps receiving
`mouse_move` + `mouse_up` until release, regardless of where the
cursor wanders. Without capture, drags break the moment the
cursor exits the thumb's box — the standard fix for that
standard problem.

`src/components/slider.zig` is the first interactive component.
Track + filled-track + thumb quads (so the slider reads as
"this much of the range is selected" at a glance). Drag computes
normalised position from the cursor's local x, formats with
`{d:.2}` precision, and calls `state.set(target_path,
formatted)`. The reactive substrate from 7e then routes that
mutation back through the registry's Binding subscriber to
whichever component reads `${state.target}`.

Demo: two sliders. One drives `box_radius`, the other drives
`box_height`. Drag either → the box's geometry updates live at
~13.3k fps. The full loop runs end-to-end without re-parsing
markdown: input → state.set → registry binding → factory.update
→ re-layout → quad upload.

The loop is closed. **The Guide is alive.**

## And then the vision widened again

Christian's end-session reflection, after watching the box react
to slider drags:

> Just think, these documents can compose as well. An AI or
> Human can create documents that are components themselves
> that get registered locally or in remote component stores...
> No HTML nonsense, no JavaScript hydration. Just collaborative
> documents flowing and interacting with each other (yes,
> headless documents, local or remote are a thing too!) as
> free as the wind and data itself.

The pattern:

- A `:::embedded-document {src=...}` directive loads another
  markdown file as a component. Recursive composition without
  code bloat.
- Headless documents (no visual layout pass) serve as state
  machines, configuration managers, data routers. Other
  documents query their state via fast in-process pointers.
- Network effect: every new document adds logic, data streams,
  or shaders the rest of the substrate can borrow. The substrate
  gets richer every minute.

Full pitch in `docs/vision.md` under "Document composition + the
flywheel." Notably: this expansion ALSO requires zero contract
changes. `:::embedded-document` is one more factory; headless
mode is a state-engine policy; the network effect is just what
happens when the substrate is plain markdown + a registry. The
contract from session 2 keeps paying back.

Component-provenance ladder ([[project-component-provenance]],
saved mid-session) and document-composition flywheel
([[project-document-composition]], saved end-of-session) are now
the two governing visions for "where components come from."

## State at session 4 end

- **Stages 7a / 7b / 7c / 7d / 7e / 7f shipped.** Block
  extension parser, registry + cache, first concrete component,
  static state interpolation, reactive state, input handling.
- **6 commits, ~2,700 LOC of our own code**, 43 unit tests
  passing through a single `src/tests.zig` entry point.
- **Demo:** the full loop runs at ~13k fps Release. Drag a
  slider → the box reacts. Resize the window → the document
  reflows. ANSI fixture, code-block chrome, link underlines,
  SDF "ATTENTION" rainbow all still rendering correctly.
- **The substrate is real.** Markdown is a living UI runtime.

## What we learned

- **The contract keeps paying back, again.** Six stages this
  session, each filled a slot the contract already had:
  `custom { vtable, ctx }` was where every component plugs in;
  `DrawList.quads` was where chrome (and now slider tracks /
  thumbs) emit; `LayoutCtx` was the host-provided everything-
  you-need bundle. The walker didn't grow a single new
  variant. The next vision leap (documents-as-components)
  needs no contract changes either.

- **Refactor when the slot's shape was wrong.** Through stages
  7a–7d, preprocess substituted `${}` references inline because
  that was the simplest pipeline. At 7e the reactive use-case
  forced the templated form to live elsewhere; we refactored
  preprocess to *not* substitute, moved substitution into the
  registry. Cost was modest because the contract didn't care
  which side did the substitution. The fix landed cleanly.

- **Components must own anything they want to retain.** The
  registry hands factories a *scratch-arena* substituted Spec
  on every call. Components that need to keep a string past
  `create` returning must dupe into their own allocator. The
  test factory tripped on this once; documenting the pattern
  now so future component authors don't.

- **Pointer capture is the bug-free drag pattern.** A naive
  hit-test on every mouse_move loses drags the instant the
  cursor exits the thumb. Capturing on `mouse_down` + routing
  subsequent events to the captured hit regardless of
  containment is the boring-and-correct fix. Standard pattern
  worth lifting from web UI history.

- **Vision keeps expanding as the substrate gets real.**
  Session 2's "Dear ImGui tomorrow" became session 3's
  "live-document runtime." Session 4's substrate-is-built
  realisation became "documents-as-components, recursive,
  headless, networked." Each expansion is a strictly stronger
  version of what came before, requiring strictly less new
  contract work. The substrate ate the vision.

## Pretty wild stretch (still)

All four sessions on the same Thursday now. Session 1 built the
rendering plumbing. Session 2 built the contract + markdown.
Session 3 built the chrome + ANSI + resize + crystallised the
live-document vision. Session 4 made the live-document vision
real and surfaced the next one.

Stage 8 (`:::update` micro-stream — LLM-streaming fast path,
bypass parse + layout entirely) is the natural next, alongside
`:::embedded-document` for the composition track. Fresh heads
will pick which one to chase first.

The Guide's first interactive entry is committed. Don't forget
your towel.
