//! Layout: turn styled text (paragraphs of lines of spans) into
//! GPU-ready `GlyphInstance` records, going through HarfBuzz for
//! shaping and the `GlyphCache` for atlas placement.
//!
//! Three layers, lowest to highest:
//!
//!   1. `appendShapedRun` — given an already-shaped HarfBuzz run +
//!      a font id + a baseline, place each glyph against the
//!      appropriate atlas. Knows nothing about spans.
//!   2. `appendLineFromSpans` — given a slice of `Span`s and a
//!      baseline, shape each span in turn and append. Spans flow
//!      left-to-right on one line; the pen carries between them so
//!      multi-style text shares one baseline.
//!   3. `layoutParagraph` — given a `Paragraph` (lines × spans),
//!      resolve each line's baseline from `max(ascender)` over the
//!      fonts used on it before placing glyphs, then advance
//!      vertically by `max(line_height)`. Row-level baseline
//!      resolution is lifted from Makepad's turtle (see
//!      [[reference-makepad-layout]]) — it's what makes inline
//!      mixed-size content like "Mix **sizes** inline" land cleanly.
//!
//! Phase 5 splits the atlas in two: `mono_atlas` (R8, hinted
//! grayscale) and `color_atlas` (RGBA8, premultiplied colour
//! bitmaps from CBDT/sbix/COLRv1 fonts). The cache routes glyphs
//! to whichever based on FT's pixel mode; the layout pass picks
//! UVs from the matching atlas and tags each `GlyphInstance` with
//! a `tex_select` so the fragment shader knows which sampler to
//! read from.
//!
//! Per-font `scale` from `FontRegistry` is applied at layout time
//! to every FT-pixel quantity (bearings, HB advances, atlas rect
//! sizes). For scalable mono fonts the scale is 1; for strike-only
//! colour emoji it's `< 1` so emoji shrink to inline with body.

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
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    run: shape.ShapedRun,
    font_id: registry_mod.FontId,
    pen_x: f32,
    baseline_y: f32,
    color: [4]f32,
) !f32 {
    var x = pen_x;
    const fscale = fonts.scale(font_id);
    const mono_w: f32 = @floatFromInt(mono_atlas.extent.width);
    const mono_h: f32 = @floatFromInt(mono_atlas.extent.height);
    const color_w: f32 = @floatFromInt(color_atlas.extent.width);
    const color_h: f32 = @floatFromInt(color_atlas.extent.height);

    for (run.glyphs) |g| {
        const entry = try cache.getOrRasterize(fonts, mono_atlas, color_atlas, font_id, g.glyph_id);
        if (entry.rect.w != 0 and entry.rect.h != 0) {
            const bx: f32 = @floatFromInt(entry.bearing_x);
            const by: f32 = @floatFromInt(entry.bearing_y);
            const rw: f32 = @floatFromInt(entry.rect.w);
            const rh: f32 = @floatFromInt(entry.rect.h);

            // All FT-pixel quantities scale by `fscale` to land in
            // display units; `pen_x` and `baseline_y` are already
            // display units coming in from the caller.
            const dx = @round(x + (bx + g.x_offset) * fscale);
            const dy = @round(baseline_y - (by - g.y_offset) * fscale);

            const aw: f32 = if (entry.kind == .color) color_w else mono_w;
            const ah: f32 = if (entry.kind == .color) color_h else mono_h;

            try out.append(.{
                .dst_pos = .{ dx, dy },
                .dst_size = .{ rw * fscale, rh * fscale },
                .uv_min = .{
                    @as(f32, @floatFromInt(entry.rect.x)) / aw,
                    @as(f32, @floatFromInt(entry.rect.y)) / ah,
                },
                .uv_max = .{
                    @as(f32, @floatFromInt(entry.rect.x + entry.rect.w)) / aw,
                    @as(f32, @floatFromInt(entry.rect.y + entry.rect.h)) / ah,
                },
                .color = color,
                .tex_select = @intFromEnum(entry.kind),
                ._pad = .{ 0, 0, 0 },
            });
        }
        x += g.x_advance * fscale;
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
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
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
            mono_atlas,
            color_atlas,
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
pub fn layoutParagraph(
    out: *std.ArrayList(tp.GlyphInstance),
    allocator: std.mem.Allocator,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    paragraph: Paragraph,
    pen_x: f32,
    start_y: f32,
) !f32 {
    var y = start_y;
    for (paragraph.lines) |line| {
        if (line.spans.len == 0) {
            y += if (fonts.entries.items.len > 0) fonts.metrics(0).line_height else 16;
            continue;
        }

        var max_asc: f32 = 0;
        var max_lh: f32 = 0;
        for (line.spans) |s| {
            const m = fonts.metrics(s.style.font_id);
            if (m.ascender > max_asc) max_asc = m.ascender;
            if (m.line_height > max_lh) max_lh = m.line_height;
        }

        const baseline_y = y + max_asc;
        _ = try appendLineFromSpans(
            out,
            allocator,
            fonts,
            cache,
            mono_atlas,
            color_atlas,
            line.spans,
            pen_x,
            baseline_y,
        );
        y += max_lh;
    }
    return y;
}
