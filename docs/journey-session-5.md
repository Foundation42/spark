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

## Patterns from session 4 that paid off

Three habits from the previous session carried over and made this
one fast:

1. **Single test entry point at `src/tests.zig`.** New file →
   one-line addition → `zig build test` covers it. Took ~5 seconds
   to wire `update.zig` into the test build.
2. **Arena-first allocation policy.** `applyAll` takes an arena,
   doesn't worry about per-update churn. The host's single-arena-
   with-reset pattern just works.
3. **Stage-by-stage commits with clear deliverables.** 8a → 8b is
   a one-stage delta. Each commit is reversible. Builds confidence
   the contract holds.
