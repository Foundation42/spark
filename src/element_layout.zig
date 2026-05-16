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

    const key = layout_cache.keyFor(elem, constraints, ctx.theme);
    const version = layout_cache.versionFor(elem);

    if (cache.lookup(key, version)) |entry| {
        return try layout_cache.blitEntry(out, entry, origin);
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

    const box = try layoutAndRender(elem, origin, constraints, ctx, out);

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
        origin,
        box,
    );
    return box;
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
        .text, .line_break, .emphasis, .strong, .code, .link => return error.InlineElementOutsideInlineContext,

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
            return box;
        },
    }
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
    try out.quads.append(.{
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

    try out.quads.append(.{
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
        .sub_block => return error.CodeBlockSubBlockNotImplemented,
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
            try out.quads.append(.{
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
    for (children, 0..) |child, i| {
        if (i != 0) y += gap;
        const child_box = try layoutAndRenderCached(
            child,
            .{ origin[0], y },
            constraints,
            ctx,
            out,
        );
        if (child_box.w > max_w) max_w = child_box.w;
        y += child_box.h;
    }
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = max_w,
        .h = y - origin[1],
        .baseline = 0,
    };
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
    const cache = ctx.cache_blocks.?;
    const js = ctx.job_system.?;
    const a = ctx.allocator;

    // Phase 1 — classify every child. No private-DrawList allocations
    // yet — we may bail out below if there aren't enough walks.
    const classifications = try a.alloc(ChildClass, children.len);
    defer a.free(classifications);

    // Count *snapshot-eligible* walks toward the dispatch threshold.
    // Walks of `disable_cache = true` children (sliders / inputs /
    // embedded-doc) happen every layout regardless of state change —
    // counting them would dispatch every frame even when nothing
    // content-relevant changed, and the worker would lose inner
    // cache hits (workers run with `cache_blocks = null` to keep the
    // block cache single-threaded). Only "real" cache misses justify
    // the dispatch.
    var snapshot_walks: usize = 0;
    for (children, 0..) |child, i| {
        classifications[i] = classifyChild(child, constraints, ctx, cache);
        if (classifications[i] == .walk_with_snapshot) snapshot_walks += 1;
    }

    if (snapshot_walks < PARALLEL_MIN_WALKS) return null;

    // Phase 2 — allocate private DrawLists for every walk slot. These
    // are released after the merge, regardless of success/failure.
    for (classifications) |*cls| {
        switch (cls.*) {
            .cache_hit => {},
            .walk_with_snapshot => |*s| {
                s.private_dl = try a.create(element.DrawList);
                s.private_dl.?.* = element.DrawList.init(std.heap.c_allocator);
            },
            .walk_no_cache => |*s| {
                s.private_dl = try a.create(element.DrawList);
                s.private_dl.?.* = element.DrawList.init(std.heap.c_allocator);
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
                const box = try layout_cache.blitEntry(out, entry, child_origin);
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
                try blitPrivate(out, spec.private_dl.?, child_origin);
                if (spec.cache_key) |key| {
                    try snapshotFromPrivate(cache, key, spec.version, spec.private_dl.?, spec.box);
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
                try blitPrivate(out, spec.private_dl.?, child_origin);
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
            const key = layout_cache.keyFor(elem, constraints, ctx.theme);
            const version = layout_cache.versionFor(elem);
            if (cache.lookup(key, version)) |entry| {
                return .{ .cache_hit = entry };
            }
            return .{ .walk_with_snapshot = .{
                .cache_key = key,
                .version = version,
            } };
        }
    }
    cache.skipped += 1;
    return .{ .walk_no_cache = .{} };
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
fn blitPrivate(out: *element.DrawList, src: *const element.DrawList, origin: [2]f32) !void {
    const ox = origin[0];
    const oy = origin[1];

    const g_start = out.glyphs.items.len;
    try out.glyphs.appendSlice(src.glyphs.items);
    for (out.glyphs.items[g_start..]) |*g| {
        g.dst_pos[0] += ox;
        g.dst_pos[1] += oy;
    }

    const q_start = out.quads.items.len;
    try out.quads.appendSlice(src.quads.items);
    for (out.quads.items[q_start..]) |*q| {
        q.dst_pos[0] += ox;
        q.dst_pos[1] += oy;
    }

    const tri_vertex_base: u32 = @intCast(out.tris.items.len);
    try out.tris.appendSlice(src.tris.items);
    for (out.tris.items[tri_vertex_base..]) |*v| {
        v.pos[0] += ox;
        v.pos[1] += oy;
    }
    const ti_start = out.tri_indices.items.len;
    try out.tri_indices.appendSlice(src.tri_indices.items);
    for (out.tri_indices.items[ti_start..]) |*idx| idx.* += tri_vertex_base;

    for (src.images.items) |im| {
        var im2 = im;
        im2.dst_pos[0] += ox;
        im2.dst_pos[1] += oy;
        try out.images.append(im2);
    }

    for (src.hits.items) |h| {
        var h2 = h;
        h2.box.x += ox;
        h2.box.y += oy;
        try out.hits.append(h2);
    }
}

/// Copy a private DrawList's contents into a new cache Entry (block-
/// local coords — no translation needed because the worker already
/// walked at origin (0,0)).
fn snapshotFromPrivate(
    cache: *layout_cache.BlockCache,
    key: layout_cache.Key,
    version: u64,
    src: *const element.DrawList,
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

    try cache.insert(key, .{
        .version = version,
        .glyphs = glyphs,
        .quads = quads,
        .tris = tris,
        .tri_indices = tri_indices,
        .images = images,
        .hits = hits,
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
    const max_x = origin[0] + constraints.max_w;
    var y = origin[1];

    // `line_start` is the first token index of the current line;
    // `pen_x` is the running pixel cursor on it.
    var line_start: usize = 0;
    var pen_x: f32 = origin[0];
    var last_baseline: f32 = 0;
    var i: usize = 0;

    while (i < tokens.items.len) : (i += 1) {
        const tok = tokens.items[i];

        // Forced break — flush current line (without including the
        // break itself), advance past it.
        if (isLineBreak(tok)) {
            const lm = try emitLine(tokens.items[line_start..i], origin[0], y, ctx, out);
            y += lm.line_height;
            last_baseline = lm.baseline;
            line_start = i + 1;
            pen_x = origin[0];
            continue;
        }

        const width = tokenWidth(tok);

        // Wrap check: only wrap *before a word*, not before a gap —
        // gaps are clean break points themselves and shouldn't push
        // wrap decisions. Don't wrap if the line has no content yet
        // (otherwise an oversized first word would loop forever).
        if (isWord(tok) and line_start < i and pen_x + width > max_x) {
            // Find the line's emit end: strip any trailing gaps so
            // wrapped lines don't render a hanging space character.
            var emit_end = i;
            while (emit_end > line_start and isGap(tokens.items[emit_end - 1])) : (emit_end -= 1) {}

            const lm = try emitLine(tokens.items[line_start..emit_end], origin[0], y, ctx, out);
            y += lm.line_height;
            last_baseline = lm.baseline;

            // Skip any gap tokens between `emit_end` and `i` — those
            // are the whitespace that "lived in" the wrap point and
            // shouldn't render on either side of the break.
            line_start = i;
            pen_x = origin[0];
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
            const lm = try emitLine(tokens.items[line_start..emit_end], origin[0], y, ctx, out);
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

const InlineToken = union(enum) {
    word: ShapedAtom,
    gap: ShapedAtom,
    line_break,
};

fn isWord(t: InlineToken) bool {
    return switch (t) {
        .word => true,
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
        .line_break => 0,
    };
}
fn tokenAtom(t: InlineToken) ?ShapedAtom {
    return switch (t) {
        .word => |w| w,
        .gap => |g| g,
        .line_break => null,
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
        const atom = tokenAtom(tok) orelse continue;
        if (atom.ascender > max_asc) max_asc = atom.ascender;
        if (atom.line_height > max_lh) max_lh = atom.line_height;
    }
    const baseline_y = y + max_asc;

    // Underline-run tracker. Each link in the source produces atoms
    // with `style.link == true`; we track contiguous runs on this
    // line and emit one underline quad per run after we know its
    // x-extent. A link wrapping across a line break naturally gets
    // one quad per line because emit_line runs once per line.
    //
    // `run_max_px` is the dominant displayPx in the current run, so
    // the underline thickness/offset scale to the largest font in
    // the link span (mixed-size links are rare but possible — heading
    // links, link-around-a-strong, etc).
    var x = pen_x;
    var run_start_x: ?f32 = null;
    var run_max_px: u32 = 0;
    var run_color: [4]f32 = .{ 0, 0, 0, 0 };

    for (line_tokens) |tok| {
        const atom = tokenAtom(tok) orelse continue;

        if (atom.style.link) {
            if (run_start_x == null) {
                run_start_x = x;
                run_max_px = ctx.fonts.displayPx(atom.style.font_id);
                run_color = atom.style.color;
            } else {
                const px = ctx.fonts.displayPx(atom.style.font_id);
                if (px > run_max_px) run_max_px = px;
            }
        } else if (run_start_x) |start_x| {
            try emitUnderline(out, ctx.theme, start_x, x, baseline_y, run_max_px, run_color);
            run_start_x = null;
        }

        x = try text_layout.appendShapedRun(
            &out.glyphs,
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
        );
    }

    // Trailing run — a link that reaches the end of the line.
    if (run_start_x) |start_x| {
        try emitUnderline(out, ctx.theme, start_x, x, baseline_y, run_max_px, run_color);
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
    try out.quads.append(.{
        .dst_pos = .{ x0, baseline_y + offset },
        .dst_size = .{ x1 - x0, thickness },
        .color = color,
        .radius = 0,
    });
}
