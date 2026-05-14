# text_engine — session 3 journey
2026-05-14 (Thursday, same day as sessions 1 + 2)

How the renderer learned chrome, learned to host another producer
(ANSI), learned to reflow on resize, and how Christian's vision
crystallised into something bigger than the original brief by the
end of the session.

## Where we started

End of session 2: markdown source → cmark → mapper → Element tree
→ walker → glyphs. Working, but visually "just text" — no
backgrounds, no quote bars, no link underlines. The roadmap doc's
session-3 direction was "quad/line primitives first, then ANSI
engine, then retained mode," with the order chosen so quad chrome
would land first (visible improvement to what already worked) and
ANSI could then render its output into a real document.

## Stage 4a — quad chrome

The first non-glyph primitives. Three target visuals:

- **Code-block background panel** — subtle rounded-corner rect
  behind fenced code, giving it a real visual identity.
- **Blockquote left bar** — vertical accent bar at the quote's
  indent.
- **Thematic break** — horizontal rule replacing the spacer hack.

Engineering shape:

- New SPIR-V pair `quad.vert` + `quad.frag`. Vertex reads
  `QuadInstance` SSBO (48-byte std430 stride), generates 6 verts
  per instance. Fragment: `roundedBoxSDF` + smoothstep AA over a
  1-pixel band; sharp-corner fast path when radius == 0.
  Premultiplies at output so the shared blend setting
  (`srcFactor = ONE`) works alongside the glyph pipeline.

- New `src/gpu/quad_pipeline.zig`, mirroring `text_pipeline.zig`:
  one SSBO binding, host-coherent mapped buffer,
  `vkCmdDraw(6, n_quads)`. Separate descriptor set from the glyph
  pipeline so the two bind cleanly inside one render pass.

- `DrawList` grew the `quads` field. Theme grew chrome fields
  (code-block bg + radius + padding, quote-bar colour + width,
  thematic-break colour + height + thickness).

- A new `thematic_break` Element variant (no payload — visuals
  come from the theme). `markdown.zig` updated to map
  `CMARK_NODE_THEMATIC_BREAK` to it instead of the placeholder
  spacer.

Walker emits the backgrounds: code-block reserves a quad slot
before its content lays out, fills its size once the total
height is known. Quote emits the left-bar quad after children are
placed, sized to their final height. Thematic break emits a thin
horizontal rule across `max_w`. All driven through `out.quads`.

3 quads / 589 glyphs / ~14.8k fps Release. The contract growth
path predicted in session-2's architecture doc paid off — the
`DrawList.quads` field slotted in alongside `glyphs`, walker
handlers gained a few lines for chrome emission, no contract
changes needed.

## Stage 4b — link underlines

The trickier quad case because the walker can't see individual
link runs directly — they're inside paragraphs, the inline
tokenizer flattens them, and underlines need to know "this
contiguous range of glyphs is inside a link" to emit one
underline quad per link-run per line.

Christian's framing on this one was load-bearing: *"By deferring
underline geometry generation until the line-emit pass, you
perfectly solve the multi-line wrapping problem. Tracking
underline runs during the per-line emit pass (after line wrapping
has frozen the X-positions and decided line breaks) is the
optimal path."*

The implementation followed exactly that shape. `emitLine` grew a
left-to-right link-run tracker. Each atom whose
`style.link == true` extends the current run; the run ends at the
next non-link atom or end of line, emitting one underline quad
spanning its x-extent. Multi-font runs use `max(displayPx)` across
constituent atoms — works for emph-inside-link, code-inside-link,
etc. without surprise.

Two design touches Christian flagged explicitly:

1. **Font-metrics-driven, not theme constants.** Thickness and
   offset declared in Theme as fractions of em
   (`link_underline_thickness_em`, `link_underline_offset_em`);
   emit pass multiplies by the run's dominant `displayPx`.
   Heading-sized links automatically get chunkier underlines than
   body links, in proportion. Clamped to >= 1px so it never
   disappears.

2. **Vertex batching + PBR hooks for later.** Each line's
   underline appends are amortised O(1) via ArrayList; the single
   `writeQuads` memcpy uploads them all in one shot. PBR/material
   slots live in the QuadInstance comment as the natural growth
   point when material IDs land on glyphs (via `fx_kind`
   extension).

A long link in the demo wraps cleanly across two lines, producing
two underline quads — one per visible line. The wrap-and-line-
emit boundary is exactly the right place for this geometry.

## Stage 5a — ANSI engine

The second tier-2 producer. Christian had a 1,894-line ANSI
parser in `~/dev/ac/src/terminal.zig` from session-1's prior art;
the state machine + 256-color palette + SGR dispatch were all
lift-and-adapt material.

What changed:

- `Terminal` callbacks (cell-grid writes, cursor moves, screen
  erases) replaced by `Builder` callbacks that accumulate text
  runs and flush them as Elements on style boundaries.
- Raylib `Color` replaced by `[4]f32` RGBA matching Style.
- Cascade for bold / italic routes through `theme.applyStrong` /
  `theme.applyEmphasis` — the same cascade helpers markdown's
  parser uses, so a bold-coloured ANSI run renders with the
  theme's bold font in the right colour.
- Pared back to states stage 5a actually needs: ground, escape,
  csi_entry, csi_param, csi_intermediate, osc_string. Cursor /
  erase / alt-screen / save+restore parse silently — relevant for
  streaming terminals (stage 6+), irrelevant for batch.

What it doesn't yet handle: underline / strikethrough / reverse /
hidden (parse cleanly but no visual change because the theme +
chrome work isn't done), background colours (need per-character
quad emission), tabs (TODO).

Demo: a small const ANSI string with `\x1b` escapes that resolve
at compile time to real ESC bytes (0x1B). Bold red / green /
yellow bullets on line 1; blue + 256-color orange + truecolor
coral + italic on line 2. Renders between markdown content and
the SDF "ATTENTION".

The contract didn't budge — ANSI is a Element producer just like
markdown. The two engines flow through the exact same walker,
exact same atlases, exact same SSBO.

## The resize problem

Christian noticed when resizing the window to portrait: text
didn't reflow. Content stayed at the pixel positions it had been
laid out for, the new viewport's NDC mapping shifted them, and
the result was either squashed or cropped.

The layout pass had run **once at startup** with
`content_max_w = 1200` baked in. The contract was always container-
aware (`Constraints.max_w` shrinks through nested blocks) — what
was missing was running the layout pass with the *current*
viewport's `max_w`.

## Stage 6a — resize-aware relayout

Two halves to the fix:

**Half 1: drawCb owns the layout work.** `FrameCtx` grew to carry
parse trees + layout prerequisites instead of pre-laid-out glyph
slices. `runLayout(extent)` runs only when `extent != last_extent`;
steady-state at one size is just animate + upload + record — no
reshape, no token rebuild, no atlas hits. First call sees
`last_extent={0,0}` → triggers initial layout, unifying init +
resize paths.

**Half 2: poll-based resize detection in the renderer.** First
attempt relied on `vkAcquireNextImage` / `vkQueuePresent`
returning `VK_ERROR_OUT_OF_DATE_KHR` / `SUBOPTIMAL_KHR` on
resize. On Christian's Wayland setup it didn't fire. The fix:
`drawFrame` polls `window.framebufferSize()` at the top of every
frame and recreates the swapchain when GLFW reports drift. The
existing OUT_OF_DATE-on-acquire/present recreate path stays as
the X11 / native-platform fast path.

Once the swapchain recreated correctly, the existing
`extent != last_extent` check in `drawCb` did the rest. The
contract earned its keep again — only the *renderer* needed the
resize detection; the layout pass already knew how to handle a
different `max_w`.

Cost: ~6% fps (13.5k vs ~14.3k Release) from per-frame writeGlyphs
even at steady-state. Retained-layout cache in the roadmap
recovers it; not yet a priority.

## And then the vision crystallised

Mid-conversation about "what to do next," Christian pitched
something much bigger than the session-2 framing of "Dear ImGui-
style game UI tomorrow."

The pitch was concrete and used markdown source as the example:

````markdown
:::3d-scene {#orbit-view width=100% height=400px}
src: "assets/sat_model.gltf"
:::

:::chart {#telemetry-plot}
title: "Telemetry for ${state.target_id}"
:::

:::update {#telemetry-plot action="append"}
00:05, 7620, 25.6
:::
````

Markdown isn't the document. It's the **declarative interface to a
live, component-driven runtime** that an LLM can author, mutate,
and stream updates into. Components are real Vulkan-native
instances. State is reactive. Updates are targeted at memory
pointers, not document re-layout.

The full vision lives in `docs/vision.md`. What's worth saying
here for the journey doc:

- **Every piece of the vision maps onto a contract decision we
  already made.** The `custom { vtable, ctx }` Element variant
  from stage 1 was put there for exactly this. `CodeContent.sub_block`
  is the same composability pattern, specialised for
  ANSI-in-markdown. Theme extends to component theming. Layout-
  vs-live-state decoupling is the same insight stages 4a and 6a
  used at smaller scales.

- **The contract held under the heaviest test it'll see.** We
  designed it in session 2 to survive markdown; we widened it
  in session 2c to anticipate widgets; we extended it in session
  3 to host quad chrome and a second producer. Adding live
  components is a producer-side concern + a host-side registry —
  no contract changes needed.

- **"text_engine" is now visibly the wrong name.** The
  destination is a live-document runtime. The rename
  conversation belongs in a future stage — but it's no longer
  "when the contract is concrete enough." The contract is
  concrete; what's still moving is the runtime layer above it.

## State at session 3 end

- **Stages 4a / 4b / 5a / 6a shipped.** Quad chrome + link
  underlines + ANSI engine + resize reflow.
- **~6,200 LOC of our own code** + vendored cmark (~20k LOC).
- **Demo:** markdown source → cmark → mapper → Element tree →
  walker, with quad chrome and link underlines, ANSI fixture
  rendered alongside, SDF "ATTENTION" rainbow at the bottom.
  Resize reflows correctly across portrait / landscape / square.
- **The vision doc** captures the live-documents direction with
  staging path 7a → 9+.

## What we learned

- **The contract keeps paying back.** Every stage of session 3
  was an extension to slots the contract already had. Quad
  chrome was `DrawList.quads`. ANSI was another Element producer.
  Resize was just running the existing layout pass at the right
  time. Live components will be `custom` elements with a
  registry. Each "new feature" is really "fill in a slot we
  already designed."

- **Wayland-shaped bugs aren't Vulkan bugs.** The resize issue
  looked like a Vulkan swapchain problem but was a
  compositor-doesn't-signal-out-of-date problem. The fix lives
  in the renderer's window-size polling, not in any Vulkan
  state. Worth remembering: poll the host window state when
  Vulkan won't tell you.

- **Vision crystallises when implementation catches up.** Session
  2's "Dear ImGui tomorrow" was a sketch. Session 3's
  live-documents pitch is concrete because we now have:
  resize-aware layout, two producers proving the contract,
  decoupled chrome+content rendering, and a custom-vtable escape
  hatch the parser can target. The vision didn't get bigger by
  accident — the foundation that made it imaginable arrived
  this session.

## Pretty wild stretch (again)

Sessions 1 + 2 + 3 all happened on the same Thursday. Session 1
built the rendering plumbing. Session 2 built the contract +
markdown. Session 3 built the chrome + ANSI + resize, then the
vision widened.

The shape of "rich text → live-document runtime" is now visible
end-to-end. Session 4 starts on the block extension parser.
