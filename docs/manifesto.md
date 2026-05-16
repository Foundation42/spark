# Manifesto — markdown is the substrate

> **Markdown is not a presentation format.** It is the working
> medium of humans, agents, and machines together. Treat it as
> such. Build the runtime that makes it live.

This is what we are building in `~/dev/terminal/`. A live-document
runtime where markdown is the **declarative interface** to a
component-driven, Vulkan-native, LLM-aware substrate. Not a viewer.
Not a renderer-on-the-side. The medium itself.

Originally written 2026-05-16, mid-session-9, in response to the
recent push from some quarters to default LLM outputs to HTML
instead of markdown. We disagree, and the disagreement is
structural — not aesthetic. Last updated 2026-05-16, end of
session 13 — homoiconic claim sharpened through external review.
The middle has settled; the claim still stands.

---

## The wrong fork

The argument is being made that LLMs should default to HTML
output: richer presentation, denser information, interactive
artifacts. With a million-token context window, the token overhead
is "negligible". With a browser as the viewer, the rendering is
"free".

This is the view from inside a closed ecosystem. From outside it,
the calculus inverts.

- **Markdown diffs.** HTML diffs are a wall of tags around a
  three-character textual change. Markdown is line-oriented and
  fits the way humans, version control, and code review actually
  work. The "free" presentation costs you everything downstream.
- **Markdown round-trips.** Markdown is something a human can
  read in a terminal, paste into an issue tracker, commit to a
  repo, and an LLM can read back without parsing. HTML round-trips
  only inside a browser.
- **Tokens are budget.** A million-token context is not an excuse
  for inefficient encoding; it is a resource to spend on
  *reasoning*. Every `</td></tr><tr><td>` is a token the model
  could have spent on the answer.
- **Structural tracking is real cost.** Even frontier models drop
  closing tags under load. Smaller, edge-deployed, locally-run
  models hit the wall much sooner. HTML-first defaults pull the
  ladder up behind the only models that can afford the format.
- **Extension is the seam; capture is closing it.** Markdown
  gets extended — it has happened at least twice already (GFM,
  MDX), and our own `:::name {attrs}` is the third. The question
  isn't whether to extend; it's whether the extension layers onto
  a surface anyone can read or whether it locks rendering to a
  single viewer. HTML-first output looks rich inside a specific
  renderer and is sludge outside it. That isn't progress; it's a
  moat. The geology says extension wins on the open surface;
  capture is what loses.

CommonMark already won the format war for a reason. It is the
ground that humans, agents, terminals, READMEs, PR descriptions,
issue trackers, and `gpt-{anything}` all stand on. Anything richer
should be **layered on top of markdown, not replace it.**

That is what this project is.

---

## What we believe

### 1. Markdown is ground truth.

It is what flows between humans and agents in 2026, and it is
what should flow inside our substrate too. The renderer's job is
to make markdown more capable, not to replace it with a format
only the renderer can read.

### 2. Extend, don't replace.

CommonMark has an extension point: fenced blocks with attributes.
We use `:::name {attrs}` for block extensions. An HTML block in
the middle of a markdown doc is the same shape. Mermaid, KaTeX,
custom widgets — all of these layer in without leaving the format.

```markdown
:::chart {#telemetry capacity=600 color=cyan}
:::

:::llm-stream {provider=openai model=deepseek-chat
               prompt="explain entropy in three lines"}
:::

:::svg-stream {model=recraft-v3 prompt="A bowl of petunias"}
:::
```

The renderer dispatches `:::name` to a registered factory.
Everything else is markdown. A human can read the file. Git can
diff the file. An LLM can author the file. The runtime makes the
file *do things*.

### 3. Tokens are precious.

Every output token costs latency, money, and reasoning bandwidth.
A format that makes the model emit `<span class="hl">x</span>` to
say `**x**` is a regression dressed as progress. The substrate's
job is to do more with fewer tokens, not the reverse.

### 4. Close to the metal.

Zig + Vulkan, no web layer, no DOM, no JavaScript runtime. Glyphs
go through HarfBuzz to a custom atlas to one `vkCmdBeginRendering`
pass. Quads, triangles, raster images, text — one pipeline order,
one draw stream. ~7,600 fps Release at idle with the full demo
loaded; ~13k fps when nothing is animating. Performance is not
a feature — it is the *budget* we spend on the live, reactive,
per-glyph behaviour that the LM tier needs.

### 5. Composition is a flywheel.

Documents *are* components. `:::embedded-document {src=...}` is
a built-in factory that parses another markdown file (local, HTTP,
content-hash, future MCP) and grafts it into the host. Reactive
state crosses the network boundary. Headless documents run as pure
state machines with no viewport. The friction to publish a new
component is the friction of writing a markdown file. The substrate
gets richer every time someone writes a document.

### 6. Provenance is a host policy.

A component can come from a built-in factory, a remote RPC, a WASM
module, an LLM inference call, or a SPIR-V shader. The `Factory`
contract (`create / update? / handle_update? / deinit?`) is
deliberately provenance-agnostic. The same registry that holds
`:::box` holds `:::llm-stream` holds `:::svg-stream`. Five
provenances, one shape.

### 7. The LLM is a component author, not just a chat partner.

The LM tier streams markdown into the document. The document is
live. `:::update {#id action=...}` directives skip layout entirely
and route bytes to a named component's buffer at >10kHz. This is
the loop: human writes markdown → markdown becomes a live runtime
→ LM streams more markdown into it → reactive state propagates
→ components mutate → screen updates. The same format the human
authored, the LM amends. There is no impedance mismatch.

### 8. The substrate is homoiconic.

Homoiconicity is representational identity between program text
and the data the language manipulates. It says nothing about
determinism — `(random)` doesn't return the same value twice and
nobody calls that a crack in LISP. The claim decomposes into
four axes, all the same kind of property:

**i. Representational identity.** The serialised form (markdown
text) and the runtime form (parsed component tree feeding the
layout walker) are the same shape. An author types `:::grid`, the
parser produces a Grid component, the renderer lays it out, and
the result serialises back to `:::grid`. A `:::flex` inside a
`:::grid` inside an `:::embedded-document` is the same tree to
the runtime as it is to the eye reading the file. No XAML between
author intent and runtime behaviour; no JSX compiler turning one
syntax into a different tree; no DOM that is a different artifact
from its source.

**ii. Source/image gap closed in practice.** A typical LISP image
does not rewrite its own on-disk source as it runs — exotic,
rare. Our substrate's normal operating mode is that. The document
tree IS the source representation; when `:::llm-stream` streams
output, it streams markdown directly into the live document, and
serialising the runtime hands back markdown the parser can re-eat.
No lossy compile step between source and image.

**iii. Modification surface in authored syntax.** At the document
layer there is no structural API by which a component reaches
across the tree and rewrites siblings. Composition happens by
emitting markdown the parser re-eats; no substructural mutation
interface exists. The runtime underneath constructs element trees
directly in Zig — that's plumbing, same as LISP's `read` is C
code building cons cells — but the only mutation surface the
document exposes to its own components, to LMs streaming into it,
or to human authors, is the surface syntax. Tree changes happen
by re-parse, not by structural poke. This is the load-bearing
invariant: **runtime state must always be representable in
source.** Any future API that breaks this would first have to
argue the substrate's central claim was wrong.

**iv. Surface as fixed point.** The serialised surface is
simultaneously three things at once: the surface a human authors,
the form the runtime executes, and the representation the
comprehender (LM) is most fluent in. One artifact, three readers
— human, runtime, model — no translation layer between any pair.
This is substrate-intrinsic, not plugin-relative: bolt an LM onto
a LISP REPL and you get comprehension, but the model's
high-fluency surface and S-expressions don't coincide, so the
impedance wall stays. Ours coincide. And the coincidence isn't a
2026 corpus accident — markdown is the comprehender's high-fluency
surface because it is the human's structured-prose surface, and
any future comprehender useful to humans is selected for fluency
in the human-legible surface. The triple coincidence is a
convergent attractor, not a temporary fact. The HTML-first push
isn't a world where this coincidence is absent — it's the choice
not to stand on it. The fixed point holds; the ecosystem declines
the surface anyway. That is what "The wrong fork" is about.

This is the LISP property in a UI context — and it generalises
one axis further than LISP itself. Markdown is the LISP of
collaborative documents: the runtime accepts the same shape it
emits, an LM streams more of the same shape, a human reads the
result. An LLM streaming markdown is streaming UI; a `:::input`
targeting an `:::llm-stream` is a document extending itself. HTML
doesn't have this property; XAML can't reach it; React's fiber
tree is a different artifact from its JSX source.

There is no compile step between writing UI and running UI. There
is no separate format the renderer "understands" that the source
doesn't. There is no template language standing between author
and pixels. The format is the program; the program is the format;
the parse is the build — and the surface is the fixed point where
author, runtime, and comprehender meet without translation.

---

## What's built

Thirteen sessions in (2026-05-14 → 2026-05-16). The substrate is
real, not a sketch.

- **Element contract** — one tagged union (text, paragraph,
  heading, list, code, quote, custom, etc.) that *every* producer
  emits and *every* consumer walks. Open at the seams via
  `custom { vtable, ctx }`.
- **Markdown engine** — cmark 0.31.2 vendored; full CommonMark
  plus `:::name {attrs}` block extensions, YAML frontmatter
  reactive state, `${state.x}` interpolation.
- **ANSI engine** — same Element contract, second producer. UTF-8
  + SGR + 256-colour + truecolor. Closes the markdown↔terminal
  composability loop.
- **Live components** — `:::box`, `:::chart`, `:::slider`,
  `:::button`, `:::input`, `:::svg`, `:::embedded-document`,
  `:::llm-stream`, `:::svg-stream`, `:::image-stream`.
- **Reactive state** — single global store, `${path}`
  interpolation, per-binding subscribers, dirty-bubble across
  embedded documents.
- **Async I/O** — work-stealing job pool for compute, dedicated
  blocking-I/O pool for HTTP and LLM streams. Main thread never
  blocks. LLM streams ride the same channel as file watchers,
  remote-document fetches, and image generation.
- **LLM authoring** — `:::llm-stream` against any
  `POST /chat/completions` SSE provider (DeepSeek, OpenRouter,
  OpenAI, Together, Groq, Mistral, local Ollama). Re-parses the
  growing message as markdown on every chunk; the document
  grows token-by-token, live.
- **Vector + raster authoring** — `:::svg-stream` (Recraft V4.1)
  generates SVGs from prompts; tessellated in parallel across
  the compute pool (8.17× speedup), drawn through a Vulkan
  triangle pipeline. `:::image-stream` (Gemini image preview)
  decodes base64 PNG into a per-component `VkImage`.
- **Recursive composition** — `:::embedded-document` over local
  paths or HTTP URLs. Scoped cache keys. Parent-overlay attrs.
  State dirty bubbles up; subscribers stay scoped.
- **Persistent layout cache** — retained per-block layout
  output, content-version keyed. 97.9% hit rate at idle. The
  chart can fire at 60 Hz without re-walking the paragraph above
  it. Parallel cache-miss walks fan out across a work-stealing
  pool when the cost threshold justifies it.
- **Constraint substrate** — pure-Zig port of Cassowary (the
  kiwi C++ solver), ~3,000 LOC and 300+ tests. Wrapped in a
  `LayoutContext` that every constraint-aware provider
  participates in. Mutexed for the parallel walker so workers
  can negotiate against the same solver without racing.
- **Layout primitives** — `:::flex` (1D row/column with gap) and
  `:::grid` (2D, mixed `100px 1fr 1fr`-style track lists,
  independent `row-gap` / `column-gap`). Both share the same
  solver under the hood. Each cell still constrains its own
  bounds; the parent allocates the track.

~20,000 LOC of our own Zig + GLSL. ~300 unit tests. Three
concurrent LLM streams, one live SVG generator, one live raster
generator, a 60 Hz chart, plus 1D + 2D constraint-driven layout
all in the same document, all ~7,600 fps Release.

---

## What we refuse

- **HTML as the in-band format.** It is the wrong currency. If
  a renderer needs HTML, that is the renderer's problem, not the
  format's.
- **JavaScript hydration.** Live behaviour comes from native
  components registered with the host, not a runtime that costs
  150 MB of memory and a JIT.
- **Closed presentation moats.** If the document only renders in
  one viewer, the document is hostage. Ours render the same
  source in this engine, in any markdown viewer (statically), and
  in a terminal (degraded gracefully). The richer behaviour
  layers on; the baseline always works.
- **Hidden state.** The frontmatter is the state. The directives
  are the components. There is no compiled artifact, no bundler,
  no opaque blob. You can read what runs.
- **Bandwidth-as-license.** A million tokens of context is not
  permission to be wasteful with the other 999,000. Tokens are
  reasoning budget. Format efficiency compounds at every layer.

---

## Why this matters now

The wider AI ecosystem is at a fork. Down one path is HTML-first
output, viewer lock-in, and presentation formats that only their
authors can render. Down the other is markdown as the durable
substrate — human-readable, agent-writable, version-controllable,
viewer-agnostic — with rich behaviour layered on top.

We are betting on the second path because it is the only one
that scales beyond a single company's UI. Markdown is the only
format where a human in a terminal, an LLM in a context window,
a code reviewer on GitHub, a small model on an edge device, and
a native renderer on a GPU all meet on equal footing. Burning
that ground to sell an artifact viewer is a category error.

The substrate we are building is the long-tail bet: that the
right thing to do with markdown is *render it harder*, not
*replace it*.

---

## The horizon

The next sessions extend the substrate in directions the contract
already anticipates. Two horizon items from the first writing of
this manifesto have since landed — **persistent
content-addressable cache** (session 10, `~/.cache/text_engine`)
and **headless documents** (session 10, `headless=true` on any
embed). What remains:

- **GPU-input → solver channel.** A compute shader writes a
  readback buffer per frame; the host wraps the result as
  `solver.suggestValue(var, x)`; surrounding layout reflows
  incrementally. The "fluid sim warps the document" demo. The
  whole constraint substrate was built nominally for this — now
  ready to claim.
- **Text intrusion.** `:::image {flow=around}` — markdown wraps
  around an SVG / raster figure via an `ExclusionShape` layered
  over the settled solver positions. Magazine-grade layout from
  a markdown file.
- **Measure-then-render protocol.** Lifting per-sibling
  negotiation (`flex-grow`, `justify=space-between`) into the
  solver itself, with every layout-aware element gaining a
  measure pass. Closes the loop on what `:::flex` and `:::grid`
  promise but currently approximate.
- **WASM-provenance components.** Drop-in sandboxed modules
  authored in any language that compiles to wasm32.
- **MCP-provenance components.** A component is an MCP server.
  The substrate hosts the bridge.
- **SPIR-V-provenance components.** Direct GPU code as a
  component. The renderer exposes raw Vulkan to the factory.
- **A terminal app** on top of the ANSI engine. The original
  motivating use case, demoted from chapter-one to chapter-N
  because the substrate became bigger than the terminal.
- **Dear-ImGui-tier game UI.** The Element contract was designed
  for this from session 2.

Every one of these slots into the existing Factory shape. The
contract was built to hold them. That was the point.

---

## In one line

**Markdown is the universal interface. Make it live.**

---

> *In the beginning was the markdown. And the markdown said: let
> there be live components. And there were live components. And
> it was good.*
>
> — somewhere in the Encyclopaedia Galactica, mid-2026

> *And the markdown spake further: let there be crisp zoom at every
> magnification, and emoji that flow inline, and ANSI fences inside
> the fences. And it was good.*
>
> — somewhere in the Encyclopaedia Galactica, late session 10

> *And the markdown spake further still: let there be a constraint
> solver beneath the page, and let `:::flex` walk its children in a
> row, and let `:::grid` arrange them in tracks both fixed and
> flexing, and let every cell negotiate its bounds against the
> same solver. And when the worker threads raced for the solver,
> let a mutex hold the line. And the document arranged itself,
> and resized, and held together. And it was good. And it was —
> improbably — still just markdown.*
>
> — somewhere in the Encyclopaedia Galactica, end of session 13
