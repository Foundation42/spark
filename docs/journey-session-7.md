# text_engine — session 7 journey
2026-05-15 (Friday, later the same day as session 6)

The arc bends toward use.

Session 6 closed with a substrate that streams. Three LLM
providers writing markdown into the same document at the same
time. The live-document Hitchhiker's Guide became real. But
Christian had to *trigger* each stream with a button — the user
couldn't actually *say anything* to it yet — and the document was
still text-only, no figures.

Session 7's mandate was both halves. **Close the user→LLM
authoring loop**, then **make the document carry vector
graphics** — including ones Recraft was authoring on demand from
a typed prompt.

Four stages. One session. By the close: a user can type "a
robot drinking coffee," hit Enter, and watch the figure materialise
in the same document that just got done streaming a haiku from
three other LLMs.

## Stage 13c — `:::input` field

The smallest of the four in line count, the biggest in feel.
Session 6 ended with three `:::button` instances, each firing a
canned prompt at a sibling `:::llm-stream`. To make the
demonstration actually be a conversation, the user needed a place
to type.

The component shape was familiar by now: take some attrs
(`target`, `action`, `placeholder`, `width`, `initial`), draw a
box, accept input. The novelty wasn't the field — it was the
keyboard plumbing it forced into the engine.

### Extending the input contract

`element.InputEvent` was mouse-only at the start of the session.
Three button events, no keyboard, no focus. That had been fine
for sliders + buttons; a text field needed all of:

- `char_input: u32` — printable codepoint, post-IME
- `key_down: KeyEvent` — non-printable keys (backspace, arrows,
  enter, delete, home, end) with a GLFW keycode + mod mask
- `focus_gained` / `focus_lost` — for the dispatcher to tell a
  component when it owns the keyboard

Each of those mapped to a different GLFW callback (`charCb`,
`keyCb`, no callback for focus — the dispatcher synthesises it
based on click landings). All three threaded through a new
`Hit.focusable: bool` and a `FrameCtx.focused: ?Hit`.

Click-on-focusable grabs focus. Click-on-anything-else (button,
empty space) clears it. Esc clears it too. While focused, key +
char events route only to the focused component; the page-scroll
navigation handler is suppressed so typing into a field doesn't
also page down.

### The walker-shadowing bug

First implementation: input component appends its own `Hit` with
`focusable=true`. Clicks don't grab focus.

Took a few minutes to spot. `element_layout.zig`'s walker
already emits a `Hit` for every `custom` element whose
`vtable.on_input != null` — that's how it stamps the layout-time
state pointer onto the hit. The walker emits **after** the
component's own `layout_and_render` returns, which means its
default-`focusable=false` Hit **shadows** the component's
focusable-true one. `findHit` walks in reverse and picks the
last-appended match.

The fix wasn't to remove the walker's Hit (other components don't
emit their own and depend on it). The fix was to move `focusable`
onto the **vtable** so the walker could stamp it onto the Hit it
already emits:

```zig
pub const ElementVTable = struct {
    layout_and_render: ...,
    on_input: ...,
    /// True if this component wants keyboard focus on click.
    focusable: bool = false,
};
```

Walker reads `cu.vtable.focusable`, copies it onto the Hit it
appends. Input component sets `vtable.focusable = true` once.
Done.

Why it generalises: any per-Hit datum that has to reach the
dispatcher should live on the vtable, not on a manual
`out.hits.append`. The walker's emission is the authoritative
one. Memory saved under [[project-hit-emission]] so the next
component to need a hit-routing flag doesn't get caught the same
way.

### The trivial extension to `:::llm-stream`

The input dispatches `handleUpdate(target, action="start",
body=buffer)` on Enter. `:::llm-stream.handleUpdate` previously
took the body and discarded it (session 6 only used buttons with
empty bodies). One change:

```zig
if (body.len > 0) {
    const new_prompt = c.allocator.dupe(u8, body) catch ...;
    c.allocator.free(c.prompt);
    c.prompt = new_prompt;
}
kickStream(c) catch ...;
```

Non-empty body replaces `c.prompt`. Empty body re-fires the
canned prompt. The button stayed valuable as a "retry with
default" path; the input took over the conversational path.

Three input fields landed in `demo.md`, one above each LLM
stream. Type "tell me about babelfish in the hitchhiker's
guide", press Enter, three different models answer the same
question with three different answer shapes. qwen3.5 hallucinated
that babelfish don't exist; DeepSeek nailed the lore;
Gemini-via-OpenRouter went poetic about petunias instead.
Petunia approved.

Sealed at `b7f2184`.

## Stage 13d.1 — `:::svg` + triangle pipeline + earcut

The palate cleanser turned out to be the biggest piece of the
session. Christian had calibrated the scope at session 6 close:
"we should aim to use compute shaders eventually like Vello, but
not for now. We can use the jobs system to do the tesselation I
guess? As far as support, I guess we just need enough to render
things like Petunias.svg."

We surveyed Recraft's actual output (the bowl-of-petunias SVG
from session 6's screenshot). The result was forgiving:

```
$ grep -oE '\b[MLCZQTAHVSmlczqtahvs]\b' Petunias.svg | sort -u
C  L  M  Z
```

125 `<path>` elements, no `<g>`, no gradients, no strokes, no
transforms beyond `translate(0,0)`, fill is `rgb(r,g,b)`. Four
path commands: M, L, C, z. Uppercase absolute coordinates only.

That set the bar. A sharply-constrained subset stays a 250-line
parser instead of an XML jungle.

### The three pieces

**Parser** (`src/svg.zig`, ~600 lines with tests). A tag scanner
that walks `<...>` byte-aware (skipping quoted attribute values
so a `>` inside a quoted SVG attribute doesn't terminate the tag
prematurely), a path-data parser that handles M/L/C/z plus the
implicit-`L`-after-`M` SVG rule, a fill parser for `rgb(r,g,b)`
and `#rrggbb` / `#rgb`, a `translate(x,y)` transform parser.
Everything else (`<g>`, gradients, opacity) is silently dropped
and the scanner moves on. Tested against the real Petunias.svg
end-to-end: 125 paths confirmed, the orange background fill
correct to within 1/255.

**Tessellator** (`src/svg_tessellate.zig`, ~700 lines with
tests). Two-step pipeline:

1. **Flatten** — each cubic Bezier subdivided at the midpoint via
   De Casteljau until the chord-perpendicular error drops below
   ~0.5 viewBox units. Bounded recursion depth (20 levels) as a
   guard against pathological control points.

2. **Earcut** — Mapbox's ear-clipping triangulator, ported to
   Zig. Doubly-linked list of vertices; repeatedly clip "ears"
   where the middle of three consecutive vertices is convex and
   no other polygon vertex lies inside. Escalation passes for
   stuck states (filterPoints retry → split via diagonal).
   No z-curve indexing — Mapbox's optimisation for huge polygons
   doesn't pay back on the tens-to-hundreds-of-vertices ranges
   we emit per path.

   Hole stitching: pre-process. Find the largest signed-area
   ring (outer); for each smaller ring (hole), pick its
   rightmost vertex, find an outer-ring vertex to the right, and
   splice with bridge edges. The two degenerate triangles the
   bridge creates produce no visible pixels.

**Triangle pipeline** (`src/gpu/tri_pipeline.zig`, ~300 lines +
`shaders/tri.{vert,frag}`). New Vulkan pipeline, different shape
from quad / text — those are SSBO-instanced (one entry per
primitive, 6 verts per instance), but a thousand-triangle SVG
fill is the wrong shape for instancing. A real **VBO + IBO**:
interleaved `Vertex { pos: vec2, color: vec4 }`, `u32` indices,
host-visible host-coherent memory the host rewrites per layout,
one `vkCmdDrawIndexed` per recordDraw. Premultiplied-alpha output
matching the existing quad / text blend factor — no rendering-
order surprises.

### Render order

Triangles, then quads, then text. SVG fills sit *under*
button chrome and glyphs. So a `:::svg` block with a `:::button`
on top would compose correctly without any clipping work.

### The bowtie linked-list bug

First earcut run produced zero triangles on a square. A few
minutes of head-scratching, then traced it to `insertNode`:

```zig
fn insertNode(head_opt: ?*Node, n: *Node) ?*Node {
    if (head_opt) |head| {
        n.next = head.next;
        n.prev = head;
        head.next.?.prev = n;
        head.next = n;
        return head; // ← bug
    }
    ...
}
```

I was inserting each new node *after the head*, returning the
head unchanged. That meant the second vertex went `head → v1`,
the third went `head → v2 → v1`, the fourth went `head → v3 →
v2 → v1` — and the square `(0,0) (10,0) (10,10) (0,10)` was being
stored as `(0,0) (0,10) (10,10) (10,0)`. **A bowtie.** Self-
intersecting. Earcut correctly refused to triangulate it.

Mapbox's reference impl threads through a `last` pointer instead:
each new node gets appended after the previous tail; the tail
becomes the new node. That preserves insertion order.

```zig
fn appendNode(last_opt: ?*Node, n: *Node) *Node {
    if (last_opt) |last| {
        n.prev = last;
        n.next = last.next;
        last.next.?.prev = n;
        last.next = n;
    } else {
        n.prev = n;
        n.next = n;
    }
    return n;
}
```

One method renamed, one pointer threaded — all the geometry tests
went green. The Petunias parser+tessellate pass produced 4,174
triangles end-to-end.

### What the user saw

`zig build run` after `:::svg {src=src/test_data/Petunias.svg}`
landed in `demo.md`. Scroll down past the LLM streams. A bowl
of petunias appears. Concave petals tessellated cleanly. The
scalloped rim of the bowl came through. "PETUNIAS" lettering at
the bottom rendered as path outlines (Recraft converts text to
vectors). Even the stems with sharp edges.

Sealed at `511e801`. The Guide demonstrably approves.

## Stage 13d.2 — parallel tessellation via the JobSystem

Session 6 had built the work-stealing pool in stage 12 to unblock
async I/O. It had been quietly waiting for a CPU workload to
chew on. Stage 13d.2 was that workload.

### What the JobSystem makes easy

`JobSystem.parallelFor(count, batch_size, func, context, counter)`.
Submit one job per `<path>`. Wait on the counter. Done.

The wrinkle was allocation. Each worker writes into its own
local `Mesh` so there's no contention, but those Meshes have to
outlive the parallelFor call until the main thread merges them.
Per-component arena allocators aren't thread-safe; thread-locals
add ceremony. Easiest answer: each worker uses
`std.heap.c_allocator` (the only thread-safe std allocator) for
its slot. After merge, free the per-path buffers explicitly.

```zig
fn tessellateOneJob(job: *jobs_mod.Job) void {
    const range = job.getData(jobs_mod.BatchRange);
    const ctx: *const ParallelContext = @ptrCast(@alignCast(range.context));
    var i = range.start;
    while (i < range.end) : (i += 1) {
        var local = Mesh.init(std.heap.c_allocator);
        _ = tessellatePath(std.heap.c_allocator, ctx.paths[i], &local, ctx.opts) catch {
            local.deinit();
            continue;
        };
        ctx.results[i].vertices = local.vertices.toOwnedSlice() catch &.{};
        ctx.results[i].indices = local.indices.toOwnedSlice() catch &.{};
    }
}
```

batch_size=1 because path costs are wildly uneven. The
background rect is one cubic; some petals are 30+ cubics. A
larger batch would let one worker draw long-tail work while
others starve. The work-stealer wants per-path flexibility.

After parallelFor + waitFor, the main thread walks
`results[]` in order, appends each `vertices` to the final
`out_mesh.vertices`, and rebases each index by the cumulative
vertex count before pushing into `out_mesh.indices`. Same path
order as serial — render Z-order is preserved.

### The number

Startup banner now prints:

```
svg tessellate (125 paths, 4174 tris): serial 22099.5 us, parallel 2704.1 us → 8.17x
```

**8.17×** on first run, **9.32×** by stage 13d.3 (cached caches,
warm CPU). Basically linear scaling against whatever core count
the box has (Christian's RTX 3090 box presumably has 12+ cores).
That's the work-stealer doing what work-stealers do — absorbing
the long-tail-skewed work distribution without main-thread
coordination.

Today this is a startup-time win; `:::svg` tessellates once per
instance and the result stays cached. When 13d.3 streams Recraft
responses live, the same speedup lights up on every prompt — the
~25 ms tessellation step becomes ~3 ms, dropping from
"noticeable" to "imperceptible".

Sealed at `446a07f`.

## Stage 13d.3 — `:::svg-stream` and the wire-format detective story

The payoff stage. User types a prompt. Recraft generates an SVG.
The same parse + parallel-tessellate + render pipeline that
handles disk files handles model output. Petunia paints itself
live.

### The plan

Mirror `:::llm-stream`: same IoChannel + JobSystem + dotenv +
parent-state plumbing. Component holds an accumulated content
buffer; per-chunk SSE events extract `delta.content` text; on
each chunk try `svg.parse` + `tessellateParallel`, swap in the
fresh mesh. The viewer sees the figure paint itself path-by-path.

### The discovery

First test: type a prompt, hit Enter, wait, "stream ended
without SVG" placeholder. Two heartbeat-only chunks
(`: OPENROUTER PROCESSING`) and then `.end` with zero
accumulated content.

The diagnostic was three lines of throwaway logging. The first
chunk: SSE comments only. No `data:` payloads. The accumulated
`content` buffer: empty. The line buffer at end: empty.

So the chat-completion-shape assumption was wrong. Time for the
authoritative answer: `curl`.

```
curl -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_DYNABOOK" \
  -H "Content-Type: application/json" \
  -d '{"model":"recraft/recraft-v4.1-vector",
       "messages":[{"role":"user","content":"A simple red circle"}],
       "stream":false,"max_tokens":8000}'
```

Two findings, both unexpected:

1. **`message.content` is `null`.** The SVG isn't there.

2. **The SVG lives in `message.images[0].image_url.url`** as a
   `data:image/svg+xml;base64,...` data URL. Same shape OpenAI's
   image endpoints use.

That makes sense in retrospect. Recraft is an *image-generation*
model. OpenRouter wraps it behind `/chat/completions` for API
uniformity, but the underlying model isn't a token-streaming
text generator — it's a one-shot image renderer. When we asked
for `stream:true`, OpenRouter forwarded heartbeat comments while
the upstream model worked, then returned the full result at the
end. The "stream" wrapping was theatre.

### The rewrite

The right shape is much simpler than what I'd built:

1. Send `stream:false` explicitly.
2. Accumulate raw HTTP chunks into one buffer.
3. On `.end`, parse the JSON envelope, find
   `choices[0].message.images[0].image_url.url`, strip the
   `data:image/svg+xml;base64,` prefix, base64-decode.
4. Run the decoded bytes through `svg.parse` + parallel
   tessellate, swap in the mesh.

The phase model collapsed from `{idle, loading, streaming, done,
failed}` to `{idle, loading, done, failed}` — there's no real
intermediate streaming state. The mesh appears all at once after
the upstream queue clears.

### The IoChannel refactor that made room

There was an architectural prerequisite tucked into the head of
this stage. The host's `drainHandler` had been routing
completions by **Result kind**:

```zig
fn drainHandler(_: *IoChannel, comp: Completion) void {
    switch (comp.result) {
        .ok, .err => embedded_document_component.handleCompletion(comp),
        .chunk, .end, .end_err => llm_stream_component.handleCompletion(comp),
    }
}
```

That was fragile and now broken: two consumers (llm-stream and
the new svg-stream) both wanted `.chunk/.end/.end_err`. The
result-kind switch couldn't disambiguate.

Fix: a polymorphic header. Every consumer's `PendingX` struct
gets a function-pointer first field:

```zig
pub const PendingHeader = struct {
    handle_completion: *const fn (Completion) void,
};
```

`user_data` (round-tripped through the IoChannel) is
`@intFromPtr(&pending)`. The drain handler reads the first usize
there and calls it:

```zig
fn drainHandler(_: *IoChannel, comp: Completion) void {
    const header: *const io.PendingHeader = @ptrFromInt(comp.user_data);
    header.handle_completion(comp);
}
```

Adding a new consumer (svg-stream, future audio-stream,
future-anything-stream) no longer touches `main.zig`. The host
doesn't even need to know they exist. Each consumer carries its
own handler with it.

### What the user saw

A robot drinking coffee.

User typed "A robot drinking coffee" into the `:::input` field.
The HTTP request fired off to OpenRouter through the IoChannel
worker. ~10 seconds later (Recraft's upstream queue) the chunks
landed, the JSON envelope parsed, the base64 decoded, the SVG
parsed, 125-ish paths flattened, earcut tessellated through the
parallel JobSystem in ~3ms, the mesh swapped in. A whimsical
red-and-grey robot appeared at a coffee table, head tilted,
holding a steaming mug.

Sealed at `3b317ae`.

## Bug-class lessons (saved in memory for the future)

### `vtable` is the authoritative routing surface, not local appends

The walker emits Hits. Components that *also* emit their own get
shadowed because the walker appends last. Anything that needs to
reach the dispatcher (focusable, future cursor-kind, future
wants-drag) belongs on the vtable, not on `out.hits.append`.
Memory: [[project-hit-emission]].

### Recraft (and image-class models on chat-completion endpoints)
are NOT chat-shaped

`message.content` is `null`. SVG is in
`message.images[0].image_url.url` as a `data:image/svg+xml;base64`
URL. `stream:true` only buys you OpenRouter heartbeats — the
upstream doesn't actually stream. Send `stream:false`, parse the
envelope, base64-decode.

The general principle: probe new model classes with curl
**first**. Don't assume the chat-completion wire format applies.
Memory: [[reference-recraft-wire]].

### Bowtie linked list

A doubly-linked-list builder that inserts new nodes "after head"
reverses every-other-vertex. Use Mapbox's last-pointer threading
pattern: each new node appends after the previous tail, becomes
the new tail. Caught early because earcut produced zero triangles
on a square — a beautifully diagnostic failure mode.

### One file at a time

Christian flagged this implicitly by approving stages one at a
time. 13d was a four-stage arc; doing it all at once would have
buried the wire-format bug under another five hours of
new code. Doing 13d.1 first, then 13d.2, then 13d.3 meant the
diagnostic surface for each was the *new code from that one
stage*.

## What ships

Four commits on master:

- `b7f2184` — stage 13c: `:::input` field, focus model,
  prompt-override
- `511e801` — stage 13d.1: `:::svg` + triangle pipeline + earcut
  tessellator + Petunias.svg
- `446a07f` — stage 13d.2: parallel tessellation via JobSystem
  (8.17× speedup)
- `3b317ae` — stage 13d.3: `:::svg-stream` (Recraft V4.1)

**~16,000 LOC, ~95 unit tests** (including parallel-vs-serial
equivalence on Petunias, base64-envelope smoke test for Recraft
shape). **350-630 fps Release** depending on which combination
of LLM streams + SVGs are visible. Three new live components,
two new GPU primitives (focus + triangle pipeline), one major
refactor (`PendingHeader`), three new memory entries for the
gotchas.

The interaction model now closes the loop. The user can author
prose into the document by typing, and figures into the document
by typing, and the same substrate handles both. Markdown is the
declarative interface. The LLM is the author. The triangle
pipeline is the canvas. The work-stealer is the muscle.

If session 6 made the document streamable, session 7 made it
*interactive and visual*. The robot drinking coffee is the
hand-off image.

## Next entry points for session 8

In rough priority:

1. **Retained layout cache.** Now overdue. Today's per-chunk
   re-parse-and-re-layout is fine when only one stream is firing,
   but a future "type your prompt, hit Enter on three streams in
   parallel, watch them race" stresses the layout pass. Per-
   Element caching by content + dependency-tracking on state
   mutations. Probably the right next bite — focused, no new
   surface area, removes a known limit.

2. **Stage 10 — headless documents.** Still parked. Cleanest
   composition-track completion: a doc that lives in memory
   without being mounted, addressable by id. Lets the future
   command-bar / palette mount results into the same Element
   tree.

3. **SVG cache.** Recraft is expensive (Christian paid $0.08
   for the robot). A content-addressable disk cache keyed on
   (model, prompt, params hash) saves repeat costs and makes
   the demo's startup deterministic. Naturally extends the
   existing IoChannel URL cache.

4. **More SVG generators.** OpenRouter also has Stability's
   SD-Vector and Bytedance's Doubao-Vector. Plug-in providers
   on `:::svg-stream` similar to how llm-stream took three
   providers in one enum branch — but probe each one's wire
   shape first.

5. **`:::image` (raster).** The same `image_url` field on
   OpenRouter image-class models also serves PNG / JPG /
   WebP (`data:image/png;base64,...`). The plumbing's
   identical; what's new is a raster decode + a texture
   pipeline. A natural extension once vector lands; PNG is
   reachable via libpng or stb_image without a giant new
   dep.

6. **Selection + clipboard for `:::input`.** The cursor + char
   path is in place; shift-arrow selection, double-click word
   select, ctrl-A / ctrl-C / ctrl-V come next. Single-line
   first; multi-line text area later.

7. **Crisp zoom.** Same note as session 5 — multi-size atlas +
   re-layout on zoom change. Bumped down each session because
   the existing fuzzy-text-at-non-1.0-zoom never blocks anyone.

8. **Persistent URL cache.** Content-addressable disk cache for
   remote sources. Doubles in value once SVG / image generation
   lands — caching a generated petunia bowl across program
   restarts saves money and time.

The arc keeps bending toward use. Session 6 made the document
streamable; session 7 made it interactive. Session 8 will
either deepen the rendering (retained layout, headless docs,
crisp zoom) or widen the input surface (raster images, more
generators, clipboard). Either is a fine next move.

Don't Panic. The towels are folded.

Catch you next time, Hitchhiker.
