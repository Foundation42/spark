//! Layout: convert a HarfBuzz `ShapedRun` into GPU-ready
//! `GlyphInstance` records, rasterising each glyph through FreeType
//! and packing into the supplied atlas as needed. Phase 3 is the
//! simplest possible single-line layout — no wrap, no styled spans,
//! no per-glyph cache. Phase 4 layers caching (avoid rasterising the
//! same `(face, glyph_id, px)` twice) and span-aware colour
//! propagation on top.
//!
//! Coordinate system: pen-space matches the framebuffer — origin at
//! top-left, Y grows downward, `baseline_y` is the Y coordinate of
//! the glyph baseline. FreeType's `bearing_y` is positive ABOVE the
//! baseline, so the glyph's top-left lives at
//! `(pen_x + bearing_x, baseline_y - bearing_y)` — note the minus.
//!
//! Pixel snapping: `dst_pos` is rounded to integer pixels so glyph
//! coverage stays hinted-grayscale crisp. Sub-pixel positioning is a
//! Phase ≥6 option once we have the MSDF lane wired (sub-pixel
//! coverage there is free; on hinted bitmaps it just causes
//! shimmering).

const std = @import("std");
const face_mod = @import("../font/face.zig");
const shape_mod = @import("../font/shape.zig");
const atlas_mod = @import("../gpu/atlas.zig");
const tp = @import("../gpu/text_pipeline.zig");

pub const RunLayout = struct {
    glyphs: []tp.GlyphInstance,
    /// Final pen-x after the run (top-right of last advance). Useful
    /// for cursor positioning and right-trim calculations.
    pen_end_x: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RunLayout) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

/// Lay out a single shaped run starting at `(pen_x, baseline_y)`,
/// rasterising and packing glyphs into `atlas`, producing
/// `GlyphInstance`s coloured `color`. Returned slice may be shorter
/// than `run.glyphs.len` because zero-width glyphs (spaces) are
/// elided — they advance the pen but produce no draw.
pub fn layoutRun(
    allocator: std.mem.Allocator,
    face: *face_mod.Face,
    atlas: *atlas_mod.Atlas,
    run: shape_mod.ShapedRun,
    pen_x: f32,
    baseline_y: f32,
    color: [4]f32,
) !RunLayout {
    var out = std.ArrayList(tp.GlyphInstance).init(allocator);
    errdefer out.deinit();

    var x = pen_x;
    const y = baseline_y;
    const atlas_w: f32 = @floatFromInt(atlas.extent.width);
    const atlas_h: f32 = @floatFromInt(atlas.extent.height);

    for (run.glyphs) |g| {
        const bitmap = try face.rasterizeGlyph(g.glyph_id);

        // Tight-pack the FT bitmap (handles negative pitch + stride
        // padding). Skipped for zero-size glyphs since `pixels` is
        // unused down that path.
        var tight: []u8 = &.{};
        defer if (tight.len > 0) allocator.free(tight);
        if (bitmap.width != 0 and bitmap.height != 0) {
            tight = try packGlyphBitmap(allocator, bitmap);
        }

        const rect = try atlas.addGlyph(bitmap.width, bitmap.height, tight);

        if (rect.w != 0 and rect.h != 0) {
            const dst_x = @round(x + @as(f32, @floatFromInt(bitmap.bearing_x)) + g.x_offset);
            const dst_y = @round(y - @as(f32, @floatFromInt(bitmap.bearing_y)) + g.y_offset);
            try out.append(.{
                .dst_pos = .{ dst_x, dst_y },
                .dst_size = .{ @floatFromInt(rect.w), @floatFromInt(rect.h) },
                .uv_min = .{
                    @as(f32, @floatFromInt(rect.x)) / atlas_w,
                    @as(f32, @floatFromInt(rect.y)) / atlas_h,
                },
                .uv_max = .{
                    @as(f32, @floatFromInt(rect.x + rect.w)) / atlas_w,
                    @as(f32, @floatFromInt(rect.y + rect.h)) / atlas_h,
                },
                .color = color,
            });
        }

        x += g.x_advance;
    }

    return .{
        .glyphs = try out.toOwnedSlice(),
        .pen_end_x = x,
        .allocator = allocator,
    };
}

/// Copy a FreeType GlyphBitmap (possibly negative pitch, padded
/// rows) into a tight top-down `w*h` byte buffer ready for atlas
/// upload. Same helper that was in `main.zig` for Phase 2 — pulled
/// in here so the layout pass is self-contained.
fn packGlyphBitmap(allocator: std.mem.Allocator, g: face_mod.GlyphBitmap) ![]u8 {
    const w = g.width;
    const h = g.height;
    const out = try allocator.alloc(u8, w * h);
    errdefer allocator.free(out);
    const abs_pitch: usize = @intCast(if (g.pitch < 0) -g.pitch else g.pitch);
    const top_down = g.pitch >= 0;
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const src_row: usize = if (top_down) row else h - 1 - row;
        const src = g.buffer + src_row * abs_pitch;
        @memcpy(out[row * w ..][0..w], src[0..w]);
    }
    return out;
}
