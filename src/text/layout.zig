//! Layout: turn styled text (paragraphs of lines of spans) into
//! GPU-ready `GlyphInstance` records, going through HarfBuzz for
//! shaping and the `GlyphCache` for atlas placement.
//!
//! Three layers, lowest to highest:
//!
//!   1. `appendShapedRun` — given an already-shaped HarfBuzz run +
//!      a font id + a baseline, place each glyph against the atlas
//!      cache. Knows nothing about spans.
//!   2. `appendLineFromSpans` — given a slice of `Span`s and a
//!      baseline, shape each span in turn and append. Spans flow
//!      left-to-right on one line; the pen carries between them so
//!      multi-style text shares one baseline.
//!   3. `layoutParagraph` — given a `Paragraph` (lines × spans),
//!      resolve each line's baseline from `max(ascender)` over the
//!      fonts used on it before placing glyphs, then advance
//!      vertically by `max(line_height)`. Row-level baseline
//!      resolution is the trick lifted from Makepad's turtle (see
//!      [[reference-makepad-layout]]) — it's what makes inline
//!      mixed-size content like "Mix **sizes** inline" land cleanly.
//!
//! Output goes into a caller-owned `ArrayList(GlyphInstance)` so the
//! aggregating caller controls one allocation across many layout
//! passes — no intermediate slice churn.
//!
//! Coordinates: framebuffer-style (origin top-left, Y down). FT
//! `bearing_y` is positive ABOVE the baseline, so a glyph's top
//! lives at `baseline_y - bearing_y`. `dst_pos` rounds to integer
//! pixels so the hinted-grayscale coverage stays sharp.

const std = @import("std");
const shape = @import("../font/shape.zig");
const registry_mod = @import("../font/registry.zig");
const atlas_mod = @import("../gpu/atlas.zig");
const tp = @import("../gpu/text_pipeline.zig");
const glyph_cache_mod = @import("glyph_cache.zig");

pub const Style = struct {
    font_id: registry_mod.FontId,
    color: [4]f32,
};

pub const Span = struct {
    text: []const u8,
    style: Style,
};

pub const Line = struct {
    spans: []const Span,
};

pub const Paragraph = struct {
    lines: []const Line,
};

/// Append glyphs for an already-shaped run, looking each glyph up
/// in the cache (rasterising + packing on miss). Returns the pen X
/// after the run for callers that want to chain runs on one line.
pub fn appendShapedRun(
    out: *std.ArrayList(tp.GlyphInstance),
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    atlas: *atlas_mod.Atlas,
    run: shape.ShapedRun,
    font_id: registry_mod.FontId,
    pen_x: f32,
    baseline_y: f32,
    color: [4]f32,
) !f32 {
    var x = pen_x;
    const aw: f32 = @floatFromInt(atlas.extent.width);
    const ah: f32 = @floatFromInt(atlas.extent.height);

    for (run.glyphs) |g| {
        const entry = try cache.getOrRasterize(fonts, atlas, font_id, g.glyph_id);
        if (entry.rect.w != 0 and entry.rect.h != 0) {
            const dx = @round(x + @as(f32, @floatFromInt(entry.bearing_x)) + g.x_offset);
            const dy = @round(baseline_y - @as(f32, @floatFromInt(entry.bearing_y)) + g.y_offset);
            try out.append(.{
                .dst_pos = .{ dx, dy },
                .dst_size = .{ @floatFromInt(entry.rect.w), @floatFromInt(entry.rect.h) },
                .uv_min = .{
                    @as(f32, @floatFromInt(entry.rect.x)) / aw,
                    @as(f32, @floatFromInt(entry.rect.y)) / ah,
                },
                .uv_max = .{
                    @as(f32, @floatFromInt(entry.rect.x + entry.rect.w)) / aw,
                    @as(f32, @floatFromInt(entry.rect.y + entry.rect.h)) / ah,
                },
                .color = color,
            });
        }
        x += g.x_advance;
    }
    return x;
}

/// Shape + append a series of spans on one line. Spans flow with the
/// pen — each carries its own style (font + colour) but they share
/// a baseline supplied by the caller.
pub fn appendLineFromSpans(
    out: *std.ArrayList(tp.GlyphInstance),
    allocator: std.mem.Allocator,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    atlas: *atlas_mod.Atlas,
    spans: []const Span,
    pen_x: f32,
    baseline_y: f32,
) !f32 {
    var x = pen_x;
    for (spans) |span| {
        const hb = fonts.hbFont(span.style.font_id);
        var run = try shape.shapeUtf8(allocator, hb, span.text);
        defer run.deinit();
        x = try appendShapedRun(
            out,
            fonts,
            cache,
            atlas,
            run,
            span.style.font_id,
            x,
            baseline_y,
            span.style.color,
        );
    }
    return x;
}

/// Lay out a full paragraph starting at `(pen_x, start_y)`. For each
/// line, do a first metrics-pass over its spans to pick a baseline
/// (the deepest ascender wins, so the tallest glyph fits inside the
/// line box), then a second pass that shapes + places glyphs against
/// that baseline. Advances `y` by the line's `max(line_height)`
/// between lines.
///
/// Returns the final `y` so callers can chain paragraphs vertically
/// or compute total paragraph height for hit-test bounds.
pub fn layoutParagraph(
    out: *std.ArrayList(tp.GlyphInstance),
    allocator: std.mem.Allocator,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    atlas: *atlas_mod.Atlas,
    paragraph: Paragraph,
    pen_x: f32,
    start_y: f32,
) !f32 {
    var y = start_y;
    for (paragraph.lines) |line| {
        if (line.spans.len == 0) {
            // Caller wants vertical whitespace — advance by a single
            // body-ish line height. We don't have a "this is body"
            // signal so just pick the first registered font's
            // line_height as a stand-in. Empty-line behaviour will
            // get a proper API when we have a real text-document
            // model.
            y += if (fonts.entries.items.len > 0) fonts.metrics(0).line_height else 16;
            continue;
        }

        // First pass: gather metrics from every font used on the
        // line. The line's baseline drops by `max(ascender)` so the
        // tallest glyph fits above it; vertical advance for the
        // next line is `max(line_height)`.
        var max_asc: f32 = 0;
        var max_lh: f32 = 0;
        for (line.spans) |s| {
            const m = fonts.metrics(s.style.font_id);
            if (m.ascender > max_asc) max_asc = m.ascender;
            if (m.line_height > max_lh) max_lh = m.line_height;
        }

        const baseline_y = y + max_asc;
        _ = try appendLineFromSpans(out, allocator, fonts, cache, atlas, line.spans, pen_x, baseline_y);
        y += max_lh;
    }
    return y;
}
