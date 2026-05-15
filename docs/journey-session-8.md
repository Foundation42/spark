# text_engine — session 8 journey
2026-05-15 (Friday, the day after sessions 6 + 7)

Session 7 made the document **interactive and visual**. A user
could type a prompt, hit Enter, and watch Recraft author a vector
SVG of petunias in the same document that just got done streaming
a haiku from three LLMs. The substrate did what session 3's vision
promised — declarative authoring surface, LLM as content engine,
triangle pipeline as canvas.

Session 8 set out to give it **legs**. The chart's 60 Hz feed was
re-walking the entire document every tick. Three LLM streams
firing simultaneously crashed the floor to ~5.9k fps. The vision
needs the substrate to hold up under genuinely heavy load — and
the document needed to grow one more medium.

Three stages plus a build fix. By the close: idle layout had a
97.9% cache hit rate, glslc release builds emit 34% smaller SPIR-V,
and the demo could turn a typed prompt into a Marvin-the-Paranoid-
Android raster image rendered through a per-component `VkImage`.

One thing didn't land cleanly. **Parallel cache-miss layouts** —
the natural sequel to retained caching — shipped, then exposed a
worker-pool starvation issue that hangs the main thread when
multiple HTTP streams are in flight. The infrastructure is in
place but the dispatch is parked. The fix is for session 9.

## Stage 14a — retained per-block layout cache

The motivator was visible the moment session 7's demo started
running. The chart fires at 60 Hz; each `:::update` flips
`state.dirty`; `drawCb` triggers `runLayout` which **walks every
top-level tree from scratch**, re-shaping every word, even
paragraphs that haven't moved. With three LLM streams chunking on
top of that, the redundant work compounds.

The fix shape was the same one I'd been circling since session 5:
cache per-block walker output, keyed on block identity + content
version + constraints. Hit → blit cached glyph/quad/tri/hit ranges
with an origin offset. Miss → walk fresh and snapshot back.

### What gets cached, what doesn't

Eligibility is per Element kind:

- **Leaf-ish blocks** — `paragraph`, `heading`, `code_block`,
  `thematic_break`. Their layout output is a pure function of
  their content + constraints + theme. Cacheable.
- **Containers** — `container`, `list`, `list_item`, `quote`.
  Recursive structures. Cached at the **stack_v child level**,
  not the container level — caching the container as a unit would
  couple every descendant's invalidation. Their internal
  `layoutStackV` caches each child individually.
- **Custom components** — cacheable iff `vtable.disable_cache ==
  false`. The flag opts out components whose layout reads
  state at render time (`:::slider` reads `state.target`
  for thumb position), animates per-frame (`:::input` blinks its
  caret), or composes a sub-tree whose state can mutate without
  the outer wrapper seeing it (`:::embedded-document`).

That last classification is the subtle one. The slider's
state-driven thumb position isn't visible to the cache key — so
the cache key can't see it move. Same for the input's blinking
caret (a wall-clock function). The right call is to bypass the
cache at the outer block for these and let their *descendants*
cache normally. In practice the slider/input/embedded-doc walks
are cheap; the savings are everywhere else.

### Versioning, off the key

The first design had `content_version` as part of the hashmap key.
That was wrong: each chunk of an LLM stream bumps the version,
which means a new key, which means the **old entry under the old
key never gets evicted**. A 1000-chunk stream would leak 1000 cache
entries — fine on a one-shot demo, catastrophic over a session.

The fix was to hold version *outside* the key, as a field on the
`Entry`. Lookup compares the entry's version against the freshly-
computed expected version; mismatch counts as a miss **and evicts
the stale entry in place** so the next snapshot replaces the slot
cleanly. Each `(elem_id, max_w, theme_ptr)` triple owns at most one
slot, regardless of how many versions go through it. Bounded
memory.

### The LLM-stream inner-cache bypass

One more wrinkle landed during integration: the LLM stream
**re-parses its child Element tree from scratch on every chunk**.
That means the children's pointer identities change every tick.
If the worker walked them with `cache_blocks` still set, it would
accumulate cache entries against stale pointers indefinitely (the
old entries can never be hit; they leak).

The fix is one save-and-clear around the recursive walk in
`llm_stream.zig:layoutAndRender`:

```zig
.streaming, .done => {
    const saved_state = lc.state;
    const saved_cache = lc.cache_blocks;
    lc.state = @ptrCast(c.child_state);
    lc.cache_blocks = null; // inner pointers churn per chunk
    defer { lc.state = saved_state; lc.cache_blocks = saved_cache; }
    return try element_layout.layoutAndRender(c.root, origin, ...);
},
```

The outer llm-stream block already invalidates per chunk (its
content_version bumps in `handleCompletion`). That's where the
savings live anyway — every *other* block in the document hits
cache.

### Numbers

Idle (chart + 1.5s color cycle, no LLM):

- Cache: 16387 hit / 357 miss / 4485 skip (**97.9% hit rate**, 56
  entries) over a 5s run
- fps: ~7600 release, identical to the session-7 baseline (idle
  case was already cheap; the win is in the chunk-storm case)

The chart's per-tick `state.dirty` no longer re-walks the whole
doc — only the chart's own block re-walks, every sibling blits
from cache.

## Build fix — pass `-O` to glslc

Christian flagged this in passing: glslc defaults to `-O0`, and
we'd been shipping unoptimised SPIR-V. The fix is one line in
`compileShaderStage`, mapped from `optimize`:

- `Debug`        → no flag (glslc default = `-O0`)
- `ReleaseSafe`  → `-O` (perf optimisation, debug info kept)
- `ReleaseFast`  → `-O`
- `ReleaseSmall` → `-Os`

The text fragment shader shrank 34% (3040 → 2008 bytes). All
fragment + vertex SPIR-V binaries shrank proportionally. Driver
work drops too — the optimiser folds constant expressions, dead-
codes unused varyings, and rewrites the control flow into shapes
the GPU can lower more efficiently.

Easy commit. Should have been there since session 1.

## Stage 14b — parallel cache-miss layouts (parked)

With the retained cache landed, each cache-miss is a clean
self-contained unit of work: walk one Element into a block-local
DrawList, return box + ranges. Job-shaped. The natural follow-up
is to fan those misses out across `JobSystem` workers.

### What got built

The threading discipline is small. Three pieces:

1. **One mutex around `GlyphCache.getOrRasterize`.** This is the
   only path in the walker that mutates shared state — FreeType's
   shared glyph slot during render, the cache hashmap on insert,
   the Atlas's packing + staging buffer. Wrapped at the
   `appendShapedRun` call site so the lock acquire is bounded.
   Uncontested cost is a single atomic compare-exchange (~25ns);
   contested cost is whatever the rasterise + atlas blit takes
   (rare — 99.4% glyph cache hit rate steady state).

2. **`layoutStackVParallel`.** Classifies each child as
   `cache_hit`, `walk_with_snapshot`, or `walk_no_cache`. If the
   count of *snapshot-eligible* walks falls below threshold, falls
   back to serial. Otherwise allocates a private DrawList per
   walk, dispatches the workers via `parallelFor`, blocks on
   `waitFor`, then merges in order (cache hits blit cached
   entries; walks blit the private DrawList).

3. **Worker-local LayoutCtx.** Each worker copies the base context,
   swaps `allocator` to `std.heap.c_allocator` (thread-safe),
   nulls `cache_blocks` (block cache stays single-threaded —
   workers return private DrawLists; main inserts), and nulls
   `job_system` (no recursive dispatch). The lock stays in place
   so workers serialise around the glyph cache.

### Why the count discipline matters

The first cut counted *all* walks toward the dispatch threshold.
That triggered parallel dispatch every frame at idle: the
`disable_cache = true` components (slider, input, embedded-doc)
walk every layout regardless of state change, so the count was
always 5+ even at idle. Workers walked the embedded document with
`cache_blocks = null`, losing the inner cache hits the serial
path would have gotten. Glyph cache hits jumped 10× over the 14a
baseline; fps dropped 6%.

Tightening to **snapshot-eligible walks only** fixed it. At idle,
the chart alone is one walk; no dispatch fires; the dormant-at-
idle invariant restores. The dispatch is now reserved for the
chunk-storm case the parallelism was meant to address.

### The hang

The test path was supposed to be: trigger all three LLM streams,
watch them chunk simultaneously, observe the per-block walks fan
out across workers. The actual test path was: trigger `:::svg-
stream` to generate a fresh petunia, watch the main thread hang
the moment the response lands, watch the CPU fan come on.

The diagnosis took a beat. The user-reported symptom — window
"Not Responding" plus high CPU — pointed at a spin somewhere, not
a blocking call. Walking the code carefully revealed the
arrangement:

- `httpStreamJob` is a `JobSystem` job. It runs for the entire
  duration of the HTTP request (5-15s for Recraft / Gemini).
  Each in-flight stream **occupies a worker slot** that whole time.
- With three LLM streams + one svg-stream + one image-stream all
  in flight, **5 worker slots are blocked on the wire**.
- The `JobSystem` is sized to `max(cpu_count - 2, 2)`. On an
  8-core machine: 6 workers. Five blocked → one free.
- When svg-stream finalises (drain handler), it calls
  `tess.tessellateParallel` — which schedules 125 jobs onto the
  *same* JobSystem and `waitFor`s.
- Main + one free worker work on the queue. The HTTP workers
  can't help (they're blocked on `req.read`).
- Meanwhile state.dirty has propagated; the layout pass also
  wants to dispatch parallel walk work on top of that.
- The whole system spins in `Counter.wait` loops with not enough
  cycles to drain anything.

The infrastructure is sound; the **placement of HTTP work on the
shared compute pool** is what doesn't compose. Two fixes
queued for session 9:

1. **Dedicated HTTP worker pool**, separate from the compute
   JobSystem. HTTP jobs are blocking I/O — they shouldn't share a
   pool sized for parallelism.
2. **Cost-aware walk classification**, so cheap walks (chart
   re-render, svg-stream re-tessellate when the mesh is already
   cached) don't trigger dispatch overhead even when their version
   bumps. Snapshot eligibility is a necessary but not sufficient
   condition.

For now: `PARALLEL_MIN_WALKS = maxInt(usize)` parks the dispatch
unconditionally. The classification, locking, blit/snapshot, and
worker plumbing all stay live for when the underlying pool
geometry gets fixed.

## Stage 14c — `:::image-stream` (raster image generation)

The mirror of `:::svg-stream`: same async I/O lane, same wire
format (OpenAI-shaped `/chat/completions`, `stream:false`, response
in `message.images[0].image_url.url` as a `data:` URL). The only
difference is the data URL contains a PNG/JPEG instead of an SVG,
and the decode path runs through **stb_image + a `VkImage` + a
sampler** instead of the SVG tessellator + triangle pipeline.

### What ships

- **`vendor/stb/stb_image.{c,h}`** — vendored from matryoshka's
  `libs/`. Single-TU static library via build.zig. Christian
  pointed to the matryoshka copy when I asked about decoder
  choice; turned out matryoshka also has the Zig wrapper pattern
  ready to copy (`stbi_load_from_memory` with `desired_channels=4`
  → RGBA8).
- **`src/gpu/image_texture.zig`** — per-image `VkImage` + view +
  sampler + staged upload. Reuses Atlas's helpers (now pub-
  promoted: `Staging`, `findMemoryType`, `cmdImageBarrier`). The
  upload path transitions UNDEFINED → TRANSFER_DST → READ_ONLY on
  the first call and READ_ONLY → TRANSFER_DST → READ_ONLY on
  every subsequent call (so re-fires can reuse the same texture
  if the new image has matching dimensions).
- **`src/gpu/image_pipeline.zig` + `shaders/image.{vert,frag}`** —
  textured-quad pipeline. Per-image descriptor sets from a pool
  sized by `MAX_IMAGES`. Push constants carry `viewport_size +
  dst_pos + dst_size`. The pipeline records one `vkCmdDraw(6,1,0,0)`
  per `recordOne` call, binding the descriptor between draws.
  Premultiplied alpha at the fragment so it composites with the
  rest of the layered pipeline (tris → images → quads → glyphs).
- **`DrawList.images: ArrayList(ImageDraw)`** — the new draw
  layer. Each entry is `{ descriptor_set, dst_pos, dst_size }`;
  descriptors are owned by the source component, stay valid across
  cache hits (a re-fire bumps version and rewrites the descriptor
  in place rather than reallocating it).
- **`src/components/image_stream.zig`** — factory adapted from
  `svg_stream.zig`. On `.end`: parse the envelope, base64-decode,
  `stbi_load_from_memory` → RGBA8, allocate-or-reuse the GPU
  texture, upload, write the descriptor. Phase model:
  `{idle, loading, done, failed}`; matches every other stream.

### Texture lifecycle

The interesting decision: **reuse the texture when the new image's
dimensions match the previous one**. Gemini's image preview returns
varying sizes (we've seen 1024×1024 and 1024×1024 on retries, plus
non-square aspect-fit'd images for some prompts), so identical
dimensions across re-fires aren't guaranteed. When they match, one
buffer-to-image copy replaces the upload; no GPU allocation
churn. When they don't, free + reallocate + re-write the
descriptor.

The descriptor handle is rewritten **in place** for both paths via
`vkUpdateDescriptorSets`. This means cached layout entries
referencing the descriptor stay valid even after a re-fire — the
pointer doesn't change, just the underlying texture it points at.

### Render order

Final ordering: **tris → images → quads → glyphs**. SVG fills and
raster images sit underneath quad chrome (panels, underlines) and
glyphs (always on top so labels stay legible above any image).
The image_stream component's `layoutAndRender` appends to
`out.images`; the host's `drawCb` iterates them after triangles,
before quads.

### The wire-format reuse

The OpenAI-shaped `/chat/completions` wrapper turns out to be the
right substrate for "anything that returns one binary asset via
LLM." Recraft (SVG, session 7), Gemini image preview (PNG,
session 8), and presumably whatever shows up next month, all
share:

- `POST /chat/completions` URL
- `stream:false` body, OpenAI-shaped message array
- Response shape: `choices[0].message.images[0].image_url.url`
- Data URL with a `data:image/<mime>;base64,...` prefix

The MIME prefix and decoder swap; everything else is shared. The
`buildRequestBody` function in `image_stream.zig` is character-for-
character `buildRecraftBody` from `svg_stream.zig`. Probably worth
extracting on the next pass.

### The hand-off image

Christian typed *"A robot holding The Hitchhiker's Guide to the
Galaxy - showing Don't Panic! in glowing letters!"*. Gemini's
image preview rendered it. The result: a metallic robot at a
desk in what looks like a spaceship cockpit, reading a screen
showing **"DON'T PANIC"** in glowing green. Books behind it. A
spaceship visible through a window in the background.

The text engine rendered it through the new pipeline at the
moment the upload completed. The same demo also has the
session-7 Petunias above it (static `:::svg`) and the
session-7-but-now-functioning fresh-petunias (`:::svg-stream`).
Three media — vector, raster, generated — sharing one document.

## Where the substrate stands at session-8 close

```
session 1   text + atlas + HarfBuzz
session 2   element contract + markdown parser
session 3   quad chrome + ANSI + resize-aware relayout + vision capture
session 4   live components (registry + state + slider)
session 5   :::update + :::chart + :::embedded-document + scroll/zoom
session 6   async I/O channel + :::llm-stream + :::button
session 7   :::input + :::svg + :::svg-stream
session 8   retained layout cache + :::image-stream  ← we are here
```

The document is a runtime now. The user types; an LLM writes
prose, draws vector figures, paints raster scenes, edits sliders,
and updates charts — all in one place, every primitive composing
with every other primitive through the same Element contract.

Stage 14b's parallel walker is the first piece of session-8 work
that didn't quite land. The bug isn't conceptually deep — the
shared JobSystem hosting both blocking HTTP work and compute work
is the wrong arrangement. Splitting the pools should be a few
hours of plumbing. We just ran out of time today.

## Commits (in order)

- `fc5bb69` — stage 14a: retained per-block layout cache
- `f266779` — build: pass -O to glslc in release builds
- `4213bdc` — stage 14b: parallel cache-miss layouts
- `ea5fd50` — stage 14c: :::image-stream — async raster image generation
- `1397f6a` — fix: park 14b's parallel walker pending HTTP-pool split

## Session-9 entry points

The natural next moves are split between *finishing 14b* and
*new substrate*. In rough payoff order:

1. **Split the HTTP worker pool.** Two-pool design: one for
   blocking I/O (HTTP fetches, future MCP pipes, file watchers),
   one for compute (layout dispatch, SVG tessellate). Once those
   are decoupled, the parallel walker's threshold can drop back
   to 2 and the chunk-storm case becomes the parallelism win it
   was supposed to be all along.

2. **Persistent / disk-backed URL + asset cache.** Recraft is
   $0.08/image. Gemini image preview is in the same league.
   Content-addressable disk cache keyed on `(model, prompt,
   params hash)` makes the demo deterministic across restarts
   and cuts spend during iteration. Naturally extends the
   existing in-memory `url_cache`.

3. **Stage 10 — headless documents.** Still parked. Parse + state
   + subscribers without layout. The composition-track companion
   to `:::embedded-document`.

4. **More image-class probes.** Each generator has its own
   wire-format surprises (Recraft taught us that). Stability
   SD-Vector, Bytedance Doubao-Vector, OpenAI gpt-image-1.

5. **Selection + clipboard for `:::input`.** Shift-arrow,
   double-click word selection, ctrl-A/C/V. Closes the
   "feels like a real text field" gap.

6. **Crisp zoom.** Same note as sessions 5/6.

## Christian's farewell

"I don't know the continuous FPS - but it certainly seems to be
holding up at 7000fps overall." Then later, after seeing Marvin
the Paranoid Android render through the new pipeline: "It worked!".

Don't panic. The texture's mapped. The triangles are tessellated.
The towels are folded. 🐬
