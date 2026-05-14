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

/// Which atlas / sampling math this font's glyphs route through.
/// Mono and SDF share the R8 atlas (different fragment branches);
/// `color` lives in the RGBA8 atlas. Auto-promoted to `.color` at
/// load time if the FT face reports `FT_FACE_FLAG_COLOR`, regardless
/// of what the caller requested — emoji are a property of the font,
/// not a stylistic choice.
pub const Lane = enum(u32) {
    mono = 0,
    color = 1,
    sdf = 2,
};

/// Rasterisation size for the SDF lane. High enough that the
/// distance field has fine-grained gradients, so the bilinear
/// sampler produces smooth edges all the way down to body sizes
/// AND up to heading-scale. 64 is a sweet spot for the radius-8
/// brute-force generator — 80² × 8² ≈ 50k ops per glyph.
const SDF_SOURCE_PX: u32 = 64;

const Entry = struct {
    face: face_mod.Face,
    hb: shape.Font,
    /// What FT actually uses internally. Equals `display_px` for
    /// scalable mono fonts; smaller (strike size) for CBDT/sbix
    /// emoji; fixed at `SDF_SOURCE_PX` for the SDF lane.
    actual_px: u32,
    /// What the caller asked for. The layout pass uses this for pen
    /// advances + bitmap dst-sizes via the `scale` factor.
    display_px: u32,
    /// `display_px / actual_px`. The layout pass multiplies every
    /// FT-pixel quantity (bearings, HB advances, atlas-rect sizes)
    /// by this to land in display coordinates.
    scale: f32,
    /// Pre-scaled to display units.
    metrics: face_mod.Metrics,
    lane: Lane,
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
    /// rendered height for the mono (hinted-grayscale) or colour
    /// (CBDT/sbix) lane. For scalable mono fonts FT rasterises at
    /// exactly that size; for strike-only colour fonts FT picks the
    /// nearest strike and the entry records a scale factor < 1.
    pub fn load(
        self: *FontRegistry,
        path: [*:0]const u8,
        display_px: u32,
    ) !FontId {
        return self.loadInner(path, display_px, display_px, .mono);
    }

    /// Load a font for the SDF lane. FT always rasterises at the
    /// fixed `SDF_SOURCE_PX` (64) regardless of `display_px`; the
    /// SDF generator computes distances from that high-res bitmap
    /// and the layout pass scales the dst-rect to `display_px`.
    /// Smooth at all sizes from body text up through headings; the
    /// per-glyph attention attribute can shift the threshold to
    /// thin / bold / glow without re-rasterising.
    pub fn loadSdf(
        self: *FontRegistry,
        path: [*:0]const u8,
        display_px: u32,
    ) !FontId {
        return self.loadInner(path, display_px, SDF_SOURCE_PX, .sdf);
    }

    fn loadInner(
        self: *FontRegistry,
        path: [*:0]const u8,
        display_px: u32,
        request_px: u32,
        requested_lane: Lane,
    ) !FontId {
        var new_face = try face_mod.Face.init(self.ft, path, 0);
        errdefer new_face.deinit();
        try new_face.setPixelSize(request_px);

        var hb = try shape.Font.fromFreetypeFace(new_face);
        errdefer hb.deinit();

        // Promote to colour lane if the face is colour-capable —
        // regardless of what the caller asked for. CBDT/sbix can
        // only produce BGRA bitmaps; an SDF / mono lane on them
        // would be nonsense.
        const effective_lane: Lane = if (new_face.hasColor()) .color else requested_lane;

        const actual_px = new_face.pixel_size;
        const sc: f32 = @as(f32, @floatFromInt(display_px)) / @as(f32, @floatFromInt(actual_px));

        // FT_Select_Size (strike fallback inside setPixelSize) changes
        // the face's metric scaling — let HB know so its cached
        // metric callbacks pick up the new size. No-op when the
        // scalable path took setPixelSize, but cheap insurance.
        shape.c.hb_ft_font_changed(hb.handle);

        // ─── HB scale fix for strike-only colour fonts ──────────────
        // NotoColorEmoji.ttf is CBDT-only; FreeType reports its
        // `units_per_EM` as 0, and HB derives font scale from
        // `units_per_EM × ppem`, so the auto-init via
        // hb_ft_font_create_referenced leaves scale at 0. Net effect:
        // every glyph's `x_advance` returns 0 and the emoji stack on
        // top of each other (Phase 5 bring-up bug). Force-set scale +
        // ppem to the actual rasterisation pixel size in 26.6 fp so
        // advances come back in real pixel units. Idempotent for
        // scalable mono fonts where the auto-derived value was
        // already `actual_px * 64`.
        const ppem_i: c_int = @intCast(actual_px);
        shape.c.hb_font_set_scale(hb.handle, ppem_i * 64, ppem_i * 64);
        shape.c.hb_font_set_ppem(hb.handle, actual_px, actual_px);

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
            .lane = effective_lane,
        });
        return @intCast(self.entries.items.len - 1);
    }

    pub fn lane(self: *const FontRegistry, id: FontId) Lane {
        return self.entries.items[id].lane;
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
