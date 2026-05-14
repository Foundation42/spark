//! HarfBuzz wrapper.
//!
//! Wraps `hb_buffer_t` + `hb_font_t` to convert a UTF-8 string into a
//! sequence of (glyph_id, x_offset, y_offset, x_advance, y_advance,
//! cluster) tuples honouring the font's shaping rules — ligatures
//! (`!=`, `=>`, fi/fl), kerning, BiDi-correct order, complex-script
//! reordering, ZWJ sequences for emoji families. The library does
//! the work; we just route bytes in and pixels out.
//!
//! The HB font is wrapped around an existing FreeType `FT_Face` via
//! `hb_ft_font_create_referenced`. Because the FT face has had
//! `FT_Set_Pixel_Sizes` called on it, HB's metric callbacks return
//! advances in 26.6 fixed-point *pixel* units. We divide by 64 here
//! to expose float pixels — keeps the layout pass arithmetic simple
//! and matches the convention text engines like Pango / Skia use.

const std = @import("std");
const face_mod = @import("face.zig");

pub const c = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});

pub const Font = struct {
    handle: *c.hb_font_t,

    /// Wrap an existing FreeType face. The returned HB font holds a
    /// reference to the FT face (it survives `Face.deinit`), but the
    /// host should keep the FT face alive for the lifetime of this
    /// HB font anyway so the rasteriser can still see it. Caller
    /// must `deinit` to release the HB ref.
    pub fn fromFreetypeFace(face: face_mod.Face) !Font {
        const hb = c.hb_ft_font_create_referenced(@ptrCast(face.handle));
        if (hb == null) return error.HbFontCreateFailed;
        // Switch HB to using FT's metric/glyph-name callbacks. Without
        // this, HB falls back to its own (slightly different) parser
        // for the same font tables; routing through FT keeps the two
        // halves of the engine consistent.
        c.hb_ft_font_set_funcs(hb);
        return .{ .handle = hb.? };
    }

    pub fn deinit(self: *Font) void {
        c.hb_font_destroy(self.handle);
        self.* = undefined;
    }
};

pub const Glyph = struct {
    /// Post-shaping glyph index into the font's internal glyph table.
    /// Pass to `Face.rasterizeGlyph` to render — NOT a Unicode
    /// codepoint any more.
    glyph_id: u32,
    /// Byte offset into the original UTF-8 input that produced this
    /// glyph. For ligatures and reordering a single cluster can
    /// produce multiple glyphs; multiple input bytes can map to one
    /// glyph. Phase 3 ignores it; later phases use it for hit-testing
    /// and selection.
    cluster: u32,
    /// Per-glyph pen offsets in pixels (HB calls these "design
    /// offsets" — e.g. mark positioning above a base glyph). Apply
    /// these on top of the bitmap bearings during layout.
    x_offset: f32,
    y_offset: f32,
    /// Advance to the next pen position in pixels.
    x_advance: f32,
    y_advance: f32,
};

pub const ShapedRun = struct {
    glyphs: []Glyph,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShapedRun) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

/// Shape `text` (UTF-8) through `font`. Allocates the output slice
/// in `allocator`. The HB buffer is created and destroyed inside
/// this call — callers don't see HB types in or out.
pub fn shapeUtf8(
    allocator: std.mem.Allocator,
    font: Font,
    text: []const u8,
) !ShapedRun {
    const buf = c.hb_buffer_create() orelse return error.HbBufferCreateFailed;
    defer c.hb_buffer_destroy(buf);

    c.hb_buffer_add_utf8(
        buf,
        text.ptr,
        @intCast(text.len),
        0,
        @intCast(text.len),
    );
    // Heuristic-derive script / direction / language from the input.
    // For Phase 3 demo text (Latin) this picks "Latin, LTR, English"
    // which is what we want. Multilingual content will want explicit
    // direction/script/language set per run; that's a later phase.
    c.hb_buffer_guess_segment_properties(buf);

    c.hb_shape(font.handle, buf, null, 0);

    var glyph_count: c_uint = 0;
    const info_ptr = c.hb_buffer_get_glyph_infos(buf, &glyph_count);
    const pos_ptr = c.hb_buffer_get_glyph_positions(buf, &glyph_count);

    const glyphs = try allocator.alloc(Glyph, glyph_count);
    var i: usize = 0;
    while (i < glyph_count) : (i += 1) {
        const info = info_ptr[i];
        const pos = pos_ptr[i];
        glyphs[i] = .{
            .glyph_id = info.codepoint, // post-shaping = glyph id
            .cluster = info.cluster,
            .x_offset = @as(f32, @floatFromInt(pos.x_offset)) / 64.0,
            .y_offset = @as(f32, @floatFromInt(pos.y_offset)) / 64.0,
            .x_advance = @as(f32, @floatFromInt(pos.x_advance)) / 64.0,
            .y_advance = @as(f32, @floatFromInt(pos.y_advance)) / 64.0,
        };
    }
    return .{ .glyphs = glyphs, .allocator = allocator };
}
