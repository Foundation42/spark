# spark — session 19 journey

2026-05-18, evening session. Phase 2 (core / extras split) and
Phase 3 (public API + ownership inversion) of `docs/library-spec.md`
both land. main.zig shrinks from 1395 → 610 LOC and imports
`std`, `text_engine`, `demo_server` — three total, down from 59.
Two commits in:

```
88ed2a9 feat: stage 17 Phase 2 — core / extras split + install methods
cece52d feat: stage 17 Phase 3 — public API + ownership inversion
```

Three bugs surface and get caught during Phase 3 bring-up — one
content-rendering bug, one leak, one ReleaseFast-only UAF that
had been latent since Phase 1. Sleuthing notes are at the end.

## Opener

Christian comes back from session 18 with one ask:

> I think we can push on with Phase 3 if you have the energy —
> would be nice to land it.

The spec had grown a long "valkyr precedent" section between
sessions, pointing at `~/dev/valkyr/docs/embedding.md` and
`~/dev/matryoshka/src/games/ai_demo.zig` as the working
sibling-precedent for the cooperative-embed shape. Six patterns
to lift: attach API, `Recorder.attachCmd`, three-tier API naming,
`@ptrCast` cImport bridge, event drain on the main thread,
per-frame submit discipline. Instruction: "if I hit design
uncertainty in Phase 1 or Phase 3, the answer is almost always
look at the valkyr equivalent and match it."

Two scope choices to lock before diving in:

- **Full Phase 3 (API + ownership inversion)** — not the smaller
  "public API only" slice. Christian wanted the demo to actually
  shrink to GLFW + swapchain + frame pacing, not just route its
  calls through `text_engine`.
- **`attachCmd` shape: per-frame attach** — the simplest fit for
  spark's MAX_FRAMES_IN_FLIGHT rotation. Descriptor pool would be
  sized on the first call and reset (not recreated) on subsequent
  ones. Closer to "what the demo's renderer.zig already wants" than
  the once-at-startup variant from valkyr's quote.

## Phase 2 first — core / extras split

Before Phase 3 could land, Phase 2 had to go in: HTTP-using
components (`llm_stream`, `svg_stream`, `image_stream`) plus
`dotenv` + `asset_cache` move to `src/extras/`. The
`embedded_document` factory splits along its scheme seam — file://
+ bare paths stay in core; the http:// branch lifts wholesale to
`src/extras/embedded_document_http.zig`.

Five `git mv` operations, import-fixup in the moved files, two
import updates in `spark.zig` + `tests.zig`. Six edits, no logic
change.

The split of `embedded_document` was the interesting one. The
spec said either (a) same directive name with scheme dispatch at
resolve time, or (b) separate directive names — "implementer
picks whichever is cleaner. Both work." I picked option (a) via a
function-pointer hook: core defined `pub var http_handler:
?HttpHandler = null`, extras' `install` populated it, core's
`create()` returned `error.HttpEmbeddedDocumentRequiresExtras`
when a URL hit without the handler installed.

Two messages in, Christian flagged the matryoshka-side agent's
review:

> url_cache + cache_allocator scope. If those land as module-globals
> in extras/embedded_document_http.zig (i.e. `var url_cache: ... = .{};`
> at file scope), they become process-global rather than per-Spark.
> That's the same principle Phase 1 purged with the `_ref` vars.

Caught at the right time. I had the cache as a module-global var,
matching the old core implementation — but Phase 1 had spent
significant work eliminating exactly that pattern. The fix was a
shape change: `EmbeddedDocumentHttp` becomes a struct with
`allocator + url_cache` as instance fields; Spark gains
`embedded_http: ?*EmbeddedDocumentHttp` (same shape as `dotenv`,
`asset_cache`). The function-pointer hook drops; core's `create()`
reads `spark.embedded_http orelse return error.X` and calls a
method on the typed pointer.

Three extras-hung resources on Spark now, all with the same
discipline. Same install pattern (`spark.extras.X.install(&spark)`),
same lifetime ownership (Spark.deinit tears down), same
per-Spark isolation. Two Sparks in one process don't share any
of them.

## Phase 2 ships

- Spark grows real `installDotEnv(env_path)` /
  `installAssetCache(dir, budget)` method bodies (Phase 1 had
  field-set placeholders).
- Extras install functions check preconditions —
  `error.RequiresDotEnv` / `error.RequiresAssetCache` if the host
  hasn't installed them yet.
- `--core-only` CLI flag skips both install calls + all four
  extras factory installs. Demo runs against pure core.
- Canary: 13,883 fps with extras / 13,470 fps `--core-only` — both
  above the ~13K Phase 1 baseline.

Christian: "Yup, commit! Awesome job!!"

`88ed2a9` lands. On to the big one.

## Phase 3 — ownership inversion

The spec's Spark struct definition is explicit about which fields
Spark owns by Phase 3. Atlases, pipelines, glyph + layout caches,
layout context, registry, IoChannel, JobSystems, FontRegistry —
all owned. Vulkan handles, theme, host_state — borrowed. The host
hands Spark raw `VkDevice` / `VkQueue` / queue_family / `VkFormat`
plus a built Theme + an owned FontRegistry + a borrowed root State,
plus sizing knobs.

The new shape:

```zig
var spark = try text_engine.Spark.init(allocator, .{
    .vk_ctx = &ctx,
    .color_format = swapchain.format,
    .theme = &theme,
    .fonts = fonts,           // ownership transferred
    .host_state = &host_state,
});
defer spark.deinit();
spark.attachToRegistry();
```

Inside `Spark.init`, each resource is constructed with its own
`errdefer` so a failure midway through cleanly unwinds. Resources
that components dereference through `c.spark.X` stay as
heap-allocated pointers in the Spark struct — `*Registry`,
`*LayoutContext`, `*IoChannel`, `*ImagePipeline`. Everything else
(atlases, three other pipelines, glyph cache, layout cache,
drawlist) lives by value inside the Spark.

Why the asymmetry? Because the Phase-1 component code expected
those four specific fields to be pointers (`c.spark.registry.X()`,
`c.spark.layout_context.X()`, etc.). Going by-value would have
required a sweep through 20+ components changing `c.spark.X.method`
calls to `(&c.spark.X).method` everywhere. Keeping them as
pointers means components don't change at all — same surface,
just owned by Spark instead of main.

## Document type

`Spark.loadDocument(source, opts)` parses markdown + frontmatter,
returns a `Document` handle wrapping its own arena + per-document
State (or a host-supplied `shared_state`). Per spec decision #8,
each Document gets its own root State by default; sharing is
explicit via `LoadOpts.shared_state = &host_state`.

The demo passes `shared_state = &host_state` for both the top
markdown doc and the ANSI passage so the existing demo behavior
(single State for both trees) survives. ANSI doesn't go through
`loadDocument` because it isn't markdown — `wrapElement(allocator,
arena, root, shared_state, theme_override)` handles the
pre-parsed-tree path.

## Frame cycle

The per-frame methods compose into the loop the spec sketched:

```zig
spark.tick();                                            // drain io
spark.attachCmd(cmd, 0, 0);                              // bind cmd
spark.beginFrame(.{ .extent = ..., .zoom = z, ... }, .{ .reset = re_layout });
if (re_layout) {
    _ = try spark.layoutAndRender(&top_doc,  .{40, 40},                              constraints);
    _ = try spark.layoutAndRender(&ansi_doc, .{40, top_box.y + top_box.h + 8},      constraints);
}
try spark.endFrame();
```

`beginFrame`'s `.reset` option is the one design wrinkle Phase 3
introduced over the spec sketch. The first attempt at the new
demo ran the layout walk every frame. Canary dropped to 9,115 fps
— 30% under baseline. The fix was straightforward once I noticed
the old `drawCb` had a state-dirty gate (`if (extent_changed or
state.dirty)`) that I'd lost in the migration. Adding it back as
a `beginFrame.reset` option:

- **`reset = true`** (default): clear drawlist, prewarm fonts at
  current zoom, reset the constraint solver. `endFrame` will
  apply the world→screen transform.
- **`reset = false`**: cache FrameInfo + cmd only; reuse the
  previous frame's screen-space drawlist verbatim. `endFrame`
  re-records draws without re-transforming.

A `drawlist_needs_transform` flag on Spark gates the transform
idempotently. Host owns the dirty-tracking discipline; Spark
respects the host's call.

Canary back to 12,408 fps. Within ~5% of baseline.

## main.zig migration

The big payoff. The old demo's `FrameCtx` was a 70-line struct
holding pointers to every engine resource the per-frame loop
needed. The new `HostCtx` is 12 lines:

```zig
const HostCtx = struct {
    spark: *text_engine.Spark,
    state: *text_engine.State,
    top_doc: *text_engine.Document,
    ansi_doc: *text_engine.Document,
    scroll_y: f32 = 0,
    target_scroll_y: f32 = 0,
    zoom: f32 = 1.0,
    max_scroll_y: f32 = 0,
    last_frame_ms: i64 = 0,
    last_extent: vk.c.VkExtent2D = .{ .width = 0, .height = 0 },
    start_ms: i64 = 0,
    overflow_logged: bool = false,
};
```

Scroll + zoom + extent-resize policy stays host-side (matryoshka
HUDs don't scroll the same way the demo does; the demo's policy
shouldn't leak into the library). Everything else routes through
spark.

Import block:

```zig
const std = @import("std");
const text_engine = @import("text_engine");
const win = text_engine.window;
const vk = text_engine.vk;
const swap = text_engine.swapchain;
const renderer = text_engine.renderer;
const demo_server_mod = @import("demo_server.zig");
```

`window` / `swapchain` / `renderer` are re-exported through
text_engine *to dodge a Zig module-system corner*: when the demo
imports them directly AND `lib.zig` transitively pulls them in via
`gpu/vk.zig`, the same source file appears in two modules and Zig
refuses to build. Routing through `text_engine.X` keeps them
single-module. They're marked as "demo-supporting code, not part
of the stable public API" in lib.zig — matryoshka brings its own.

Spec done-when grep passes:

```sh
grep -E '@import\("(element|element_layout|markdown|component|state)' src/main.zig
# (empty)
```

## Three bugs after demo.md test

The migration built clean, tests passed, hello.md canary held at
12K fps. I reported Phase 3 done. Christian ran demo.md
interactively and reported back:

> We have some issues with the demo.md — numerous missing sections,
> and also a crash on exit.

Screenshots showed every `:::box`, `:::slider`, `:::handle`,
`:::flex`/`:::grid` child rectangle, `:::input`, `:::button`,
`:::svg`, `:::svg-stream`, `:::image-stream`, `:::chart`,
`:::embedded-document` rendering as **empty space**. Headings and
prose worked. So markdown text was fine; ALL components were
silent.

### Bug 1: empty SSBOs

Search for `writeQuads` call sites returned zero. `writeMesh` for
the triangle pipeline: also zero. Only `writeGlyphs` was being
called — from `spark.endFrame`. The pipelines were recording draws
correctly, just against empty buffers.

Git history clarified: the old `runLayout` (Phase 2) had been
calling `writeQuads` + `writeMesh` at the END of layout, alongside
applying the scroll/zoom transform. The OLD `drawCb` only called
`writeGlyphs` because glyphs were the part that changed every
frame for animation; quads + tris were stable across frames.

My migration moved the transform into `endFrame` but didn't carry
over the quad/tri SSBO uploads. One three-line addition:

```zig
try self.quad_pipeline.writeQuads(dl.quads.items);
try self.tri_pipeline.writeMesh(dl.tris.items, dl.tri_indices.items);
try self.text_pipeline.writeGlyphs(dl.glyphs.items);
```

All components reappeared.

### Bug 2: doc-bytes leak

GPA reported a leak on exit, traced to `readFileAlloc` in the
argv[1] branch. Original code had had the same leak — the comment
"doc_source's storage lives until program exit. We don't free it
— the parse arena and reactive state both hold long-lived slices
into it" justified it. My refactor kept the leak without the
comment and without an explicit free.

Fix: `var doc_bytes_owned: ?[]u8 = null;` plus an early-declared
defer to free after `top_doc.deinit` and `host_state.deinit` run.
LIFO defer order guarantees the parsed-tree references stay valid
until everything that holds slices into them is gone.

### Bug 3: ReleaseFast crash on exit

Debug exited clean. ReleaseFast crashed somewhere during teardown
— exit code non-zero, no panic message (ReleaseFast strips them).
`TEXT_ENGINE_EXIT_AFTER=N` timed-exit didn't crash. Only
user-driven X-button exit crashed.

That distinction was the clue. The timed-exit path called `break`;
the X-button path went through `!window.shouldClose()`. After
break-or-shouldClose, the same defers fire either way — unless
they were doing different *things* across the two paths, which
seemed unlikely.

I changed `TEXT_ENGINE_EXIT_AFTER` to call
`glfwSetWindowShouldClose(window.handle, GLFW_TRUE)` instead of
`break` so the timed-exit path now triggers `shouldClose` true on
the next iteration. Same path the user takes. The crash reproduced.

Then instrumented `Spark.deinit` with `std.debug.print` at each
phase. Output:

```
[deinit] enter
[deinit] 1 registry
exit=0
```

Crash inside `self.registry.deinit()`. Reading `Registry.deinit`:

```zig
pub fn deinit(self: *Registry) void {
    var it = self.instances.iterator();
    while (it.next()) |entry| {
        const e = entry.value_ptr.*;
        if (e.binding) |b| b.destroy();
        if (self.factories.get(e.factory_name)) |f| {
            if (f.deinit) |d| d(e.instance.ctx, self.allocator);  // ← component deinit_
        }
        self.allocator.free(entry.key_ptr.*);
    }
    self.instances.deinit(self.allocator);
    ...
}
```

It iterates `self.instances` AND invokes each component's
`deinit_` during the same iteration. Now look at
`embedded_document.zig`'s `deinit_`:

```zig
c.spark.registry.deinitScope(c.scope);
```

`deinitScope` calls `self.instances.fetchRemove` on every entry
under the scope prefix — *mutating the same map* `deinit` is
iterating. Debug's hashmap iterator has a safety check that
catches mutation-during-iteration and panics with a clear message;
ReleaseFast strips the check, the iteration corrupts, and a few
entries later it crashes on a dangling pointer.

The bug was latent since Phase 1 — `Registry.deinit` was already
calling component `deinit_` in the same iteration back then. It
just hadn't been tripped in ReleaseFast until demo.md's particular
mix of embedded documents + chart timer activity. The pattern was
already known to `Registry`: `deinitScope` and `gc` both used
two-phase collect-then-remove. Only `deinit` had the bug.

Fix: same two-phase pattern.

```zig
// Phase 1: snapshot every live instance key.
var keys = std.ArrayList([]const u8).init(self.allocator);
defer keys.deinit();
var it = self.instances.iterator();
while (it.next()) |entry| {
    keys.append(entry.key_ptr.*) catch continue;
}

// Phase 2: for each key, fetchRemove + invoke deinit_.
// Embedded documents' deinit_ may call deinitScope which removes
// more keys; an already-removed key just returns null here.
for (keys.items) |key| {
    const entry = self.instances.fetchRemove(key) orelse continue;
    ...
}
```

Demo runs clean in ReleaseFast. All 9 deinit phases traverse
through to exit.

The `glfwSetWindowShouldClose` change stays in — `TEXT_ENGINE_EXIT_AFTER`
now exercises the same destructor sequence as a real X-button
close. This class of regression will catch deterministically going
forward.

## What this unlocked

For the demo:

- 1395 → 610 LOC in main.zig
- 59 → 3 imports
- Same visual + interactive behavior, same FPS, clean Debug +
  ReleaseSafe + ReleaseFast exits

For matryoshka:

The shape is in place. After Phase 4 (`examples/minimal_host.zig`)
and Phase 5 (integration tests at the library boundary) land,
matryoshka can do:

```zig
const spark = @import("spark");

var ui = try spark.Spark.init(alloc, .{
    .vk_ctx = &my_vk_ctx,
    .color_format = my_vk.swap_format,
    .theme = &hud_theme,
    .fonts = hud_fonts,
    .host_state = &game_state,
});
defer ui.deinit();
ui.attachToRegistry();
try spark.installCoreComponents(&ui);
try ui.installDotEnv("/home/chris/.env");
try ui.installAssetCache("/home/chris/.cache/spark", 500 * 1024 * 1024);
try spark.extras.llm_stream.install(&ui);

const hud_doc = try ui.loadDocument(@embedFile("hud.md"), .{});
defer hud_doc.deinit();

// In matryoshka's render loop, inside an active vkCmdBeginRendering:
ui.tick();
ui.attachCmd(host_cmd, 0, 0);
try ui.beginFrame(.{ .extent = swap_extent, .zoom = 1.0 }, .{});
_ = try ui.layoutAndRender(&hud_doc, .{0, 0}, .{ .max_w = ... });
try ui.endFrame();
```

matryoshka HUDs become markdown files — sliders, charts,
telemetry, debug panels — authored as text, hot-reloadable, an LM
can stream directly into them. No Dear ImGui anywhere in
matryoshka.

## Open threads

- **Phase 4** — `examples/minimal_host.zig`, ~200 LOC, the
  smallest possible second consumer.
- **Phase 5** — integration tests at the library boundary,
  two-instances test for State isolation.
- **Rename** — `text_engine` → `spark` everywhere (repo dir,
  module name in build.zig, asset cache dir, env var prefixes).
  Decision #11 parks this as mechanical and orthogonal.

## Memory

- `[[project-spark-libraryification]]` updated to reflect Phase 2
  + Phase 3 closure.
- The two-phase iteration discipline for hashmap teardown when
  callbacks may mutate the map is a generalizable pattern worth
  remembering for any future registry-style cleanup.

See you next session, partner.
