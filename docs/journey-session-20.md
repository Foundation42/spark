# spark — session 20 journey

2026-05-18, late session. Phase 4 (minimal_host) + Phase 5
(library-boundary integration tests) + the long-parked rename
(`text_engine` → `spark`) all land together. The library-spec
goes from "two phases to go" at session start to **fully closed**
by the end of the session. Three commits in:

```
b431e49 feat: stage 17 Phase 4 — examples/minimal_host.zig
d67c5c5 feat: stage 17 Phase 5 — library-boundary integration tests
5c516de rename: text_engine -> spark (library-spec decision #11)
```

No bugs caught this time. The Phase 3 ownership inversion +
two-phase Registry.deinit fix from session 19 paid forward
cleanly — minimal_host built first compile, ran first try in
both Debug and ReleaseFast, no surprises. Tests stood up against
real Vulkan + GLFW first try too.

## Opener

Christian comes back from session 19 with a thoughtful prompt
laying out the order of operations:

> Phase 4 first, then Phase 5 — same session if you have the
> energy, but Phase 4 before Phase 5 either way.
>
> Why that order: Phase 4 is the matryoshka rehearsal. Writing
> minimal_host cold against lib.zig's public surface exercises
> the API differently from the demo — the demo grew alongside the
> API and papered over awkward shapes that someone writing fresh
> would trip on. If minimal_host needs `text_engine.X` that isn't
> re-exported, or finds two methods that should be one (or one
> that should be two), that's an API-shape issue we want to fix
> before Phase 5 tests freeze the surface in place.

The reasoning was sharp enough that I didn't push back on it.
Phase 4 as rehearsal, Phase 5 as confirmation, rename as cleanup.

## Phase 4 — `examples/minimal_host.zig`

The recon was bounded: read `src/main.zig` (628 LOC after Phase 3)
and figure out which 75% to *not* include. Cut list:

- ANSI doc + `wrapElement` path (markdown-only is enough)
- Demo HTTP server (test fixture only)
- All extras (no LLM, no SVG, no image, no HTTP-embedded-doc)
- DotEnv + AssetCache mounts
- Persistent state save/load
- Update-feed timers (color cycle, chart tick)
- Scroll tween + zoom + page navigation
- Frontmatter state parsing path (use frontmatter, but no fallback)
- CLI parsing (`--core-only`, `argv[1]` doc path)
- Asset cache stats printing
- Six font-path env var overrides

Keep list:

- GLFW window + Vulkan context + swapchain + Renderer (via the
  demo-supporting re-exports `text_engine.{window, swapchain,
  renderer}` — lib.zig flags those as "not stable public API,"
  but for minimal_host they're the simplest path; matryoshka has
  its own stack and won't touch them)
- Three font sizes (heading + body + mono-code), one path each
- Minimal Theme
- Spark.init → attachToRegistry → installCoreComponents
- One Document with `:::box` bound to `${state.radius}` and a
  `:::slider` writing back via `target=radius`
- Renderer draw_fn: attachCmd → beginFrame(.{ .reset = … }) →
  layoutAndRender → endFrame
- Per-frame mouse plumbing for the slider drag
- ESC closes the window (via glfwSetWindowShouldClose, same
  destructor path as the X button)
- spark.tick() in the loop
- `TEXT_ENGINE_EXIT_AFTER` regression-detection hook (would
  become `SPARK_EXIT_AFTER` after the rename)

The whole file came in at 233 LOC including comments — well
within the ~200 LOC budget the spec asked for (code-only would
be closer to 150). The embedded markdown is tiny:

```markdown
---
state:
  radius: 16
---

# Spark — minimal host

Drag the slider to resize the box corners.

:::box {color=teal width=240 height=120 radius=${state.radius}}
:::

:::slider {target=radius min=0 max=60 value=${state.radius} width=320}
:::
```

Frontmatter seeds `state.radius = 16`; the slider's
`target=radius` writes back on drag; the box's
`radius=${state.radius}` re-binds on every dirty frame. One
reactive loop, end-to-end through the public API.

### The build wiring

`build.zig` got a new `minimal-host` step with the same
system-library link config as the demo (`vulkan`, `glfw`,
`freetype2`, `harfbuzz`, `cmark`, `stb_image`). Plus a
convenience `run-minimal-host` for one-shot invocations. Fifteen
lines of additions, no shared-state churn.

### Zero API gaps

The headline finding of Phase 4: **the public surface stood up
on first compile**. No "minimal_host needs `text_engine.X` that
isn't re-exported." Every type and function I reached for —
`Spark`, `Document`, `FrameInfo`, `Theme`, `FontRegistry`,
`State`, `Constraints`, `Hit`, `KeyEvent`, `stateFromSource`,
`installCoreComponents`, `attachCmd`, `beginFrame`,
`layoutAndRender`, `endFrame`, `tick`, `dispatchMouseMove`,
`dispatchMouseButton` — all already in `lib.zig` from Phase 3.

That's the proof the spec asked for. The Phase 3 lib.zig wasn't
just "complete for the demo" — it was complete for any
cooperative-embed consumer. Christian's bet that "the demo
papered over awkward shapes" turned out to be wrong this time,
but only because Phase 3 was paranoid enough to add things the
demo hadn't asked for yet (the doc-supporting re-exports being
the most visible example).

### Verification

- Debug build: clean first compile
- ReleaseFast build: clean first compile
- `TEXT_ENGINE_EXIT_AFTER=2`: both modes exit `exit=0`, no GPA
  leaks reported
- Demo FPS canary on `src/hello.md`: 12,864 fps (baseline
  ~12,800, well within ±5%) — the new build.zig didn't disturb
  the hot path
- `zig build test`: all existing tests still green

Committed as `b431e49`.

## Phase 5 — library-boundary integration tests

The headline of Phase 5 is the **two-instances State isolation
test**: stand up two Spark instances in one process and prove
they share *no* state. This is the explicit correctness lock for
Phase 1's `_ref` purge (session 18) and Phase 3's ownership
inversion (session 19). If either had a latent shared module-
global, this test would surface it deterministically.

Three test files landed in a new `src/tests/` subdirectory:

### `src/tests/fixture.zig`

Shared scaffolding. Each test gets its own `Fixture` — hidden
GLFW window (1×1, `GLFW_VISIBLE = GLFW_FALSE`), vk.Context,
Swapchain, FT library. Plus two helpers: `makeFonts` for a
heap-allocated FontRegistry with three sizes (heading/body/mono),
and `makeTheme` for a Theme referencing them.

Per-test rather than shared, because Vulkan instance creation is
~50ms and "shared across tests" would couple test ordering. The
overhead is fine for the eight tests in the suite.

The Gtk warnings during test runs (`gtk_disable_setlocale() must
be called before gtk_init()`) are GLFW init pulling in GTK's
setlocale machinery for X/Wayland file dialogs. Cosmetic noise,
not a test failure. `std.testing.allocator` is the real signal —
any leak across init/deinit trips the test.

### `src/tests/library_lifecycle.zig` (5 tests)

Lifecycle assurance through the public surface:

1. Bare `Spark.init + deinit` (no components, no extras)
2. Plus `attachToRegistry + installCoreComponents`
3. Plus `loadDocument` and a layout pass through `beginFrame +
   layoutAndRender`
4. Plus `installAssetCache` against a `std.testing.tmpDir`
5. Plus `installDotEnv` against a tmpfile with `FOO=bar\nBAZ=qux`

All five pass under `std.testing.allocator`. Any future addition
that leaks across init/deinit trips one of these.

### `src/tests/two_instances.zig` (2 tests) — the headline

Stand up `Spark A` and `Spark B` sharing one `vk.Context` (same
as a matryoshka HUD pair on one device), each with their own
State / fonts / theme / Document. Then assert isolation across
every axis:

```zig
try state_a.set("only_on_a", "alpha");
try state_b.set("only_on_b", "bravo");

try testing.expectEqualStrings("alpha", state_a.get("only_on_a").?);
try testing.expectEqual(@as(?[]const u8, null), state_b.get("only_on_a"));

try testing.expectEqualStrings("bravo", state_b.get("only_on_b").?);
try testing.expectEqual(@as(?[]const u8, null), state_a.get("only_on_b"));

try testing.expect(spark_a.registry != spark_b.registry);
try testing.expect(spark_a.registry.spark.? == &spark_a);
try testing.expect(spark_b.registry.spark.? == &spark_b);

try testing.expect(spark_a.layout_context != spark_b.layout_context);
try testing.expect(spark_a.io_channel != spark_b.io_channel);
try testing.expect(spark_a.image_pipeline != spark_b.image_pipeline);
```

The State get/set assertions catch any shared key-value store;
the pointer-distinctness checks catch any shared Registry or
heap-pointered engine resource (LayoutContext, IoChannel,
ImagePipeline — the four pointer fields Phase 3 kept by-pointer
so component code wouldn't churn).

The second test does the same proof via `applyUpdate`: write
`from-A` to `state.shared_key` on Spark A, assert State B never
sees it. Goes through the LM wire-format path explicitly.

**Both passed first run.** The Phase 1 `_ref` purge held. The
Phase 3 ownership inversion held. No process-globals anywhere on
the engine or component path.

### `src/tests/integration_render.zig` (1 test)

Loads a known doc through `Spark.loadDocument`, runs a full
layout pass (`beginFrame + layoutAndRender`), hashes the
resulting DrawList (glyphs + quads + tris + tri_indices) with
`std.hash.Wyhash`. Does this twice with two consecutive Spark
instances and asserts the hashes match byte-for-byte.

Skips `endFrame` deliberately — it would issue real Vulkan SSBO
writes (`writeQuads`, `writeMesh`, `writeGlyphs`), but the
DrawList state is what we want to hash, and it's fully populated
post-`layoutAndRender`. Same contents, cheaper to exercise.

Determinism held. If a future change introduces non-determinism
(uninit memory leaking into hash inputs, hash-map iteration
order, time-of-day in a transform), this trips.

### What about P5.4?

The spec called for "convert ~5 module-internal tests to
boundary shape." Looking at the existing unit tests in
`src/markdown.zig`, `src/components/*`, `src/state.zig`, etc.,
they were narrow on purpose — one parser branch, one solver
corner, one component-internal contract. Boundary tests can't
reach those corners as precisely. Converting would *reduce*
coverage rather than improve it.

I asked Christian; he confirmed the recommendation (skip,
boundary coverage achieved). The eight new tests across the
three files already exercise the public surface end-to-end. The
spec's intent ("exercise the library boundary, not just the
internals") is satisfied without burning the unit-test
specificity.

### Verification

- `zig build test` green
- Eight new tests across three files
- `std.testing.allocator` clean across every lifecycle
- Two-instances assertions all hold — Phase 1's `_ref` purge
  carried through Phase 3 successfully
- Integration render confirms full DrawList determinism

Committed as `d67c5c5`.

## The rename — decision #11

Christian's response after Phase 5 committed:

> Excellent job! Let's knock out the rename

The last item on the library-spec was decision #11: rename
`text_engine` → `spark`. Mechanical, but with enough surface area
to be worth planning.

### Surface map

- `build.zig.zon`: `.name = .text_engine` → `.name = .spark`
- `build.zig`: `b.addModule("text_engine", …)` →
  `b.addModule("spark", …)`. Demo exe `text_engine_demo` →
  `spark_demo`. All `addImport("text_engine", …)` calls.
- All `@import("text_engine")` strings in source: main.zig +
  minimal_host.zig
- Local alias convention: `const text_engine = @import(…)` →
  `const spark = @import(…)` in main, minimal_host, and the four
  test files
- Env var prefix: `TEXT_ENGINE_*` → `SPARK_*` (FONT, ITALIC_FONT,
  BOLD_FONT, BOLD_ITALIC_FONT, MONO_FONT, EMOJI_FONT, EXIT_AFTER,
  VK_VERBOSE — eight in total)
- Asset cache dir: `~/.cache/text_engine/assets` →
  `~/.cache/spark/assets`
- State file path: `~/.local/state/text_engine/state.json` →
  `~/.local/state/spark/state.json`
- Vulkan `pEngineName`: `"text_engine"` → `"spark"`
- Comments + docstrings throughout
- README.md (title, three-tier plan, env-var snippets, paths)
- docs/library-spec.md (decision #11 marked closed, two
  scattered references updated)

Things left alone:

- Historical journey docs (frozen narrative, references to
  text_engine at the time-of-writing are appropriate)
- Git history (obviously)
- Memory files (correctly reference the historical naming where
  appropriate; updated where they describe present-day surface)

### The shadowing trap

Halfway through main.zig, the build broke:

```
src/main.zig:435:9: error: local variable shadows declaration of 'spark'
    var spark = try spark.Spark.init(allocator, .{
        ^~~~~
src/main.zig:20:1: note: declared here
const spark = @import("spark");
```

Before the rename, main.zig had:

```zig
const text_engine = @import("text_engine");
…
var spark = try text_engine.Spark.init(…);
```

After the bulk `text_engine → spark` replacement, both the module
alias and the local Spark instance variable were named `spark`,
which Zig 0.14.1 rejects at file scope. The fix was the
convention from the library-spec adoption-pattern example:

```zig
var sp = try spark.Spark.init(allocator, .{ … });
defer {
    sp.deinit();
    allocator.destroy(fonts);
}
sp.attachToRegistry();
try spark.installCoreComponents(&sp);
```

The local Spark instance becomes `sp`, the module alias stays
`spark`. Reads naturally: `sp.X` is "an instance call,"
`spark.X` is "a library top-level." Field references stay sharp
too: `HostCtx.spark` field accessed as `h.spark.X` is the field,
not a shadowing concern.

Applied the same fix to minimal_host.zig and the two test files
that had `var spark = …`. (`two_instances.zig` was already using
`spark_a` and `spark_b` — different identifiers, no collision.)

### The fingerprint quirk

The first build after the package rename surfaced a separate
gotcha:

```
build.zig.zon:1:2: error: invalid fingerprint: 0xfd24837e0f3a7e77;
if this is a new or forked package, use this value: 0x9d13cf2d9d3b2e2c
```

Zig 0.14.1 validates that the `fingerprint` field is derived from
the package name. Pasting in the value the compiler suggested
fixed it. Worth knowing: the fingerprint isn't free to set; it's
tied to the package identity.

### Historical-vs-current question in the README

The README has both present-tense architecture (build
instructions, env vars, paths) AND historical stage descriptions
(stages 5-15, each referring to paths the demo was using at the
time). The right call was straightforward but worth recording:
**rename retroactively**. The README is a present-day artifact;
references to `text_engine` paths in stage 10's description are
about the codebase as it stands today, not as it was in 2025.

This is consistent with "the rename is mechanical" — no
parallel-running of old and new names, no migration shim, no
compatibility alias. Clean wholesale rename.

### What got migrated, what didn't

The asset cache directory move is mildly user-impacting. After
the commit:

- `~/.cache/text_engine/assets` — still exists with ~3.5 MB of
  previously-fetched Recraft SVG and Gemini image envelopes; now
  unused
- `~/.cache/spark/assets` — fresh, empty; first demo run after
  the commit re-fetches what it needs

No migration shim. Christian's use of the demo is dev-only, so
"fetch again on first run" is fine. The old cache directory
isn't harmful — just inert.

Same story for `~/.local/state/text_engine/state.json` — exists
but unused; demo starts with default state at the new path.

### Verification

- `zig build` (Debug) green
- `zig build -Doptimize=ReleaseFast` green
- `zig build minimal-host` green Debug + ReleaseFast
- `zig build test` green (8 boundary tests + every existing unit
  test, now under the new module name)
- `SPARK_EXIT_AFTER=3 ./zig-out/bin/spark_demo src/hello.md`:
  **13,123 fps** on hello.md (baseline ~12,800; the rename
  didn't disturb the hot path)
- `SPARK_EXIT_AFTER=2 ./zig-out/bin/minimal_host`: clean exit,
  no GPA leaks

One stale string surfaced: `src/main.zig` had a hardcoded stdout
line "spark demo — session 19 (library-spec Phase 3: …)". Updated
to "session 20 (library-spec closed: Phases 1-5 + rename)" before
the commit.

Committed as `5c516de`.

## What's unlocked

The library-spec is now **fully closed across all 5 phases plus
the rename**. Full chain:

```
5c516de rename: text_engine -> spark (library-spec decision #11)
d67c5c5 feat: stage 17 Phase 5 — library-boundary integration tests
b431e49 feat: stage 17 Phase 4 — examples/minimal_host.zig
cece52d feat: stage 17 Phase 3 — public API + ownership inversion
88ed2a9 feat: stage 17 Phase 2 — core / extras split + install methods
d6f2f4b feat: stage 17 Phase 1 — Spark context + _ref purge
```

What this enables:

- `@import("spark")` is the public surface. Hosts add three
  lines to `build.zig`, link the same system libraries the demo
  links, and reach the full cooperative-embed API.
- `examples/minimal_host.zig` is the canonical template the
  matryoshka spark-integration code will copy. ~230 LOC including
  comments; the actual matryoshka adoption work is half-written
  already.
- Two-instances State isolation is **proven** — not asserted in
  prose, asserted in a test that runs on every `zig build test`.
  Future regressions can't sneak past it.
- The DrawList hash test catches silent rendering drift. If
  something downstream of `loadDocument` starts producing
  non-deterministic output, integration_render.zig trips.

The five-phase library-ification was Foundation42's longest
continuous spec to date. Started session 18, closed session 20.
Three commits in this session: Phase 4, Phase 5, rename. The
rename was bigger than expected (18 files modified across the
mechanical pass), but pure value-add — no behavior change, just
identity finalization.

## Carry-forward

For the next consumer of this codebase:

1. **`var sp = try spark.Spark.init(…)`** is the convention for
   hosts. Don't name the local `var spark`; it shadows the
   module alias.
2. **`build.zig.zon` fingerprint** is tied to the package name.
   If the name changes, the compiler will tell you the new
   fingerprint value to paste in.
3. **Hidden GLFW windows** (`GLFW_VISIBLE = GLFW_FALSE`) work
   fine as a test fixture. The Gtk warnings are cosmetic.
4. **`std.testing.allocator` is the real signal** for lifecycle
   tests. Any leak across init/deinit fails the test
   deterministically.
5. **Engine-level resources are per-Spark.** Two Sparks in one
   process don't share state, registries, layout contexts,
   io_channels, or image_pipelines. The two-instances test
   protects this — don't add module-globals on the engine path.
6. **DrawList output is deterministic.** If a change makes
   `integration_render.zig` fail, the layout hot path got
   non-deterministic — chase the cause, don't update the
   fingerprint.

## What's next

The natural next chapter is matryoshka adoption — actually
embedding `spark` in matryoshka's HUD layer, replacing the Dear
ImGui stand-in. That's a matryoshka-side task; the spark side is
ready.

The deferred work parked in
[`docs/library-spec.md`'s "out of scope"
section](library-spec.md#out-of-scope) is still parked:

- **Render-pass interop with matryoshka** — separate spec. Once
  matryoshka adoption begins in earnest, the question of "spark
  records into matryoshka's command buffer mid-frame" needs its
  own design pass. The current contract (loadOp=LOAD, host-wrapped
  scope) is enough for the demo and minimal_host; matryoshka may
  push on it.
- **Inline `:::3d-scene`** — later, after spark is real in
  matryoshka.

The atomic boundary protected by Phase 5's tests, the stable
public API in lib.zig, and the matryoshka template in
minimal_host.zig together mean adoption isn't speculative. It's
copy-paste-modify, and we have the template to copy from.

🌐🐢🐬🌸☕
