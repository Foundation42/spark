---
state:
  box_color: blue
  box_width: 240
  box_radius: 12
  box_height: 80
  target_id: "SAT-04"
  config_hidden: "true"
  size_curve: "[1.0, 0.7, 0.0]"
  gain: 1.250
---

# spark 🚀✨

Live-document runtime — colour emoji 🎨 flows inline with text 🌸, mathematical signs ✓ ✗ ≈ ≠ ∞ ≤ ≥ pick up the body font, and rich glyphs (rocket 🚀, sparkles ✨, flower 🌸, palette 🎨, party 🎉, star ⭐, fire 🔥, heart ❤️) ride the colour atlas alongside everything else.

## Inline components

Service health: API ::badge{label="200ms" color=green} cache ::badge{label="stale" color=yellow} queue ::badge{label="13ms" color=green}, all green except auth ::badge{label="503" color=red}. Tracking ::badge{label="PR-1234" color=blue} ::badge{label="draft" color=purple} for the next release.

Latency last hour ::sparkline{data="3,5,7,4,8,6,9,5,7,4,6,8,5,3,7,9,6,4,5,8" color=cyan} steady. Errors per minute ::sparkline{data="0,1,0,0,2,1,0,0,1,3,1,0,0,0,1,0,2,0,0,1" color=orange} mostly quiet. Cache hits ::sparkline{data="92,94,93,95,96,94,93,95,97,95,96,94,93,95,97,96,98,95,96,97" color=green} stable.

Press ::kbd{key="Ctrl+C"} to copy, ::kbd{key="Ctrl+V"} to paste, or ::kbd{key="Esc" color=red} to bail out. Vim survivors reach for ::kbd{key="hjkl"} on instinct.

Build is ::progress{value=0.7 color=green} almost done. Disk usage ::progress{value=0.92 color=red} getting tight. And bound to the slider below — `box_radius` is ::progress{value=${state.box_radius} max=40 color=cyan} live.

Services: API ::status{color=green label="online"}, cache ::status{color=yellow label="degraded"}, queue ::status{color=green label="online"}, auth ::status{color=red label="offline"}. Background workers ::status{color=green}.

Tagged ::tag{label="wip"} ::tag{label="deprecated" color=orange} ::tag{label="security" color=red} ::tag{label="docs" color=cyan} ::tag{label="v0.42" color=purple} — five facets, one line of prose.

Revenue ::trend{value="+12.4%"} this quarter, orders ::trend{value="-2.1%"} from last week, NPS holding ::trend{value="0%"}. Latency ::trend{value="-23ms" down_color=green} (lower is better), error rate ::trend{value="+0.4%" up_color=red}.

The book scored ::rating{value=4.5} on Goodreads, the sequel only ::rating{value=2.5}, and the third never quite landed ::rating{value=1}. Five-star reviews dominate at ::rating{value=5 color=orange}.

Build status: ::dot{color=green} passing on main, ::dot{color=yellow} flaky on PR #42, ::dot{color=red} blocked on staging. Workers ::dot{color=green} ::dot{color=green} ::dot{color=yellow} ::dot{color=green} mostly fine.

Fixed in ::commit{hash="acf8e7b"} (part of session 17), shipping alongside ::commit{hash="8d6e7a3c4d5e6f7a8b9c0d1e2f"} and ::commit{hash="d26d67d" repo="fdn42/spark"} in the next release.

The Pro plan is ::price{value=29 currency=USD} per month, Enterprise bills annually at ::price{value=499 currency=USD} (~::price{value=499 currency=EUR} for European customers, or ::price{value=399 currency=GBP} sterling). Tokyo office runs ::price{value=4990 currency=JPY} per seat.

Today's PR: ::diff{add=437 remove=17} across six files. Yesterday's churn: ::diff{add=72 remove=68}. The big rebase last month: ::diff{add=2840 remove=1402}. And the no-op cleanup: ::diff{add=0 remove=0}.

Tracked in ::issue{n=247} and ::pr{n=1042} (part of the ::issue{n=89 repo="fdn42/spark"} epic). Shipped via ::pr{n=311 repo="fdn42/spark"} after a long review thread.

Last deploy ::ago{value="3m"}, last incident ::ago{value="2d"}, last full outage ::ago{value="3w"} (touch wood). Build kicked off ::ago{value="just now"}.

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
[1mspark [32m✓[0m[0m  build [36mok[0m
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

A `:::curve` is a piecewise-linear value over normalised x — spindrift's `row.age | over row.life [1.0, 0.7, 0.0]` — bound in mirror mode to a state path holding the ARRAY. Drag a puck; the whole array goes back through `state.set` as one write.

:::curve {#size_curve target=size_curve value=${state.size_curve} min=0 max=2 label="size over life" width=320}
:::

## Numeric fields — drag to scrub

A `numeric` field is right-aligned, mono and **draggable**: press and pull sideways to scrub, or click and type an exact value into the same rectangle. Under three pixels of travel a press is still just a click, so the field stays typeable. `min`/`max` clamp — and because the scrub is measured from the press rather than integrated, dragging hard past a bound and back returns to exactly where you started.

**The drag is curved.** Near the press point a pixel is worth about a sixth of what a straight-line scrub would give it, so you can creep up on a value one unit at a time; further out the curve overtakes and the whole range is still one gesture. Twelve pixels moves `box_width` by about four, where a linear scrub would have moved it twenty-eight.

**Drag whichever way you reach for.** The field watches the first few pixels and commits to that axis for the rest of the gesture — sideways like Blender and Resolve, or up and down like a DAW's number box. Up is more. Once it has committed it stays committed, so a mostly-vertical pull that wanders sideways keeps answering to the vertical.

Nothing else writes `box_width`, so the box up the page is following this field alone. Compare the feel against the two sliders above it.

:::input {numeric target=state.box_width initial=${state.box_width} min=40 max=600 width=140}
:::

Precision is inherited from the seed rather than defaulted. `gain` arrives as `1.250`, so it scrubs in thousandths — a default of two decimals would have rounded it to `1.25` the first time anyone touched it. Currently **${state.gain}**.

:::input {numeric target=state.gain initial=${state.gain} step=0.005 width=140}
:::

And an ordinary field is unchanged — proportional, left-aligned, and it ignores the drag entirely:

:::input {target=state.target_id initial=${state.target_id} width=140}
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

## Flex grow (stage 15 Phase C.3)

The measure-pass protocol lets `:::flex` ask each child for its intrinsic width *before* placement, then distribute slack across children with a `grow` weight. Below: two fixed-width caps + a middle box that takes whatever's left. Resize the window — the middle box stretches; the caps stay put.

:::flex {#grow_row direction=row gap=8}
:::box {color=orange width=80 height=48 radius=6}
:::

:::box {color=cyan grow=1 height=48 radius=6}
:::

:::box {color=orange width=80 height=48 radius=6}
:::
:::

Multiple grow weights split slack proportionally — `grow=1` + `grow=2` + `grow=1` here means the middle panel claims half the row's slack and the side panels split the rest.

:::flex {#grow_proportional direction=row gap=8}
:::box {color=purple grow=1 height=40 radius=6}
:::

:::box {color=green grow=2 height=40 radius=6}
:::

:::box {color=purple grow=1 height=40 radius=6}
:::
:::

## Text exclusion (stage 15 Phase E)

Floats opt a block out of normal flow: the parent stack places the floated box at its left or right edge, *doesn't* advance the cursor, and the floated box registers a rect exclusion on `LayoutContext` so following paragraphs wrap around its silhouette. CSS `shape-outside` semantics, layered atop the settled-positions model the constraint solver produced.

:::box {float=left width=140 height=140 color=orange radius=10}
:::

A floated block is taken out of normal flow. The stack walker positions it at the chosen edge of the column at the current cursor — and crucially does not advance the cursor. Following paragraphs continue at the same y, but their inline-flow wrap loop queries the active exclusion list every line, shrinking the usable x-range so glyphs miss the float's rectangle. Add enough text and the lines eventually escape the float's bottom and resume the full column width.

This second paragraph picks up where the first left off. Notice how the lines hug the float on the left until the y-cursor passes the float's lower edge — at which point the column reopens to its full width and the prose stops indenting. Behind the scenes nothing about the float is special: it's a regular `:::box` whose `flow_kind` vtable slot reports `.float_left`, and whose `on_layout_complete` hook re-registers the exclusion rect on every walk so the cache-hit path doesn't lose track of it.

The right edge plays the same way. Below the orange float is a teal one nudged the other direction — same machinery, opposite side.

:::box {float=right width=160 height=120 color=cyan radius=10}
:::

Right floats need their measured width up front so the stack walker can place them flush against the column's right edge. The measure-pass protocol shipped in Phase C.3 already provides this: `measure_block` reports the box's intrinsic width, the walker subtracts it from `max_w`, and the float lands at the resolved x. The wrap loop on this paragraph sees a right-side exclusion and shrinks the line from the right, so the prose hugs the float's left silhouette while the column itself stays unchanged. After the float ends, the column reopens — a clean rectangular cut that the solver never had to know about.

The architectural cut for floats keeps coverage problems separate from constraint problems. Cassowary settles boxes; the float pass is a layered consultation atop the settled positions. v1 ships axis-aligned rects only; polygons and per-line spans (real CSS `shape-outside`) are v2 territory, and glyph-driven exclusions are v3 / probably-never. Three lines of demo, one new attribute, one new vtable slot.

## Drag-to-resize (stage 15D)

Stage 15D wires GPU-side input deltas straight to the kiwi constraint solver via `LayoutContext.setSuggestion`. A `:::handle` between two boxes drags horizontally; the left box reads its own width as a `suggestValue` edit at medium strength, and the right box shifts to follow. No state intermediary, no re-parse — the cursor drives the solver, the solver reshapes the layout, the renderer paints the new geometry on the next frame.

:::flex {#resizer_row direction=row gap=0}
:::box {#resizer_left color=cyan width=240 height=80 radius=6}
:::

:::handle {target=#resizer_left axis=horizontal width=8 height=80}
:::

:::box {color=magenta width=200 height=80 radius=6}
:::
:::

## Grid layout (stage 15d/e)

The second multi-child constraint-aware provider. `:::grid` lays its body out into tracks (`columns=N` for `N` equal columns, or a CSS-style list like `"100px 1fr 1fr"` mixing fixed and flexible widths), row-major, with independent `row-gap` and `column-gap`. Each cell still goes through the kiwi solver for its own bounds — the grid parent allocates the track, the cell constrains its size inside it. `:::flex` handles 1D; `:::grid` handles 2D; both stack cleanly inside each other.

A 3×2 dashboard with equal columns and uniform gap:

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

Mixed fixed + flex tracks — `180px 1fr 1fr` gives a fixed-width sidebar plus two equal-width panels that share whatever's left. Resize the window: the sidebar holds its width while the two flex tracks negotiate for the remainder.

:::grid {#sidebar_layout columns="180px 1fr 1fr" column-gap=16 row-gap=8}
:::box {color=cyan width=100% height=80 radius=6}
:::

:::box {color=magenta width=100% height=80 radius=6}
:::

:::box {color=orange width=100% height=80 radius=6}
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

:::input {#ask_local target=#chat_local action=start placeholder="Ask qwen3.5… (Enter to send)" width=100% height=34}
:::

:::button {#run_local label="Run default prompt (Ollama)" target=#chat_local action=start}
:::

:::llm-stream {#chat_local auto_start=false model=qwen3.5:2b prompt="In 4 short lines, write a haiku about Vulkan rendering text glyphs through a markdown document. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Live LLM authoring (stage 13a.5) — remote DeepSeek

Same component, different provider. `provider=openai` switches the body shape (OpenAI-compatible `max_tokens` field, `Authorization: Bearer` header) and the chunk parser (SSE events instead of NDJSON). The API key lives in `~/.env` as `DEEPSEEK_DYNABOOK`; `api_key_env=` names which entry to read. The fetch goes out over real internet — **and the renderer never blocks waiting** because every byte of work happens on a worker thread.

:::input {#ask_remote target=#chat_remote action=start placeholder="Ask DeepSeek… (Enter to send)" width=100% height=34}
:::

:::button {#run_remote label="Run default prompt (DeepSeek)" target=#chat_remote action=start}
:::

:::llm-stream {#chat_remote auto_start=false provider=openai endpoint=https://api.deepseek.com/chat/completions model=deepseek-chat api_key_env=DEEPSEEK_DYNABOOK prompt="In 4 short lines, write a haiku about a network packet finding its way home through a worker thread. Use a level-2 markdown heading for the title." max_tokens=120}
:::

## Live LLM authoring (stage 13a.5) — Gemini via OpenRouter

Same component yet again, *third* provider — OpenRouter is itself OpenAI-compatible and fronts dozens of upstream models. Pointed at `google/gemini-2.5-flash` here, but `anthropic/claude-haiku-4`, `openai/gpt-4o-mini`, `meta-llama/llama-3.3-70b-instruct`, and others all drop in just by changing `model=`. The OpenAI wire format earned its place as the lingua franca.

:::input {#ask_router target=#chat_router action=start placeholder="Ask Gemini Flash… (Enter to send)" width=100% height=34}
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

:::input {#ask_petunia target=#fresh_svg action=start placeholder="Describe an SVG… (Enter to generate)" width=100% height=34}
:::

:::button {#run_petunia label="Run default prompt (a bowl of petunias)" target=#fresh_svg action=start}
:::

:::svg-stream {#fresh_svg auto_start=false provider=openai endpoint=https://openrouter.ai/api/v1/chat/completions model=recraft/recraft-v4.1-vector api_key_env=OPENROUTER_DYNABOOK prompt="A bowl of petunias, vector art, clean shapes, single bowl viewed from front, transparent background" max_tokens=8000 width=480}
:::

## Live raster image (stage 14c) — `:::image-stream`

Same async I/O lane as `:::svg-stream`, but the data URL is a PNG — and the decode path runs through **stb_image** instead of the SVG tessellator, dropping the pixels into a per-component `VkImage` + sampler. The wire format is identical to Recraft (OpenAI-shaped `/chat/completions`, `stream:false`, image lives in `message.images[0].image_url.url`); only the MIME prefix and decoder swap out.

:::input {#ask_image target=#fresh_image action=start placeholder="Describe an image… (Enter to generate)" width=100% height=34}
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
