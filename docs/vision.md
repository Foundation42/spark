# text_engine — vision: live documents

> Markdown isn't the document. It's the **declarative interface to a
> live, component-driven runtime** that an LLM (or human) writes,
> mutates, and streams updates into. Components are real
> Vulkan-native instances. State is reactive. Updates are targeted
> at memory pointers, not document re-layout.

Captured 2026-05-14, end of session 3. Crystallised after stages
1 through 6a shipped a working markdown renderer with quad chrome
+ resize reflow + an ANSI engine — at which point Christian's
framing of "what we're actually building" widened from
"Dear ImGui-style game UI tomorrow" (session 2) to this.

## The full pitch

A markdown document that *runs*. Block extensions instantiate
native Vulkan components; YAML frontmatter is reactive state;
template interpolation binds component attributes to state paths;
LLM-streamed micro-updates target specific component instances by
ID and skip document layout entirely.

Examples Christian sketched:

````markdown
# Orbit Optimization Report
The agent has compiled the asset metrics and physical simulation below.

:::3d-scene {#orbit-view width=100% height=400px}
src: "assets/sat_model.gltf"
animation: "orbital_drift"
shading: "pbr_metallic"
:::

### Telemetry Stream
Below is the real-time sensor array data synced from the model.

:::chart {#telemetry-plot type="line" x="time" y="velocity"}
time, velocity, temperature
00:01, 7400, 24.5
00:02, 7450, 24.8
00:03, 7510, 25.1
00:04, 7580, 25.2
:::

Use the slider in the canvas above to change simulation speed.
````

The AI streams a *targeted* micro-update at a specific component:

````markdown
:::update {#telemetry-plot action="append"}
00:05, 7620, 25.6
:::
````

> Engine Execution: Your parser intercepts the `:::update` tag.
> It skips the document text layout pass entirely. It pushes the
> new CSV row directly into the memory buffer of the
> `#telemetry-plot` chart component. The chart instantly redraws
> at 15,000 FPS.

And reactive frontmatter-as-state with `${}` bindings:

````markdown
---
state:
  sim_speed: 1.0
  target_id: "SAT-04"
---

:::3d-scene {#orbit-view}
src: "models/${state.target_id}.gltf"
speed: "${state.sim_speed}"
:::

:::chart {#telemetry-plot}
title: "Telemetry for ${state.target_id}"
:::
````

> The variables act as single-source-of-truth pointers. If a user
> drags a native Vulkan slider component inside the `#orbit-view`,
> your engine mutates `state.sim_speed` in memory. The chart
> immediately updates its title because it binds to the exact
> same memory pointer.

## How it maps to the contract we already have

Every architectural piece slotted into a contract decision we made
in earlier stages. The mapping isn't a retrofit — it's the design
finally being asked to do what we always anticipated:

| Vision concept | Contract slot |
|---|---|
| `:::name {attrs}` block | The `custom { vtable, ctx }` Element variant we put in `element.zig` at stage 1, **specifically** for this case. |
| Component registry | Host-provided `name → ComponentFactory` table. Markdown layer dispatches by directive name to produce `custom` elements. |
| Component identity (`#id`) | Persistent cache keyed by ID, survives relayouts. `custom.ctx` carries the cached instance. |
| YAML frontmatter + `${state.x}` | Reactive observable store + path-based interpolation in attribute values. |
| `:::update {#id action="append"}` | Bypass layout entirely — call the registered component's append handler. Whole point: zero text-pipeline cost. |
| LLM streams 15k fps deltas into a chart | `:::update` is a microsecond hot path that touches one component's SSBO and skips everything else. |
| Native widget inside a 3d-scene (slider) | The Dear ImGui-style game-UI hooks Christian flagged in session 2 — quad / line primitives from stage 4 + future input handling. |

## The architectural insight that makes this work

**Layout and live state are decoupled.**

- The Element walker (`element_layout.zig`) decides *where* a
  component lives on screen. It hands the component a `Box`. The
  walker doesn't know what's inside — that's the component's
  business.

- Live state mutates a component's own GPU buffers without touching
  layout. A `:::chart` instance owns its own VBO / SSBO / texture;
  `:::update` writes to those directly.

- An `:::update` micro-stream skips layout entirely because the
  component already knows where it is. We're not re-walking the
  Element tree; we're poking a buffer pointer.

That decoupling is what lets a chart render at 15,000 fps while
the document around it stays static. The text pipeline isn't
spending cycles on glyphs that haven't changed; the quad
pipeline isn't redrawing chrome that hasn't changed; the
component runs its own update loop at full speed.

The lineage is real. Stage 4's quad chrome decoupled
backgrounds from glyph emit. Stage 6a's resize reflow decoupled
layout-time from per-frame cost. Live components are the same
move, generalised: **only re-do work when the input that drove it
has changed**.

## Staging path

Six stages from the current state (markdown rendering + ANSI +
resize reflow) to the full live-documents runtime. Each one is a
focused commit; each adds a concrete capability while honouring
the contract.

### Stage 7a — block extension parser

`markdown.zig` recognises `:::name {attrs}\nbody\n:::` syntax.
Emits a `custom` Element with vtable pulled from a host-provided
registry, plus a `ctx` pointer to a cached component instance.

- cmark doesn't support `:::` blocks natively. Three options:
  pre-process the source replacing them with sentinel HTML blocks
  cmark will pass through; or walk cmark's paragraph output
  detecting leading `:::` lines; or use cmark-gfm's extension
  mechanism. Pragmatic: walk cmark's output — keeps the vendored
  cmark untouched.
- Attribute parser: simple `{#id key=val key="quoted val"}`
  tokenizer. Quote rules + escape rules deferred until content
  needs them.
- Components without a registered factory render a
  fallback "missing component: name" box — clear failure mode for
  authors / LLMs that get the directive name wrong.

### Stage 7b — component registry + persistent cache

Host registers factories; cache keyed by `#id` persists instances
across re-layouts. The `custom.ctx` pointer carries the cached
instance; the vtable's `layout_and_render` calls into it.

- Components without an `#id`: auto-generate a stable ID from
  position in the tree (parent's ID + sibling index). Stable across
  trivial document edits; not stable across structural reorders —
  but that's the right trade-off for stage 7b.
- Lifecycle: instantiated on first appearance; destroyed when
  removed from the tree for N consecutive layouts (deferred GC).
  Avoids thrashing on edits.

### Stage 7c — first concrete component

Pick something simple to prove the loop end-to-end. Candidates:

- **`:::box {color width height}`** — minimum viable component.
  Renders a coloured quad. Proves the entire pipeline: parse →
  registry → cached instance → layout returns Box → quad emit.
  ~50 LOC for the component implementation, then everything
  thereafter is "add more components."
- **`:::chart`** — more visually convincing, exercises the
  live-data path immediately. Heavier — needs a chart-rendering
  routine. But the right test for the vision.

Lean toward `:::box` first as the loop validator, then `:::chart`
as the next stage proving the live-data hot path.

### Stage 7d — frontmatter state + `${}` interpolation (static)

Parse YAML frontmatter into a flat map of path → value. Attribute
values containing `${state.x}` resolve at component construction
time. No mutation yet — static interpolation only.

- YAML parser: don't vendor one yet. The state subset we need is
  `key: value` pairs in a `state:` block. ~50 LOC of hand-rolled
  Zig will do; revisit if richer schemas (lists, nested maps)
  emerge.
- `${}` substitution: simple template engine. Path lookup, type
  coercion to string. Errors on undefined paths.

### Stage 7e — reactive state

State becomes observable. Bindings (component attribute values
with `${path}`) subscribe to paths. Mutations notify subscribers,
which re-evaluate.

- Reactive primitive: `State { values: map, subscribers: map<path, list<callback>> }`.
- `state.set(path, value)` walks subscribers for that path, calls each.
- Component-side: `binding.refresh()` re-evaluates the attribute
  expression and calls the component's setter.

Without user input this isn't visible, but it sets up the plumbing
for stage 7f.

### Stage 7f — input handling

Mouse events route through the laid-out Element tree by hit-test.
The Box every element returns is finally consumed. Component
handlers mutate state; reactive bindings refresh.

- Walker grows a parallel pass: `hitTest(point, root) → ?Element`.
- Per-component `onInput` callback in the vtable. Slider component
  registers handlers; on drag, mutates `state.sim_speed`.
- This is where the loop closes: drag a slider, chart title
  updates because both bind to the same path.

### Stage 8 — `:::update` micro-stream path

The bit that makes LLM-driven live documents feel real-time.

- Markdown layer recognises `:::update {#id action=...}` at parse
  time and routes it to a *handler* function on the target
  component — not as a renderable element.
- The micro-update bypasses cmark entirely for the body: just
  hands the raw text + action + target ID to the component.
- Component-specific append / set / delete handlers.
- The whole pipeline becomes: receive bytes → look up target by
  ID → push to its buffer → component schedules a redraw of its
  own region. No document-level layout, no text shaping, no
  cascade resolution. Microsecond hot path.

### Stages 9+ — real components

3D scene (integrates with matryoshka eventually), chart (live
data), slider (input), input field, button. Each is a self-
contained component module. The contract is fixed by stage 7;
adding components is repetitive work, not architectural.

## Design questions worth thinking through before stage 7a

Three decisions shape the rest of the work:

### 1. State model

A single global reactive store (path-based, like Svelte stores) vs
per-component state with explicit subscriptions.

Christian's pitch uses `${state.target_id}` syntax, which assumes
**global path access**. Per-component scoping can layer on later
if scoping conflicts emerge. **Decision: global-with-paths.**

### 2. Component identity & lifecycle

`#id` is the obvious key. Without an `#id`:

- **Auto-generate stable ID from tree position** (parent + sibling
  index). Preserves component state across most edits; loses it on
  structural reorders.
- **Re-create on every layout.** Simpler; loses state cheaply.

The first matters once an LLM is mutating documents — a chart
should keep its accumulated data even if the surrounding paragraph
gets edited. **Decision: auto-generate IDs from position.**

### 3. Layout vs render contract for components

Do components participate in flow (return a `Box` like every other
Element), or claim a fixed area declared in attrs?

CSS does both via `display: block` vs `display: inline`. We
probably want both too:

- `:::chart {width=100% height=400px}` claims a fixed-height
  area in the block flow.
- `:::badge {inline}` flows inline with surrounding text.

**Decision: default to block (claims a Box, fills `max_w`,
height from attrs). Inline opt-in via attr later.**

## What this means for the renderer architecture

Most of the work isn't in the renderer — it's in the layers above:

- **markdown.zig** grows the block-extension parser + attribute
  parser. cmark handles standard markdown; we walk its output
  detecting `:::` blocks.
- **A new `component.zig`** hosts the registry + cache + lifecycle.
- **A new `state.zig`** hosts the reactive store + bindings.
- **Components themselves** live in `src/components/*.zig`, each
  implementing the existing `ElementVTable` shape.

The walker (`element_layout.zig`) barely changes. The contract
holds. The new work is in the producers (markdown extension parser,
state engine) and consumers (concrete components), with the
renderer mostly untouched.

That's the deepest signal that the contract was right: a vision
this much larger than the original "rich text rendering" goal
slots in without needing to break the shape we landed.

## Naming

`text_engine` is now visibly the wrong name. The destination is a
**live-document runtime**. Renaming conversation belongs in a
future stage — but it's no longer "when the contract is concrete
enough to name what the library actually does." The contract is
concrete; what's still moving is the runtime layer above it. Once
stage 7c ships (first concrete component), the rename can land.

Candidates that came up implicitly across sessions:
- `glow` (live + glowing)
- `forge` (matches the runtime/factory feel)
- `litho` (printed page + dynamic)
- something tied to matryoshka (sibling brand)

Not naming yet. Just flagging that "text_engine" has a shelf life.
