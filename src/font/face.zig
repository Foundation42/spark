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
    /// True when the face has CBDT / sbix / COLRv1 colour glyph
    /// tables. Caller queries via `hasColor()`; rasterise paths use
    /// `FT_LOAD_COLOR` when set so the bitmap comes back as
    /// `FT_PIXEL_MODE_BGRA` premultiplied.
    has_color: bool = false,

    pub fn init(lib: Library, path: [*:0]const u8, face_index: i32) !Face {
        var f: c.FT_Face = null;
        try checkFt(c.FT_New_Face(lib.handle, path, face_index, &f));
        // FT_HAS_COLOR is a macro testing the `face_flags` field;
        // re-implement it explicitly here so we can store the
        // result without re-querying every glyph.
        const has_color = (f.*.face_flags & c.FT_FACE_FLAG_COLOR) != 0;
        return .{ .handle = f, .has_color = has_color };
    }

    pub fn hasColor(self: *const Face) bool {
        return self.has_color;
    }

    pub fn deinit(self: *Face) void {
        _ = c.FT_Done_Face(self.handle);
        self.* = undefined;
    }

    /// Configure the face for px-tall glyphs. The 0 width arg lets
    /// FreeType derive width from the face's design aspect ratio,
    /// which is what we want for proportional fonts.
    ///
    /// For colour bitmap fonts (CBDT/sbix) the available "strikes"
    /// are fixed sizes baked into the font (Noto Color Emoji ships
    /// a single 136px strike). `FT_Set_Pixel_Sizes` will fail with
    /// `Invalid_Pixel_Size` if asked for an arbitrary size on a
    /// strike-only font, so we fall back to `FT_Select_Size` on the
    /// nearest strike — emoji come out at the strike pixel height
    /// rather than the requested one, and the layout step scales
    /// the destination rect to compensate.
    pub fn setPixelSize(self: *Face, px: u32) !void {
        const err = c.FT_Set_Pixel_Sizes(self.handle, 0, px);
        if (err == 0) {
            self.pixel_size = px;
            return;
        }
        // Fall back to fixed-strike selection for colour bitmap fonts.
        const num_sizes = self.handle.*.num_fixed_sizes;
        if (num_sizes > 0) {
            const sizes = self.handle.*.available_sizes[0..@intCast(num_sizes)];
            var best_idx: u32 = 0;
            var best_diff: u64 = std.math.maxInt(u64);
            for (sizes, 0..) |s, i| {
                const a = @as(i64, @intCast(s.height));
                const b = @as(i64, @intCast(px));
                const diff: u64 = @abs(a - b);
                if (diff < best_diff) {
                    best_diff = diff;
                    best_idx = @intCast(i);
                }
            }
            try checkFt(c.FT_Select_Size(self.handle, @intCast(best_idx)));
            self.pixel_size = @intCast(sizes[best_idx].height);
            return;
        }
        return checkFt(err); // bubble the original error if nothing fits
    }

    /// Load + render a single glyph by Unicode codepoint. The
    /// `bearing_*` values position the bitmap relative to the
    /// baseline / pen X; `advance_px` is the pen advance after
    /// drawing this glyph. Returns a borrowed view of the face's
    /// internal glyph slot — valid until the next load on this face.
    pub fn rasterizeChar(self: *Face, codepoint: u32) !GlyphBitmap {
        try checkFt(c.FT_Load_Char(self.handle, codepoint, self.loadFlags()));
        return self.slotBitmap();
    }

    /// Same as `rasterizeChar` but indexed by glyph id (post-shaping).
    /// HarfBuzz produces glyph ids; FreeType wants them via Load_Glyph
    /// rather than Load_Char (which does its own cmap lookup that
    /// would double-count what the shaper already did).
    pub fn rasterizeGlyph(self: *Face, glyph_id: u32) !GlyphBitmap {
        try checkFt(c.FT_Load_Glyph(self.handle, glyph_id, self.loadFlags()));
        return self.slotBitmap();
    }

    /// Whether to let FreeType's hinter move the outline onto the pixel
    /// grid before rasterising.
    ///
    /// **Off, deliberately.** Hinting snaps horizontal stems and the
    /// extremes of curves to whole pixels, which is what makes hinted
    /// text feel crisp — and at UI sizes it also flattens the top and
    /// bottom of every round letter. A capital `G` comes back with a
    /// straight edge across its crown and another under its bowl, and a
    /// stem's cap lands at full coverage with no partial row above it,
    /// so the glyph reads as though a pixel had been sliced off each
    /// end. Chris, 2026-09-01, seeing it in a panel label: "it's the
    /// same half pixel vertical chop off top and bottom we saw on those
    /// slider thumb tacks."
    ///
    /// It is NOT that bug — nothing in this path loses a pixel. At the
    /// HUD's zoom of 1 the whole chain is exactly 1:1: `eff_world_scale`
    /// is 1, `dst_pos` is rounded to whole pixels, `dst_size` is the
    /// atlas rect, and the UVs sit on texel edges. What reaches the
    /// screen IS the bitmap FreeType handed over, row for row. The flat
    /// edges were already in that bitmap, put there on purpose.
    ///
    /// Unhinted is the trade this vocabulary wants: faithful outlines
    /// with real anti-aliasing on every edge, against slightly softer
    /// stems. It is the call macOS makes, and the same one `relief.zig`
    /// makes when it feathers a circle rather than snapping it.
    const HINTING = false;

    fn loadFlags(self: *const Face) c_int {
        // FT_LOAD_COLOR routes through the colour-bitmap (CBDT/sbix)
        // or COLRv1 paths and produces an FT_PIXEL_MODE_BGRA bitmap;
        // without it, an emoji face would return its monochrome
        // .notdef placeholder. Mono faces ignore the flag.
        // FT's flag macros land at slightly different widths after
        // @cImport (FT_LOAD_RENDER is c_int, FT_LOAD_COLOR is c_long
        // on this platform) — explicit cast both sides keeps Zig happy.
        const base: c_long = @as(c_long, c.FT_LOAD_RENDER);
        const color: c_long = if (self.has_color) @as(c_long, c.FT_LOAD_COLOR) else 0;
        const hint: c_long = if (HINTING) 0 else @as(c_long, c.FT_LOAD_NO_HINTING);
        return @intCast(base | color | hint);
    }

    fn slotBitmap(self: *Face) !GlyphBitmap {
        const slot = self.handle.*.glyph;
        const bm = slot.*.bitmap;
        // Allow zero-size glyphs (e.g. U+0020 space) — they have a
        // valid advance but no pixels, and HarfBuzz still emits them
        // in the output run so the caller can advance the pen.
        if (bm.width != 0 and bm.rows != 0 and
            bm.pixel_mode != c.FT_PIXEL_MODE_GRAY and
            bm.pixel_mode != c.FT_PIXEL_MODE_BGRA)
        {
            return error.UnsupportedPixelMode;
        }
        // FT stores GRAY as 1 byte/pixel and BGRA as 4 bytes/pixel
        // (premultiplied). Pitch may be negative (bottom-up) or
        // larger than width*bpp (row padding). We expose the raw
        // buffer + pitch + pixel_mode so the cache uploader can
        // route mono → R8 atlas vs colour → RGBA8 atlas.
        return .{
            .width = bm.width,
            .height = bm.rows,
            .pitch = bm.pitch,
            .pixel_mode = bm.pixel_mode,
            .buffer = bm.buffer,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            // advance.x is in 26.6 fixed point (1/64 px units).
            .advance_px = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
        };
    }

    /// Vertical metrics in pixels for the current pixel size.
    /// `ascender` is positive above baseline, `descender` is negative
    /// below. `line_height` is the recommended line-to-line distance
    /// (face->size->metrics.height in 26.6 fp).
    pub fn metrics(self: *const Face) Metrics {
        const m = self.handle.*.size.*.metrics;
        return .{
            .ascender = @as(f32, @floatFromInt(m.ascender)) / 64.0,
            .descender = @as(f32, @floatFromInt(m.descender)) / 64.0,
            .line_height = @as(f32, @floatFromInt(m.height)) / 64.0,
        };
    }
};

pub const Metrics = struct {
    ascender: f32,
    descender: f32,
    line_height: f32,
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    /// Bytes between consecutive rows of `buffer`. Negative means
    /// rows are stored bottom-up — uncommon for FT_LOAD_RENDER but
    /// honour it just in case.
    pitch: c_int,
    /// `FT_PIXEL_MODE_GRAY` (1 byte/px) or `FT_PIXEL_MODE_BGRA`
    /// (4 bytes/px premultiplied). The cache uploader routes by
    /// this field — mono goes to the R8 atlas, BGRA to the RGBA8
    /// atlas (swizzled on the way in).
    pixel_mode: u8,
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
