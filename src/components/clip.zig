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
//! ### What this is and is not
//!
//! It is the substrate under a scroll view, not a scroll view: there is
//! no wheel handling, no momentum, no scrollbar, and `offset` is an
//! ordinary bound attribute so the document decides what moves it. That
//! is deliberate — `:::input {numeric}` can drive it today, and when the
//! wheel is routed to components the same attribute is what it will
//! write. The pieces above this one differ (a log pins to the bottom, a
//! chat transcript follows the newest turn, a launcher list does not
//! move at all) and they can be built without re-deciding how clipping
//! works.
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
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "width")) {
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
    };
    errdefer c.arena.deinit();

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
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    // See the header: a cached subtree's clip indices point into the clip
    // table of the frame that recorded them.
    .disable_cache = true,
};

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

    const outer = lc.current_clip;
    const clip = try out.pushClip(outer, .{ .x = origin[0], .y = origin[1], .w = w, .h = h });
    lc.current_clip = clip;

    // The children are laid out at their NATURAL height, pulled up by
    // `offset`. They are not told they are in a window — a paragraph that
    // reflowed to the viewport's height would be a different document at
    // every scroll position, and the whole point is that the content is
    // taller than what shows.
    var child_constraints = constraints;
    child_constraints.max_w = w;
    _ = element_layout.layoutAndRender(
        c.root,
        .{ origin[0], origin[1] - c.offset },
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

    // The box is the WINDOW, never the content. Reporting the content's
    // height would make the layout below this element start past the
    // bottom of a scrolled-away paragraph, and a clip that pushed its
    // neighbours around would not be a window.
    return .{ .x = origin[0], .y = origin[1], .w = w, .h = h, .baseline = origin[1] + h };
}
