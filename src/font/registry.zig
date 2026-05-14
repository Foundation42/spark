//! Font registry: indexes loaded `(face, hb_font, ...)` entries by
//! an opaque `FontId` (u32). Each `load(path, px)` call adds a new
//! entry — same file at two pixel sizes becomes two entries,
//! because FreeType's `FT_Set_Pixel_Sizes` mutates the face
//! globally and we don't want to interleave rasterisations at
//! different sizes through one face.
//!
//! Each entry tracks both the *requested* display size (what the
//! user asked for) and the *actual* rasterisation size (what FT
//! settled on — usually equal, but for strike-only colour bitmap
//! fonts like Noto Color Emoji's CBDT it's the nearest baked-in
//! strike size). The ratio is exposed as `scale(font_id)` so the
//! layout pass can shrink emoji bitmaps down to inline with body
//! text. For scalable mono fonts the scale is always 1.
//!
//! `metrics(font_id)` returns metrics in display units (already
//! scaled), so the layout pass doesn't have to multiply at every
//! callsite.

const std = @import("std");
const face_mod = @import("face.zig");
const shape = @import("shape.zig");

pub const FontId = u32;

const Entry = struct {
    face: face_mod.Face,
    hb: shape.Font,
    /// What FT actually uses internally — may be a strike size for
    /// CBDT/sbix fonts where the requested size wasn't available.
    actual_px: u32,
    /// What the caller asked for. Equal to `actual_px` for scalable
    /// fonts; smaller for strike fonts being shrunk to inline.
    display_px: u32,
    /// `display_px / actual_px`. The layout pass multiplies every
    /// FT-pixel quantity (bearings, HB advances, atlas-rect sizes)
    /// by this to land in display coordinates.
    scale: f32,
    /// Pre-scaled to display units.
    metrics: face_mod.Metrics,
};

pub const FontRegistry = struct {
    allocator: std.mem.Allocator,
    ft: face_mod.Library,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator, ft: face_mod.Library) FontRegistry {
        return .{
            .allocator = allocator,
            .ft = ft,
            .entries = std.ArrayList(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *FontRegistry) void {
        for (self.entries.items) |*e| {
            e.hb.deinit();
            e.face.deinit();
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// Load a TTF/OTF font file targeting `display_px` pixels of
    /// rendered height. For scalable fonts FT rasterises at exactly
    /// that size; for CBDT/sbix strike fonts FT picks the nearest
    /// strike and the entry records a scale factor < 1 so the
    /// layout pass can shrink the bitmaps inline.
    pub fn load(
        self: *FontRegistry,
        path: [*:0]const u8,
        display_px: u32,
    ) !FontId {
        var new_face = try face_mod.Face.init(self.ft, path, 0);
        errdefer new_face.deinit();
        try new_face.setPixelSize(display_px);

        var hb = try shape.Font.fromFreetypeFace(new_face);
        errdefer hb.deinit();

        const actual_px = new_face.pixel_size;
        const sc: f32 = @as(f32, @floatFromInt(display_px)) / @as(f32, @floatFromInt(actual_px));

        // FT_Select_Size (strike fallback inside setPixelSize) changes
        // the face's metric scaling — let HB know so its cached
        // metric callbacks pick up the new size. No-op when the
        // scalable path took setPixelSize, but cheap insurance.
        shape.c.hb_ft_font_changed(hb.handle);

        const raw_metrics = new_face.metrics();
        const scaled_metrics = face_mod.Metrics{
            .ascender = raw_metrics.ascender * sc,
            .descender = raw_metrics.descender * sc,
            .line_height = raw_metrics.line_height * sc,
        };

        try self.entries.append(.{
            .face = new_face,
            .hb = hb,
            .actual_px = actual_px,
            .display_px = display_px,
            .scale = sc,
            .metrics = scaled_metrics,
        });
        return @intCast(self.entries.items.len - 1);
    }

    pub fn face(self: *FontRegistry, id: FontId) *face_mod.Face {
        return &self.entries.items[id].face;
    }

    pub fn hbFont(self: *const FontRegistry, id: FontId) shape.Font {
        return self.entries.items[id].hb;
    }

    pub fn metrics(self: *const FontRegistry, id: FontId) face_mod.Metrics {
        return self.entries.items[id].metrics;
    }

    /// Scale factor from actual FT pixel units to display units —
    /// 1.0 for scalable mono fonts, < 1.0 for strike-only colour
    /// emoji fonts being shrunk inline.
    pub fn scale(self: *const FontRegistry, id: FontId) f32 {
        return self.entries.items[id].scale;
    }

    pub fn displayPx(self: *const FontRegistry, id: FontId) u32 {
        return self.entries.items[id].display_px;
    }
};
