# text_engine — session 9 journey
2026-05-16 (Saturday, the day after session 8)

Session 8 closed with a parking note. **Stage 14b** — parallel
cache-miss layouts — had shipped end-to-end, then hung the main
thread the moment we ran multiple `:::*-stream` HTTP fetches at
once. The infrastructure stayed in place; the dispatch threshold
got raised to `maxInt(usize)` so it never fired. The session ended
with Marvin-the-Paranoid-Android on screen and a clear next move
in memory: **split the worker pool**.

Session 9 took that as the opening and kept going. By the close,
**six stages shipped**: the worker-pool split that unparked 14b,
a persistent asset cache for expensive remote responses, headless
documents that complete the composition track, state-target button
dispatch that closes the reactive-attr loop end-to-end, persistent
reactive state across restarts, and cost-aware parallel-walk
classification so the chart's 60 Hz feed stops paying dispatch
overhead it doesn't need.

Halfway through the session, [a manifesto landed](manifesto.md) —
written in response to the recent push from some quarters to
default LLM outputs to HTML instead of markdown. The substrate's
stance got explicit: markdown is the universal interface, not a
presentation format; the right answer is to render it harder, not
replace it. The stages that shipped this session are exactly what
that stance asks for. Persistent state, persistent assets,
headless docs, scope-aware buttons — all directly extend the
"markdown is the working medium" thesis. The format does not get
richer. The substrate around it does.

## Stage 14d — split the worker pool (compute vs blocking I/O)

The session-8 parking note was clear. `httpStreamJob` in
`src/io_channel.zig` runs `client.open` / `req.send` / `req.wait`
/ `req.read` in a loop — it pins a `JobSystem` worker for the
entire 5-15s of upstream wait per stream. With three `:::llm-stream`
+ one `:::svg-stream` + one `:::image-stream` all firing, five of
the JobSystem's six worker slots (on an 8-core machine that's
`cpu_count - 2`) sit blocked on socket reads. When `:::svg-stream`
finalises a response and calls `tess.tessellateParallel` from the
drain handler, only main + one free worker can drain the 125-job
tessellation queue. The session-8 stage-14b parallel walker
dispatching its own walks on top of that pushed the system into
`Counter.wait` spin loops with not enough free workers to drain
anything; GLFW reported the window as Not Responding.

The fix is structural and tiny. Two `JobSystem` instances coexist:

- **Compute pool** — keeps the original sizing (`cpu_count - 2`
  workers, all hot for parallel layout + tessellation).
- **I/O pool** — 24 workers, sized for concurrency not parallelism.
  Each happily parked on `req.read` for the upstream duration of
  a stream costs nothing; the kernel sleeps them in the syscall.

`IoChannel.init` takes the I/O pool. `submitHttpGet` and
`submitHttpStream` now schedule onto it. The compute `JobSystem`
keeps the rest. Zero contract change — `submitHttpStream` still
returns a `Handle` synchronously and posts completions through the
channel asynchronously. Only the pool routing moved.

With the contention gone, `PARALLEL_MIN_WALKS` dropped from
`maxInt(usize)` back to `2`. The walker re-armed. Multi-stream
demo (three LLMs + svg-stream + image-stream live) confirmed no
hang, no fan spinup. The doc comment on `IoChannel.jobs` makes
the routing rule explicit: the field must be the I/O pool, never
the compute pool — passing the wrong one is the bug we just fixed.

The retired memory `project_worker_pool_split.md` was the parking
note for this fix. With it shipped, the memory got removed and a
session-9 close added to `project_text_engine.md`.

## Stage 14e — persistent asset cache

Recraft V4.1 is $0.08 per generated SVG. Gemini's image preview is
~$0.08 per image. The demo fires both on click, and we'd been
losing both on every restart — `embedded-document` had an
in-memory `url_cache: StringHashMapUnmanaged([]const u8)` for
short-circuiting same-session re-fetches, but it died with the
process.

The shape ended up browser-style. New module
`src/asset_cache.zig`: flat directory at
`${XDG_CACHE_HOME:-$HOME/.cache}/text_engine/assets`, sha256 keys,
`<hex>` files for the bytes, a `manifest.json` for per-entry
metadata. The manifest carries `size`, `created_at_ms`,
`last_accessed_at_ms`, optional `source` descriptor, optional
`content_type`. A configurable byte budget (500 MB default) with
LRU eviction on overflow. Atomic manifest writes (tmp +
`rename`-within-directory) so a crash leaves either the old file
or the new one — never a partial.

Manual eviction knobs landed too: `pruneOlderThan(cutoff_ms)`,
`pruneAll()`, `setBudget(new_bytes)`. None exposed via a CLI yet
but the API is ready when a future stage wires one up.

Each cacheable consumer derives its own key:
`sha256(prefix | provider | endpoint | model | system | prompt | max_tokens)`.
The prefix carries a schema version (`svg-stream:v1`) so a future
key-shape change silently bypasses the old entries rather than
producing collisions.

`:::svg-stream` and `:::image-stream` both opt in. The cache-hit
fast path in `kickStream` reads the bytes synchronously (sub-ms on
SSD for the sizes we deal with), feeds them into the existing
`finalizeResponse` parser, and goes straight to `.done`. No
`IoChannel` traffic, no spinner pause. On a cache miss, the
existing submit path runs; the successful `.end` writes the
accumulated envelope to disk. Corrupt or incompatible cached
entries fall through to a fresh fetch.

The numbers from the smoke test:

```
zig build run                                  # cold run
text_engine demo — session 9 / stage 14e (persistent asset cache)
  asset cache:    0 entries / 0.0 MB / 500 MB budget @ ...
  # click Run on svg-stream + image-stream
  # both fire fresh, total ~$0.16, 117 KB SVG + 3.5 MB image land

zig build run                                  # warm run
  asset cache:    2 entries / 3.5 MB / 500 MB budget @ ...
  # both stream contents materialise instantly, no spinner, no charge
```

The same `manifest.json` shape generalises. Future consumers
(generated audio, scientific plots, model probes) drop in by
calling `AssetCache.keyFor(...)` + `get/put`.

## Stage 10 — headless documents

The composition track has been waiting for this since session 5
laid `:::embedded-document` down. The roadmap entry read:
"Architecturally just 'don't call element_layout.layoutAndRender;
do call markdown.parseWithStateAndScope'."

The change ended up exactly that small. `Component` grew a
`headless: bool` field. `create()` reads the `headless` attr
(via a new `parseBoolAttr` helper that takes "false" / "0" / "no"
as off and anything else as on). `layoutAndRender` short-circuits
when `headless` is true — returns a zero-size box, emits nothing
into the DrawList, never recurses into the parsed child tree.

The substrate consequence is important. Headless propagates
**behaviourally**, not via an inherited flag. The walker simply
doesn't descend, so visual content nested arbitrarily deep inside
a headless doc stays hidden regardless of its own `headless`
value. A `:::svg-stream` three layers inside a headless wrapper
still won't render. But its `factory.create` still ran, its
registry entry exists under the scope prefix, its `auto_start`
HTTP request fired, its completion will land, its mesh will be
tessellated. The doc is **live**, just not **visible**.

That is the cache-warming pattern from the manifesto's *"headless
documents run as pure state machines with no viewport"* clause.
A headless doc can hold `:::svg-stream` / `:::image-stream` with
`auto_start=true` and the same prompts a visible doc will use —
when the visible one mounts later, the cache is warm and the
asset paints instantly. We didn't ship the cache-warming demo yet
but the building block is there.

The demo doc was structured to make the invisibility visceral:
`src/widgets/headless_config.md` contains a heading, a paragraph,
a block quote, and a 200px magenta box. Embedded with
`headless=true`, none of it appears on screen. Embedded with
`headless=false`, the whole thing shows up and the surrounding
stack-v re-flows around it.

### Stage 10 follow-up — runtime toggle

Christian asked about toggling the flag at runtime, which the
substrate's reactive shape clearly anticipated. Two paths landed
in the same commit:

**Reactive-attr path.** `update()` re-reads the `headless` attr on
every spec re-resolve. With `headless=${state.config_hidden}`, the
existing Binding subsystem reacts: a state mutation triggers
attr re-resolution, the field flips, the next layout pass sees
the new value. Composes with sliders, `:::update {target=state.x}`
directives, and any future state mutator without further plumbing.

**`handle_update` path.** Direct imperative: `:::button {target=#config
action=toggle-headless}` or `:::button {target=#config action=set-headless
body=false}`. The component-target arm on `:::embedded-document`
flips the flag without bouncing through state. Useful for LLM-
authored update fragments that want to reveal a previously
configured doc on a specific trigger.

Both paths coexist. The demo demonstrates path 1 once stage 13b.1
(below) lands the state-target button.

## Stage 13b.1 — state-target dispatch for `:::button`

Closes a gap that's been documented since stage 13b: "State-target
dispatch (`target=state.path`) is deferred — pair this with the
existing `:::update` directive emitter when that case comes up."
The case came up.

`onInput` already received a state pointer through its third
argument (the scope-aware state the dispatcher captured into the
`Hit`). The button just wasn't using it. With this stage, button
dispatch splits at click time:

- **`target=state.path`** writes `body` into the scope-local
  state at `path`. `action=` is ignored on this branch — state
  mutation is a single primitive verb.
- **`target=#id`** keeps the existing `registry.handleUpdate(id,
  action, body)` path against the host registry. A button in a
  child doc still reaches parent-scope or sibling-scope components.

Because the state pointer threads through `on_input` from the
dispatcher, scope is correct. A button inside an `:::embedded-document`
that targets `state.x` mutates **child** state, matching how
`:::slider` and `:::input` have been working since stage 9.

The action is also now optional for state-target buttons (a
courtesy — the existing tests verified the missing-action error;
that error is now gated on whether the target is state-shaped).
With path 1 from stage 10 wired up, the headless demo now reads:

```markdown
:::embedded-document {#config src="..." headless=${state.config_hidden}}
:::

:::button {#show_config label="Show config doc"
           target=state.config_hidden body=false}
:::

:::button {#hide_config label="Hide config doc"
           target=state.config_hidden body=true}
:::
```

State drives visibility. The reactive-attr path proves out
end-to-end. Click → state.set → Binding fires → factory.update
re-resolves attrs → headless flips → next layout pass collapses
or materialises the embed.

## Stage 13b.2 — persistent reactive state

Slider positions evaporated at every restart. Input contents,
button-driven state mutations (the new `config_hidden`),
everything in the host `state` map — gone on `kill -INT`. The
asset cache survives restarts; the state map didn't.

`State` grew two persistence methods and a `persist_dirty` flag:

```zig
pub fn saveToFile(self: *const State, path: []const u8) !void;
pub fn loadFromFile(self: *State, path: []const u8) !void;
pub fn clearPersistDirty(self: *State) void;
```

The wire format is JSON with a version field — `{"version":1,
"entries":{"key":"value", ...}}`. Atomic tmp + rename so a crash
leaves either the old file or the new one. `set()` flips
`persist_dirty` alongside `dirty`; the two flags are independent
so the host can throttle disk writes on its own cadence without
disturbing the renderer's repaint signal.

The state file lives at
`${XDG_STATE_HOME:-$HOME/.local/state}/text_engine/state.json`
(state is user data, not regenerable cache — the XDG conventions
put them under different roots so `rm -rf ~/.cache` doesn't lose
slider positions).

Main loads the file between `state_mod.fromSource(demo_md)` (which
populates the map from `---` frontmatter) and
`markdown.parseWithState` (which builds components whose Bindings
subscribe to current state). The order matters: frontmatter
populates defaults, then persisted values overlay on top, *then*
components subscribe. Components see the user's last-session
values from the very first render.

The throttled save runs from the main loop every 60 frames if
`persist_dirty` is set (~1s at 60 fps; faster at higher refresh
rates). A final flush on graceful exit catches the tail. The
slider-drag pattern (60 `state.set` calls per second) coalesces
into one disk write per second instead of 60. SSDs handle 60
writes/sec fine but the wear-leveling unfriendliness is real;
throttling is the right shape.

Restart now picks up where the user left off. Dragged the radius
slider to 30? It's at 30 next launch. Hidden the config doc?
Stays hidden. The colour-cycle's last value shows briefly before
the cycle resumes from blue — minor cosmetic quirk; not load-
bearing enough to fix in v0.

## Stage 14f — cost-aware parallel-walk classification

The session-8 parking note also flagged this. Stage 14b's
parallel walker counts every snapshot-eligible cache miss equally,
but the costs are wildly uneven. A `:::chart` miss is a few
column quads in microseconds; a paragraph miss is HarfBuzz
shaping in tens to hundreds of microseconds. Dispatching a chart
walk in parallel pays more in `Counter.wait` spin than it saves.

`ElementVTable` grew a `parallel_layout_cheap: bool` flag, default
false. Three components opt in:

- **`:::chart`** — emits column quads from a ring buffer. O(N
  samples) memcpy, microseconds per frame even at 600 samples.
- **`:::svg-stream`** — re-walks already-tessellated mesh slices.
  The expensive work (Bezier flatten + earcut) happens in
  `finalizeResponse`, not in the walk.
- **`:::image-stream`** — emits a single `ImageDraw` entry. The
  PNG decode + texture upload happens in `finalizeResponse`.

The classifier now distinguishes expensive walks (everything else)
from cheap walks (vtable-marked). Only expensive walks count
toward `PARALLEL_MIN_WALKS`. Cheap walks still dispatch in
parallel **when** the threshold is met by expensive siblings —
they ride along for free once we've decided to go parallel — but
chart-only-dirty frames stay serial.

The numbers from the smoke run:

```
zig build -Doptimize=ReleaseFast run

# Three back-to-back idle-with-chart sessions:
frames: 75940 in 13175ms (5763.9 fps)
frames: 39717 in  9040ms (4393.5 fps)
frames: 23197 in  3466ms (6692.7 fps)
```

Variance is from how much LLM-stream activity each run sampled,
plus the demo.md grew from 8636 to 9999 bytes (16% more content
across all six stages). Layout cache hit rate held at 98-99.9%
across runs. The chart fires at 60 Hz throughout and no longer
triggers parallel dispatch on its own.

The flag is conservative — only chart/svg-stream/image-stream
declare cheapness. Paragraph / heading / code_block stay
"expensive" because their cost is variable per-content and
sometimes genuinely high. Future stages can add finer-grained
cost memo (cache the actual walk time, gate on `>N us`) but the
static flag covers the present problem.

## Numbers at session 9 close

- **~17,800 LOC** of our own Zig + GLSL.
- **~190 unit tests** passing (8 new for asset_cache, 7 new for
  state persistence, 4 new for state-target button, 1 new for
  parseBoolAttr).
- **~5-7k fps Release** under the multi-stream demo. ~7-13k fps
  Release at idle.
- **Six commits** on master plus this writeup.

## Commits

- `00e87f8` — stage 14d: split worker pool — compute vs blocking I/O
- `b51e740` — stage 14e: persistent asset cache — content-addressable, LRU, budget
- `1514eac` — stage 10: headless documents — invisible substrate parses + state lives
- `f74a946` — stage 13b.1: state-target dispatch for `:::button`
- `304b2e5` — stage 13b.2: persistent reactive state — slider positions survive restarts
- `1b403ac` — stage 14f: cost-aware parallel-walk classification

## The hand-off image

Christian dragged the radius slider to 30, clicked **Hide config
doc**, closed the window. Reopened it. The slider snapped to 30.
The config doc stayed hidden. Inside the same launch, Marvin
materialised the moment the image-stream button was clicked —
straight from the asset cache, no spinner, no charge. The bowl of
petunias did the same on the SVG side. The 60 Hz chart was
ticking in the background and no longer pulling the parallel
walker into dispatch on every append.

Six pieces, all silent in the running demo. None of them have a
visible new on-screen feature. All of them make the substrate
feel **inhabited** — the document remembers, the assets persist,
the worker pool doesn't starve, the cheap walks don't spin.

## How session 10 picks up

The wishlist after this session is smaller and the open queue is
more focused. Top picks:

1. **More image-class probes** — Stability SD-Vector, Bytedance
   Doubao-Vector, OpenAI gpt-image-1. Each one is curl-first
   reconnaissance per `[[reference-recraft-wire]]` then a small
   provider arm in `:::svg-stream` / `:::image-stream`. Half-day
   each.

2. **Selection + clipboard for `:::input`** — shift-arrow,
   double-click word selection, ctrl-A/C/V. The cursor + char
   path is already in place; this closes the "feels like a real
   text field" gap.

3. **Stage 5b — markdown ↔ ANSI composability** — small (~50
   LOC). ` ```ansi ``` ` fenced code blocks in markdown route
   through `ansi.parse` into `CodeContent.sub_block`. Closes the
   markdown↔ANSI loop that's been parked since session 3.

4. **Crisp zoom** — multi-size atlas + re-layout-on-zoom-change.
   Bigger surface (atlas refactor + size-aware shape cache). The
   current post-layout transform is fine but text stretches at
   non-1.0 zoom.

5. **Cache-warming headless demo** — pair stage 10's headless docs
   with the asset cache: a `:::embedded-document {headless=true}`
   that holds `:::svg-stream`/`:::image-stream` with `auto_start`,
   pre-fetching the assets a visible doc will need. Manifesto pattern
   made concrete.

6. **MCP / WASM provenance** — the [[project-component-provenance]]
   ladder's middle rungs. The Factory contract was built to hold
   them; the missing piece is the bridge.

## Closing thought

Six stages, none of them flashy. The substrate is in the best
shape it has ever been in: persistent, scoped, scope-toggleable,
cache-savvy, and quiet under load. Session 9 didn't add a new
medium. It made every existing medium hold up under what comes
next.

> **Markdown is the universal interface. Make it live.**
>
> — [`docs/manifesto.md`](manifesto.md), 2026-05-16

Catch you next session on The Heart of Gold, partner. ☕🚀
