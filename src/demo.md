---
state:
  box_color: blue
  box_width: 240
  box_radius: 12
  box_height: 80
  target_id: "SAT-04"
  config_hidden: "true"
---

# text_engine 🚀✨

Live-document runtime — colour emoji 🎨 flows inline with text 🌸, mathematical signs ✓ ✗ ≈ ≠ ∞ ≤ ≥ pick up the body font, and rich glyphs (rocket 🚀, sparkles ✨, flower 🌸, palette 🎨, party 🎉, star ⭐, fire 🔥, heart ❤️) ride the colour atlas alongside everything else.

## Stage 3 — markdown source becomes the tree

Same renderer as before — only the construction path changed. This document is parsed by *cmark* into an AST, then walked into an `element.Element` tree.

## Inline cascade

This paragraph uses *italic* and **bold** and ***bold-italic*** and `inline code` and a [link](https://example.com).

Underlines honour wrap — [this is a longer link with enough text inside its anchor that it spans more than one line, producing one underline quad per visible line of the link](https://example.com).

## Nesting

- block kinds nest
- indent shrinks `max_w` for nested content
- and items hold multiple blocks:
  1. first nested
  2. second nested

> Quotes indent their content, and indent propagates through Constraints so the inline-flow inside this quote wraps on the narrower available width — not on the full viewport width.

---

## Code

```zig
fn render(elem: Element) !void {
    // code blocks: monospace, preformatted
}
```

A `​```ansi` fence (stage 5b) hands its body to the ANSI parser and embeds the result back as `CodeContent.sub_block` — the layout walker recurses, so SGR foreground colours, **bold**, *italic*, underline (4/24), strikethrough (9/29), and reverse video (7/27) all render inside the same code-block chrome as raw fences:

```ansi
[1mtext_engine [32m✓[0m[0m  build [36mok[0m
[31merror:[0m  out of [33mfuel[0m (recoverable)
[38;5;141mloaded[0m  [1mglyph_cache[0m + [1matlas[0m + [1mshaper[0m
[38;2;255;128;200mtruecolor[0m supported via SGR 38;2;R;G;B
[4munderline[24m + [9mstrikethrough[29m + [7mreverse video[27m
[1;4;36mbold underline cyan[0m, [31;9mred strike[0m, [7;33myellow reverse[0m
```

## Live components

Block extensions parse into Specs, get resolved through a host-owned registry into cached instances, and survive across re-parses. Templated `${state.x}` attrs subscribe to state mutations through the reactive layer. The host's frame loop streams `:::update {target=state.box_color}` directives at 1.5s intervals — watch the box recolour through the same fast lane an LLM would use.

:::box {#bx color=${state.box_color} width=${state.box_width} height=${state.box_height} radius=${state.box_radius}}
:::

:::slider {#radius_slider target=box_radius min=0 max=40 value=${state.box_radius} width=320}
:::

:::slider {#height_slider target=box_height min=20 max=120 value=${state.box_height} width=320}
:::

## Flex layout (stage 15c)

The first multi-child constraint-aware provider. `:::flex` walks its children with cumulative-x positioning, dropping `gap` pixels between siblings. Each child still goes through the kiwi solver for its own bounds — the flex parent computes positions, the children constrain their sizes.

:::flex {#three_boxes direction=row gap=20}
:::box {color=red width=120 height=80 radius=8}
:::

:::box {color=green width=120 height=80 radius=8}
:::

:::box {color=blue width=120 height=80 radius=8}
:::
:::

## Grid layout (stage 15d)

The second multi-child constraint-aware provider. `:::grid` lays its body out into equal-width tracks (`columns=N`), row-major, gap between cells, auto-height rows sized to the tallest cell. Each cell still goes through the kiwi solver for its own bounds — the grid parent allocates the track, the cell constrains its size inside it. `:::flex` handles 1D; `:::grid` handles 2D; both stack cleanly inside each other.

:::grid {#dashboard columns=3 gap=12}
:::box {color=red width=100% height=60 radius=6}
:::

:::box {color=orange width=100% height=60 radius=6}
:::

:::box {color=yellow width=100% height=60 radius=6}
:::

:::box {color=green width=100% height=60 radius=6}
:::

:::box {color=cyan width=100% height=60 radius=6}
:::

:::box {color=purple width=100% height=60 radius=6}
:::
:::

## Composition (stage 9)

The block below is a *whole other document* — `src/widgets/orbit_panel.md` — embedded recursively. Parent attrs (`panel_color=cyan`, `inner_color=magenta`) overlay the child's frontmatter; child components live in the same registry under the scope `orbit/...` so their ids can't collide with the parent's.

:::embedded-document {#orbit src="src/widgets/orbit_panel.md" panel_color=cyan inner_color=magenta}
:::

## Remote composition (stage 11)

The block below is the *same factory* — but loaded over HTTP from a localhost server the demo spins up at startup. `src=` distinguishes filesystem paths from URLs; the URL path goes through `std.http.Client.fetch` and lives in an in-memory cache for the rest of the session. The first bar's colour follows the parent's `state.box_color` cycle — proof that reactive state crosses the network boundary.

:::embedded-document {#remote_orbit src="http://127.0.0.1:8080/remote_panel.md" primary=${state.box_color}}
:::

:::chart {#telemetry type=line min=-1 max=1 width=100% height=140}
:::

## Live LLM authoring (stage 13a) — local Ollama

The block below is *not* a static document — it is being written by a local language model right now, streaming token by token through an [IoChannel](../src/io_channel.zig). Each chunk is line-buffered NDJSON; the `message.content` tokens accumulate into a markdown buffer that is re-parsed and re-rendered on every chunk. Click *Run* to fire the canned prompt, or **type into the input field and hit Enter** to send your own (stage 13c). The button keeps the default prompt around as a quick retry.

:::input {#ask_local target=#chat_local action=start placeholder="Ask qwen3.5… (Enter to send)" width=100%}
:::

:::button {#run_local label="Run default prompt (Ollama)" target=#chat_local action=start}
:::

:::llm-stream {#chat_local auto_start=false model=qwen3.5:2b prompt="In 4 short lines, write a haiku about Vulkan rendering text glyphs through a markdown document. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Live LLM authoring (stage 13a.5) — remote DeepSeek

Same component, different provider. `provider=openai` switches the body shape (OpenAI-compatible `max_tokens` field, `Authorization: Bearer` header) and the chunk parser (SSE events instead of NDJSON). The API key lives in `~/.env` as `DEEPSEEK_DYNABOOK`; `api_key_env=` names which entry to read. The fetch goes out over real internet — **and the renderer never blocks waiting** because every byte of work happens on a worker thread.

:::input {#ask_remote target=#chat_remote action=start placeholder="Ask DeepSeek… (Enter to send)" width=100%}
:::

:::button {#run_remote label="Run default prompt (DeepSeek)" target=#chat_remote action=start}
:::

:::llm-stream {#chat_remote auto_start=false provider=openai endpoint=https://api.deepseek.com/chat/completions model=deepseek-chat api_key_env=DEEPSEEK_DYNABOOK prompt="In 4 short lines, write a haiku about a network packet finding its way home through a worker thread. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Live LLM authoring (stage 13a.5) — Gemini via OpenRouter

Same component yet again, *third* provider — OpenRouter is itself OpenAI-compatible and fronts dozens of upstream models. Pointed at `google/gemini-2.5-flash` here, but `anthropic/claude-haiku-4`, `openai/gpt-4o-mini`, `meta-llama/llama-3.3-70b-instruct`, and others all drop in just by changing `model=`. The OpenAI wire format earned its place as the lingua franca.

:::input {#ask_router target=#chat_router action=start placeholder="Ask Gemini Flash… (Enter to send)" width=100%}
:::

:::button {#run_router label="Run default prompt (Gemini)" target=#chat_router action=start}
:::

:::llm-stream {#chat_router auto_start=false provider=openai endpoint=https://openrouter.ai/api/v1/chat/completions model=google/gemini-2.5-flash api_key_env=OPENROUTER_DYNABOOK prompt="In 4 short lines, write a haiku about three providers streaming markdown into the same Vulkan-rendered document. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Vector graphics (stage 13d.1) — `:::svg`

A new triangle pipeline + CPU tessellator (Bezier flatten + earcut) renders SVG figures alongside the markdown. Recraft V4.1 generated this bowl-of-petunias from a one-line prompt; we load the file from disk, parse the M/L/C/z subset, flatten cubics to polylines, earcut to triangles, and feed the lot through a flat-fill VBO+IBO pipeline. **The Guide approves.**

:::svg {#petunias src=src/test_data/Petunias.svg width=480}
:::

## Live vector generation (stage 13d.3) — `:::svg-stream`

Same triangle pipeline, but the SVG isn't on disk — it's authored by **Recraft V4.1** via OpenRouter. Recraft turns out to be a one-shot image-generation model behind a chat-completions endpoint: the SVG comes back base64-encoded inside `message.images[0].image_url`. We decode, parse, **parallel-tessellate through the JobSystem from 13d.2**, and swap in the mesh. Type a prompt, hit Enter, and after 5–15s of upstream queue the figure pops in. The renderer never blocks — every byte of the HTTP wait happens off-thread on the IoChannel.

:::input {#ask_petunia target=#fresh_svg action=start placeholder="Describe an SVG… (Enter to generate)" width=100%}
:::

:::button {#run_petunia label="Run default prompt (a bowl of petunias)" target=#fresh_svg action=start}
:::

:::svg-stream {#fresh_svg auto_start=false provider=openai endpoint=https://openrouter.ai/api/v1/chat/completions model=recraft/recraft-v4.1-vector api_key_env=OPENROUTER_DYNABOOK prompt="A bowl of petunias, vector art, clean shapes, single bowl viewed from front, transparent background" max_tokens=8000 width=480}
:::

## Live raster image (stage 14c) — `:::image-stream`

Same async I/O lane as `:::svg-stream`, but the data URL is a PNG — and the decode path runs through **stb_image** instead of the SVG tessellator, dropping the pixels into a per-component `VkImage` + sampler. The wire format is identical to Recraft (OpenAI-shaped `/chat/completions`, `stream:false`, image lives in `message.images[0].image_url.url`); only the MIME prefix and decoder swap out.

:::input {#ask_image target=#fresh_image action=start placeholder="Describe an image… (Enter to generate)" width=100%}
:::

:::button {#run_image label="Run default prompt (robot drinking coffee)" target=#fresh_image action=start}
:::

:::image-stream {#fresh_image auto_start=false provider=openai endpoint=https://openrouter.ai/api/v1/chat/completions model=google/gemini-3.1-flash-image-preview api_key_env=OPENROUTER_DYNABOOK prompt="A friendly robot sitting at a wooden table, drinking a steaming mug of coffee. Soft natural lighting." max_tokens=4000 width=480}
:::

## Headless documents (stage 10)

The block below is a `:::embedded-document` with `headless=true`. The
referenced widget contains a heading, a paragraph, a quote block, and
a 200px magenta `:::box` — none of which appear on screen. The doc is
still **parsed**, the frontmatter still populates the child state, the
`:::box` still gets instantiated and lives in the registry under
`config/never_visible`, but `layoutAndRender` short-circuits before
walking it. Use this shape for config docs, cache-warming widgets, or
"model" docs whose state other (visible) docs observe.

:::embedded-document {#config src="src/widgets/headless_config.md" headless=${state.config_hidden}}
:::

The two buttons below are **state-target dispatch** (`target=state.path`)
— they write straight into the demo's `state.config_hidden` value, and
the embed's `headless=${state.config_hidden}` re-resolves through the
reactive Binding subsystem. No `handle_update` involved on this path;
the same lane sliders use, exposed to clicks. (The component-target
`action=toggle-headless` arm on `:::embedded-document` is still wired
for direct/LLM mutation — both paths coexist.)

:::button {#show_config label="Show config doc" target=state.config_hidden body=false}
:::

:::button {#hide_config label="Hide config doc" target=state.config_hidden body=true}
:::
