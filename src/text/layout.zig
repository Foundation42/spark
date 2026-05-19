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
const element = @import("../element.zig");

/// Canonical `Style` lives in `element.zig` as part of the public
/// element vocabulary; re-exported here so existing callers using
/// `layout.Style` (or the `.style = .{ ... }` duck-typed shape on
/// `Span`) keep compiling. New code should reach for `element.Style`
/// directly.
pub const Style = element.Style;

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
///
/// `glyph_cache_lock` (optional): when non-null, every
/// `cache.getOrRasterize` call is wrapped in the lock. The mutex
/// protects (a) the FT shared glyph slot used during glyph rendering,
/// (b) the GlyphCache hashmap, and (c) the Atlas packing/staging
/// buffer. Pass `null` for the serial path — no locking overhead.
/// Stage 14b's parallel stack_v walker hands the same mutex to every
/// worker thread.
pub fn appendShapedRun(
    out: *std.ArrayList(tp.GlyphInstance),
    /// Parallel target-routing array (effects-spec Phase B.4.a).
    /// Length-locked to `out` — every glyph append also appends
    /// `target_index` here, keeping the parallel-array invariant
    /// for downstream `Spark.endFrame` render-pass routing.
    out_targets: *std.ArrayList(u32),
    target_index: u32,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    glyph_cache_lock: ?*std.Thread.Mutex,
    run: shape.ShapedRun,
    font_id: registry_mod.FontId,
    pen_x: f32,
    baseline_y: f32,
    color: [4]f32,
    hot_color: [4]f32,
    attention: f32,
    /// Crisp-zoom: rasterise glyphs at `display_px × zoom` so the
    /// post-layout world→screen scale samples each bitmap at exactly
    /// 1:1. Defaults to 1.0 (no zoom) — when host passes its real
    /// zoom, layout output stays in world coords and the GPU pass
    /// scales bitmaps up by zoom for screen.
    zoom: f32,
) !f32 {
    var x = pen_x;
    // Pen advances/offsets stay in BASE-font units (the run was shaped
    // against the base hb_font). They scale to world by `base_scale`.
    const base_scale = fonts.scale(font_id);

    // Pick an effective entry sized for the current zoom. Mono fonts
    // get a fresh face at `target_px`; SDF entries keep their fixed
    // source size (the distance field is zoom-independent); strike-
    // only colour fonts (emoji) also stay at the original strike.
    //
    // `effectiveFontId` can grow `FontRegistry.entries` on its lazy-
    // create path → ArrayList realloc → the old `items` buffer is
    // freed. A parallel-walker worker reading `actualPx` immediately
    // after another worker triggered that realloc would dereference
    // freed memory → segfault. So we hold the cache lock across BOTH
    // the resolve and the metadata read (`actualPx`), keeping them
    // atomic from the perspective of any other worker's grow path.
    // The lock guards (FT slot + GlyphCache hashmap + Atlas packing
    // + FontRegistry mutations) — same surface, same lock.
    const base_display_px = fonts.displayPx(font_id);
    const target_px: u32 = @intFromFloat(@max(@as(f32, 1.0), @round(@as(f32, @floatFromInt(base_display_px)) * zoom)));
    const eff_id: registry_mod.FontId, const eff_actual_px: u32 = blk: {
        if (glyph_cache_lock) |m| {
            m.lock();
            defer m.unlock();
            const id = try fonts.effectiveFontId(font_id, target_px);
            break :blk .{ id, fonts.actualPx(id) };
        }
        const id = try fonts.effectiveFontId(font_id, target_px);
        break :blk .{ id, fonts.actualPx(id) };
    };

    // World-space scale for everything that comes out of the EFFECTIVE
    // entry's bitmap (bearings + rect dims). Defined so that
    // `bitmap × world_scale = world units that the post-layout zoom
    // multiply then takes to screen pixels`.
    //
    //   `world_scale = base.display_px / eff.actual_px`
    //
    // collapses to the right thing in every case:
    //
    //   * mono z=1: eff = base, eff.actual_px = base.display_px →
    //     world_scale = 1, identical to the pre-crisp-zoom path.
    //   * mono z=N: eff is a fresh face at target_px=base.display_px×N;
    //     eff.actual_px = target_px → world_scale = 1/N, so a 2× bitmap
    //     occupies the same WORLD footprint as the 1× bitmap; the
    //     post-layout `× N` then takes it to N× screen pixels (crisp).
    //   * SDF: eff = base (distance field is zoom-independent);
    //     eff.actual_px = 64 → world_scale = base.display_px / 64 =
    //     base.scale. Identical to the pre-crisp-zoom path at every
    //     zoom, so SDF text keeps its existing world dst_size and
    //     scales with the host's zoom multiply — correct behaviour.
    //   * emoji: eff.actual_px = strike size (e.g. 136) at every zoom
    //     → world_scale = base.display_px / 136 = base.scale. Emoji
    //     stays the same world size regardless of zoom; zoom multiply
    //     scales it on screen like the rest of the text.
    const eff_world_scale: f32 =
        @as(f32, @floatFromInt(base_display_px)) /
        @as(f32, @floatFromInt(eff_actual_px));

    const mono_w: f32 = @floatFromInt(mono_atlas.extent.width);
    const mono_h: f32 = @floatFromInt(mono_atlas.extent.height);
    const color_w: f32 = @floatFromInt(color_atlas.extent.width);
    const color_h: f32 = @floatFromInt(color_atlas.extent.height);

    for (run.glyphs) |g| {
        const entry = blk: {
            if (glyph_cache_lock) |m| {
                m.lock();
                defer m.unlock();
                break :blk try cache.getOrRasterize(fonts, mono_atlas, color_atlas, eff_id, g.glyph_id);
            }
            break :blk try cache.getOrRasterize(fonts, mono_atlas, color_atlas, eff_id, g.glyph_id);
        };
        if (entry.rect.w != 0 and entry.rect.h != 0) {
            const bx: f32 = @floatFromInt(entry.bearing_x);
            const by: f32 = @floatFromInt(entry.bearing_y);
            const rw: f32 = @floatFromInt(entry.rect.w);
            const rh: f32 = @floatFromInt(entry.rect.h);

            // Bearings & rect are in the EFFECTIVE entry's actual-px
            // units → use `eff_world_scale`. Per-glyph HB offsets stay
            // in BASE units → `base_scale`. At zoom=1 the two collapse
            // (same entry) and produce identical output to the
            // pre-crisp-zoom path.
            const dx = @round(x + bx * eff_world_scale + g.x_offset * base_scale);
            const dy = @round(baseline_y - by * eff_world_scale + g.y_offset * base_scale);

            const aw: f32 = if (entry.kind == .color) color_w else mono_w;
            const ah: f32 = if (entry.kind == .color) color_h else mono_h;

            // UVs at exact texel-edge boundaries. With linear sampling
            // and a quad sized to match the bitmap, this puts each
            // fragment center directly on its corresponding texel
            // center → crisp 1:1 reproduction.
            //
            // We used to inset by half a texel to defend against
            // neighbour-glyph bleed under downscale, but the atlas
            // already keeps a 2-texel zero-cleared gutter between
            // glyphs (`GLYPH_PAD` in `gpu/atlas.zig`), and bilinear
            // sampling can never reach further than 1 texel past a
            // quad edge. So the inset was redundant — and at 1:1 it
            // turned the top + bottom rows into a 52.5/47.5 mix with
            // the gutter, visibly clipping the bottom (and top) half-
            // pixel of every glyph.
            try out.append(.{
                .dst_pos = .{ dx, dy },
                .dst_size = .{ rw * eff_world_scale, rh * eff_world_scale },
                .uv_min = .{
                    @as(f32, @floatFromInt(entry.rect.x)) / aw,
                    @as(f32, @floatFromInt(entry.rect.y)) / ah,
                },
                .uv_max = .{
                    @as(f32, @floatFromInt(entry.rect.x + entry.rect.w)) / aw,
                    @as(f32, @floatFromInt(entry.rect.y + entry.rect.h)) / ah,
                },
                .color = color,
                .hot_color = hot_color,
                .tex_select = @intFromEnum(entry.kind),
                .attention = attention,
                .fx_kind = 0,
                ._pad = 0,
            });
            try out_targets.append(target_index);
        }
        // Advances came from BASE shaping — scale by base entry's
        // strike factor (= 1 for scalable mono fonts; < 1 for the
        // emoji strike-only path).
        x += g.x_advance * base_scale;
    }
    return x;
}

/// Shape + append a series of spans on one line. Spans flow with the
/// pen — each carries its own style (font + colour) but they share
/// a baseline supplied by the caller.
pub fn appendLineFromSpans(
    out: *std.ArrayList(tp.GlyphInstance),
    out_targets: *std.ArrayList(u32),
    target_index: u32,
    allocator: std.mem.Allocator,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    glyph_cache_lock: ?*std.Thread.Mutex,
    spans: []const Span,
    pen_x: f32,
    baseline_y: f32,
    zoom: f32,
) !f32 {
    var x = pen_x;
    for (spans) |span| {
        const hb = fonts.hbFont(span.style.font_id);
        var run = try shape.shapeUtf8(allocator, hb, span.text);
        defer run.deinit();
        x = try appendShapedRun(
            out,
            out_targets,
            target_index,
            fonts,
            cache,
            mono_atlas,
            color_atlas,
            glyph_cache_lock,
            run,
            span.style.font_id,
            x,
            baseline_y,
            span.style.color,
            span.style.hot_color,
            span.style.attention,
            zoom,
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
    glyph_cache_lock: ?*std.Thread.Mutex,
    paragraph: Paragraph,
    pen_x: f32,
    start_y: f32,
    zoom: f32,
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
            glyph_cache_lock,
            line.spans,
            pen_x,
            baseline_y,
            zoom,
        );
        y += max_lh;
    }
    return y;
}
