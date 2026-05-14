//! Per-glyph atlas cache. Keyed by `(font_id, glyph_id)`; value
//! carries the atlas rect, the bitmap bearings, **and** an
//! `AtlasKind` tag so the layout pass knows whether to emit
//! `tex_select = mono` or `tex_select = color` into the SSBO.
//! Colour is per-`Span`, not per-glyph, applied at layout time —
//! lifting that out of the cache lets the same glyph serve any
//! number of tinted draws without re-rasterising (Makepad's
//! `LaidoutGlyph` does the same — see [[reference-makepad-layout]]).
//!
//! Phase 5 grows the cache miss path to route by `pixel_mode`: a
//! mono bitmap goes to the R8 atlas as-is; a BGRA bitmap (from a
//! `FT_LOAD_COLOR`-capable face) is swizzled BGRA→RGBA on the CPU
//! and uploaded to the RGBA8 atlas. Both atlases share the same
//! `(font_id, glyph_id)` key space — there's no key for which
//! atlas; the entry's `kind` is the only routing info needed at
//! draw time.

const std = @import("std");
const atlas_mod = @import("../gpu/atlas.zig");
const face_mod = @import("../font/face.zig");
const registry_mod = @import("../font/registry.zig");

pub const AtlasKind = enum(u32) {
    mono = 0,
    color = 1,
};

pub const GlyphKey = struct {
    font_id: registry_mod.FontId,
    glyph_id: u32,
};

pub const GlyphEntry = struct {
    /// Atlas-pixel rect — equals the FT bitmap dimensions at the
    /// face's *actual* rasterisation size, which can be a strike
    /// size for emoji rather than the requested display size. The
    /// layout pass multiplies by `FontRegistry.scale(font_id)` so
    /// emoji shrink to inline with body text.
    rect: atlas_mod.Rect,
    bearing_x: i32,
    bearing_y: i32,
    kind: AtlasKind,
};

pub const GlyphCache = struct {
    map: std.AutoHashMap(GlyphKey, GlyphEntry),
    allocator: std.mem.Allocator,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) GlyphCache {
        return .{
            .map = std.AutoHashMap(GlyphKey, GlyphEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    /// Look up a glyph in the cache. On miss, rasterise via the font
    /// registry's face and upload to either the mono or color atlas
    /// based on the bitmap's pixel mode. Both atlas refs are required
    /// because we don't know in advance which lane a glyph wants
    /// until FreeType returns the bitmap.
    pub fn getOrRasterize(
        self: *GlyphCache,
        fonts: *registry_mod.FontRegistry,
        mono_atlas: *atlas_mod.Atlas,
        color_atlas: *atlas_mod.Atlas,
        font_id: registry_mod.FontId,
        glyph_id: u32,
    ) !GlyphEntry {
        const key = GlyphKey{ .font_id = font_id, .glyph_id = glyph_id };
        if (self.map.get(key)) |e| {
            self.hits += 1;
            return e;
        }
        self.misses += 1;

        const face = fonts.face(font_id);
        const bitmap = try face.rasterizeGlyph(glyph_id);

        var pixels: []u8 = &.{};
        defer if (pixels.len > 0) self.allocator.free(pixels);

        const kind: AtlasKind = switch (bitmap.pixel_mode) {
            face_mod.c.FT_PIXEL_MODE_BGRA => .color,
            else => .mono,
        };

        if (bitmap.width != 0 and bitmap.height != 0) {
            pixels = switch (kind) {
                .mono => try packMonoBitmap(self.allocator, bitmap),
                .color => try packBgraAsRgba(self.allocator, bitmap),
            };
        }

        const target = if (kind == .color) color_atlas else mono_atlas;
        const rect = try target.addGlyph(bitmap.width, bitmap.height, pixels);
        const entry = GlyphEntry{
            .rect = rect,
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
            .kind = kind,
        };
        try self.map.put(key, entry);
        return entry;
    }

    pub fn hitRate(self: *const GlyphCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// Copy a FreeType GRAY bitmap (possibly negative pitch, padded
/// rows) into a tight top-down `w*h` byte buffer ready for atlas
/// upload.
fn packMonoBitmap(allocator: std.mem.Allocator, g: face_mod.GlyphBitmap) ![]u8 {
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

/// Copy a FreeType BGRA bitmap into a tight top-down `w*h*4` buffer,
/// swizzling BGRA → RGBA on the way (matches the R8G8B8A8_UNORM
/// atlas format). Source is premultiplied per the CBDT/sbix
/// specs — the destination stays premultiplied so the fragment
/// shader can `output = sampled * tint.a` without alpha rounding
/// errors.
fn packBgraAsRgba(allocator: std.mem.Allocator, g: face_mod.GlyphBitmap) ![]u8 {
    const w = g.width;
    const h = g.height;
    const out = try allocator.alloc(u8, w * h * 4);
    errdefer allocator.free(out);
    const abs_pitch: usize = @intCast(if (g.pitch < 0) -g.pitch else g.pitch);
    const top_down = g.pitch >= 0;
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const src_row: usize = if (top_down) row else h - 1 - row;
        const src = g.buffer + src_row * abs_pitch;
        const dst = out[row * w * 4 ..][0 .. w * 4];
        var px: usize = 0;
        while (px < w) : (px += 1) {
            // FT BGRA byte order:  src[0]=B src[1]=G src[2]=R src[3]=A
            // Vk  RGBA byte order: dst[0]=R dst[1]=G dst[2]=B dst[3]=A
            dst[px * 4 + 0] = src[px * 4 + 2];
            dst[px * 4 + 1] = src[px * 4 + 1];
            dst[px * 4 + 2] = src[px * 4 + 0];
            dst[px * 4 + 3] = src[px * 4 + 3];
        }
    }
    return out;
}
