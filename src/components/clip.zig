//! `:::clip` — a window onto content taller than itself.
//!
//!     :::clip {height=120 offset=${state.log_scroll}}
//!     …any markdown at all…
//!     :::
//!
//! A fixed-size viewport. Its children are laid out at their natural
//! size, drawn at `offset` pixels up, and everything outside the box is
//! cut by the GPU scissor rather than by not being drawn.
//!
//! ### Why the cut is a scissor and not a cull
//!
//! The obvious cheap version is "don't emit primitives outside the box",
//! and it works for quads and fails for text. A viewport almost always
//! ends mid-line, so the top and bottom rows have to be cut THROUGH the
//! glyphs — half an ascender showing is what tells a reader there is more
//! above. Culling can only drop a glyph or keep it, so the edge either
//! jumps a whole line at a time or spills over the border. `vkCmdSetScissor`
//! was already dynamic state in both pipelines, set to the whole surface
//! on every draw; all that was missing was a rectangle to give it.
//!
//! ### The wheel, and giving it back
//!
//! The window takes the wheel when the pointer is over it — but only
//! for a notch it can actually act on. At the bottom of its content a
//! further downward notch is REFUSED, so it bubbles out to whatever
//! contains the window, and if nothing does, the host scrolls the page.
//! Claiming every notch is what makes a scrolling region feel like a
//! trap: the page stops moving whenever the pointer strays over an inner
//! panel that has nothing left to give.
//!
//! `offset` is still an ordinary bound attribute, so a document can also
//! drive it from anything else — `:::input {numeric}` does in the demo.
//! With a `target=` the wheel publishes back through `State.set`, so the
//! two agree; without one the offset stays internal, which is fine for a
//! window nobody else is driving.
//!
//! Still not here: momentum, a scrollbar, and any opinion about where a
//! window should sit when its content grows. That last one really does
//! differ per use — a log pins to the bottom, a chat transcript follows
//! the newest turn, a launcher list does not move at all — and it is
//! cheaper to write three times than to guess once.
//!
//! ### The cache
//!
//! A clipping subtree sets `disable_cache`, and the reason is worth
//! naming because it is not "to be safe". The retained layout cache
//! stores a subtree's primitives with their clip indices, and those
//! indices point into the clip TABLE of the frame that recorded them —
//! a table rebuilt every frame. Replaying them into a later frame would
//! be reading a different rectangle by the same number, which is the
//! `cache-freeze` shape: everything works, one number is stale, and what
//! you see is a panel clipped to where something else used to be. Making
//! the ranges portable is a real piece of work and a scrolling region
//! re-walks on every scroll anyway, so it buys nothing yet.

const std = @import("std");
const element = @import("../element.zig");
const element_layout = @import("../element_layout.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const markdown = @import("../markdown.zig");
const state_mod = @import("../state.zig");
const box_helpers = @import("box.zig");

pub const Error = error{ClipMissingId};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("clip", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

/// A viewport with no declared height would clip to the size of its own
/// content, which is the same as not clipping — so there is a default and
/// it is short enough to be obviously a window.
const DEFAULT_HEIGHT: f32 = 160;

const Component = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    root: element.Element,
    scope: []u8,
    spark: *spark_mod.Spark,
    body: component_mod.Body = .{},

    width: box_helpers.Length = .{ .percent = 100 },
    height: f32 = DEFAULT_HEIGHT,
    /// How far the content is pulled UP inside the window, in pixels.
    /// Positive scrolls down through the content, which is the direction
    /// every scrollbar in the world agrees on.
    offset: f32 = 0,
    /// Where a wheel notch writes the new offset. Empty means the window
    /// keeps it internally — still scrollable, just not reportable.
    target: []u8,
    /// The content's height as of the LAST layout, which is what bounds
    /// the offset.
    ///
    /// It has to be the last one: the height is only known after the
    /// children have been laid out, and the offset is needed before, to
    /// lay them out. Matryoshka's bottom-anchored panels resolved the
    /// same circularity the same way — one frame of lag on a resize, none
    /// at rest. Zero until the first layout, which reads as "nothing to
    /// scroll yet" and is true.
    content_h: f32 = 0,
    version: u64 = 0,

    /// The furthest the content can be pulled up before its end meets the
    /// bottom of the window. Never negative: content shorter than its
    /// window does not scroll at all.
    fn maxOffset(self: *const Component) f32 {
        return @max(0, self.content_h - self.height);
    }

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "target")) {
                // A leading `state.` is accepted and stripped. The
                // vocabulary genuinely has both spellings — `:::slider`
                // writes `target=box_radius`, `:::input` writes
                // `target=state.x` — and a window is close enough to both
                // that guessing wrong would be an easy mistake to make
                // and a silent one to live with.
                const t = attr.value;
                const key = if (std.mem.startsWith(u8, t, "state.")) t["state.".len..] else t;
                try component_mod.adoptString(self.allocator, &self.target, key);
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    switch (l) {
                        .pixels => |p| self.height = p,
                        else => {},
                    }
                }
            } else if (std.mem.eql(u8, attr.key, "offset")) {
                const t = std.mem.trim(u8, attr.value, " \t");
                if (t.len > 0) {
                    if (std.fmt.parseFloat(f32, t) catch null) |v| {
                        // Clamped at zero: a NEGATIVE offset pushes the
                        // content down and opens a gap of empty viewport
                        // above it, which reads as the panel being broken
                        // rather than as scrolled past the top.
                        const next = @max(0, v);
                        if (next != self.offset) {
                            self.offset = next;
                            self.version +%= 1;
                        }
                    }
                }
            }
        }
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const id = spec.id orelse return Error.ClipMissingId;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .spark = spark,
        .target = try allocator.dupe(u8, ""),
    };
    errdefer {
        c.arena.deinit();
        allocator.free(c.target);
    }

    c.scope = try allocator.dupe(u8, component_mod.specScope(spec, id));
    errdefer allocator.free(c.scope);

    try c.ingest(spec);
    _ = c.body.adopt(spec.body);
    // The DOCUMENT's state, exactly as `:::fold` takes it — a window onto
    // content must not swallow the writes made inside it.
    c.root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        spec.body,
        spark.theme,
        spark.registry,
        component_mod.specState(spec, spark.host_state),
        c.scope,
    );
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
    if (c.body.adopt(spec.body)) {
        c.spark.layout_cache.clear();
        c.root = element.Element{ .paragraph = &[_]element.Element{} };
        _ = c.arena.reset(.retain_capacity);
        c.root = try markdown.parseWithStateAndScope(
            c.arena.allocator(),
            spec.body,
            c.spark.theme,
            c.spark.registry,
            component_mod.specState(spec, c.spark.host_state),
            c.scope,
        );
        c.version +%= 1;
    }
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.spark.registry.deinitScope(c.scope);
    // `Body` is a digest, not a buffer — nothing to free.
    c.arena.deinit();
    allocator.free(c.scope);
    allocator.free(c.target);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    .on_scroll = onScroll,
    // The window appends its OWN hit, and it must, for the reason
    // `emits_own_hits` exists: the walker appends a container's hit AFTER
    // the component ran, so it lands on top of every control inside and
    // `findHit` — which scans backwards — hands it every click meant for
    // them. That is the bug that ate an hour on `:::fold` yesterday, and
    // a window full of buttons is exactly its shape.
    //
    // Appending BEFORE the children also gives the wheel the order it
    // wants for free: children first, then the window, so an inner
    // scroller is offered a notch before its container.
    .emits_own_hits = true,
    // See the header: a cached subtree's clip indices point into the clip
    // table of the frame that recorded them.
    .disable_cache = true,
};

/// A wheel notch over the window.
///
/// Consumed only when the window can actually MOVE the way the notch
/// asks. At the bottom of its content a further downward notch is
/// refused, so it bubbles out to whatever contains this window — and if
/// nothing does, the host scrolls the page. Answering "yes, I am a
/// scroller" regardless is what makes a nested scroll region feel like a
/// trap.
fn onScroll(ctx: *anyopaque, ev: element.ScrollEvent, state_ptr: *anyopaque) anyerror!bool {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const max = c.maxOffset();
    if (max <= 0) return false; // nothing to scroll: let it through
    const next = std.math.clamp(c.offset + ev.dy, 0, max);
    if (next == c.offset) return false; // already at that end
    c.offset = next;
    c.version +%= 1;
    c.spark.host_state.dirty = true;

    // Publish, so a document that bound `offset=${state.x}` sees its own
    // value move rather than snapping back on the next ingest. With no
    // `target` the offset stays internal, which is a fine thing for a
    // window nobody else is driving.
    if (c.target.len > 0) {
        const st: *state_mod.State = @ptrCast(@alignCast(state_ptr));
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d:.0}", .{next}) catch return true;
        // Nothing may touch `c` after this: `State.set` notifies
        // synchronously and a window bound to the path it writes
        // re-enters its own `ingest`. Same rule as `:::input`'s Enter.
        st.set(c.target, text) catch |e| {
            std.log.warn(":::clip: state.set failed: err={s}", .{@errorName(e)});
        };
    }
    return true;
}

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 480;
    const w = c.width.resolve(max_w, fallback_w);
    const h = c.height;

    // Seal what came BEFORE with the clip already in force, so the
    // window's own clip cannot reach backwards over its siblings. This
    // is the pairing that makes the lagging clip arrays correct: every
    // boundary seals, so between two seals the clip is uniform.
    try out.sealClips(lc.current_clip);

    // The window's own hit, appended BEFORE the children so theirs land
    // on top of it — see `emits_own_hits` on the vtable.
    try out.hits.append(.{
        .box = .{ .x = origin[0], .y = origin[1], .w = w, .h = h },
        .vtable = &vtable,
        .ctx = ctx,
        .state = lc.state,
    });

    const outer = lc.current_clip;
    const clip = try out.pushClip(outer, .{ .x = origin[0], .y = origin[1], .w = w, .h = h });
    lc.current_clip = clip;

    // Clamped against the LAST layout's content height — see `content_h`.
    // Without this a wheel or a bound offset can pull the content clean
    // out of the top of its own window and leave it empty, with nothing
    // on screen to suggest which way to go back.
    const eff_offset = std.math.clamp(c.offset, 0, c.maxOffset());

    // The children are laid out at their NATURAL height, pulled up by
    // `offset`. They are not told they are in a window — a paragraph that
    // reflowed to the viewport's height would be a different document at
    // every scroll position, and the whole point is that the content is
    // taller than what shows.
    var child_constraints = constraints;
    child_constraints.max_w = w;
    const child_box = element_layout.layoutAndRender(
        c.root,
        .{ origin[0], origin[1] - eff_offset },
        child_constraints,
        lc,
        out,
    ) catch |e| {
        // Restore before propagating: a walk that leaves the clip pushed
        // would clip the REST of the document to this window.
        try out.sealClips(clip);
        lc.current_clip = outer;
        return e;
    };

    try out.sealClips(clip);
    lc.current_clip = outer;
    // Record what the next frame will bound the offset against.
    c.content_h = child_box.h;

    // The box is the WINDOW, never the content. Reporting the content's
    // height would make the layout below this element start past the
    // bottom of a scrolled-away paragraph, and a clip that pushed its
    // neighbours around would not be a window.
    return .{ .x = origin[0], .y = origin[1], .w = w, .h = h, .baseline = origin[1] + h };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// `onScroll` dirties `spark.host_state`, and the default testStub leaves
// that undefined — so back it with a real State, exactly as `input.zig`
// does. The first draft of these gates ducked this by asserting the clamp
// arithmetic beside the handler instead of through it, which is a gate
// watching a COPY of the logic: it would have passed against an
// `onScroll` that consumed every notch.
var _test_state = state_mod.State.init(testing.allocator);
var _test_spark = blk: {
    var s = spark_mod.Spark.testStub(testing.allocator);
    s.host_state = &_test_state;
    break :blk s;
};

fn testComponent(content_h: f32, height: f32) Component {
    return .{
        .allocator = testing.allocator,
        .arena = undefined,
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
        .spark = &_test_spark,
        .target = @constCast(""),
        .height = height,
        .content_h = content_h,
    };
}

test "clip: the offset is bounded by content that is actually taller" {
    // Without a bound, a wheel or a bound `offset=` pulls the content
    // clean out of the top of its own window and leaves it empty — with
    // nothing on screen to suggest which way to go back.
    var c = testComponent(500, 120);
    try testing.expectEqual(@as(f32, 380), c.maxOffset());

    // Content SHORTER than its window does not scroll at all, and the
    // bound is zero rather than negative — a negative max would let the
    // clamp push the content down and open a gap above it.
    c.content_h = 40;
    try testing.expectEqual(@as(f32, 0), c.maxOffset());
    c.content_h = 120;
    try testing.expectEqual(@as(f32, 0), c.maxOffset());

    // Nothing laid out yet reads as nothing to scroll, which is true.
    c.content_h = 0;
    try testing.expectEqual(@as(f32, 0), c.maxOffset());
}

test "clip: the wheel is given BACK at the ends, and refused with nothing to scroll" {
    // The nested-scroller contract, through the real handler. A window
    // that claims every notch stops the page whenever the pointer strays
    // over it, which is what makes inner scroll regions feel like traps.
    // So `onScroll` answers per NOTCH: taken only if the window can
    // actually move that way.
    var c = testComponent(500, 120); // max offset 380
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();

    // At the top, up has nowhere to go — handed back, and nothing moved.
    c.offset = 0;
    try testing.expect(!try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = -60 }, @ptrCast(&st)));
    try testing.expectEqual(@as(f32, 0), c.offset);

    // Down from the top is taken, and lands where the notch asked.
    try testing.expect(try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = 60 }, @ptrCast(&st)));
    try testing.expectEqual(@as(f32, 60), c.offset);

    // A notch bigger than what is left CLAMPS and is still taken — the
    // window moves as far as it can before it starts refusing.
    try testing.expect(try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = 5000 }, @ptrCast(&st)));
    try testing.expectEqual(@as(f32, 380), c.offset);

    // …and only NOW does it hand the wheel back, still at 380.
    try testing.expect(!try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = 60 }, @ptrCast(&st)));
    try testing.expectEqual(@as(f32, 380), c.offset);
    // Up from the bottom still moves, so the window is not stuck.
    try testing.expect(try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = -60 }, @ptrCast(&st)));
    try testing.expectEqual(@as(f32, 320), c.offset);

    // Content that FITS refuses every notch, so a page of short windows
    // scrolls the page rather than swallowing the wheel.
    var short = testComponent(40, 120);
    try testing.expect(!try onScroll(@ptrCast(&short), .{ .local = .{ 0, 0 }, .dy = 60 }, @ptrCast(&st)));
    try testing.expect(!try onScroll(@ptrCast(&short), .{ .local = .{ 0, 0 }, .dy = -60 }, @ptrCast(&st)));
}

test "clip: a window with a target publishes the offset it scrolled to" {
    // Without this the wheel moves the window and the next ingest snaps
    // it back to whatever `offset=${state.x}` still says — the window
    // would scroll and undo itself, once per frame.
    var c = testComponent(500, 120);
    c.target = @constCast("log_scroll");
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();

    try testing.expect(try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = 60 }, @ptrCast(&st)));
    try testing.expectEqualStrings("60", st.get("log_scroll").?);

    // A refused notch publishes NOTHING — a write is what wakes the
    // plane, and a window at its end should not be waking it every time
    // the wheel turns.
    c.offset = 380;
    try testing.expect(!try onScroll(@ptrCast(&c), .{ .local = .{ 0, 0 }, .dy = 60 }, @ptrCast(&st)));
    try testing.expectEqualStrings("60", st.get("log_scroll").?);
}
