# text_engine — session 6 journey
2026-05-15 (Friday — the day after sessions 1-5)

The payoff.

Session 5 closed with the live-document substrate complete: parse →
registry → cache → state → reactivity → input → first interactive
components → `:::update` wire format → streaming components →
recursive composition → remote sources → scroll/zoom/keyboard. The
substrate could host any component that fit the Factory contract,
and the parent reactive state crossed the network boundary cleanly.

What it couldn't yet do was *cash in the bet*. Every future
blocking surface — LLM streams, file-watcher hot-reload, MCP
subprocess pipes — was waiting on one primitive: async I/O off
the main thread.

That's stage 12.

And once 12 landed, the headline use case from session 3's vision
doc was a 200-line component away: a live document being written
by a language model, in real time, with markdown re-parsing
token by token. That's 13a.

And then it turned out the OpenAI chat-completions wire format
is the lingua franca that covers DeepSeek, OpenRouter, Together,
Groq, Mistral, and OpenAI proper — so 13a.5 stacked three
streaming providers into the same document concurrently for the
price of one extra enum branch.

And then the streams ran so fast Christian couldn't actually
*see* them, which is how 13b — the first manual-trigger
component, `:::button` — turned into the closing beat.

Four stages. One Friday. The live-document substrate is now
driven by clicks and remote inference.

## Stage 12 — async I/O channel

Session 5 captured the architectural direction as
[`memory/feedback_async_io.md`](../.claude/projects/-home-chrisbe-dev-terminal/memory/feedback_async_io.md):
network / file / LLM streams run on a worker thread, results come
back to the main thread via a lock-free channel. The renderer
never blocks.

Christian pointed at valkyr's `Jobs.zig` — a Chase-Lev work-
stealing thread pool — and said "it's probably not exactly what
we need, but it'll be useful." Right on both counts.

### Why jobs.zig wasn't enough on its own

`JobSystem` is **fork-join**. The main thread schedules N jobs,
calls `waitFor(counter)`, spin-helps until they all finish.
Designed for frame-bounded CPU parallelism: parallel mesh build,
parallel layout, parallel anything-the-frame-needs.

That's the wrong shape for I/O. An HTTP fetch can hold a worker
for hundreds of milliseconds — sometimes seconds. The renderer
cannot `waitFor` it. We need **fire-and-forget**: submit a
request, get a handle, keep rendering at 60 Hz, pick up results
opportunistically.

So jobs.zig ports verbatim as `src/jobs.zig` and becomes the
foundation primitive (we'll reuse it later for parallel layout
and mesh build), and `src/io_channel.zig` layers on top with the
fire-and-forget shape.

### IoChannel shape

```zig
pub const IoChannel = struct {
    pub fn submitHttpGet(url, user_data) !Handle;
    pub fn submitHttpStream(req, user_data) !Handle; // stage 13a
    pub fn drain(ctx, handler) usize;
};

pub const Completion = struct {
    handle: Handle,
    user_data: usize,  // round-tripped untouched
    result: union {
        ok: []u8,           // one-shot success
        err: anyerror,      // one-shot error
        chunk: []u8,        // stream chunk (more follow)  [stage 13a]
        end: void,          // stream done                 [stage 13a]
        end_err: anyerror,  // stream errored              [stage 13a]
    },
};
```

`submit*` packages the request into a Job, schedules it on the
pool, returns immediately with a Handle. The worker runs the
blocking I/O. When done, it pushes one or more Completions onto a
mutex-guarded MPSC queue. Main thread calls `drain(handler)` once
per frame to flush.

### Why mutex, not lock-free MPSC

Completion volume is *tiny*. A handful of fetches per second,
drained at 60+ Hz. Contention is essentially zero. A real Vyukov
MPSC ring would add complexity that's not load-bearing yet.
Swap one in if load ever justifies. Boring code, fast enough.

### The Pending↔Component cancellation invariant

The trickiest part of stage 12 wasn't the channel — it was the
discipline for what happens when a Component dies *between*
submitting a request and receiving the completion.

Consider: `:::embedded-document {src=http://...}` submits a fetch
on first mount. The renderer GC sweeps the component four parses
later because the parent stopped referencing it. Forty seconds
after that, the network finally responds.

The completion handler now holds a `user_data` that *was* a
component pointer. If we follow it, we dereference freed memory.

Solution: indirection through a heap-allocated `PendingFetch`.
The Component holds a back-pointer to the Pending; the Pending
holds a (nullable) forward-pointer to the Component:

```
       owns lifetime
PendingFetch  ←──────── completion handler  (main thread, drain)
     │
     │ component: ?*Component    ← null = cancelled
     ▼
 Component
     │
     │ pending: ?*PendingFetch   ← used only for cancel-signal
     ▼
 (deinit_: if (c.pending) |p| p.component = null;)
```

The completion handler **owns** Pending's lifetime — frees it
when the completion arrives, regardless of whether the Component
is still alive. The Component **only** holds Pending for the
signal-cancel call in `deinit_`.

The instinctive opposite — Component owns Pending, frees it in
deinit — segfaults when the worker tries to post the completion
into freed memory. We never wrote that version, but the
discipline is easy to invert under refactor pressure, so it's
saved as [`memory/project_io_channel_cancellation.md`](../.claude/projects/-home-chrisbe-dev-terminal/memory/project_io_channel_cancellation.md)
alongside the symptom signature.

### Stage 12 verification

`embedded_document.cachedFetch` migrated from synchronous to
async. The Component grew `phase: {ready, loading, failed}`. URL
fetches that miss the in-memory cache return a Component in
`.loading` that renders a soft-grey "loading {url}…" placeholder.
When the completion lands, `fulfillFromBytesWithOverlays` parses
the body, swaps to `.ready`, bubbles `state.dirty`.

The interesting subtlety: the parent-overlay attrs (the `key=val`
pairs on the `:::embedded-document` block that get layered onto
the child's frontmatter) are snapshotted into the Pending. If the
parent re-parses while the fetch is in flight, the Component's
`update()` arm refreshes the snapshot on the Pending too — so
when the completion lands, the *latest* parent values land on top
of the frontmatter. Parent always wins, even mid-flight.

Local `src=` paths stay synchronous. Filesystem reads are fast
and the loading-state machinery isn't worth the complexity there.

Demo runs at ~9.3k fps Release with the full stack + the migrated
async fetch — async path costs essentially nothing on the hot
path. Commit: `6045f2b`.

## Stage 13a — `:::llm-stream`

With async I/O landed, the LLM tier was the obvious next stop.
The wire format already existed: chat-completion streaming has
been a stable shape across providers since ~2024. The plumbing
already existed: `IoChannel` just needed to learn streaming, the
component just needed to layer markdown re-parse on top.

### IoChannel grows streaming

Three new `Result` variants:

- `.chunk: []u8` — partial response bytes; more completions
  follow under the same Handle. Body ownership identical to `.ok`.
- `.end: void` — stream finished cleanly. Handle retires.
- `.end_err: anyerror` — stream errored mid-flight. Handle
  retires.

`submitHttpStream` takes a `HttpStreamRequest` with `method`
(GET / POST), optional `body`, optional `content_type`, and a
`chunk_size` knob for read-buffer granularity. The worker uses
the lower-level `std.http.Client.open` + `req.send/wait/read`
loop instead of the high-level `fetch` (which buffers the whole
body). Each `req.read(buf)` of N>0 bytes produces one `.chunk`
completion owning a slice of exactly N bytes; EOF produces an
`.end`; any error along the way produces an `.end_err`.

The mutex queue stayed. Even at 100 tokens/second, that's 100
completions/second — three orders of magnitude below where the
lock-free MPSC would start to matter.

### `:::llm-stream` component

```markdown
:::llm-stream {#chat model=qwen3.5:2b prompt="..."}
:::
```

`create()` packages a JSON request body (`stream: true`,
`think: false`), submits via `submitHttpStream`, returns a
Component in `.loading`. The loading placeholder shows
"{model} thinking…" until the first chunk lands.

The chunk handler is the key piece. Ollama emits NDJSON — one
complete JSON object per `\n`-delimited line. But raw socket
reads don't land on line boundaries, so the Component carries a
`line_buf` that accumulates incoming bytes; each chunk appends to
the buffer; the handler drains all complete lines, parses each as
JSON, extracts `message.content`, and appends to a separate
`content` buffer that holds the *accumulated user-visible text*.

After draining lines, the component re-parses the **whole**
content buffer as markdown — `arena.reset(.retain_capacity)`,
then `parseWithStateAndScope`. The new Element tree replaces
`Component.root`. The parent's `state.dirty` bubbles. Next frame
re-lays out.

So as tokens arrive: `"# "` → `"# H"` → `"# Hi\n\n"` → `"# Hi\n\nVulkan"` →
re-parse each time → the heading appears, then the body, then the
next line, then the next. Markdown structure materialises in real
time.

### Phases

- `.loading` — submitted, no chunks yet. Grey-green "thinking…"
  placeholder.
- `.streaming` — first chunk arrived. Render the parsed
  `Component.root`.
- `.done` — stream ended cleanly. Same render as `.streaming`,
  just no further re-parses.
- `.failed` — stream errored. Red "LLM stream failed: …"
  placeholder with the error name.

Cancellation discipline identical to stage 12. Re-parse cost
shows up as an FPS drop from ~9.3k to ~5.9k *during* active
streaming; recovers to ~9k after. That's the per-chunk full-
document re-parse paying for itself in clarity. The right fix
(retained layout cache — skip re-walks when neither the tree
nor inputs changed) is captured on the roadmap; load-bearing
now, parked until a quiet day.

Demo gained one block prompting qwen3.5:2b for a Vulkan haiku.
Watching `## Heading` appear, then the first line, then the next
— for the first time in the substrate's history, the document
was authoring itself in real time.

## Stage 13a.5 — multi-provider

Christian's offer to test against a remote model turned into the
defining architectural insight of the day.

The journey: he mentioned Gemini first; then DeepSeek (OpenAI-
compatible, said his credits were unbounded); then realising he
had `OPENROUTER_DYNABOOK` in `~/.env` too. Three remote
providers, none of them new infrastructure.

Because OpenAI's `POST /chat/completions` SSE streaming wire
format is **the** lingua franca:

```
data: {"choices":[{"delta":{"content":"# "}}]}

data: {"choices":[{"delta":{"content":"Hi"}}]}

data: [DONE]

```

This shape covers OpenAI proper, **DeepSeek**, **OpenRouter** (which
itself fronts dozens of upstreams), **Together**, **Groq**,
**Mistral**'s OpenAI-compat endpoint, **Claude via OpenRouter**,
**Gemini via OpenRouter**. The only providers that *don't* speak
it are Anthropic-direct and Gemini-direct, both routable through
OpenRouter anyway.

So `:::llm-stream` grew exactly one new enum branch:

```zig
pub const Provider = enum { ollama, openai };
```

with per-provider dispatch on:
- **body builder**: `buildOllamaBody` vs `buildOpenAiBody`
  (`max_tokens` vs `options.num_predict`; `think:false` is
  Ollama-only).
- **chunk parser**: `drainNdjsonLines` (split on `\n`, parse
  each non-empty line) vs `drainSseEvents` (split on `\n\n`,
  extract `data: ` payloads, handle `[DONE]` terminator, skip
  comment lines).
- **content extractor**: `message.content` vs
  `choices[0].delta.content`.
- **auth**: none for Ollama; `Authorization: Bearer {key}` for
  OpenAI-shape.

### Bearer auth needed plumbing too

`IoChannel.HttpStreamRequest` grew `extra_headers: ?[]const Header`.
Worker dupes the headers into its context, then assembles a
`std.http.Header` slice including content-type (default
`application/json` when a body is set) plus the extras, hands it
to `client.open(..., .extra_headers = ...)`. Three lines of
mechanism that opens up every future header use case (custom
org IDs, version pins, anything).

### API keys

Christian had keys in `~/.env`: `DEEPSEEK_DYNABOOK`,
`OPENROUTER_DYNABOOK`, and several others he'd accumulated for
unrelated work.

So `src/dotenv.zig` arrived — 200 lines, deliberately tiny:
KEY=VALUE lines, optional matching surrounding quotes, comments
and blank lines ignored, last-write-wins on duplicates, CRLF
tolerated. 7 unit tests. Loads lazily from `$HOME/.env`. Process
env vars are *not* consulted — one source of truth, easy to
reason about, add a fallback later if a deployment needs it.

The `:::llm-stream` factory reads `api_key_env=NAME` from the
spec, looks up `NAME` in the dotenv map, formats `Bearer {key}`,
ships it as the extra header. The key never lands in stdout,
never in a log line, never in a string-formatted URL.

### Three providers concurrently

The demo gained two more blocks. Local Ollama qwen3.5:2b (NDJSON,
no auth). Remote DeepSeek `deepseek-chat` via
`https://api.deepseek.com/chat/completions`. OpenRouter fronting
`google/gemini-2.5-flash` via
`https://openrouter.ai/api/v1/chat/completions`.

Three streams launch on parse. Three workers run three blocking
read loops in parallel. Three completion streams interleave on
the drain queue. Three Components grow three child Element trees.
The renderer doesn't notice — each frame, drain takes a
millisecond, dispatches each completion to `llm_stream.
handleCompletion`, three component instances mutate, dirty
bubbles, layout re-runs.

~7.6k fps Release with all three live. The async path cashes its
dividend: blocking I/O is unconditionally off the hot path. The
worker thread is doing 20-150 tokens/second of network read
work, and the renderer doesn't care.

Wire-format reference saved as
[`memory/reference_llm_streaming_wire.md`](../.claude/projects/-home-chrisbe-dev-terminal/memory/reference_llm_streaming_wire.md)
so the next contributor doesn't have to re-derive the dispatch
table. Commit: `b2bd333`.

### One sharp edge: routing

`IoChannel.drain` calls a single handler. Stage 12 had one
consumer (embedded-document). Stage 13a had two
(embedded-document + llm-stream).

The current dispatch in `main.zig`'s `drainHandler` switches on
*result kind*:

```zig
switch (comp.result) {
    .ok, .err => embedded_document.handleCompletion(comp),
    .chunk, .end, .end_err => llm_stream.handleCompletion(comp),
}
```

Fragile-by-design. The moment a third consumer issues
`http_get`, the routing collides. The proper fix is a router
table keyed by `user_data` (tagged or via a generation map) but
v0 lives with the kind switch. Documented in the code comment +
the roadmap.

## Stage 13b — `:::button`

The streams completed so fast that Christian, watching from his
chair, couldn't actually *see* them paint. The model first-token
latency plus a few hundred tokens at 50-150 tok/s adds up to
about a second total. Sub-blink for the local Ollama. Visible
but blurry for the remote ones.

So: a button. Click → trigger the stream. Click again → trigger
again. See it fresh every time.

### `:::button` shape

```markdown
:::button {#run_local label="Run local (Ollama)" target=#chat_local action=start}
:::
```

Renders a clickable blue rectangle with the label centred. The
`vtable.on_input` arm fires on primary `mouse_up`, calls
`registry.handleUpdate(target, action, body)`. The `#` prefix on
`target=` is stripped. Component-target only for v0 — pair with
the existing `:::update` byte-stream emitter when state-target
dispatch is needed.

Important detail: the input dispatch in element_layout already
passes `LayoutCtx.state` through to the Hit, but the button
doesn't *use* the state pointer. It uses the registry. So a
button inside an `:::embedded-document` still reaches the *host*
registry, which is the right semantics (a button in a child doc
that triggers a parent-scope component, or a sibling in the
child's scope — both work).

Hover state is not yet plumbed. The hit-test layer carries
clicks, not enter/leave. Stage 13d or so when that matters.

### `:::llm-stream` learns to be triggered

`auto_start=false` attribute (default `true` preserves prior
behaviour). When false, `create()` sets phase to `.idle` instead
of `.loading` and skips the initial submit. The `.idle`
placeholder is a subtle grey "qwen3.5:2b — ready" box.

`handle_update(ctx, action, body)` was added to the factory.
Today's only recognised action is `start`. It triggers the new
`kickStream(c)` function, which:

1. Nulls the in-flight Pending's `.component` back-pointer (any
   chunks already queued will land but be discarded — same
   cancellation discipline as stage 12).
2. Clears the content buffer + line buffer.
3. Resets the arena (drops the cached parsed tree).
4. Resets `Component.root` to an empty paragraph.
5. Builds a fresh request body + auth headers (still in scratch
   arena; `submitHttpStream` dupes everything it needs).
6. Creates a fresh Pending, calls `submitHttpStream`.

`kickStream` is now the single submission path. First-mount via
`create()` calls it once; click-driven re-fires call it many
times. Same code path, same cancellation discipline.

### What the demo looks like now

Three sections, each with a button above an idle stream block:

- Run local (Ollama) → `qwen3.5:2b — ready` → click →
  `qwen3.5:2b thinking…` → markdown materialises.
- Run DeepSeek (remote) → `deepseek-chat — ready` → click →
  `deepseek-chat thinking…` → markdown materialises.
- Run Gemini-Flash (via OpenRouter) → `google/gemini-2.5-flash — ready`
  → click → markdown materialises.

Click any button repeatedly to re-run that provider. Petunia
approved. Commit: `ed01221`.

## Bug-class lessons

### Pending↔Component cancellation, generalised

Stage 12 introduced it for the one-shot case. Stage 13a needed
exactly the same shape for streams. Stage 13b's re-fire path
needed it once more — `kickStream` cancels an in-flight by
nulling the back-pointer before submitting the new one.

Three uses of the same pattern in three stages. The pattern's
proper home is in `memory/project_io_channel_cancellation.md`,
saved during stage 12.

The general rule: when an async operation has unbounded duration
and the requester might die before the completion lands, the
completion handler must own the indirection struct. The
requester only holds a back-pointer for cancel-signal. Never the
reverse.

### OpenAI wire as lingua franca

The architectural lesson of 13a.5. If you build a streaming-LLM
client, build it for OpenAI's chat-completion wire first. You
get the entire ecosystem minus two providers (which are routable
through OpenRouter anyway). The shape:

- POST `/chat/completions`
- `Authorization: Bearer {key}`
- Body: `{model, messages, stream:true, max_tokens}`
- Response: SSE `data: {json}\n\n` events; `[DONE]` terminator
- Per chunk: `choices[0].delta.content`

Reference table: `memory/reference_llm_streaming_wire.md`.

### Routing fragility

Result-kind dispatch in `drainHandler` is the kind of trick that
works *until*. It's working now because each kind has exactly
one consumer. It will stop working the day a second component
type issues an `http_get` (a content-addressable disk cache?
prefetch warm-up? content negotiation?). Fix: tag `user_data`
with a discriminator, or maintain a `Handle → handler` map.

Captured in the code comment and on the roadmap. Don't refactor
ahead of need — but recognise the trip-wire when it pulls.

### Re-parse-per-chunk

The 9.3k → 5.9k FPS drop *during* active LLM streaming is the
load-bearing reason retained layout cache became urgent on the
roadmap. Each chunk does a full markdown reparse (cmark walks
the AST, mapper emits the Element tree), then a full layout walk
(textbox + line break + glyph shape across every leaf). The
content buffer grows monotonically, so each reparse does
strictly more work than the last.

The fix is straightforward: cache per-Element layout output;
invalidate only when the Element's own ctx changes (state attr
substitution, content append). Stream-grown trees would
re-layout *only* the newly-added trailing nodes. The 9k floor
becomes the streaming-active rate, not the streaming-idle rate.

Parked because (a) it's a substantial component-by-component
audit, (b) demo runs fine at 5.9k anyway, (c) the right design
deserves its own session. But the cost is now load-bearing,
which it wasn't before stage 13a.

### Switch arms when adding union variants

Adding `.chunk / .end / .end_err` to the `Result` union broke
nothing at compile time — Zig 0.14 is more permissive about
non-exhaustive switches on tagged unions than I'd remembered.
Defensively added arms in `embedded_document.handleCompletion`
that release any owned bytes for the never-reachable cases.
Cheap insurance. Worth doing every time a discriminator grows.

## What ships at session 6 close

Four stages in one Friday. The substrate is now driven by clicks
and remote inference.

- **12 — Async I/O channel.** Work-stealing thread pool in
  `src/jobs.zig` (Chase-Lev deque, ported from valkyr) +
  `IoChannel` in `src/io_channel.zig` (fire-and-forget submit,
  mutex-guarded MPSC drain, per-frame `drain(handler)`).
  `embedded-document` HTTP fetch migrated off the main thread.
  Cancellation discipline captured in memory.
- **13a — Live LLM authoring.** `IoChannel` gained streaming
  variants. `:::llm-stream` component does NDJSON line-buffered
  chunk parsing, markdown-re-parse-per-chunk, child Element tree
  grows token-by-token. Ollama qwen3.5:2b authoring Vulkan
  haikus in the document.
- **13a.5 — Multi-provider.** `provider=openai` covers DeepSeek,
  OpenRouter, OpenAI, Together, Groq, Mistral, and anything else
  that speaks the SSE chat-completion wire. `IoChannel` grew
  `extra_headers` for Bearer auth. Tiny `src/dotenv.zig` reads
  API keys from `~/.env`. Three providers stream concurrently
  into the same document.
- **13b — Button → LLM trigger.** `:::button` component
  (clickable rect → `registry.handleUpdate`). `:::llm-stream`
  grew `auto_start=false` + `Phase.idle` + `handle_update`
  arm. The `kickStream` submission path is reusable for both
  first-mount-fire and click-driven re-fire.

Plus three memory entries:
- `project_io_channel_cancellation.md` — Pending↔Component
  lifetime discipline.
- `reference_llm_streaming_wire.md` — OpenAI wire as lingua
  franca; per-provider quirks table.
- Updated `project_text_engine.md` with the session-6 outcome.

**~14,000 LOC, ~85 unit tests, ~7.5k fps Release idle with three
provider Components installed (no streams firing).** During
active streaming the floor drops to ~5.9k pending the retained
layout cache.

Four commits on master:

- `6045f2b` — stage 12: async I/O channel
- `b2bd333` — stage 13a + 13a.5: live LLM authoring + multi-provider
- `ed01221` — stage 13b: button + manual trigger

The Hitchhiker's Guide became real today. Markdown is the
declarative interface. The LLM is just another author. The
button is the user's hand on the wheel.

## Next entry points for session 7

Captured during the session close:

1. **Stage 13c — input field.** Closes the user→LLM authoring
   loop. A `:::input` text field (single-line cursor, type/
   backspace, arrow keys, write to a state path) plus the small
   twist of letting `:::button` pass its `body=` as a prompt
   override to `:::llm-stream`'s `handle_update(action=start,
   body=...)`. End result: type a question, click send, watch
   the answer stream in below. The v1 chat-with-your-document
   experience. Text input is its own little subsystem (cursor,
   editing, focus, eventually selection/IME) so 13c-i ships
   minimal then layers on later.

2. **Stage 13d — SVG / vector graphics.** Recraft V4.1 on
   OpenRouter generates real SVGs from text prompts. The pieces
   for a `:::svg` (or `:::image`) component are mostly in place:
   the registry, the layout contract, async fetch via IoChannel.
   What's missing is an SVG parser → quad/glyph emission path.
   Christian had Recraft generate "A bowl of petunias" — pure
   live-document magic when the same prompt-and-stream
   substrate that authors markdown also draws the figures.

3. **Retained layout cache.** Per-Element caching to reclaim the
   per-chunk re-layout cost. Now load-bearing because of 13a's
   re-parse pattern. Maybe sized right for after 13c-i ships and
   before the SVG work — quiet day, focused diff.

4. **Stage 10 — headless documents.** Still parked. Cleanest
   composition-track completion. Doesn't block 13c/13d.

5. **Crisp zoom.** Multi-size atlas + re-layout on zoom change.
   Same as session 5's note.

6. **Persistent URL cache.** Content-addressable disk cache for
   remote sources. Becomes more interesting once SVG generation
   lands — caching a generated petunia bowl across program
   restarts saves both money and time.

The arc bends toward the user actually *using* the substrate.
Session 6 made it streamable; session 7 makes it interactive.
Then come the figures.

Catch you next time, Hitchhiker.
