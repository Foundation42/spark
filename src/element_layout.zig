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

// ── Stage-2a layout constants ──────────────────────────────────────
// Hardcoded indents and gaps used by block kinds that don't carry
// their own. These move into a `Theme` struct in LayoutCtx during
// stage 2c — they're walker-baked for now so we can ship nesting
// without inventing the theme abstraction yet.

/// Horizontal offset from the list's left edge to where the marker
/// glyph starts.
const LIST_MARKER_INDENT: f32 = 8;
/// Horizontal offset from the list's left edge to where item content
/// starts. The marker sits in the gap between this and
/// `LIST_MARKER_INDENT`.
const LIST_CONTENT_INDENT: f32 = 32;
/// Vertical space between adjacent list items.
const LIST_ITEM_GAP: f32 = 2;
/// Horizontal indent applied to block-quote children.
const QUOTE_INDENT: f32 = 20;
/// Vertical space between siblings inside a list_item / quote when
/// they don't already have margins of their own.
const BLOCK_CHILD_GAP: f32 = 4;

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
        .text, .line_break => return error.InlineElementOutsideInlineContext,

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

        .list => |li| return layoutList(li, origin, constraints, ctx, out),

        .list_item => |it| return layoutStackV(it.children, BLOCK_CHILD_GAP, origin, constraints, ctx, out),

        .quote => |q| return layoutQuote(q.children, origin, constraints, ctx, out),

        .code_block => |cb| return layoutCodeBlock(cb.content, origin, constraints, ctx, out),

        .custom => |cu| return cu.vtable.layout_and_render(
            cu.ctx,
            origin,
            constraints,
            ctx,
            out,
        ),
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

/// Block quote — indent children horizontally, recurse as stack_v.
/// Left-bar visual is deferred until quad/line primitives land.
fn layoutQuote(
    children: []const element.Element,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    const inner_origin: [2]f32 = .{ origin[0] + QUOTE_INDENT, origin[1] };
    const inner_constraints = shrinkConstraints(constraints, QUOTE_INDENT);
    const inner_box = try layoutStackV(children, BLOCK_CHILD_GAP, inner_origin, inner_constraints, ctx, out);
    return .{
        .x = origin[0],
        .y = origin[1],
        .w = inner_box.w + QUOTE_INDENT,
        .h = inner_box.h,
        .baseline = 0,
    };
}

/// List — iterate items, render a marker (• for unordered, "N." for
/// ordered) at `LIST_MARKER_INDENT`, then recurse each item's content
/// at `LIST_CONTENT_INDENT`. Marker baseline alignment with the first
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
    const inner_constraints = shrinkConstraints(constraints, LIST_CONTENT_INDENT);

    for (li.items, 0..) |item, i| {
        if (i != 0) y += LIST_ITEM_GAP;

        // ── Marker ─────────────────────────────────────────────────
        // Compose a tiny inline-flow on the fly: one text run with the
        // marker glyph(s). Stack buffer for ordered-list digits.
        var marker_buf: [16]u8 = undefined;
        const marker_text = if (li.ordered) blk: {
            break :blk std.fmt.bufPrint(&marker_buf, "{d}.", .{index}) catch "•";
        } else "•";

        const marker_children = [_]element.Element{
            .{ .text = .{ .content = marker_text, .style = li.marker_style } },
        };
        const marker_paragraph = element.Element{ .paragraph = &marker_children };
        // Marker's glyphs land in the draw list; its returned Box.h
        // is discarded because the item's content advances `y` for
        // us (marker and content share the first line — see comment
        // above).
        _ = try layoutAndRender(
            marker_paragraph,
            .{ origin[0] + LIST_MARKER_INDENT, y },
            constraints,
            ctx,
            out,
        );

        // ── Item content ───────────────────────────────────────────
        const item_box = try layoutAndRender(
            item,
            .{ origin[0] + LIST_CONTENT_INDENT, y },
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

/// Preformatted code block. Splits `raw.text` on '\n' and lays each
/// line out as its own paragraph in the supplied style. No wrap, no
/// whitespace collapsing — what's in `text` is what renders.
/// `.sub_block` is the composability hook for the ANSI engine and is
/// not handled until that engine lands.
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
            var y = origin[1];
            var it = std.mem.splitScalar(u8, r.text, '\n');
            while (it.next()) |line| {
                const children = [_]element.Element{
                    .{ .text = .{ .content = line, .style = r.style } },
                };
                const para = element.Element{ .paragraph = &children };
                const box = try layoutAndRender(para, .{ origin[0], y }, constraints, ctx, out);
                y += box.h;
            }
            return .{
                .x = origin[0],
                .y = origin[1],
                .w = 0,
                .h = y - origin[1],
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
    var y = origin[1];
    var max_w: f32 = 0;
    for (children, 0..) |child, i| {
        if (i != 0) y += gap;
        const child_box = try layoutAndRender(
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

/// Lay out a flat list of inline elements as one or more lines of
/// text. `text` runs accumulate into the current line; `line_break`
/// flushes the current line and starts a new one. Anything else is
/// out of place — stage 1's inline vocabulary is just text + breaks.
///
/// Per-line work mirrors Makepad's `Turtle.finish_row`: first scan
/// the line's runs for `max(ascender)` + `max(line_height)`, then
/// place glyphs against that resolved baseline. This is what makes
/// mixed-size runs in one line ("body **and 28-px accent** inline")
/// land cleanly.
fn layoutInlineFlow(
    children: []const element.Element,
    origin: [2]f32,
    constraints: element.Constraints,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    _ = constraints; // wrap-policy hook: future Phase B work
    var y = origin[1];

    // Accumulator for the current line's text runs. Cleared on each
    // line_break flush.
    var current_line = std.ArrayList(text_layout.Span).init(ctx.allocator);
    defer current_line.deinit();

    var last_baseline: f32 = 0;

    for (children) |child| {
        switch (child) {
            .text => |t| try current_line.append(.{
                .text = t.content,
                .style = .{
                    .font_id = t.style.font_id,
                    .color = t.style.color,
                    .hot_color = t.style.hot_color,
                    .attention = t.style.attention,
                },
            }),
            .line_break => {
                const flushed = try flushLine(current_line.items, origin[0], y, ctx, out);
                y += flushed.line_height;
                last_baseline = flushed.baseline;
                current_line.clearRetainingCapacity();
            },
            // Anything else is out of place inside an inline flow.
            // Block elements nesting inside a paragraph is a parser
            // error in markdown ("can't have a list inside a single
            // paragraph"); strict here lets us catch malformed trees
            // before they cause subtle layout glitches.
            else => return error.InlineElementOutsideInlineContext,
        }
    }

    // Flush trailing line (the common case — most paragraphs end
    // without an explicit hard break).
    if (current_line.items.len > 0) {
        const flushed = try flushLine(current_line.items, origin[0], y, ctx, out);
        y += flushed.line_height;
        last_baseline = flushed.baseline;
    } else if (children.len == 0) {
        // Empty inline flow (a `paragraph { children: &.{} }`) takes
        // one default line of height. Picks up the first font's
        // line_height; falls back to 16 if no fonts are loaded yet.
        const lh: f32 = if (ctx.fonts.entries.items.len > 0)
            ctx.fonts.metrics(0).line_height
        else
            16;
        y += lh;
    }

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = 0, // we don't measure width yet — wrapping comes later
        .h = y - origin[1],
        .baseline = last_baseline,
    };
}

const LineMetrics = struct {
    baseline: f32,
    line_height: f32,
};

/// Place one line's spans at the resolved baseline, return its
/// height-advance for the caller to bump `y` by.
fn flushLine(
    spans: []const text_layout.Span,
    pen_x: f32,
    y: f32,
    ctx: *element.LayoutCtx,
    out: *element.DrawList,
) !LineMetrics {
    // First pass: deepest ascender + tallest line_height across the
    // line. This is what tucks the tallest glyph inside the line box
    // and gives mixed-size runs a shared baseline.
    var max_asc: f32 = 0;
    var max_lh: f32 = 0;
    for (spans) |s| {
        const m = ctx.fonts.metrics(s.style.font_id);
        if (m.ascender > max_asc) max_asc = m.ascender;
        if (m.line_height > max_lh) max_lh = m.line_height;
    }
    const baseline_y = y + max_asc;

    // Second pass: shape + place. Reuses session 1's per-glyph
    // emission path (`appendShapedRun` inside `appendLineFromSpans`)
    // unchanged — that's the work the new walker delegates to.
    _ = try text_layout.appendLineFromSpans(
        &out.glyphs,
        ctx.allocator,
        ctx.fonts,
        ctx.cache,
        ctx.mono_atlas,
        ctx.color_atlas,
        spans,
        pen_x,
        baseline_y,
    );

    return .{ .baseline = baseline_y, .line_height = max_lh };
}
