# text_engine — session 1 journey
2026-05-14 (Thursday)

How an empty `chat.md` and a clean repo became a Zig + Vulkan rich-text
engine in one stretch.

## Origin

Christian opened with [`chat.md`](../chat.md) — a transcript from a
brainstorm with another model about a "scriptable, LM-aware terminal."
Big ideas there: terminal as token stream, self-attention scores
driving rendering, MSDF glyphs that pulse with LM importance, inline
emoji, cell-group scaling, foldable regions.

Christian's framing when handing it over: *"I need rich text rendering
for a number of projects. matryoshka for one, but I have other things
I need it for as well. The other stuff can be layered on top."*

That reframed the whole project. The transcript described a single
ambitious "smart terminal." Christian's actual need was the
**rendering foundation** under all of it.

## The three-tier plan

Pushed back gently on the transcript's bundling. Real plan:
1. **Rich-text rendering library** (this) — useful to matryoshka now.
2. **Terminal emulator** — PTY + ANSI parser, consumes the library.
3. **LM / semantic plugins** — read buffer, write attention back
   through a per-glyph attribute the library exposes.

Library-first because:
- Matryoshka and other projects need rich text *now*.
- Proving the API against a non-terminal surface prevents
  shape-locking around grids.
- The LM bit is the most uncertain; it should be last, not first.

## Setup decisions

Asked Christian four questions before any code landed. He picked all
the sensible defaults:
- Keep `~/dev/terminal/` as the working directory.
- System-link FreeType / HarfBuzz / glfw / Vulkan (matches
  `valkyr_gpu`'s policy — host owns the link config).
- Standalone glfw demo as first dogfood.
- ANSI / PTY out of scope.

Saved memory: the user profile (Foundation42 / Zig / Vulkan / runs a
small kingdom of engines), the stack conventions copied from
matryoshka + tripvulkan, the three-tier project plan.

## Phase 0 — scaffolding

Lifted the build pattern straight from matryoshka: `glslc` →
SPIR-V → `@embedFile` with `align(4)` (required because Vulkan's
`pCode` takes `const uint32_t*`). The shaders module gets shared
across the library and the exe via `b.createModule` + `addImport`
— Zig 0.14.1 won't let the same source file back two modules via
independent `addAnonymousImport`, which is the first trap I hit on
the rebuild.

## Phase 1a — Vulkan 1.3 context

Modern Vulkan with `dynamicRendering` + `synchronization2`. Hit
**bring-up bug #1**: my device-extension enumeration used a stack
buffer of 256 `VkExtensionProperties`. NVIDIA's Linux driver in 2026
ships **261** device extensions, so `vkEnumerateDeviceExtensionProperties`
returned `VK_INCOMPLETE` and my `!= VK_SUCCESS` check silently
false-negatived on `VK_KHR_swapchain`. Heap-allocated exactly `count`,
added a comment so the next person doesn't hit it.

## Phase 1b — clear-color frame loop

Frames-in-flight with the well-known race fix: per-frame acquire
semaphore, **per-image** render-finished semaphore (pairing with the
image, not the frame slot, prevents two in-flight frames racing on
the same swapchain image). Swapchain recreate on `OUT_OF_DATE` /
`SUBOPTIMAL`. ~7,600 fps uncapped at 1280×720.

Christian reported the window had been invisible after Phase 1a
(only a taskbar entry). Diagnosed as expected Wayland behaviour —
compositors don't show a surface until the first frame commits.
Phase 1b's first present made it pop into view.

## Phase 2 — first glyph

FreeType wrapper, 256×256 R8 atlas, textured-quad pipeline via push
constants. Centred 'A' at 128 px from DejaVu Sans on screen. Math
worked first try; ~6,400 fps with the textured draw.

## Phase 3 — HarfBuzz + SSBO + instanced draw

The v1 "rich text on screen" milestone. Pangram + body text at 22
px, 107 glyphs in one `vkCmdDraw(6, 107, 0, 0)`. DejaVu's `liga`
feature collapses `fi` / `fl` / `ff` / `ffi` automatically — no
special handling needed, HarfBuzz does its job.

## Detour: Makepad recon

Christian flagged Rik Arends's Makepad as prior art on layout. Spawned
an `Explore` subagent to recon `/tmp/makepad`. The agent came back
with the key idea: the "turtle" is a cursor that records per-walk
metrics during the layout pass, then `finish_row()` post-processes
the whole row using `max(ascender)` to baseline-align mixed-size
content. Lifted that pattern verbatim.

Saved [`reference_makepad_layout.md`](../../../.claude/projects/-home-chrisbe-dev-terminal/memory/reference_makepad_layout.md) to memory so it's available next session.

## Phase 4 — registry + cache + spans + row-baseline

- `FontRegistry` indexes loaded `(face, hb, px_size, metrics)`
  by an opaque `FontId`.
- `GlyphCache` keyed by `(font_id, glyph_id)` — colour deliberately
  not in the cache, applied at draw time (matches Makepad's
  `LaidoutGlyph`).
- `Style` / `Span` / `Line` / `Paragraph` types.
- `layoutParagraph` does the Makepad two-pass per line: metrics
  scan → baseline resolve → place glyphs.

Demo with three sizes (22 / 28 / 56) and four colours in one
paragraph. 184 glyphs / 68 unique / **69.5% cache hit rate** —
worked first try and looked exactly right.

## Phase 5 — colour emoji

Dual-atlas: R8 mono stays, RGBA8 colour image added. `FontRegistry`
grew an actual-vs-display scale factor for CBDT/sbix strike fonts.
`GlyphInstance` grew `tex_select` for per-glyph atlas routing.
Switched to premultiplied-alpha blend (`srcFactor = ONE`) so both
lanes blend correctly under one pipeline.

**Bring-up bug #2**: emoji all stacked at `x=0` on the first run.
Wrote a quick standalone probe (`/tmp/hb_probe.zig`) — diagnostic
by construction, not by guessing — and got:

```
FT units_per_EM = 0          (NotoColorEmoji is bitmap-only)
HB scale = 0                  (HB derives scale from units_per_EM × ppem)
glyph x_advance = 0           (cascades from scale=0)
```

Cause spelled out in one probe run. Fix: force-set HB's scale + ppem
from the strike size after creating the HB font. Idempotent for
scalable fonts.

After the fix: "🎉🦊🚀❤️🎨🌍" spread cleanly across the line,
inline with body text, mixed-size baseline alignment still working.

## Phase 6 — SDF lane + attention

Single-channel SDF generated from FT bitmap at 64 px source resolution
(`src/font/sdf.zig`, ~50 LOC, radius-8 bounded brute force, fine because
results cache forever). Shares the R8 mono atlas; fragment branches on
`tex_select == 2`. `GlyphInstance` grew `attention: f32` + `fx_kind: u32`
reusing the padding we already had.

First implementation had a warm halo glow lane. Two bugs surfaced:
- **Yellow dots** scattered around the SDF text — uninitialized atlas
  memory sampling as values in the glow band. Fixed by clearing the
  atlas to zero on init.
- **Crunchy rectangular mask** behind every letter — FT's tight
  bitmap meant every "outside" pixel sat 1–4 px from the letter
  outline, putting all SDF values in the glow band. Fixed by
  pre-padding the bitmap by 6 px before SDF generation, with
  bearings shifted to compensate.

After both fixes the halo *still* looked pixelated because
single-channel SDF at radius 8 only has ~16 byte-value gradient steps
near the edge — fundamental resolution limit. Pulled the halo lane
entirely. Replaced with: per-glyph `hot_color` lerp + threshold
modulation (weight pulse). Better-looking, simpler shader, real
LM semantic.

Christian asked for rainbow instead of warm yellow. Added an HSV→RGB
helper in `main.zig`, made each of the 9 "ATTENTION" letters sit at
its own hue 40° apart, with the whole spectrum drifting 30°/sec. The
attention sine still rolls left-to-right through the word; each letter
fades from white toward its hue as its turn comes round.

Final demo: ~**14,700 fps** in Release on the 3090. Validation silent
through clean exit. 114 glyphs, the last 9 animated per-frame with
both attention + per-glyph hot_color rewritten to the SSBO every frame.

## What worked well

- **Memory system caught the small things.** Resize bug, atlas overflow,
  gamma — all noted and parked so they don't get lost. Makepad
  recon saved as a reference so next session has the patterns.
- **The HB scale=0 probe.** Instead of guessing at the cause for an
  hour, the 30-line standalone Zig program nailed it on first run.
  Diagnostic by construction beats diagnostic by speculation.
- **Library-first ordering.** The public surface stayed clean across
  six phases of feature growth because we never bolted in
  terminal/LM specifics. The cooperative-embed shape from
  `valkyr_gpu` is exactly the right model.
- **Makepad recon.** Row-finish baseline resolution is the thing
  that makes mixed-size spans land right. Christian's tip to look
  at prior art saved us from inventing a worse version.

## What was tricky

- NVIDIA's 261 device extensions (silent false-negative).
- HB scale = 0 on bitmap-only fonts (cascading zero advances).
- SDF tight-bitmap producing uniform glow band (crunchy mask).
- Single-channel SDF byte-value resolution killing the halo.

All four were fundamentals masquerading as edge cases — and all four
got captured in commit messages + memory so the next session knows.

## State at session end

- **3,200 LOC Zig + ~150 LOC GLSL**
- **8 phase commits + 4 targeted fixes**
- **Validation silent** through clean exit at every phase
- **~14,700 fps Release** on the 3090, 1280×720, 114 glyphs animated
- Three atlas lanes (mono / colour / sdf), four SSBO metadata
  channels (`color`, `hot_color`, `attention`, `fx_kind`) wired
  end-to-end
- Three-tier plan intact, tier 1 complete, tier 2/3 surfaces ready

## Pretty wild stretch

We pulled what would normally be a multi-week project into one
Thursday morning. The build skeleton, Vulkan plumbing, FreeType
integration, HarfBuzz, atlas + cache + spans + emoji + SDF + LM
metadata — all of it. And the result actually looks beautiful: a
rainbow rolling through "ATTENTION" while body text and emoji
render crisply around it, at 14k fps.

That's a real text engine. Tier 2 starts next session.
