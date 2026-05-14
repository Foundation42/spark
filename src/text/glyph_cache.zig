//! Per-glyph atlas cache. Keyed by `(font_id, glyph_id)`; value
//! carries the atlas rect plus the bitmap bearings (so the layout
//! pass can position the quad without going back to FreeType for
//! every reuse). Crucially the value does NOT carry a colour —
//! colour is per-`Span`, not per-glyph, applied at layout time.
//! Lifting that out of the cache lets the same glyph serve any
//! number of differently-tinted draws without re-rasterising
//! (Makepad's `LaidoutGlyph` does the same — see
//! [[reference-makepad-layout]]).
//!
//! Phase 4 owns just the cache map + counters. The atlas is passed
//! in to `getOrRasterize` so the cache stays a pure dictionary
//! whose only side effect is the atlas write on miss.
//!
//! `hits` / `misses` counters are public so the demo can show that
//! the cache works — drop them or namespace them when this becomes
//! library API for real.

const std = @import("std");
const atlas_mod = @import("../gpu/atlas.zig");
const face_mod = @import("../font/face.zig");
const registry_mod = @import("../font/registry.zig");

pub const GlyphKey = struct {
    font_id: registry_mod.FontId,
    glyph_id: u32,
};

pub const GlyphEntry = struct {
    rect: atlas_mod.Rect,
    bearing_x: i32,
    bearing_y: i32,
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

    pub fn getOrRasterize(
        self: *GlyphCache,
        fonts: *registry_mod.FontRegistry,
        atlas: *atlas_mod.Atlas,
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

        // Tight-pack the FT bitmap (negative pitch → bottom-up;
        // pitch != width → row padding). Skipped for zero-size
        // glyphs (space) — `addGlyph` returns a degenerate rect
        // straight from the shelf cursor.
        var pixels: []u8 = &.{};
        defer if (pixels.len > 0) self.allocator.free(pixels);
        if (bitmap.width != 0 and bitmap.height != 0) {
            pixels = try packGlyphBitmap(self.allocator, bitmap);
        }

        const rect = try atlas.addGlyph(bitmap.width, bitmap.height, pixels);
        const entry = GlyphEntry{
            .rect = rect,
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
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

/// Copy a FreeType GlyphBitmap (possibly negative pitch, padded
/// rows) into a tight top-down `w*h` byte buffer ready for atlas
/// upload. Phase 3 had a copy of this in `layout.zig`; pulled here
/// so the layout pass is purely about positioning and the cache
/// owns its own miss path.
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
