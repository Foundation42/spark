# Manifesto — markdown is the substrate

> **Markdown is not a presentation format.** It is the working
> medium of humans, agents, and machines together. Treat it as
> such. Build the runtime that makes it live.

This is what we are building in `~/dev/terminal/`. A live-document
runtime where markdown is the **declarative interface** to a
component-driven, Vulkan-native, LLM-aware substrate. Not a viewer.
Not a renderer-on-the-side. The medium itself.

Written 2026-05-16, mid-session-9, in response to the recent push
from some quarters to default LLM outputs to HTML instead of
markdown. We disagree, and the disagreement is structural — not
aesthetic.

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
- **Ecosystem capture is the actual play.** HTML output looks
  rich inside a specific viewer. Outside it, it is sludge. Choosing
  a format that only renders in your own UI is a moat. Call it
  that.

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

---

## What's built

Nine sessions in (2026-05-14 → 2026-05-16). The substrate is
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
  it.

~17,500 LOC of our own Zig + GLSL. ~100 unit tests. Three
concurrent LLM streams, one live SVG generator, one live raster
generator, and a 60 Hz chart all in the same document, all
~7,600 fps Release.

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

Sessions 10+ extend the substrate in directions that the
contract already anticipates:

- **Persistent content-addressable cache** for generated SVG /
  image / LLM responses. Deterministic, cheap-to-restart demos;
  cost-recoverable demos.
- **Headless documents** as pure state machines, no viewport.
  Configuration managers, collaborative data routers.
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
