//! Element walker — lays out + renders an `Element` tree into a
//! `DrawList`. Single-pass: each call to `layoutAndRender` measures
//! and writes glyphs in one walk.
//!
//! Dispatch is the canonical immediate-mode shape:
//!
//!   * Block kinds (`paragraph`, `heading`, `container`) place
//!     themselves at `origin`, recurse for nested content, and return
//!     a `Box` saying how much vertical space they took.
//!   * Inline leaves (`text`, `line_break`) are not valid as
//!     top-level children of a container — they only appear inside
//!     paragraph/heading content. The walker enforces this at runtime;
//!     parsers shouldn't construct trees that violate it.
//!   * `custom` defers to its vtable. The walker doesn't peek inside
//!     the ctx — that's the whole point of the escape hatch.
//!
//! Stage-1 scope:
//!   * Constraints flow down but the inline-flow path doesn't yet
//!     wrap on `max_w`. Wrapping lands when the markdown layout
//!     engine starts (Phase B) — at which point the wrap policy
//!     becomes per-block.
//!   * No widget chrome — `DrawList` only carries glyphs.
//!   * No input handling — every `Box` is captured though, so
//!     hit-testing slots in later without contract changes.
//!
//! The per-line baseline resolution (`max(ascender)` across the line)
//! is the Makepad-turtle pattern carried over from session 1's
//! `text/layout.zig`. It's what makes mixed-size content land cleanly
//! on one baseline.

const std = @import("std");
const element = @import("element.zig");
const text_layout = @import("text/layout.zig");
const shape = @import("font/shape.zig");
const qp = @import("gpu/quad_pipeline.zig");
const layout_cache = @import("layout_cache.zig");
const jobs_mod = @import("jobs.zig");

/// Stage 14b — parallel stack_v walk thresholds. The dispatcher falls
/// back to serial when these aren't met; dispatch overhead dominates
/// for short stacks.
///
/// **Re-armed in stage 14d (worker pool split).** Blocking HTTP work
/// has moved onto a dedicated I/O pool, so the compute JobSystem's
/// workers are no longer pinned by in-flight streams. The walker can
/// dispatch parallel cache-miss layouts again without the
/// `Counter.wait` spin loop that hung the main thread before.
const PARALLEL_MIN_CHILDREN: usize = 4;
const PARALLEL_MIN_WALKS: usize = 2;

pub const Error = error{
    /// `text` or `line_break` appeared at a position where only block
    /// elements are valid (e.g. as a direct child of a container).
    /// Inline content belongs inside a `paragraph` or `heading`.
    InlineElementOutsideInlineContext,
    /// `code_block` with `.sub_block` content was encountered — this
    /// is the composability hook for the ANSI engine et al., but the
    /// renderer for it lands when that engine does (post-2a).
    CodeBlockSubBlockNotImplemented,
} || std.mem.Allocator.Error || error{ Overflow, SsboOverflow };

// Layout constants now live in `element.Theme` and are read via
// `ctx.theme.*` — see element.zig for the named fields. Walker
// reaches them through LayoutCtx so the host can swap themes
// without touching engine internals.

/// Cache-aware entry point. Wraps `layoutAndRender` for elements that
/// are eligible to be cached at the block grain (stage 14a). Use this
/// at top-level call sites and inside stack_v walks; bypass when you
/// know you want a fresh walk (e.g. inside a custom component that
/// owns its own DrawList).
///
/// Hit → blit cached glyph/quad/tri/hit ranges with origin offset.
/// Miss → fall through to `layoutAndRender`, then snapshot the
/// appended ranges back into the cache in block-local coordinates.
/// No cache wired, or element not eligible → plain walk.
pub fn layoutAndRenderCached(
    elem: element.Element,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const cache = ctx.cache_blocks orelse return layoutAndRender(elem, origin, constraints, ctx, out);
    if (!layout_cache.cacheableLeaf(elem)) {
        cache.skipped += 1;
        return layoutAndRender(elem, origin, constraints, ctx, out);
    }
    const id = layout_cache.elementIdentity(elem);
    if (id == 0) {
        cache.skipped += 1;
        return layoutAndRender(elem, origin, constraints, ctx, out);
    }

    // Pass-seed folds in any layout-state the cached output baked into
    // its positions but that isn't visible in `(elem, constraints,
    // theme, zoom)`. Stage 15 Phase E: active exclusion rects shrink
    // the per-line wrap on the way down. With the seed in the key, a
    // float entering / leaving the document invalidates dependent
    // paragraph caches automatically.
    const pass_seed: u64 = if (ctx.layout_context) |lctx| lctx.exclusionsHash() else 0;
    const key = layout_cache.keyFor(elem, constraints, ctx.theme, ctx.zoom, pass_seed);
    const version = layout_cache.versionFor(elem);

    if (cache.lookup(key, version)) |entry| {
        const box = try layout_cache.blitEntry(out, ctx, entry, origin);
        // The component's `on_layout_complete` hook needs to fire on
        // cache hit too — `layoutAndRender` didn't run, so without
        // this the persistent `last_sizes` cache would never see the
        // hit's resolved size (and drag handlers reading it would
        // miss). Mirror the call layoutAndRender makes on cache miss.
        notifyLayoutComplete(elem, box, ctx);
        return box;
    }

    // Miss: walk into the live DrawList at `origin`, then snapshot the
    // appended ranges back into the cache (translated to block-local
    // coordinates) so the next walk hits.
    const g_start = out.glyphs.items.len;
    const q_start = out.quads.items.len;
    const t_start = out.tris.items.len;
    const ti_start = out.tri_indices.items.len;
    const i_start = out.images.items.len;
    const h_start = out.hits.items.len;
    const tri_vertex_base: u32 = @intCast(out.tris.items.len);
    const pd_start: u32 = if (ctx.pass_dispatches) |pd| @intCast(pd.items.len) else 0;

    const box = try layoutAndRender(elem, origin, constraints, ctx, out);

    const pd_slice: []const element.PassDispatch = if (ctx.pass_dispatches) |pd|
        pd.items[pd_start..]
    else
        &[_]element.PassDispatch{};
    try layout_cache.snapshotEntry(
        cache,
        key,
        version,
        out,
        g_start,
        q_start,
        t_start,
        ti_start,
        i_start,
        h_start,
        tri_vertex_base,
        pd_slice,
        pd_start,
        origin,
        box,
    );
    return box;
}

/// Dispatch the `on_layout_complete` vtable hook for a custom
/// element. Called on cache-hit paths in `layoutAndRenderCached`
/// AND on every cache-miss path through `layoutAndRender`'s .custom
/// branch, so participating components get exactly one notification
/// per walk regardless of cache outcome. No-op for built-in element
/// kinds (only `.custom` has a vtable).
inline fn notifyLayoutComplete(elem: element.Element, box: element.Box, ctx: *element.LayoutCtx) void {
    switch (elem) {
        .custom => |cu| if (cu.vtable.on_layout_complete) |hook| hook(cu.ctx, box, ctx),
        else => {},
    }
}

/// Lay out + render `elem` with its top-left at `origin`. Returns the
/// element's measured `Box` (in display pixels). Constraints are
/// suggestions — stage 1 mostly lays out content-sized — but they
/// flow through the tree so wrap-aware blocks can honour them later.
pub fn layoutAndRender(
    elem: element.Element,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    switch (elem) {
        // Inline kinds — leaf and structural — are only valid inside
        // an inline-flow context (paragraph / heading content).
        // `inline_object` (Stage 15E text intrusion) belongs to the
        // same family: a component flowing inside a paragraph rather
        // than as a standalone block. At block level both are tree-
        // construction errors.
        .text, .line_break, .emphasis, .strong, .code, .link, .inline_object => return error.InlineElementOutsideInlineContext,

        .paragraph => |children| return layoutInlineFlow(
            children,
            origin,
            constraints,
            ctx,
            out,
        ),

        .heading => |h| return layoutInlineFlow(
            h.content,
            origin,
            constraints,
            ctx,
            out,
        ),

        .container => |co| switch (co.layout) {
            .stack_v => return layoutStackV(co.children, co.gap, origin, constraints, ctx, out),
        },

        .spacer => |sp| return .{
            .x = origin[0],
            .y = origin[1],
            .w = 0,
            .h = sp.height,
            .baseline = 0,
        },

        .thematic_break => return layoutThematicBreak(origin, constraints, ctx, out),

        .list => |li| return layoutList(li, origin, constraints, ctx, out),

        .list_item => |it| return layoutStackV(it.children, ctx.theme.block_child_gap, origin, constraints, ctx, out),

        .quote => |q| return layoutQuote(q.children, origin, constraints, ctx, out),

        .code_block => |cb| return layoutCodeBlock(cb.content, origin, constraints, ctx, out),

        .custom => |cu| {
            // **Subtree dispatch-range capture (Phase B.3).** For
            // `.single_source` pass shapes, the walker records the
            // pass-dispatch list length immediately before and after
            // the child's `layout_and_render`. Any pass dispatches
            // emitted by the child subtree fall naturally inside
            // this range — nested single-source effects nest by
            // construction, no recursive data structure needed.
            // For `.pattern` and `.content`, the start index is
            // unused (kept zero).
            //
            // TODO(B.6): nested single-source coverage. No factory
            // ships with `.pass_shape = .single_source` until B.6
            // (`:::drop_shadow`) and B.7 (`:::frosted_glass`), so
            // there is no integration test exercising a nested
            // single-source case (e.g. `:::drop_shadow { :::drop_shadow … }`)
            // at B.4.a. The dispatch-range nesting and walker
            // push/pop are structurally correct by construction,
            // but the round-trip is unproven until B.6 lands a real
            // factory and a test stacks it on itself.
            const dispatch_start: u32 = if (ctx.pass_dispatches) |pd| @intCast(pd.items.len) else 0;

            // **Drawlist target push (Phase B.4.a).** For
            // `.single_source` effects, every drawlist primitive the
            // child subtree emits should route into the offscreen
            // target — not the main color attachment. Push the new
            // dispatch index onto LayoutCtx before the child walk,
            // restore the saved value on return. Nested single-source
            // children push deeper indices that override during their
            // own subtree, restoring back to the enclosing target on
            // exit. Pattern dispatches don't push because they render
            // directly to the parent target via scissored viewport.
            const saved_target = ctx.current_target_dispatch_index;
            if (cu.pass_kind == 2 and ctx.pass_dispatches != null) {
                ctx.current_target_dispatch_index = dispatch_start;
            }
            defer ctx.current_target_dispatch_index = saved_target;

            const box = try cu.vtable.layout_and_render(
                cu.ctx,
                origin,
                constraints,
                ctx,
                out,
            );
            // Register the laid-out box on the hit-test layer iff
            // the component accepts input — non-interactive customs
            // (decorative quads etc.) don't appear in hit-tests.
            if (cu.vtable.on_input != null) {
                try out.hits.append(.{
                    .box = box,
                    .vtable = cu.vtable,
                    .ctx = cu.ctx,
                    // Stamp the layout-time state pointer onto the
                    // Hit so dispatch routes input to the right
                    // state. Top-level walks have `lc.state` set to
                    // the host state; embedded-doc walks swap it to
                    // the doc's child state before delegating.
                    .state = ctx.state,
                    // Propagate vtable focusability so the input
                    // dispatcher can grab keyboard focus on click.
                    // Without this, the walker's Hit shadows any Hit
                    // a component emitted itself — meaning a text
                    // field's own focusable=true would be lost.
                    .focusable = cu.vtable.focusable,
                });
            }
            // Effects-spec Phase A.6.a + B.2/B.3 — pass-graph
            // emission. Content elements MUST NOT declare
            // snapshot_uniforms (asserted with a clear message);
            // pattern + single-source elements emit per-arm
            // dispatch records into LayoutCtx.pass_dispatches.
            if (cu.pass_kind == 0) {
                // Content elements must not declare snapshot_uniforms;
                // only pass-shape variants (.pattern / .single_source /
                // .chain / .host_slot) do. If this fires, a factory
                // wired snapshot_uniforms on a content-shaped vtable —
                // remove it or change the factory's pass_shape.
                if (cu.vtable.snapshot_uniforms != null) {
                    @panic("content element (pass_kind=0) must not declare snapshot_uniforms; only pass-shape variants do");
                }
            } else if (ctx.pass_dispatches) |pd| {
                const snapshot = cu.vtable.snapshot_uniforms orelse
                    return error.NonContentElementMissingSnapshotUniforms;
                var uniform_buf: [element.MAX_PASS_UNIFORM_BYTES]u8 = [_]u8{0} ** element.MAX_PASS_UNIFORM_BYTES;
                const ulen: u32 = @intCast(snapshot(cu.ctx, uniform_buf[0..]));
                const region: element.PassRegion = .{
                    .x = @intFromFloat(@round(box.x)),
                    .y = @intFromFloat(@round(box.y)),
                    .w = @intFromFloat(@round(box.w)),
                    .h = @intFromFloat(@round(box.h)),
                };
                const seq: u32 = @intCast(pd.items.len);
                const dispatch: element.PassDispatch = switch (cu.pass_kind) {
                    1 => .{ .pattern = .{
                        .shader_id = cu.shader_id,
                        .layout_region = region,
                        .uniform_bytes = uniform_buf,
                        .uniform_len = ulen,
                        .sequence_index = seq,
                    } },
                    2 => .{ .single_source = .{
                        .target_size = .{
                            @intFromFloat(@max(0, @round(box.w))),
                            @intFromFloat(@max(0, @round(box.h))),
                        },
                        .filter_shader_id = cu.shader_id,
                        .filter_uniforms = uniform_buf,
                        .filter_uniforms_len = ulen,
                        .compose_region = region,
                        .subtree_dispatch_range = .{ dispatch_start, seq },
                        .sequence_index = seq,
                    } },
                    // Reserved arms (chain, host_slot) — no factory
                    // declares them yet, so this branch is dead. When
                    // Phase B's :::placeholder_scene lights up pass_kind
                    // = 4, the host_slot arm gets its own case here.
                    else => unreachable,
                };
                try pd.append(dispatch);
            }
            // Notify post-layout. Symmetric with the cache-hit branch
            // in `layoutAndRenderCached` — every custom walk fires
            // the hook exactly once, regardless of whether the cache
            // was consulted.
            if (cu.vtable.on_layout_complete) |hook| hook(cu.ctx, box, ctx);
            return box;
        },
    }
}

/// Measure-pass dispatcher (stage 15 Phase C.3). Returns the
/// intrinsic width + height + grow-weight a block-level element
/// reports when asked by a constraint-aware parent. Mirrors the
/// shape of `layoutAndRender` — same switch over Element kinds, no
/// DrawList side effects.
///
/// Built-in element kinds report sensible defaults:
///   * paragraph / heading / list / code_block / thematic_break →
///     claim `constraints.max_w` (wrap or stretch handles the rest)
///   * container.stack_v / list_item → recurse, return max child
///     width and (height-wise) sum of child heights + gaps
///   * spacer → width 0, height = sp.height
///   * quote → recurse, indent applied to the reported width
///
/// `.custom` dispatches to `vtable.measure_block` when present;
/// otherwise falls back to running `layout_and_render` into a
/// throwaway DrawList and translating the returned Box. The
/// fallback is correct but expensive (shapes glyphs, allocates the
/// DrawList); flex/grid children should implement `measure_block`
/// directly.
///
/// Inline kinds at block position → `InlineElementOutsideInlineContext`
/// (the parent constructed the tree incorrectly).
pub fn measureBlock(
    elem: element.Element,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
) anyerror!element.BlockMetrics {
    switch (elem) {
        .text, .line_break, .emphasis, .strong, .code, .link, .inline_object => return error.InlineElementOutsideInlineContext,

        .paragraph, .heading => {
            const w: f32 = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 0;
            return .{ .width = w, .height = 0 };
        },

        .container => |co| switch (co.layout) {
            .stack_v => {
                var max_w: f32 = 0;
                var total_h: f32 = 0;
                for (co.children, 0..) |child, i| {
                    if (i != 0) total_h += co.gap;
                    const m = try measureBlock(child, constraints, ctx);
                    if (m.width > max_w) max_w = m.width;
                    total_h += m.height;
                }
                return .{ .width = max_w, .height = total_h };
            },
        },

        .spacer => |sp| return .{ .width = 0, .height = sp.height },

        .thematic_break => return .{
            .width = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320,
            .height = ctx.theme.thematic_break_height,
        },

        .list => return .{
            .width = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 0,
            .height = 0,
        },

        .list_item => |it| {
            var max_w: f32 = 0;
            var total_h: f32 = 0;
            for (it.children, 0..) |child, i| {
                if (i != 0) total_h += ctx.theme.block_child_gap;
                const m = try measureBlock(child, constraints, ctx);
                if (m.width > max_w) max_w = m.width;
                total_h += m.height;
            }
            return .{ .width = max_w, .height = total_h };
        },

        .quote => |q| {
            const indent = ctx.theme.quote_indent;
            const inner_constraints = shrinkConstraints(constraints, indent);
            var max_w: f32 = 0;
            var total_h: f32 = 0;
            for (q.children, 0..) |child, i| {
                if (i != 0) total_h += ctx.theme.block_child_gap;
                const m = try measureBlock(child, inner_constraints, ctx);
                if (m.width > max_w) max_w = m.width;
                total_h += m.height;
            }
            return .{ .width = max_w + indent, .height = total_h };
        },

        .code_block => return .{
            .width = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320,
            .height = 0,
        },

        .custom => |cu| {
            if (cu.vtable.measure_block) |m| {
                return m(cu.ctx, ctx, constraints);
            }
            return measureViaLayoutFallback(cu.vtable, cu.ctx, constraints, ctx);
        },
    }
}

/// Fallback measure path for `custom` components that don't expose
/// `measure_block`. Runs `layout_and_render` into a scratch DrawList
/// at origin (0,0) and reports the resulting Box dimensions with
/// grow=0. Correct but expensive (shapes glyphs, allocates DrawList
/// scratch). Components used as flex/grid children should implement
/// `measure_block` to skip this.
fn measureViaLayoutFallback(
    vtable: *const element.ElementVTable,
    ctx_anyopaque: *anyopaque,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
) anyerror!element.BlockMetrics {
    var scratch = element.DrawList.init(lc.allocator);
    defer scratch.deinit();
    const box = try vtable.layout_and_render(
        ctx_anyopaque,
        .{ 0, 0 },
        constraints,
        lc,
        &scratch,
    );
    return .{ .width = box.w, .height = box.h };
}

/// Shrink `constraints.max_w` by the given indent. Used by quote /
/// list to propagate "less width is available" to nested content.
/// Other constraint fields pass through unchanged.
fn shrinkConstraints(c: element.Constraints, indent: f32) element.Constraints {
    var out_c = c;
    if (std.math.isFinite(c.max_w) and c.max_w > indent) {
        out_c.max_w = c.max_w - indent;
    }
    return out_c;
}

/// Block quote — indent children horizontally, recurse as stack_v,
/// then emit a thin vertical bar quad spanning the laid-out height
/// at `origin.x`. Bar quad sits in the gap between the document
/// edge and the indented content — looks like the conventional
/// "vertical accent line" mark for quotes.
fn layoutQuote(
    children: []const element.Element,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    const indent = ctx.theme.quote_indent;
    const inner_origin: [2]f32 = .{ origin[0] + indent, origin[1] };
    const inner_constraints = shrinkConstraints(constraints, indent);
    const inner_box = try layoutStackV(children, ctx.theme.block_child_gap, inner_origin, inner_constraints, ctx, out);

    // Emit the bar AFTER child layout so we know its height. Quads
    // render before glyphs in the frame loop, so the bar still
    // appears under any text that happens to overlap it (it doesn't,
    // but the ordering is correct regardless).
    try out.appendQuad(ctx, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ ctx.theme.quote_bar_width, inner_box.h },
        .color = ctx.theme.quote_bar_color,
        .radius = 0,
    });

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = inner_box.w + indent,
        .h = inner_box.h,
        .baseline = 0,
    };
}

/// Thematic break — markdown's `---`. Emits a thin horizontal quad
/// spanning the available width, centred vertically within
/// `theme.thematic_break_height`. Falls back to a small fixed width
/// when constraints are unbounded.
fn layoutThematicBreak(
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    const h = ctx.theme.thematic_break_height;
    const thickness = ctx.theme.thematic_break_thickness;
    const w: f32 = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320.0;

    try out.appendQuad(ctx, .{
        .dst_pos = .{ origin[0], origin[1] + (h - thickness) * 0.5 },
        .dst_size = .{ w, thickness },
        .color = ctx.theme.thematic_break_color,
        .radius = 0,
    });

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = 0,
    };
}

/// List — iterate items, render a marker (• for unordered, "N." for
/// ordered) at `theme.list_marker_indent`, then recurse each item's
/// content at `theme.list_content_indent`. Marker style is
/// `theme.list_marker`. Marker baseline alignment with the first
/// line of item content is implicit: both lay out from the same y,
/// and per-line baseline resolution lands them on the same baseline
/// when they share line metrics.
fn layoutList(
    li: anytype,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    var y = origin[1];
    var index: u32 = li.start;
    const marker_indent = ctx.theme.list_marker_indent;
    const content_indent = ctx.theme.list_content_indent;
    const inner_constraints = shrinkConstraints(constraints, content_indent);

    for (li.items, 0..) |item, i| {
        if (i != 0) y += ctx.theme.list_item_gap;

        // ── Marker ─────────────────────────────────────────────────
        // Compose a tiny inline-flow on the fly: one text run with the
        // marker glyph(s). Stack buffer for ordered-list digits.
        var marker_buf: [16]u8 = undefined;
        const marker_text = if (li.ordered) blk: {
            break :blk std.fmt.bufPrint(&marker_buf, "{d}.", .{index}) catch "•";
        } else "•";

        const marker_children = [_]element.Element{
            .{ .text = .{ .content = marker_text, .style = ctx.theme.list_marker } },
        };
        const marker_paragraph = element.Element{ .paragraph = &marker_children };
        // Marker's glyphs land in the draw list; its returned Box.h
        // is discarded because the item's content advances `y` for
        // us (marker and content share the first line — see comment
        // above).
        _ = try layoutAndRender(
            marker_paragraph,
            .{ origin[0] + marker_indent, y },
            constraints,
            ctx,
            out,
        );

        // ── Item content ───────────────────────────────────────────
        const item_box = try layoutAndRender(
            item,
            .{ origin[0] + content_indent, y },
            inner_constraints,
            ctx,
            out,
        );
        y += item_box.h;

        index += 1;
    }

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = 0,
        .h = y - origin[1],
        .baseline = 0,
    };
}

/// Preformatted code block. Each physical line of `raw.text` (split
/// on '\n') is shaped as a single HB run and emitted directly —
/// bypassing the inline-flow tokenizer because preformatted means
/// **leading whitespace is significant and wrap is disabled**. The
/// inline-flow path's whitespace-collapsing rules (drop leading,
/// strip trailing) are correct for prose but wrong for code; we'd
/// lose the indent on every continuation line otherwise.
/// `.sub_block` is the composability hook for the ANSI engine —
/// when it lands the engine will hand us an Element tree that
/// renders through `layoutAndRender` recursively.
fn layoutCodeBlock(
    content: element.CodeContent,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    switch (content) {
        .sub_block => |sub| {
            // Same chrome as `.raw` (background panel + padding +
            // rounded corners) wrapped around a recursive
            // `layoutAndRender` call. The embedded tree owns its own
            // styles — typically produced by `ansi.parse` for ```ansi
            // fences — so all this arm contributes is the panel and
            // the constraint shrink.
            const pad_x = ctx.theme.code_block_pad_x;
            const pad_y = ctx.theme.code_block_pad_y;
            const bg_idx = out.quads.items.len;
            try out.appendQuad(ctx, .{
                .dst_pos = .{ origin[0], origin[1] },
                .dst_size = .{ 0, 0 },
                .color = ctx.theme.code_block_bg,
                .radius = ctx.theme.code_block_radius,
            });

            const inner_origin: [2]f32 = .{ origin[0] + pad_x, origin[1] + pad_y };
            const inner_constraints = shrinkConstraints(constraints, 2 * pad_x);
            const inner_box = try layoutAndRender(sub.*, inner_origin, inner_constraints, ctx, out);

            const total_h = inner_box.h + 2 * pad_y;
            const total_w: f32 = if (std.math.isFinite(constraints.max_w))
                constraints.max_w
            else
                inner_box.w + 2 * pad_x;
            out.quads.items[bg_idx].dst_size = .{ total_w, total_h };

            return .{
                .x = origin[0],
                .y = origin[1],
                .w = total_w,
                .h = total_h,
                .baseline = 0,
            };
        },
        .raw => |r| {
            const pad_x = ctx.theme.code_block_pad_x;
            const pad_y = ctx.theme.code_block_pad_y;
            // Reserve the background quad slot up front, fill in
            // size once we know the final height. Appending now
            // means the background is BEFORE all the glyphs in the
            // draw-order — the host's frame loop already draws
            // quads-before-glyphs, but keeping insertion-order
            // background-then-content matches mental model.
            const bg_idx = out.quads.items.len;
            try out.appendQuad(ctx, .{
                .dst_pos = .{ origin[0], origin[1] },
                .dst_size = .{ 0, 0 },
                .color = ctx.theme.code_block_bg,
                .radius = ctx.theme.code_block_radius,
            });

            const m = ctx.fonts.metrics(r.style.font_id);
            const hb = ctx.fonts.hbFont(r.style.font_id);
            var y = origin[1] + pad_y;
            const text_x = origin[0] + pad_x;
            var it = std.mem.splitScalar(u8, r.text, '\n');
            while (it.next()) |line| {
                const baseline_y = y + m.ascender;
                if (line.len > 0) {
                    var run = try shape.shapeUtf8(ctx.allocator, hb, line);
                    defer run.deinit();
                    _ = try text_layout.appendShapedRun(
                        &out.glyphs,
        &out.glyph_targets,
        ctx.current_target_dispatch_index,
                        ctx.fonts,
                        ctx.cache,
                        ctx.mono_atlas,
                        ctx.color_atlas,
                        ctx.glyph_cache_lock,
                        run,
                        r.style.font_id,
                        text_x,
                        baseline_y,
                        r.style.color,
                        r.style.hot_color,
                        r.style.attention,
                        ctx.zoom,
                    );
                }
                y += m.line_height;
            }
            y += pad_y;

            // Background quad spans full available width (the
            // conventional code-block look — panel reaches the
            // right edge regardless of content length). Falls back
            // to "content + 2*pad_x" when constraints are unbounded.
            const total_h = y - origin[1];
            const total_w: f32 = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320.0;
            out.quads.items[bg_idx].dst_size = .{ total_w, total_h };

            return .{
                .x = origin[0],
                .y = origin[1],
                .w = total_w,
                .h = total_h,
                .baseline = 0,
            };
        },
    }
}

/// Lay out a vertical stack of block elements. Children sit at the
/// container's `origin.x`; each one's measured `Box.h` advances the
/// cursor, with `gap` between siblings (not before the first nor
/// after the last). The container's reported width is whatever
/// content asked for, clamped to constraints.
fn layoutStackV(
    children: []const element.Element,
    gap: f32,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    // Stage 14b — try parallel fan-out for cache misses across a wide
    // enough stack. The dispatcher checks classification + threshold
    // and falls back to the serial loop below when it doesn't pay.
    if (ctx.job_system != null and ctx.cache_blocks != null and ctx.glyph_cache_lock != null and children.len >= PARALLEL_MIN_CHILDREN) {
        if (try layoutStackVParallel(children, gap, origin, constraints, ctx, out)) |box| return box;
        // null return → not enough cache-miss work to amortise dispatch;
        // fall through to serial.
    }

    var y = origin[1];
    var max_w: f32 = 0;
    // Tracks the furthest-down y any child (floats included) has
    // reached. Floats don't advance the in-flow cursor, but the stack
    // still needs to report a height that covers them so a host
    // container doesn't visually clip the float box.
    var max_bottom_y = origin[1];
    // Whether the *previous* in-flow child was a float — used to skip
    // the gap before a float (a float sitting between two paragraphs
    // shouldn't push the second paragraph down by `gap`) and to skip
    // the gap after a float when the next child is also a float.
    var prev_was_normal = false;
    for (children) |child| {
        const fk = flowKindOf(child);
        if (fk == .normal) {
            if (prev_was_normal) y += gap;
            const child_box = try layoutAndRenderCached(
                child,
                .{ origin[0], y },
                constraints,
                ctx,
                out,
            );
            if (child_box.w > max_w) max_w = child_box.w;
            y += child_box.h;
            if (y > max_bottom_y) max_bottom_y = y;
            prev_was_normal = true;
            continue;
        }
        // Float positioning. The child is laid out at the appropriate
        // edge; its rendered height is reported back via the returned
        // Box but the in-flow cursor `y` does NOT advance — following
        // paragraphs continue at the same y and wrap around the float
        // via the exclusion the float registers on `on_layout_complete`.
        const child_x = floatChildX(child, fk, origin[0], constraints, ctx);
        const child_box = try layoutAndRenderCached(
            child,
            .{ child_x, y },
            constraints,
            ctx,
            out,
        );
        const float_bottom = child_box.y + child_box.h;
        if (float_bottom > max_bottom_y) max_bottom_y = float_bottom;
        // Float width contributes to the stack's reported width
        // (matters when a float is the widest piece of content; for
        // text columns the paragraph usually wins).
        if (child_box.w > max_w) max_w = child_box.w;
    }
    const reported_bottom = if (max_bottom_y > y) max_bottom_y else y;
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = max_w,
        .h = reported_bottom - origin[1],
        .baseline = 0,
    };
}

/// Stage 15 Phase E text exclusion — peek at a child's FlowKind
/// without laying it out. Built-in element kinds always flow normally;
/// only custom components can opt into floats (currently `:::box`).
fn flowKindOf(elem: element.Element) element.FlowKind {
    return switch (elem) {
        .custom => |cu| if (cu.vtable.flow_kind) |fk| fk(cu.ctx) else .normal,
        else => .normal,
    };
}

/// Stage 15 Phase E text exclusion — resolve a floated child's
/// laid-out x against its parent's `origin[0]` + `constraints.max_w`.
/// Left floats sit flush at the left edge. Right floats need the
/// child's measured width up-front so we can place them flush-right;
/// we ask the child via `measure_block` (the same protocol flex grow
/// uses) and fall back to `max_w` / 3 if the child didn't opt in.
fn floatChildX(
    elem: element.Element,
    fk: element.FlowKind,
    parent_x: f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
) f32 {
    if (fk == .float_left) return parent_x;
    if (!std.math.isFinite(constraints.max_w)) return parent_x;
    const cu = switch (elem) {
        .custom => |c| c,
        else => return parent_x,
    };
    const measure = cu.vtable.measure_block orelse {
        return parent_x + constraints.max_w / 3;
    };
    const m = measure(cu.ctx, ctx, constraints) catch {
        return parent_x + constraints.max_w / 3;
    };
    const x = parent_x + constraints.max_w - m.width;
    return if (x < parent_x) parent_x else x;
}

// ── Stage 14b parallel stack_v walk ──────────────────────────────────

/// Per-child decision produced by phase-1 classification. `walk`
/// variants are populated with their `private_dl` only in phase 2 —
/// no allocation if we bail out before dispatching.
const ChildClass = union(enum) {
    cache_hit: layout_cache.Entry,
    walk_with_snapshot: WalkSpec,
    walk_no_cache: WalkSpec,
};

const WalkSpec = struct {
    /// Filled in by the worker (or by the merge-phase fallback walk).
    box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0, .baseline = 0 },
    /// Private per-job DrawList owned by main; the worker writes into
    /// it at origin (0,0). Allocated lazily in phase 2 once we're
    /// committed to dispatching. c_allocator-backed for thread-safety.
    private_dl: ?*element.DrawList = null,
    /// Private per-job `pass_dispatches` — siblings of `private_dl`,
    /// same reason: std.ArrayList is not thread-safe and the walker's
    /// .custom arm both reads (for dispatch_start / seq capture) and
    /// writes (for the dispatch emission) it. Per-worker private
    /// arrays let each worker capture indices into its own local
    /// space; the merge phase appends them into the shared pd in
    /// child order, offsetting every dispatch's sequence_index and
    /// subtree_dispatch_range by the merge base, and the matching
    /// blitPrivate offsets the drawlist's parallel target tags by
    /// the same base. Allocated only when ctx.pass_dispatches is
    /// non-null (no point in allocation for a pre-effects-spec
    /// walker call that doesn't carry a pd).
    private_pd: ?*std.ArrayList(element.PassDispatch) = null,
    /// `null` for the `walk_no_cache` variant; set when this child
    /// will be snapshotted back into the cache after walking.
    cache_key: ?layout_cache.Key = null,
    /// Snapshot version when `cache_key != null`. Captured pre-walk
    /// so a concurrent bump doesn't desynchronise the entry's stored
    /// version from the content it actually holds.
    version: u64 = 0,
    /// Set if the worker errored. Merge phase falls back to a fresh
    /// serial walk for this child.
    err: ?anyerror = null,
    /// Cost hint from the element's vtable (custom components only;
    /// false for paragraph/heading/code_block which always cost
    /// HarfBuzz shaping). Cheap walks don't count toward the
    /// dispatch threshold — frames with only `:::chart` /
    /// `:::*-stream` re-walks stay serial — but they still dispatch
    /// in parallel when an expensive sibling pushes us over.
    cheap: bool = false,
};

const ParallelWalkCtx = struct {
    children: []const element.Element,
    classifications: []ChildClass,
    constraints: element.Constraints,
    base_ctx: *element.LayoutCtx,
};

/// Dispatch parallel walks. Returns null when classification finds
/// fewer than `PARALLEL_MIN_WALKS` walk-able children — caller falls
/// back to serial in that case.
fn layoutStackVParallel(
    children: []const element.Element,
    gap: f32,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!?element.Box {
    // Stage 15 Phase E text exclusion: floats need order-sensitive
    // placement (left/right edge of the column) and per-child cursor
    // logic that doesn't fit the parallel walker's "every child gets
    // origin (0,0)" contract. When the stack contains any float, fall
    // through to the serial path — floats are rare enough that
    // forfeiting parallelism for a section that has one is the right
    // tradeoff for now.
    for (children) |c| {
        if (flowKindOf(c) != .normal) return null;
    }
    const cache = ctx.cache_blocks.?;
    const js = ctx.job_system.?;
    const a = ctx.allocator;

    // Phase 1 — classify every child. No private-DrawList allocations
    // yet — we may bail out below if there aren't enough walks.
    const classifications = try a.alloc(ChildClass, children.len);
    defer a.free(classifications);

    // Count *expensive snapshot-eligible* walks toward the dispatch
    // threshold. Two reasons to exclude:
    //   - `disable_cache = true` children (sliders / inputs /
    //     embedded-doc) walk every frame regardless of state change.
    //     Counting them would dispatch every frame, and workers run
    //     with `cache_blocks = null` so inner cache hits are lost.
    //   - `parallel_layout_cheap = true` custom components (chart,
    //     svg-stream, image-stream) are O(N) memcpy on the re-walk.
    //     Microseconds. Dispatch overhead would dominate. A frame
    //     dirtied only by chart appends stays serial; once an
    //     expensive sibling (paragraph re-shape, fresh LLM-stream
    //     re-parse) pushes us over, the cheap walks ride along in
    //     parallel for free.
    var expensive_walks: usize = 0;
    for (children, 0..) |child, i| {
        classifications[i] = classifyChild(child, constraints, ctx, cache);
        switch (classifications[i]) {
            .walk_with_snapshot => |s| if (!s.cheap) {
                expensive_walks += 1;
            },
            else => {},
        }
    }

    if (expensive_walks < PARALLEL_MIN_WALKS) return null;

    // Phase 2 — allocate private DrawLists for every walk slot. These
    // are released after the merge, regardless of success/failure.
    // private_pd allocated alongside iff the parent ctx carries a
    // pass_dispatches (effects-spec post-B.2/B.3).
    const want_private_pd = ctx.pass_dispatches != null;
    for (classifications) |*cls| {
        switch (cls.*) {
            .cache_hit => {},
            .walk_with_snapshot => |*s| {
                s.private_dl = try a.create(element.DrawList);
                s.private_dl.?.* = element.DrawList.init(std.heap.c_allocator);
                if (want_private_pd) {
                    s.private_pd = try a.create(std.ArrayList(element.PassDispatch));
                    s.private_pd.?.* = std.ArrayList(element.PassDispatch).init(std.heap.c_allocator);
                }
            },
            .walk_no_cache => |*s| {
                s.private_dl = try a.create(element.DrawList);
                s.private_dl.?.* = element.DrawList.init(std.heap.c_allocator);
                if (want_private_pd) {
                    s.private_pd = try a.create(std.ArrayList(element.PassDispatch));
                    s.private_pd.?.* = std.ArrayList(element.PassDispatch).init(std.heap.c_allocator);
                }
            },
        }
    }
    defer {
        for (classifications) |cls| {
            const pdl_opt: ?*element.DrawList = switch (cls) {
                .cache_hit => null,
                .walk_with_snapshot => |s| s.private_dl,
                .walk_no_cache => |s| s.private_dl,
            };
            if (pdl_opt) |pdl| {
                pdl.deinit();
                a.destroy(pdl);
            }
            const ppd_opt: ?*std.ArrayList(element.PassDispatch) = switch (cls) {
                .cache_hit => null,
                .walk_with_snapshot => |s| s.private_pd,
                .walk_no_cache => |s| s.private_pd,
            };
            if (ppd_opt) |ppd| {
                ppd.deinit();
                a.destroy(ppd);
            }
        }
    }

    // Phase 3 — dispatch one job per child index. Cache hits return
    // immediately inside the job; only walks do real work. We dispatch
    // *all* indices (not just walks) so the worker loop doesn't need
    // to map sparse indices — uncontested hits cost a few ns each.
    var walk_ctx = ParallelWalkCtx{
        .children = children,
        .classifications = classifications,
        .constraints = constraints,
        .base_ctx = ctx,
    };
    var counter = jobs_mod.Counter.init(0);
    js.parallelFor(
        @intCast(children.len),
        1,
        walkOneJob,
        @ptrCast(&walk_ctx),
        &counter,
    );
    js.waitFor(&counter);

    // Phase 4 — merge in order. Hits blit cached entries; walks blit
    // private DrawLists and snapshot back into the cache when
    // applicable. Worker errors fall back to a serial walk in the
    // master so a flaky path doesn't leave a hole.
    var y = origin[1];
    var max_w: f32 = 0;
    for (children, 0..) |child, i| {
        if (i != 0) y += gap;
        const child_origin: [2]f32 = .{ origin[0], y };
        switch (classifications[i]) {
            .cache_hit => |entry| {
                const box = try layout_cache.blitEntry(out, ctx, entry, child_origin);
                if (box.w > max_w) max_w = box.w;
                y += entry.box.h;
            },
            .walk_with_snapshot => |spec| {
                if (spec.err != null or spec.private_dl == null) {
                    const box = try layoutAndRenderCached(child, child_origin, constraints, ctx, out);
                    if (box.w > max_w) max_w = box.w;
                    y += box.h;
                    continue;
                }
                // Merge pd FIRST so pd_offset matches where the
                // private entries land in the shared pd. Then
                // blitPrivate uses that offset to rewrite the
                // drawlist's parallel target tags. Same
                // child_origin flows into both so dispatch regions
                // and drawlist primitives end up in the same
                // (screen-space) coord system.
                const pd_offset = try mergePrivatePassDispatches(ctx.pass_dispatches, spec.private_pd, child_origin);
                try blitPrivate(out, spec.private_dl.?, child_origin, pd_offset);
                if (spec.cache_key) |key| {
                    try snapshotFromPrivate(cache, key, spec.version, spec.private_dl.?, spec.private_pd, spec.box);
                }
                if (spec.box.w > max_w) max_w = spec.box.w;
                y += spec.box.h;
            },
            .walk_no_cache => |spec| {
                if (spec.err != null or spec.private_dl == null) {
                    const box = try layoutAndRenderCached(child, child_origin, constraints, ctx, out);
                    if (box.w > max_w) max_w = box.w;
                    y += box.h;
                    continue;
                }
                const pd_offset = try mergePrivatePassDispatches(ctx.pass_dispatches, spec.private_pd, child_origin);
                try blitPrivate(out, spec.private_dl.?, child_origin, pd_offset);
                if (spec.box.w > max_w) max_w = spec.box.w;
                y += spec.box.h;
            },
        }
    }

    return element.Box{
        .x = origin[0],
        .y = origin[1],
        .w = max_w,
        .h = y - origin[1],
        .baseline = 0,
    };
}

/// Classify one child. Cache eligibility mirrors `layoutAndRenderCached`:
/// must be `cacheableLeaf`, must have a non-zero `elementIdentity`,
/// must hit the cache at the current version. Anything else falls
/// through to a walk; cacheable-but-stale walks get a `cache_key` so
/// the merge step snapshots back into the cache.
///
/// Note: does NOT allocate `private_dl` — that happens in phase 2.
fn classifyChild(
    elem: element.Element,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    cache: *layout_cache.BlockCache,
) ChildClass {
    if (layout_cache.cacheableLeaf(elem)) {
        const id = layout_cache.elementIdentity(elem);
        if (id != 0) {
            const pass_seed: u64 = if (ctx.layout_context) |lctx| lctx.exclusionsHash() else 0;
            const key = layout_cache.keyFor(elem, constraints, ctx.theme, ctx.zoom, pass_seed);
            const version = layout_cache.versionFor(elem);
            if (cache.lookup(key, version)) |entry| {
                return .{ .cache_hit = entry };
            }
            return .{ .walk_with_snapshot = .{
                .cache_key = key,
                .version = version,
                .cheap = isCheap(elem),
            } };
        }
    }
    cache.skipped += 1;
    return .{ .walk_no_cache = .{} };
}

/// True when an element's per-frame walk cost is small enough that
/// parallel dispatch overhead would dominate it. Only custom
/// components can opt in (via `vtable.parallel_layout_cheap`); all
/// other Element kinds run real layout work (HarfBuzz shape, etc.)
/// and are always treated as expensive.
fn isCheap(elem: element.Element) bool {
    return switch (elem) {
        .custom => |c| c.vtable.parallel_layout_cheap,
        else => false,
    };
}

/// Worker entry. Walks each child in its batch range into the
/// already-allocated private DrawList at origin (0,0). On error the
/// worker stamps `spec.err` and the merge phase falls back to serial.
fn walkOneJob(job: *jobs_mod.Job) void {
    const range = job.getData(jobs_mod.BatchRange);
    const wc: *ParallelWalkCtx = @constCast(@ptrCast(@alignCast(range.context)));

    // Worker-local LayoutCtx: shadow the cache + job_system fields
    // so workers walk recursively without touching the block cache
    // and without recursive dispatch. Allocator swaps to c_allocator
    // (thread-safe; the inline-flow arena builds on top). Lock stays
    // in place so the inner shaping path serialises around the glyph
    // cache + atlas.
    var worker_ctx = wc.base_ctx.*;
    worker_ctx.allocator = std.heap.c_allocator;
    worker_ctx.cache_blocks = null;
    worker_ctx.job_system = null;

    var i = range.start;
    while (i < range.end) : (i += 1) {
        const cls_ptr = &wc.classifications[i];
        const spec_ptr: *WalkSpec = switch (cls_ptr.*) {
            .cache_hit => continue,
            .walk_with_snapshot => |*s| s,
            .walk_no_cache => |*s| s,
        };
        const pdl = spec_ptr.private_dl orelse continue;
        // Route pass_dispatches through this worker's private
        // pd. Workers can capture dispatch_start / seq inside
        // their own local index space without racing other
        // workers' appends; merge phase rewrites indices.
        // current_target_dispatch_index starts at MAIN_TARGET
        // for each worker — top-level children begin outside
        // any effect, identical to the serial walker's start
        // state.
        worker_ctx.pass_dispatches = spec_ptr.private_pd;
        worker_ctx.current_target_dispatch_index = element.MAIN_TARGET;
        const box = layoutAndRender(
            wc.children[i],
            .{ 0, 0 },
            wc.constraints,
            &worker_ctx,
            pdl,
        ) catch |e| {
            spec_ptr.err = e;
            continue;
        };
        spec_ptr.box = box;
    }
}

/// Append a private DrawList's contents into `out`, translating
/// positions by `origin` and rebasing triangle indices. Symmetric to
/// `layout_cache.blitEntry`, but reads from a live DrawList rather
/// than a cached snapshot.
///
/// `pd_offset` rewrites the worker-side target tags to point at
/// their post-merge positions in the shared pass_dispatches. Workers
/// captured dispatch indices into their PRIVATE pd (worker-local);
/// the merge slid those entries to `pd_offset` in main pd. Every
/// non-sentinel target tag in src's parallel arrays needs the same
/// slide. `MAIN_TARGET` is the sentinel for "main color attachment,
/// no dispatch" and stays unmodified. Phase B.5 polish.
fn blitPrivate(
    out: *element.DrawList,
    src: *const element.DrawList,
    origin: [2]f32,
    pd_offset: u32,
) !void {
    const ox = origin[0];
    const oy = origin[1];

    const g_start = out.glyphs.items.len;
    try out.appendGlyphsPreservingTargets(src.glyphs.items, src.glyph_targets.items);
    for (out.glyphs.items[g_start..]) |*g| {
        g.dst_pos[0] += ox;
        g.dst_pos[1] += oy;
    }
    rebaseTargets(out.glyph_targets.items[g_start..], pd_offset);

    const q_start = out.quads.items.len;
    try out.appendQuadsPreservingTargets(src.quads.items, src.quad_targets.items);
    for (out.quads.items[q_start..]) |*q| {
        q.dst_pos[0] += ox;
        q.dst_pos[1] += oy;
    }
    rebaseTargets(out.quad_targets.items[q_start..], pd_offset);

    const tri_vertex_base: u32 = @intCast(out.tris.items.len);
    try out.appendTrisPreservingTargets(src.tris.items, src.tri_targets.items);
    for (out.tris.items[tri_vertex_base..]) |*v| {
        v.pos[0] += ox;
        v.pos[1] += oy;
    }
    rebaseTargets(out.tri_targets.items[tri_vertex_base..], pd_offset);
    const ti_start = out.tri_indices.items.len;
    try out.tri_indices.appendSlice(src.tri_indices.items);
    for (out.tri_indices.items[ti_start..]) |*idx| idx.* += tri_vertex_base;

    for (src.images.items, src.image_targets.items) |im, tag| {
        var im2 = im;
        im2.dst_pos[0] += ox;
        im2.dst_pos[1] += oy;
        const rebased: u32 = if (tag == element.MAIN_TARGET) tag else tag + pd_offset;
        try out.appendImagePreservingTarget(im2, rebased);
    }

    for (src.hits.items) |h| {
        var h2 = h;
        h2.box.x += ox;
        h2.box.y += oy;
        try out.hits.append(h2);
    }
}

/// In-place rewrite of parallel target tags by `offset`. Sentinel
/// `MAIN_TARGET` entries are preserved verbatim — they mean "main
/// color attachment, no offset applies."
fn rebaseTargets(targets: []u32, offset: u32) void {
    if (offset == 0) return;
    for (targets) |*t| {
        if (t.* != element.MAIN_TARGET) t.* += offset;
    }
}

/// Append every entry from a worker's private `pass_dispatches`
/// array into the shared `out` pd, offsetting every internal index
/// by the merge base so cross-references stay valid, AND translating
/// `layout_region` / `compose_region` by the worker's `origin` so
/// the regions are in shared (screen-space) coords rather than
/// worker-local (0,0) coords. Returns the base offset so the caller
/// can pass it to `blitPrivate` to rewrite the matching drawlist
/// target tags.
///
/// Index rewrites per entry:
///   * Both arms: `sequence_index += base` (preserves hashing
///     determinism — sequence_index is hashed, so it must reflect
///     position in the merged pd).
///   * `single_source`: `subtree_dispatch_range[0..2] += base`
///     (range still describes the same subtree, just at shifted
///     positions).
///
/// Region translation per entry:
///   * `pattern.layout_region`: offset by (origin.x, origin.y) —
///     worker captured this at its own (0,0) origin via the walker;
///     screen-space requires the parent's child_origin.
///   * `single_source.compose_region`: same translation.
///   * `single_source.target_size`: unchanged (size is invariant).
///
/// Symmetric with `blitPrivate`'s positional translation of
/// drawlist primitives — same `origin` value flows into both so the
/// per-target rendering's coord systems stay aligned (drawlist quads
/// rendered into an offscreen target use target-local coords derived
/// from compose_region; compose dispatches use screen-space derived
/// from compose_region).
///
/// No-op when `out_opt` is null (parent ctx had no pass_dispatches —
/// the worker didn't allocate a private_pd either, so src is null
/// and we return 0).
fn mergePrivatePassDispatches(
    out_opt: ?*std.ArrayList(element.PassDispatch),
    src_opt: ?*const std.ArrayList(element.PassDispatch),
    origin: [2]f32,
) !u32 {
    const out = out_opt orelse return 0;
    const src = src_opt orelse return 0;
    const base: u32 = @intCast(out.items.len);
    const ox: i32 = @intFromFloat(@round(origin[0]));
    const oy: i32 = @intFromFloat(@round(origin[1]));
    try out.ensureUnusedCapacity(src.items.len);
    for (src.items) |d| {
        var d_local = d;
        switch (d_local) {
            .pattern => |*p| {
                p.sequence_index += base;
                p.layout_region.x += ox;
                p.layout_region.y += oy;
            },
            .single_source => |*ss| {
                ss.subtree_dispatch_range[0] += base;
                ss.subtree_dispatch_range[1] += base;
                ss.sequence_index += base;
                ss.compose_region.x += ox;
                ss.compose_region.y += oy;
            },
        }
        out.appendAssumeCapacity(d_local);
    }
    return base;
}

/// Copy a private DrawList's contents into a new cache Entry (block-
/// local coords — no translation needed because the worker already
/// walked at origin (0,0)). Includes the worker's private
/// pass_dispatches — also already block-local for the same reason
/// (worker's pd indices start at 0; regions captured at origin
/// (0, 0)).
fn snapshotFromPrivate(
    cache: *layout_cache.BlockCache,
    key: layout_cache.Key,
    version: u64,
    src: *const element.DrawList,
    src_pd_opt: ?*const std.ArrayList(element.PassDispatch),
    box: element.Box,
) !void {
    const glyphs = try cache.allocator.dupe(@TypeOf(src.glyphs.items[0]), src.glyphs.items);
    errdefer cache.allocator.free(glyphs);
    const quads = try cache.allocator.dupe(@TypeOf(src.quads.items[0]), src.quads.items);
    errdefer cache.allocator.free(quads);
    const tris = try cache.allocator.dupe(@TypeOf(src.tris.items[0]), src.tris.items);
    errdefer cache.allocator.free(tris);
    const tri_indices = try cache.allocator.dupe(u32, src.tri_indices.items);
    errdefer cache.allocator.free(tri_indices);
    const images = try cache.allocator.dupe(element.ImageDraw, src.images.items);
    errdefer cache.allocator.free(images);
    const hits = try cache.allocator.dupe(element.Hit, src.hits.items);
    errdefer cache.allocator.free(hits);
    // Phase B.6 — dup parallel routing tags. Worker walked its
    // private DrawList from scratch (pd_start = 0, no outer
    // single_source context), so any local-pd indices on the
    // primitives are already 0-based and `MAIN_TARGET` is its own
    // sentinel — neither needs further rebase here.
    const glyph_targets = try cache.allocator.dupe(u32, src.glyph_targets.items);
    errdefer cache.allocator.free(glyph_targets);
    const quad_targets = try cache.allocator.dupe(u32, src.quad_targets.items);
    errdefer cache.allocator.free(quad_targets);
    const tri_targets = try cache.allocator.dupe(u32, src.tri_targets.items);
    errdefer cache.allocator.free(tri_targets);
    const image_targets = try cache.allocator.dupe(u32, src.image_targets.items);
    errdefer cache.allocator.free(image_targets);
    const pds = if (src_pd_opt) |src_pd|
        try cache.allocator.dupe(element.PassDispatch, src_pd.items)
    else
        try cache.allocator.alloc(element.PassDispatch, 0);
    errdefer cache.allocator.free(pds);

    try cache.insert(key, .{
        .version = version,
        .glyphs = glyphs,
        .glyph_targets = glyph_targets,
        .quads = quads,
        .quad_targets = quad_targets,
        .tris = tris,
        .tri_targets = tri_targets,
        .tri_indices = tri_indices,
        .images = images,
        .image_targets = image_targets,
        .hits = hits,
        .pass_dispatches = pds,
        .box = .{
            .x = 0,
            .y = 0,
            .w = box.w,
            .h = box.h,
            .baseline = box.baseline, // already block-local: worker walked at (0,0)
        },
    });
}

/// Lay out a flat list of inline elements as one or more lines of
/// text, wrapping on `constraints.max_w`.
///
/// Algorithm:
///   1. Tokenize children into a flat list of `InlineToken`s — each
///      contiguous non-whitespace UTF-8 run becomes a `word`, each
///      whitespace run becomes a `gap`, and each `line_break` becomes
///      a `line_break` token. Whitespace splitting is ASCII space
///      only for now (CommonMark prose is dominated by space anyway;
///      tab + NBSP + Unicode whitespace classes land when we hit
///      content that needs them).
///   2. Shape each word + gap once via HarfBuzz (arena-allocated for
///      this call so the shaped runs all free in one shot). Per-atom
///      width is the sum of `x_advance × fscale` over its glyphs.
///   3. Greedy line build: accumulate tokens until adding the next
///      word would exceed `max_w`; if the line already has content,
///      wrap before that word and start fresh. Strip trailing gaps
///      from the wrapped line (no rendered trailing whitespace);
///      drop leading gaps from a new line (no rendered leading
///      whitespace).
///   4. Per-line emit reuses Makepad-style baseline resolution —
///      `max(ascender)` across atoms on the line, then place each
///      atom's shaped glyphs at the resolved baseline via
///      `appendShapedRun`.
///
/// What's deliberately *not* here yet:
///   * Tabs / Unicode whitespace classes — split on ASCII space only.
///   * Character-level break for an oversized single word — currently
///     it overflows; future stage adds break-anywhere fallback.
///   * Hyphenation / soft-hyphen / U+00AD handling.
///   * Bidirectional text — HB does the per-run shaping correctly,
///     but line composition assumes LTR pen flow.
fn layoutInlineFlow(
    children: []const element.Element,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    // Arena owns every shaped run we allocate in this call. One free
    // at the end instead of N free()s — the per-frame layout pass
    // doesn't keep these around.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // ── 1 & 2: tokenize + shape ────────────────────────────────────
    var tokens = std.ArrayList(InlineToken).init(arena_alloc);
    try collectInlineTokens(children, &tokens, arena_alloc, ctx);

    // Handle the empty-paragraph case before the wrap loop. Picks up
    // the first font's line_height; falls back to 16 if no fonts are
    // loaded yet. This preserves the spacer-as-empty-paragraph
    // behavior session-1 callers relied on.
    if (tokens.items.len == 0) {
        const lh: f32 = if (ctx.fonts.entries.items.len > 0)
            ctx.fonts.metrics(0).line_height
        else
            16;
        return .{
            .x = origin[0],
            .y = origin[1],
            .w = 0,
            .h = lh,
            .baseline = origin[1] + lh,
        };
    }

    // ── 3: greedy wrap-aware line build ────────────────────────────
    // The column's hard left + right edges. Exclusions (stage 15 Phase
    // E text exclusion) shrink the per-line usable range from these
    // edges; the wrap loop queries `lc.lineBounds` at the start of
    // each new line and again whenever `y` advances. With no
    // exclusions registered the query returns `[column_left,
    // column_right]` unchanged, so the no-float fast path costs only
    // the (usually empty) for-loop in `lineBounds`.
    const column_left = origin[0];
    const column_right = origin[0] + constraints.max_w;
    // Conservative per-line query height — exclusion lookups assume
    // each line occupies roughly the body line_height. Mixed-size
    // content can exceed this; the float boundary is generous enough
    // (rect spans the whole floated element's height) that off-by-a-
    // few-pixels in the query height doesn't move the wrap decision.
    const query_line_h: f32 = if (ctx.fonts.entries.items.len > 0)
        ctx.fonts.metrics(ctx.theme.body.font_id).line_height
    else
        16;

    var y = origin[1];

    // Resolve the current line's left + right against any active
    // exclusion. When `layout_context` isn't wired (built-in tests,
    // headless preview), exclusions are unreachable and the line spans
    // the full column.
    var line_left = column_left;
    var line_right = column_right;
    if (ctx.layout_context) |lctx| {
        const lb = lctx.lineBounds(y, query_line_h, column_left, column_right);
        line_left = lb[0];
        line_right = lb[1];
    }

    // `line_start` is the first token index of the current line;
    // `pen_x` is the running pixel cursor on it.
    var line_start: usize = 0;
    var pen_x: f32 = line_left;
    var last_baseline: f32 = 0;
    var i: usize = 0;

    while (i < tokens.items.len) : (i += 1) {
        const tok = tokens.items[i];

        // Forced break — flush current line (without including the
        // break itself), advance past it.
        if (isLineBreak(tok)) {
            const lm = try emitLine(tokens.items[line_start..i], line_left, y, ctx, out);
            y += lm.line_height;
            last_baseline = lm.baseline;
            line_start = i + 1;
            if (ctx.layout_context) |lctx| {
                const lb = lctx.lineBounds(y, query_line_h, column_left, column_right);
                line_left = lb[0];
                line_right = lb[1];
            }
            pen_x = line_left;
            continue;
        }

        const width = tokenWidth(tok);

        // Wrap check: only wrap *before a word*, not before a gap —
        // gaps are clean break points themselves and shouldn't push
        // wrap decisions. Don't wrap if the line has no content yet
        // (otherwise an oversized first word would loop forever).
        if (isWord(tok) and line_start < i and pen_x + width > line_right) {
            // Find the line's emit end: strip any trailing gaps so
            // wrapped lines don't render a hanging space character.
            var emit_end = i;
            while (emit_end > line_start and isGap(tokens.items[emit_end - 1])) : (emit_end -= 1) {}

            const lm = try emitLine(tokens.items[line_start..emit_end], line_left, y, ctx, out);
            y += lm.line_height;
            last_baseline = lm.baseline;

            // Skip any gap tokens between `emit_end` and `i` — those
            // are the whitespace that "lived in" the wrap point and
            // shouldn't render on either side of the break.
            line_start = i;
            if (ctx.layout_context) |lctx| {
                const lb = lctx.lineBounds(y, query_line_h, column_left, column_right);
                line_left = lb[0];
                line_right = lb[1];
            }
            pen_x = line_left;
        }

        // Drop a leading gap at the start of a fresh line. We do
        // this by advancing `line_start` past it; the gap atom
        // simply never enters the rendered slice. No `pen_x`
        // update because the gap had no width charge.
        if (isGap(tok) and i == line_start) {
            line_start = i + 1;
            continue;
        }

        pen_x += width;
    }

    // Flush trailing line (the common case — most paragraphs end
    // without an explicit hard break).
    if (line_start < tokens.items.len) {
        var emit_end = tokens.items.len;
        while (emit_end > line_start and isGap(tokens.items[emit_end - 1])) : (emit_end -= 1) {}
        if (emit_end > line_start) {
            const lm = try emitLine(tokens.items[line_start..emit_end], line_left, y, ctx, out);
            y += lm.line_height;
            last_baseline = lm.baseline;
        }
    }

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 0,
        .h = y - origin[1],
        .baseline = last_baseline,
    };
}

// ── Inline-flow internals ──────────────────────────────────────────

/// A single atom in the wrap pass — one shaped run plus the cached
/// metrics the wrap algorithm needs (width, ascender, line_height).
/// One per word or whitespace gap; LineBreak carries no atom.
const ShapedAtom = struct {
    run: shape.ShapedRun,
    style: element.Style,
    width: f32,
    ascender: f32,
    line_height: f32,
};

/// Wrap-pass atom for an inline component. Carries the vtable + ctx
/// the emit pass dispatches to, plus the intrinsic metrics the line-
/// build needs (width drives wrap; ascender + descender drive baseline
/// resolve and line-box height). `valign` is the alignment policy
/// declared at the Element layer; emit consults it to position the
/// component vertically against the resolved baseline.
const ObjectAtom = struct {
    vtable: *const element.ElementVTable,
    ctx: *anyopaque,
    valign: element.InlineAlign,
    width: f32,
    ascender: f32,
    descender: f32,
};

const InlineToken = union(enum) {
    word: ShapedAtom,
    gap: ShapedAtom,
    object: ObjectAtom,
    line_break,
};

fn isWord(t: InlineToken) bool {
    return switch (t) {
        // Objects wrap like words — they're atomic units the wrap
        // logic must decide to keep or push to a new line. Treating
        // them as words makes "would adding this overflow?" use the
        // right code path; the line-build's leading-gap drop logic
        // then naturally handles a gap that fell at the wrap point.
        .word, .object => true,
        else => false,
    };
}
fn isGap(t: InlineToken) bool {
    return switch (t) {
        .gap => true,
        else => false,
    };
}
fn isLineBreak(t: InlineToken) bool {
    return switch (t) {
        .line_break => true,
        else => false,
    };
}
fn tokenWidth(t: InlineToken) f32 {
    return switch (t) {
        .word => |w| w.width,
        .gap => |g| g.width,
        .object => |o| o.width,
        .line_break => 0,
    };
}
fn tokenAtom(t: InlineToken) ?ShapedAtom {
    return switch (t) {
        .word => |w| w,
        .gap => |g| g,
        // Objects don't carry a ShapedAtom — emit handles them
        // separately. Returning null lets the existing decoration /
        // shaping loop skip the object's slot without touching style
        // fields that don't exist on it.
        .object, .line_break => null,
    };
}

/// Per-atom ascender contribution to the line's `max(ascender)`
/// resolve. Text atoms read their font's ascender; objects report
/// their own.
fn tokenAscender(t: InlineToken) f32 {
    return switch (t) {
        .word => |w| w.ascender,
        .gap => |g| g.ascender,
        .object => |o| o.ascender,
        .line_break => 0,
    };
}

/// Per-atom `line_height` contribution to the line box. Text atoms
/// supply their font's `line_height` (already includes leading);
/// objects supply `ascender + descender` so the line box grows just
/// enough to contain them.
fn tokenLineHeight(t: InlineToken) f32 {
    return switch (t) {
        .word => |w| w.line_height,
        .gap => |g| g.line_height,
        .object => |o| o.ascender + o.descender,
        .line_break => 0,
    };
}

/// Recursively walk an inline-context element list, flattening
/// inline structural containers (`emphasis` / `strong` / `code` /
/// `link`) into their constituent leaves. Each `text` leaf becomes a
/// stream of Word + Gap atoms; `line_break` becomes one
/// `InlineToken.line_break`. The structural kinds are render-time
/// transparent — the cascade that gives them visual distinction was
/// already baked into the descendant text leaves' Style by the
/// parser / builder.
///
/// Block elements at an inline position are a tree-construction
/// error and surface as `InlineElementOutsideInlineContext`.
fn collectInlineTokens(
    children: []const element.Element,
    tokens: *std.ArrayList(InlineToken),
    allocator: std.mem.Allocator,
    ctx: *element.LayoutCtx,
) !void {
    for (children) |child| {
        switch (child) {
            .text => |t| try tokenizeText(t.content, t.style, tokens, allocator, ctx),
            .line_break => try tokens.append(.line_break),
            .emphasis => |inner| try collectInlineTokens(inner, tokens, allocator, ctx),
            .strong => |inner| try collectInlineTokens(inner, tokens, allocator, ctx),
            .code => |inner| try collectInlineTokens(inner, tokens, allocator, ctx),
            .link => |l| try collectInlineTokens(l.content, tokens, allocator, ctx),
            .inline_object => |io| {
                // Pull the component's intrinsic metrics so wrap +
                // baseline-resolve know where to put it. A component
                // that surfaces as inline_object MUST set
                // `measure_inline`; an unmeasured object is a
                // construction error rather than a silent zero-width
                // ghost.
                const measurer = io.vtable.measure_inline orelse
                    return error.InlineObjectMissingMeasurer;
                const em_px: f32 = @floatFromInt(ctx.fonts.displayPx(ctx.theme.body.font_id));
                const m = try measurer(io.ctx, em_px, ctx);
                try tokens.append(.{ .object = .{
                    .vtable = io.vtable,
                    .ctx = io.ctx,
                    .valign = io.valign,
                    .width = m.width,
                    .ascender = m.ascender,
                    .descender = m.descender,
                } });
            },
            else => return error.InlineElementOutsideInlineContext,
        }
    }
}

/// Walk one text element's content, splitting on runs of ASCII space
/// into Word + Gap atoms (each shaped once and pushed to `tokens`).
/// Empty content emits nothing.
fn tokenizeText(
    content: []const u8,
    style: element.Style,
    tokens: *std.ArrayList(InlineToken),
    allocator: std.mem.Allocator,
    ctx: *element.LayoutCtx,
) !void {
    var i: usize = 0;
    while (i < content.len) {
        const is_space = content[i] == ' ';
        const start = i;
        if (is_space) {
            while (i < content.len and content[i] == ' ') : (i += 1) {}
        } else {
            while (i < content.len and content[i] != ' ') : (i += 1) {}
        }
        const atom = try shapeAtom(content[start..i], style, allocator, ctx);
        if (is_space) {
            try tokens.append(.{ .gap = atom });
        } else {
            try tokens.append(.{ .word = atom });
        }
    }
}

/// Shape one text slice through HB at the style's font, cache its
/// width + metrics, return a `ShapedAtom` ready for layout. The
/// returned ShapedRun is owned by `allocator` (typically an arena
/// for the duration of one layoutInlineFlow call).
fn shapeAtom(
    text: []const u8,
    style: element.Style,
    allocator: std.mem.Allocator,
    ctx: *element.LayoutCtx,
) !ShapedAtom {
    const hb = ctx.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(allocator, hb, text);
    const fscale = ctx.fonts.scale(style.font_id);
    var width: f32 = 0;
    for (run.glyphs) |g| width += g.x_advance * fscale;
    const m = ctx.fonts.metrics(style.font_id);
    return .{
        .run = run,
        .style = style,
        .width = width,
        .ascender = m.ascender,
        .line_height = m.line_height,
    };
}

const LineMetrics = struct {
    baseline: f32,
    line_height: f32,
};

/// Per-line decoration tracker. Walks the line's atoms left-to-right
/// and accumulates a contiguous span (start_x .. end_x) sharing some
/// style attribute (underline, strikethrough, run background). The
/// span closes into a single quad when the attribute switches off;
/// `max_px` carries the run's dominant `displayPx` so emit
/// thickness/offset scale to the largest font in the span.
const DecorationRun = struct {
    start_x: f32 = 0,
    active: bool = false,
    max_px: u32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0 },

    /// Advance the tracker for one atom. Returns true when a run
    /// just closed — the caller reads the still-populated fields and
    /// emits the quad.
    fn step(self: *DecorationRun, on: bool, x: f32, px: u32, color: [4]f32) bool {
        if (on) {
            if (!self.active) {
                self.start_x = x;
                self.active = true;
                self.max_px = px;
                self.color = color;
            } else if (px > self.max_px) {
                self.max_px = px;
            }
            return false;
        }
        const was_active = self.active;
        self.active = false;
        return was_active;
    }

    /// Force-close at end of line — a run reaching the trailing edge.
    fn flush(self: *DecorationRun) bool {
        const was_active = self.active;
        self.active = false;
        return was_active;
    }
};

/// Place one line's worth of shaped atoms at the resolved baseline.
/// First pass: max(ascender) + max(line_height) across the line —
/// Makepad-style row finish that gives mixed-size content a shared
/// baseline. Second pass: stream each atom's glyphs through
/// `appendShapedRun`. Returns the line's metrics so the caller can
/// advance its `y`.
fn emitLine(
    line_tokens: []const InlineToken,
    pen_x: f32,
    y: f32,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !LineMetrics {
    if (line_tokens.len == 0) {
        // Empty line (back-to-back line_breaks). Use a sensible
        // default so y still advances.
        const lh: f32 = if (ctx.fonts.entries.items.len > 0)
            ctx.fonts.metrics(0).line_height
        else
            16;
        return .{ .baseline = y, .line_height = lh };
    }

    var max_asc: f32 = 0;
    var max_lh: f32 = 0;
    for (line_tokens) |tok| {
        const asc = tokenAscender(tok);
        const lh = tokenLineHeight(tok);
        if (asc > max_asc) max_asc = asc;
        if (lh > max_lh) max_lh = lh;
    }
    const baseline_y = y + max_asc;

    // Three decoration trackers: underline (markdown link OR ANSI
    // SGR 4), strikethrough (ANSI SGR 9), and run background (ANSI
    // SGR 7 reverse; future stage hooks ANSI bg-set codes through
    // the same field). Each closes into one quad per contiguous run;
    // a span wrapping across a line break naturally gets one quad
    // per line because emitLine runs once per line.
    //
    // Emit order on close: bg first (broadest, lowest layer), then
    // underline + strikethrough on top. Glyphs draw last via the
    // text pipeline, so per-quad submission order only ranks the
    // chrome relative to itself.
    var underline_run = DecorationRun{};
    var strike_run = DecorationRun{};
    var bg_run = DecorationRun{};
    var x = pen_x;
    const line_top = baseline_y - max_asc;

    for (line_tokens) |tok| {
        // ── Inline objects: close decorations + dispatch + advance ──
        // An inline component is a hard break in any open decoration
        // run — a link underline doesn't visually extend across a
        // badge, an ANSI reverse-video span doesn't paint behind it.
        // Force-close the trackers at the object's start x, paint the
        // object, and resume after it with empty runs.
        if (tok == .object) {
            const obj = tok.object;
            if (bg_run.flush()) {
                try emitBgQuad(out, ctx, bg_run.start_x, x, line_top, max_lh, bg_run.color);
            }
            if (underline_run.flush()) {
                try emitUnderline(out, ctx, ctx.theme, underline_run.start_x, x, baseline_y, underline_run.max_px, underline_run.color);
            }
            if (strike_run.flush()) {
                try emitStrikethrough(out, ctx, ctx.theme, strike_run.start_x, x, baseline_y, strike_run.max_px, strike_run.color);
            }

            try emitInlineObject(obj, x, baseline_y, max_asc, max_lh, line_top, ctx, out);
            x += obj.width;
            continue;
        }

        const atom = tokenAtom(tok) orelse continue;
        const px = ctx.fonts.displayPx(atom.style.font_id);

        if (bg_run.step(
            atom.style.bg != null,
            x,
            px,
            atom.style.bg orelse .{ 0, 0, 0, 0 },
        )) {
            try emitBgQuad(out, ctx, bg_run.start_x, x, line_top, max_lh, bg_run.color);
        }
        if (underline_run.step(
            atom.style.link or atom.style.underline,
            x,
            px,
            atom.style.color,
        )) {
            try emitUnderline(
                out,
                ctx,
                ctx.theme,
                underline_run.start_x,
                x,
                baseline_y,
                underline_run.max_px,
                underline_run.color,
            );
        }
        if (strike_run.step(
            atom.style.strikethrough,
            x,
            px,
            atom.style.color,
        )) {
            try emitStrikethrough(
                out,
                ctx,
                ctx.theme,
                strike_run.start_x,
                x,
                baseline_y,
                strike_run.max_px,
                strike_run.color,
            );
        }

        x = try text_layout.appendShapedRun(
            &out.glyphs,
        &out.glyph_targets,
        ctx.current_target_dispatch_index,
            ctx.fonts,
            ctx.cache,
            ctx.mono_atlas,
            ctx.color_atlas,
            ctx.glyph_cache_lock,
            atom.run,
            atom.style.font_id,
            x,
            baseline_y,
            atom.style.color,
            atom.style.hot_color,
            atom.style.attention,
            ctx.zoom,
        );
    }

    // Trailing flushes — runs reaching the line's trailing edge.
    // Same order as the in-loop emits: bg first, then decorations.
    if (bg_run.flush()) {
        try emitBgQuad(out, ctx, bg_run.start_x, x, line_top, max_lh, bg_run.color);
    }
    if (underline_run.flush()) {
        try emitUnderline(
            out,
            ctx,
            ctx.theme,
            underline_run.start_x,
            x,
            baseline_y,
            underline_run.max_px,
            underline_run.color,
        );
    }
    if (strike_run.flush()) {
        try emitStrikethrough(
            out,
            ctx,
            ctx.theme,
            strike_run.start_x,
            x,
            baseline_y,
            strike_run.max_px,
            strike_run.color,
        );
    }

    return .{ .baseline = baseline_y, .line_height = max_lh };
}

/// Emit one underline quad spanning `[x0, x1]` at the given baseline.
/// Thickness + offset derive from the run's dominant `displayPx`
/// scaled by `theme.link_underline_*_em` so the underline auto-sizes
/// with the run's font. Thickness clamped to >= 1px so it never
/// disappears even at tiny sizes.
fn emitUnderline(
    out: *element.DrawList,
    lc: *const element.LayoutCtx,
    theme: *const element.Theme,
    x0: f32,
    x1: f32,
    baseline_y: f32,
    run_px: u32,
    color: [4]f32,
) !void {
    if (x1 <= x0) return;
    const px_f: f32 = @floatFromInt(run_px);
    const thickness = @max(1.0, px_f * theme.link_underline_thickness_em);
    const offset = px_f * theme.link_underline_offset_em;
    try out.appendQuad(lc, .{
        .dst_pos = .{ x0, baseline_y + offset },
        .dst_size = .{ x1 - x0, thickness },
        .color = color,
        .radius = 0,
    });
}

/// Emit one strikethrough quad spanning `[x0, x1]` at the given
/// baseline. Sits *above* baseline at `theme.strikethrough_offset_em`
/// (typically ~26% of em → through the middle of x-height); thickness
/// clamped to >= 1px.
fn emitStrikethrough(
    out: *element.DrawList,
    lc: *const element.LayoutCtx,
    theme: *const element.Theme,
    x0: f32,
    x1: f32,
    baseline_y: f32,
    run_px: u32,
    color: [4]f32,
) !void {
    if (x1 <= x0) return;
    const px_f: f32 = @floatFromInt(run_px);
    const thickness = @max(1.0, px_f * theme.strikethrough_thickness_em);
    const offset = px_f * theme.strikethrough_offset_em;
    try out.appendQuad(lc, .{
        .dst_pos = .{ x0, baseline_y - offset },
        .dst_size = .{ x1 - x0, thickness },
        .color = color,
        .radius = 0,
    });
}

/// Emit one background quad spanning `[x0, x1]` × the line's
/// vertical extent. Used by ANSI reverse-video runs (and future
/// ANSI bg-set codes) — colour comes from the run's `style.bg`.
/// Drawn first in submission order so underline + strikethrough +
/// glyphs layer on top.
fn emitBgQuad(
    out: *element.DrawList,
    lc: *const element.LayoutCtx,
    x0: f32,
    x1: f32,
    line_top: f32,
    line_height: f32,
    color: [4]f32,
) !void {
    if (x1 <= x0) return;
    try out.appendQuad(lc, .{
        .dst_pos = .{ x0, line_top },
        .dst_size = .{ x1 - x0, line_height },
        .color = color,
        .radius = 0,
    });
}

/// Paint one inline component at the resolved line position.
/// Translates the four `InlineAlign` modes into a concrete top-y for
/// the component's bbox, hands the vtable an origin pinned to that
/// position, and registers a Hit if the component accepts input.
/// Width is the caller's responsibility — `emitLine` advances `x` by
/// the measured `obj.width` after this returns, ignoring the Box the
/// vtable hands back. (Trust the measure-pass intent; the Box exists
/// so future block-level retained-mode plumbing has a return slot.)
fn emitInlineObject(
    obj: ObjectAtom,
    pen_x: f32,
    baseline_y: f32,
    max_asc: f32,
    max_lh: f32,
    line_top: f32,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !void {
    const obj_h = obj.ascender + obj.descender;
    const origin_y: f32 = switch (obj.valign) {
        // Component's ascender lands on the resolved line baseline —
        // the standard "share a baseline with surrounding text" case.
        .baseline => baseline_y - obj.ascender,
        // Component is vertically centred against the line's full
        // box. Matches CSS `vertical-align: middle` closely enough
        // for the cases we care about (sparklines, icons).
        .middle => line_top + (max_lh - obj_h) * 0.5,
        // Component hangs from the line's cap line.
        .top => baseline_y - max_asc,
        // Component sits on the line's bottom edge.
        .bottom => line_top + max_lh - obj_h,
    };
    const origin: [2]f32 = .{ pen_x, origin_y };

    // Tight constraints — the component already declared its intrinsic
    // size via measure_inline. Passing the same width back as max_w
    // keeps any defensive max-clamping inside the component honest;
    // max_h is the component's own height for the same reason.
    const constraints: element.Constraints = .{
        .min_w = 0,
        .max_w = obj.width,
        .min_h = 0,
        .max_h = obj_h,
    };

    const box = try obj.vtable.layout_and_render(obj.ctx, origin, constraints, ctx, out);

    // Register on the hit-test layer if the component accepts input —
    // mirrors the block-level `.custom` path. Stamped with the current
    // walker `state` so input dispatch routes to the right scope.
    if (obj.vtable.on_input != null) {
        try out.hits.append(.{
            .box = box,
            .vtable = obj.vtable,
            .ctx = obj.ctx,
            .state = ctx.state,
            .focusable = obj.vtable.focusable,
        });
    }
}
