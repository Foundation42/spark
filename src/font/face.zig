//! FreeType wrapper.
//!
//! Thin shim over `FT_Library` + `FT_Face` + `FT_Load_Char` returning
//! a Zig-friendly `GlyphBitmap` view of the rasterised glyph slot.
//! Stays narrow on purpose — colour fonts, hinting modes, kerning
//! pair queries, etc. land here in later phases as the engine grows.
//!
//! Bitmap memory is owned by FreeType inside `face->glyph->bitmap`,
//! so the returned `GlyphBitmap` is only valid until the next call
//! into the same face — callers must either consume it immediately
//! (e.g. memcpy into a staging buffer) or copy into their own
//! allocator.

const std = @import("std");

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub fn checkFt(err: c.FT_Error) !void {
    if (err == 0) return;
    std.debug.print("FreeType call failed: FT_Error={d}\n", .{err});
    return error.FreeTypeFailed;
}

pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() !Library {
        var lib: c.FT_Library = null;
        try checkFt(c.FT_Init_FreeType(&lib));
        return .{ .handle = lib };
    }

    pub fn deinit(self: *Library) void {
        _ = c.FT_Done_FreeType(self.handle);
        self.* = undefined;
    }
};

pub const Face = struct {
    handle: c.FT_Face,
    pixel_size: u32 = 0,

    pub fn init(lib: Library, path: [*:0]const u8, face_index: i32) !Face {
        var f: c.FT_Face = null;
        try checkFt(c.FT_New_Face(lib.handle, path, face_index, &f));
        return .{ .handle = f };
    }

    pub fn deinit(self: *Face) void {
        _ = c.FT_Done_Face(self.handle);
        self.* = undefined;
    }

    /// Configure the face for px-tall glyphs. The 0 width arg lets
    /// FreeType derive width from the face's design aspect ratio,
    /// which is what we want for proportional fonts.
    pub fn setPixelSize(self: *Face, px: u32) !void {
        try checkFt(c.FT_Set_Pixel_Sizes(self.handle, 0, px));
        self.pixel_size = px;
    }

    /// Load + render a single glyph by Unicode codepoint. The
    /// `bearing_*` values position the bitmap relative to the
    /// baseline / pen X; `advance_px` is the pen advance after
    /// drawing this glyph. Returns a borrowed view of the face's
    /// internal glyph slot — valid until the next load on this face.
    pub fn rasterizeChar(self: *Face, codepoint: u32) !GlyphBitmap {
        try checkFt(c.FT_Load_Char(self.handle, codepoint, c.FT_LOAD_RENDER));
        const slot = self.handle.*.glyph;
        const bm = slot.*.bitmap;
        if (bm.pixel_mode != c.FT_PIXEL_MODE_GRAY) return error.UnsupportedPixelMode;

        // FreeType stores grayscale as 1 byte/pixel; pitch may be
        // negative (bottom-up) or larger than width (row padding).
        // We expose the raw buffer + pitch so the uploader can copy
        // row-by-row.
        return .{
            .width = bm.width,
            .height = bm.rows,
            .pitch = bm.pitch,
            .buffer = bm.buffer,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            // advance.x is in 26.6 fixed point (1/64 px units).
            .advance_px = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
        };
    }
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    /// Bytes between consecutive rows of `buffer`. Negative means
    /// rows are stored bottom-up — uncommon for FT_LOAD_RENDER but
    /// honour it just in case.
    pitch: c_int,
    /// Borrowed pointer into the face's glyph slot. Caller must copy
    /// before the next rasterizeChar() on the same face.
    buffer: [*c]const u8,
    /// Pen-space offset to the bitmap's top-left, in pixels.
    /// `bearing_x` is +right of the pen origin; `bearing_y` is
    /// +above the baseline.
    bearing_x: c_int,
    bearing_y: c_int,
    advance_px: f32,
};
