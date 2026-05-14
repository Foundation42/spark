# text_engine — session 5 journey
2026-05-14 (Thursday — same day as 1-4)

The fast lane.

Session 4 closed with the live-document substrate complete: parse →
registry → cache → frontmatter state → reactivity → input → first
two concrete components. The reactive subscriber path (state.set →
Binding.refire → factory.update) was already running, validated by
two sliders driving box geometry. What was missing was the **wire
format** that path was built to be driven *from*: a way for an LLM
(or any outside producer) to push deltas in as bytes, not as Zig
calls.

That's stage 8a.

## The two dispatch paths

The session-3 vision pitched one shape for streaming updates:

```markdown
:::update {#id action=NAME}
BODY
:::
```

Routes the body to the cached component instance's
`handle_update` handler. Reuses the registry's id-keyed cache from
7b — `#id` lookup is the entire dispatch. No cmark, no Element
walker, no layout. New `Factory.handle_update` vtable slot;
components opt in.

Designing it I realised there's a second, complementary shape that
falls naturally out of the existing reactive plumbing:

```markdown
:::update {target=state.box_color}
red
:::
```

Routes to `state.set("box_color", "red")` directly. The 7e reactive
substrate handles the rest — `Binding.refire` re-substitutes
templated attrs on every subscriber, `factory.update` runs, the
component picks up the new value.

These aren't competing — they're complementary:

- **Component-target** is for *opaque streaming payloads*. Chart
  samples, log lines, raw bytes that don't fit a flat key→string
  state map. The component owns the data; updates are append-only
  or domain-specific.
- **State-target** is for *declarative scalar mutations*. The LLM
  doesn't need to know the component exists — it just nudges a
  state value, and any component bound to that path picks it up.
  Same dispatch path the slider already uses.

I almost forced everything through component-target ("just one
path"), then realised that would make the LLM responsible for
knowing every component's id + action vocabulary just to set a
colour. State-target keeps the simple case simple. Both paths land
through one parser + one dispatcher; the dispatch decision is "id
or target?" at runtime.

## Component-target conflicts with templated attrs

Pitfall I hit while wiring the demo: I wanted to drive
`color` via component-target updates as the visible proof. But the
box's color attr in demo.md is `${state.box_color}` — templated.
The box has a reactive Binding subscribed to `state.box_color`.

What happens with component-target on a templated component:

1. `:::update {#bx action=set-color}\nred\n:::` arrives.
2. `factory.handle_update` fires. `c.color` mutates to red. ✅
3. Anything else fires `state.set` later (e.g., a slider drag on
   radius). The Binding for `box_color` is still subscribed to its
   path; the registry's binding callback re-substitutes *all*
   templated attrs from current state and calls `factory.update`.
4. `factory.update` rebuilds `c` from the spec — and the spec still
   has `${state.box_color}` resolved to whatever `state.box_color`
   actually is (still "blue"). Our red gets stomped.

The fix is design clarity, not code: **component-target updates
are for *non-templated* components**. Or for templated components
where the action targets a field that *isn't* in the templated set
(a hypothetical `border-color` attr the demo didn't expose).

For the visible demo I switched to state-target — same end result
(box recolours every 1.5s), no fight with the binding, and it
exercises the wire format's most common shape. Component-target
gets full unit-test coverage and waits for `:::chart` (stage 8b)
where it's the only sensible path.

This conflict is documented in box.zig's `handleUpdate` doc
comment so the next person who hits it doesn't have to rederive it.

## The implementation arc

The changes were small, in dependency order:

### `component.zig` — vtable slot + dispatcher

Added an optional fourth field on `Factory`:

```zig
handle_update: ?*const fn(ctx, action, body) anyerror!void = null,
```

Added two new error variants to `Registry.Error`:
`UnknownComponentId`, `NoUpdateHandler`. Added two public methods:

```zig
pub fn lookup(self, id) ?Resolved
pub fn handleUpdate(self, id, action, body) anyerror!void
```

`handleUpdate` looks up the entry by exact id (not `auto:N` — those
are tree-position synthetic; updates target author-stable ids),
fetches the factory by name, calls the handler. Errors propagate
naturally because `try handler(...)` returns `anyerror`, so the
method's return type is `anyerror!void` rather than a narrower
named set.

One sub-decision: `handleUpdate` does *not* touch `parses_unused`.
Update lifecycle is intentionally orthogonal to parse lifecycle. If
the document stops referencing a component, the next gc() sweeps
it and subsequent updates fall through with `UnknownComponentId` —
which is correct: the doc no longer wants this component, the
updates are moot.

### `update.zig` — parser + applyAll

Two main functions:

```zig
pub fn parseUpdate(arena, source) → ?ParsedUpdate
pub fn applyAll(arena, state, registry, source) → usize
```

`parseUpdate` is a stripped-down version of `markdown_components.
preprocess` that only knows about one block shape: `:::update`.
Skips leading whitespace, validates the open line is `:::update`
plus attrs, reuses `parseDirectiveLine` for the attribute parse,
scans for the close `:::`, trims the body. Returns the parsed
Spec + a `consumed` byte count so `applyAll` can loop over multiple
updates in one buffer.

`applyUpdate` is the dispatch decision:

```zig
if (spec.id) |id| {
    // Component-target
    const action = findAttr(spec.attrs, "action") orelse return error.MissingAction;
    try registry.handleUpdate(id, action, spec.body);
    state.dirty = true; // explicit; component may have mutated only opaque state
} else if (findAttr(spec.attrs, "target")) |target| {
    // State-target
    const key = strip "state." prefix optionally
    try state.set(key, spec.body); // already sets dirty
}
```

Two pieces of small mechanism that matter:

1. **`state.dirty = true` after component dispatch.** A component
   might mutate only its own opaque state; the renderer's re-layout
   trigger keys off `state.dirty`. Without this, component-target
   updates would land but not redraw until the next state-target
   update or input event. (`state.set` already sets dirty, so the
   state-target path gets it for free.)

2. **The `state.` prefix on `target` is optional.** Same rule as
   `${state.x}` / `${x}` in `parseDirectiveLine` (stage 7d). The
   vision examples lean on the prefixed form; tolerating both
   costs nothing.

### `components/box.zig` — opt in

The box gained:

```zig
fn handleUpdate(ctx, action, body) anyerror!void {
    if (action == "set-color") parseColor + assign
    else if (action == "set-radius") parseLength + assign
    else if (action == "set-width") ...
    else if (action == "set-height") ...
    // Unknown action: silent no-op
}
```

The same `parseColor` / `parseLength` helpers from 7c are reused —
the input format is identical (named colors, hex, pixels, percent).
Unknown actions silently no-op at this stage; structured logging
is the next refinement.

### `main.zig` — the visible demo loop

A single shared `update_arena` lives across the program lifetime;
each cycle resets it via `reset(.retain_capacity)`. The
steady-state allocation cost is zero — the arena pages stay
populated.

```zig
var update_arena = std.heap.ArenaAllocator.init(allocator);
const cycle_colors = [_][]const u8{ "blue", "purple", "cyan", "green", "orange" };
var color_idx: usize = 0;
var last_update_ms = std.time.milliTimestamp();

while (!window.shouldClose()) {
    // ... existing per-frame work ...
    const now_ms = std.time.milliTimestamp();
    if (now_ms - last_update_ms >= UPDATE_CYCLE_MS) {
        color_idx = (color_idx + 1) % cycle_colors.len;
        const directive = std.fmt.bufPrint(&buf,
            \\:::update {{target=state.box_color}}
            \\{s}
            \\:::
        , .{cycle_colors[color_idx]}) catch unreachable;
        _ = update.applyAll(update_arena.allocator(), &host_state, &registry, directive) catch 0;
        _ = update_arena.reset(.retain_capacity);
        last_update_ms = now_ms;
    }
}
```

Smoke run: 53,366 frames in 4 seconds → 13,341 fps Release, 2
updates dispatched. Same baseline as session 4 close. The wire
format pays for itself in clarity, not cost.

## What's queued

The roadmap split stage 8 into 8a (this) + 8b (`:::chart`). 8b is
the visceral 15k-fps streaming demo the component-target path was
designed for — it'll wire `Factory.handle_update` to a ring buffer
of samples, with a sine-plus-noise data source initially and a
streaming-text adapter later. 8b is the next clean entry point.

The parallel composition track (stages 9–11) is also unblocked —
documents-as-components, headless documents, remote sources. Those
slot in cleanly because the `Factory` shape stays provenance-
agnostic (see `memory/project_component_provenance.md`).

## Stage 8b — `:::chart` streaming showcase

The visceral demo for component-target dispatch. A real streaming
component, real data flowing through `Factory.handle_update`, no
state Binding in the way.

### Design choices

**Ring buffer, not an ArrayList.** The chart's steady-state cost is
append. Append-with-occasional-realloc has a long tail; append-into-
ring-buffer is O(1) with zero allocation after `create`. At 60 Hz
the difference doesn't matter; at 13k Hz (one append per frame) the
ArrayList would start showing memmove pauses.

**Filled columns, not connected lines.** Each sample renders as a
thin vertical quad anchored at the chart's bottom edge. Line charts
need rotated geometry which the rounded-quad pipeline doesn't have
yet; columns are axis-aligned so the existing pipeline carries
them. Visually the column sparkline reads like a histogram /
"audio waveform" — appropriate for the demo's signal-with-noise
synthetic data.

**No state binding.** Chart attrs (min/max/width/height/color) are
static-at-author-time by design; the data lives entirely in the
component's opaque ring buffer. So the chart runs *without* a
`Binding` allocated by the registry — no `${state.x}` references
means `collectReferencedPaths` returns empty and the binding step
is skipped. The 8a pitfall (component-target updates fighting
templated attrs) doesn't apply because there's nothing to fight.

This is the architecturally correct shape for streaming components:
state for declarative scalars, opaque-handler for streamed payloads.
The two paths complement each other.

### Synthetic data source

In `main.zig`:

```zig
const CHART_TICK_MS: i64 = 16;  // 60 Hz
var last_chart_ms = std.time.milliTimestamp();
var chart_phase: f32 = 0;
var chart_rng = std.Random.DefaultPrng.init(0xC04EE);

// In the main loop:
if (now_ms - last_chart_ms >= CHART_TICK_MS) {
    chart_phase += 0.06;
    const base = std.math.sin(chart_phase);
    const harmonic = 0.40 * std.math.sin(chart_phase * 3.1);
    const detail = 0.18 * std.math.sin(chart_phase * 7.7);
    const noise = (chart_rng.random().float(f32) - 0.5) * 0.15;
    const sample = std.math.clamp(base * 0.6 + harmonic + detail + noise, -1.0, 1.0);

    var buf: [128]u8 = undefined;
    const directive = std.fmt.bufPrint(&buf,
        \\:::update {{#telemetry action=append}}
        \\{d:.4}
        \\:::
    , .{sample}) catch unreachable;
    _ = update.applyAll(update_arena.allocator(), &host_state, &registry, directive) catch 0;
    _ = update_arena.reset(.retain_capacity);
    last_chart_ms = now_ms;
}
```

Three sines at different frequencies plus noise — looks more like
real data than a pure sine would. The seed 0xC04EE keeps runs
reproducible.

### Numbers

4-second smoke run, Release, 1280×720:

- **48,101 frames** = 12,025 fps.
- **241 updates dispatched** through the wire format (240 expected
  at 60 Hz / 4 s, plus 1 colour-cycle update — accounting matches).
- **144 quads** total (1 chart bg + ~127 columns + box + sliders +
  chrome). Cache hit rate jumped to 99.9% because the chart adds
  quad work, not glyph work.

The 13.3k → 12.0k drop is `state.dirty` triggering full document
re-layout on every chart append. That's the cost of routing through
the unified reactive substrate; for a 60-Hz feed it's acceptable.
For the eventual >1 kHz feeds we'll want a retained-layout cache
that only re-walks elements whose ctx changed — bumped to
"parallel — active watch" priority on the roadmap.

### Lesson re-confirmed: separation of concerns is cheap to add later

The fact that 8b needed *zero* changes to the wire-format code in
`update.zig` is the design payoff. The chart is just a factory.
Future components — 3D scenes, charts of charts, ML inferred
visualisations — slot in the same way: register a factory,
optionally implement `handle_update`, done.

The substrate is doing what the vision asked it to do.

## Patterns from session 4 that paid off

Three habits from the previous session carried over and made this
one fast:

1. **Single test entry point at `src/tests.zig`.** New file →
   one-line addition → `zig build test` covers it. Took ~5 seconds
   to wire `update.zig` (and later `chart.zig`) into the test build.
2. **Arena-first allocation policy.** `applyAll` takes an arena,
   doesn't worry about per-update churn. The host's single-arena-
   with-reset pattern just works — and worked again for 8b's 60 Hz
   feed without any change.
3. **Stage-by-stage commits with clear deliverables.** 8a → 8b is
   a one-stage delta. Each commit is reversible. Builds confidence
   the contract holds.

## Stage 9 — `:::embedded-document`

The composition flywheel. Documents that contain whole other
documents. Christian's pitch from end of session 4 ("documents are
components, recursively, with headless variants and a network-effect
substrate") becomes real here.

### The shape

```markdown
:::embedded-document {#orbit src="src/widgets/orbit_panel.md" panel_color=cyan inner_color=magenta}
:::
```

A built-in factory. The host reads the file, parses it through a
new `markdown.parseWithStateAndScope` that takes a fresh child
`State` and a *scope* prefix, grafts the resulting Element subtree
into the parent's layout, and tracks the child instances under the
shared registry — namespaced so they can't collide with anything
parent-level.

### The three pieces of plumbing

**1. Scope-prefixed cache keys (component.zig).**
`Registry.resolve` grew an optional fifth parameter
`scope: ?[]const u8`. When non-null, the cached instance's key is
`"{scope}/{id_or_auto:N}"` instead of the bare `id`. So a child's
`:::box {#bx}` resolves to `"orbit/bx"` while the parent's
`:::box {#bx}` is just `"bx"`. No collision. Same registry, two
distinct slots.

The auto:N path scopes too: `:::box` (no id) inside the embedded
doc becomes `"orbit/auto:0"`, the parent's anonymous box stays at
`"auto:0"`. So even author-anonymous components in nested docs
survive co-existence.

**2. The parent-state dirty bubble (state.zig).**
`State` grew a `parent: ?*State = null` field. `set` walks up the
parent chain flipping `dirty` so when a child-state mutation fires
inside an embedded doc — via a slider, a `:::update`, or a
Binding.refire — the host's renderer (which only watches the
*root* state) still wakes up.

Subscriber firing stays local to each State. The bubble is *only*
about waking the renderer. No spurious refires across documents.

**3. `Registry.deinitScope(prefix)`.**
When the embedded doc itself gets gc'd, its child components need
to die *before* their bindings' subscribed-to state does. The new
`deinitScope` walks the registry, picks every instance key
matching `"{prefix}/..."`, destroys each one (calling
`Binding.destroy` for any reactive plumbing along the way), and
unsubscribes them from child state. Then the factory.deinit can
free child state safely.

The ordering matters: child instances first, child state second,
child arena (Element tree) third, Component struct last. Bindings
hold pointers into child state; reversing the order is a use-
after-free in waiting.

### `markdown.parseWithStateAndScope`

The new public entry point. `parseWithState` calls it with
`scope = null` (the top-level path); embedded-doc factory.create
calls it with `scope = spec.id`. They share an internal helper
`parseInternal` to keep behaviour consistent.

The only extra subtlety: `beginParse` only runs at the top-level
parse, not on nested embedded parses. Nested parses are happening
*inside* the parent's parse cycle — they shouldn't reset the
parent's `parses_unused` counters. Conditional on `scope == null`.

### The module-globals smell

`Factory.create` takes `(allocator, spec)`. It doesn't see theme,
registry, or parent state — but the embedded-doc factory needs
all three to call `parseWithStateAndScope`. v0 workaround:
module-level globals in `embedded_document.zig`, captured by an
`install(registry, theme, parent_state)` helper the host calls in
place of `registry.register("embedded-document", ...)`.

The long-term fix is either a per-factory config pointer baked
into the `Factory` struct, or a `*Host` context threaded through
`Factory.create`'s signature. Both are deferred because:

- the smell is isolated to one file,
- contract-changing every Factory for one feature is a steeper
  price than this localised global,
- the right shape is unclear until a second factory ever needs
  similar context.

Noted in this writeup, the source file, and the project memory so
we don't forget to revisit.

### The widget file

`src/widgets/orbit_panel.md` — a self-contained mini-document:

```markdown
---
state:
  panel_color: orange
  panel_height: 60
  inner_color: yellow
  inner_radius: 6
---

A nested document. Frontmatter values become the child state...

:::box {#outer color=${state.panel_color} width=100% height=${state.panel_height} radius=10}
:::

:::box {#inner color=${state.inner_color} width=60% height=28 radius=${state.inner_radius}}
:::
```

Two boxes pulling their colours and dimensions from child state.
Parent overlays in `demo.md` say `panel_color=cyan inner_color=magenta`
so the rendered output is **cyan-on-magenta** — not the orange-on-
yellow the widget's own frontmatter defaults to. Visible proof that
parent attrs win over child frontmatter.

### What the demo renders

The parent doc gets a new "Composition (stage 9)" section that
embeds the widget. Visually below the chart, above the ANSI fixture:

- Parent prose ("The block below is a *whole other document*...")
- The widget's prose ("A nested document. Frontmatter values...")
- A cyan rounded box (the outer panel, full width)
- A magenta rounded box (the inner panel, 60% width)
- More widget prose ("These two `:::box` components...")
- Continues into the chart + ANSI

The widget's components share the parent's quad pipeline, glyph
atlas, font registry. There's no second renderer, no second
GPU pipeline. Just one substrate, recursive.

### Limitations v0 ships with

Captured on the roadmap, repeated here so they're visible from one
place when you pick this up next time:

- **Interactive components inside embedded docs route input to
  parent state.** The walker stamps the root state pointer onto
  every Hit; embedded sliders would mutate the wrong state. Fix
  needs `LayoutCtx` and `Hit` to carry an optional state pointer.
- **External `:::update` directives can't target scoped components.**
  `:::update {#bx ...}` from outside always hits the parent-scope
  `bx`. Future: `id="scope/leaf"` syntax or `scope=` attr.
- **`src=` is a CWD-relative path.** No base-dir resolution, no
  URLs (stage 11), no content-hash cache.
- **`src` changes on a live embed are ignored by `update`.** Author
  changes the `#id` to force destroy + recreate.

### Performance footprint

11.2k fps Release with everything from 8a + 8b + 9 all active:
- 1.5s box colour cycle (state-target update)
- 60 Hz chart feed (component-target update)
- Embedded doc with two reactive boxes
- Plus all the original markdown + ANSI + SDF content

1691 glyphs (up from 1155 in 8b — the widget's prose adds ~536),
144 quads (unchanged — the new boxes replaced the 3d-scene
placeholder which also drew 2 quads), 100.0% cache hit rate. The
0.8k fps drop from 8b is the embedded doc's extra layout + text
shaping work. Cheap.

## What ships at session 5 close

Stages 8a, 8b, *and* 9. The wire format, the streaming component,
and the composition flywheel — three of the four pieces from
session 4's vision close. Headless docs (stage 10) and remote
sources (stage 11) round out the composition track; the retained
layout cache parallels the perf reclaim.

~10,200 LOC, 70 unit tests passing, ~11.2k fps Release.

The substrate is recursive, streaming, and live.

Next entry points (in order of expected payoff):

1. **Stage 10 — headless documents.** Pure state-machine docs with
   no viewport. Cleanest split from stage 9: the existing parse
   pipeline runs minus `layoutAndRender`. State lives, subscribers
   fire. Other docs subscribe to its paths.
2. **Stage 11 — remote sources.** URL loaders for `:::embedded-document`.
   Local-first, content-hash cache, offline fallback.
3. **Retained layout cache.** Reclaims the 8b + 9 perf cost.
4. **Plumbing for embedded-doc input handling.** When someone wants
   a `:::slider` inside an embedded doc.
