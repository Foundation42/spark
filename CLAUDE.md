# Working in spark

## Running tests — the default is to run NOTHING

Pick a gate because the change can break the thing it watches, never to
feel reassured. Chris has asked for this twice; a suite run per edit
makes the harness the activity rather than the work.

**While iterating, filter.** This repo supports it:

    zig build test -Dtest-filter=trackball     # seconds, not the suite

**The full suite (646) belongs before a commit, and there.**

    zig build test

A gate that passed stays passed until the code changes. Do not re-run
one for reassurance.

Sibling repos have their own gates and their own costs — matryoshka's
`demos/hud-lab/repro.sh` is a nineteen-section GPU sweep. Changing spark
can move those, but "can" is the test: a new component moves nothing, a
change to `element_layout.zig` or the pass graph moves everything.

## House style

`docs/` carries the long-form journey notes. New components follow
`src/components/slider.zig` and `src/components/grip.zig` — a `Component`
struct with `ingest`, a `factory`, a vtable, visual constants at the top,
and the tests in the same file as the thing they test.

Write the reasoning into the code, not into a commit message. Every
non-obvious constant and every guard should say what it is paid for.

## The trap: `State.set` re-enters

`State.set` notifies subscribers **synchronously**, and it hashes its
`key` twice — once for the value map, once for `subscribers.getPtr`. A
component bound to a path it writes (`value_r=${state.lift_r}`) is its
own subscriber, so:

    writeChannels → state.set(paths[0]) → update → ingest → free(paths[1])
    … loop continues → state.set(paths[1])   ← freed

That segfaulted the trackball on 2026-09-01, and the same re-entry made
its puck jump: the update lands after the FIRST of three writes, so the
widget re-derived itself from `(new_r, old_g, old_b)` — a triple that
never existed.

Any component that writes **more than one path from one gesture** meets
this. `:::slider` cannot (one path, no partial state). `::grip` writes
two and survives only because `x=px` carries no `${}`, so there is no
binding and no subscriber — luck, not design. If you write a multi-path
widget:

1. never reallocate an attribute that has not changed — compare first;
2. hold both the path swap and the value ingest off while a gesture is
   live. Latch a zone at mouse_down and test it; every route into the
   write helper comes from `onInput`, so that is exactly the unsafe
   window.

Between gestures the plane is the truth; during one, the widget is.
