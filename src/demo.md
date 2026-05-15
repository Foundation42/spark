---
state:
  box_color: blue
  box_width: 240
  box_radius: 12
  box_height: 80
  target_id: "SAT-04"
---

# text_engine

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

## Live components

Block extensions parse into Specs, get resolved through a host-owned registry into cached instances, and survive across re-parses. Templated `${state.x}` attrs subscribe to state mutations through the reactive layer. The host's frame loop streams `:::update {target=state.box_color}` directives at 1.5s intervals — watch the box recolour through the same fast lane an LLM would use.

:::box {#bx color=${state.box_color} width=${state.box_width} height=${state.box_height} radius=${state.box_radius}}
:::

:::slider {#radius_slider target=box_radius min=0 max=40 value=${state.box_radius} width=320}
:::

:::slider {#height_slider target=box_height min=20 max=120 value=${state.box_height} width=320}
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

The block below is *not* a static document — it is being written by a local language model right now, streaming token by token through an [IoChannel](../src/io_channel.zig). Each chunk is line-buffered NDJSON; the `message.content` tokens accumulate into a markdown buffer that is re-parsed and re-rendered on every chunk. Click *Run* to trigger; click again to re-run.

:::button {#run_local label="Run local (Ollama)" target=#chat_local action=start}
:::

:::llm-stream {#chat_local auto_start=false model=qwen3.5:2b prompt="In 4 short lines, write a haiku about Vulkan rendering text glyphs through a markdown document. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Live LLM authoring (stage 13a.5) — remote DeepSeek

Same component, different provider. `provider=openai` switches the body shape (OpenAI-compatible `max_tokens` field, `Authorization: Bearer` header) and the chunk parser (SSE events instead of NDJSON). The API key lives in `~/.env` as `DEEPSEEK_DYNABOOK`; `api_key_env=` names which entry to read. The fetch goes out over real internet — **and the renderer never blocks waiting** because every byte of work happens on a worker thread.

:::button {#run_remote label="Run DeepSeek (remote)" target=#chat_remote action=start}
:::

:::llm-stream {#chat_remote auto_start=false provider=openai endpoint=https://api.deepseek.com/chat/completions model=deepseek-chat api_key_env=DEEPSEEK_DYNABOOK prompt="In 4 short lines, write a haiku about a network packet finding its way home through a worker thread. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Live LLM authoring (stage 13a.5) — Gemini via OpenRouter

Same component yet again, *third* provider — OpenRouter is itself OpenAI-compatible and fronts dozens of upstream models. Pointed at `google/gemini-2.5-flash` here, but `anthropic/claude-haiku-4`, `openai/gpt-4o-mini`, `meta-llama/llama-3.3-70b-instruct`, and others all drop in just by changing `model=`. The OpenAI wire format earned its place as the lingua franca.

:::button {#run_router label="Run Gemini-Flash (via OpenRouter)" target=#chat_router action=start}
:::

:::llm-stream {#chat_router auto_start=false provider=openai endpoint=https://openrouter.ai/api/v1/chat/completions model=google/gemini-2.5-flash api_key_env=OPENROUTER_DYNABOOK prompt="In 4 short lines, write a haiku about three providers streaming markdown into the same Vulkan-rendered document. Use a level-2 markdown heading for the title." max_tokens=120}
:::
