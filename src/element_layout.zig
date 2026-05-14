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
} || std.mem.Allocator.Error || error{ Overflow, SsboOverflow };

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

        .custom => |cu| return cu.vtable.layout_and_render(
            cu.ctx,
            origin,
            constraints,
            ctx,
            out,
        ),
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
