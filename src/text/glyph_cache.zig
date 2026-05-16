//! Per-glyph atlas cache. Keyed by `(font_id, glyph_id)`; value
//! carries the atlas rect, the bitmap bearings, **and** an
//! `AtlasKind` tag so the layout pass knows whether to emit
//! `tex_select = mono | color | sdf` into the SSBO. Colour is
//! per-`Span`, not per-glyph, applied at layout time — lifting that
//! out of the cache lets the same glyph serve any number of tinted
//! draws without re-rasterising (Makepad's `LaidoutGlyph` does the
//! same — see [[reference-makepad-layout]]).
//!
//! Miss-path routing comes from the font registry's `lane` field:
//!   * `.mono`  → FT GRAY bitmap → tight-packed → R8 atlas
//!   * `.color` → FT BGRA bitmap → BGRA→RGBA swizzle → RGBA8 atlas
//!   * `.sdf`   → FT GRAY bitmap → SDF generate → R8 atlas (same
//!                 image as `.mono`; fragment shader branches on
//!                 sampling math).
//!
//! Mono and SDF share the R8 atlas because both are 1-byte-per-pixel
//! grayscale data. The `kind` field in the entry distinguishes
//! how the fragment should interpret the sample (coverage vs
//! distance) — no second sampler binding needed for SDF.

const std = @import("std");
const atlas_mod = @import("../gpu/atlas.zig");
const face_mod = @import("../font/face.zig");
const registry_mod = @import("../font/registry.zig");
const sdf = @import("../font/sdf.zig");

pub const AtlasKind = enum(u32) {
    mono = 0,
    color = 1,
    sdf = 2,
};

/// Zero-padding added around an SDF glyph bitmap before distance-
/// field generation. Without this, FreeType's tight bounding box
/// puts every "outside-the-letter" pixel within 1–4 px of the
/// letter outline, so every SDF value across the rect lands in the
/// 0.3..0.5 range — which overlaps the fragment's glow band and
/// lights up the entire quad with a warm rectangle behind the
/// letter. Padding gives the SDF generator room to descend cleanly
/// to "far outside" (= byte 0) at the rect edges, so glow only
/// fires in the 1–3 px ring around the letter contour. The
/// dst-rect grows correspondingly and bearings shift so the letter
/// still lands at the right pen position. Set ≥ the SDF radius
/// (8) so the boundary is guaranteed to read as "far outside".
const SDF_PAD: u32 = 6;

pub const GlyphKey = struct {
    font_id: registry_mod.FontId,
    glyph_id: u32,
};

pub const GlyphEntry = struct {
    /// Atlas-pixel rect — equals the FT bitmap dimensions at the
    /// face's *actual* rasterisation size. The layout pass
    /// multiplies by `FontRegistry.scale(font_id)` to land in
    /// display units; for SDF fonts that ratio handles the
    /// scale-from-source-to-display.
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

    /// Drop every cached glyph. Paired with `Atlas.reset()` by the
    /// host's AtlasFull recovery path — after both calls, the next
    /// layout pass re-rasterises whatever glyphs the visible viewport
    /// actually needs (at whatever zoom is current), so the working
    /// set shrinks back to what's on screen instead of every glyph
    /// every visited zoom bucket has ever shaped.
    pub fn clear(self: *GlyphCache) void {
        self.map.clearRetainingCapacity();
        self.hits = 0;
        self.misses = 0;
    }

    /// Look up a glyph in the cache. On miss, rasterise via the
    /// font registry's face and route based on the registered lane:
    /// mono goes to the R8 atlas straight from FT; colour goes to
    /// the RGBA8 atlas with a BGRA→RGBA swizzle; SDF runs FT's
    /// grayscale through `sdf.generate` and writes to the same R8
    /// atlas as mono.
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

        // The bitmap's pixel mode (set by FreeType based on FT_LOAD_*
        // flags) authoritatively says "this is BGRA". For mono vs
        // SDF, both arrive as FT_PIXEL_MODE_GRAY — the registry's
        // lane decides which post-processing to apply.
        const kind: AtlasKind = switch (bitmap.pixel_mode) {
            face_mod.c.FT_PIXEL_MODE_BGRA => .color,
            else => switch (fonts.lane(font_id)) {
                .sdf => .sdf,
                else => .mono,
            },
        };

        var pixels: []u8 = &.{};
        defer if (pixels.len > 0) self.allocator.free(pixels);

        // SDF gets a padded bitmap so the distance field has room
        // for "far outside" gradient at its edges. Other lanes use
        // the tight FT bitmap dimensions as-is.
        const has_pixels = bitmap.width != 0 and bitmap.height != 0;
        const out_w: u32 = if (kind == .sdf and has_pixels) bitmap.width + 2 * SDF_PAD else bitmap.width;
        const out_h: u32 = if (kind == .sdf and has_pixels) bitmap.height + 2 * SDF_PAD else bitmap.height;

        if (has_pixels) {
            pixels = switch (kind) {
                .mono => try packMonoBitmap(self.allocator, bitmap),
                .color => try packBgraAsRgba(self.allocator, bitmap),
                .sdf => blk: {
                    const mono = try packMonoBitmap(self.allocator, bitmap);
                    defer self.allocator.free(mono);

                    // Zero-pad the mono bitmap into a (W+2P, H+2P)
                    // buffer with the letter content at offset (P, P).
                    // SDF generation then sees a clean "far outside"
                    // ring around the letter on all sides.
                    const padded = try self.allocator.alloc(u8, out_w * out_h);
                    defer self.allocator.free(padded);
                    @memset(padded, 0);
                    var ry: u32 = 0;
                    while (ry < bitmap.height) : (ry += 1) {
                        const dst_off = (ry + SDF_PAD) * out_w + SDF_PAD;
                        @memcpy(padded[dst_off..][0..bitmap.width], mono[ry * bitmap.width ..][0..bitmap.width]);
                    }

                    const sdf_buf = try self.allocator.alloc(u8, out_w * out_h);
                    sdf.generate(out_w, out_h, padded, sdf_buf);
                    break :blk sdf_buf;
                },
            };
        }

        // Mono and SDF share the R8 atlas; colour lives in RGBA8.
        const target = if (kind == .color) color_atlas else mono_atlas;
        const rect = try target.addGlyph(out_w, out_h, pixels);

        // SDF entry's bearings shift to compensate for the padding.
        // FT's bearing_x is positive right of pen origin → subtract
        // padding so the padded top-left lands `SDF_PAD` left of the
        // unpadded one. FT's bearing_y is positive ABOVE baseline →
        // add padding because the padded top is `SDF_PAD` higher.
        const pad_i: i32 = @intCast(SDF_PAD);
        const entry_bearing_x: i32 = if (kind == .sdf and has_pixels) bitmap.bearing_x - pad_i else bitmap.bearing_x;
        const entry_bearing_y: i32 = if (kind == .sdf and has_pixels) bitmap.bearing_y + pad_i else bitmap.bearing_y;
        const entry = GlyphEntry{
            .rect = rect,
            .bearing_x = entry_bearing_x,
            .bearing_y = entry_bearing_y,
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
            dst[px * 4 + 0] = src[px * 4 + 2];
            dst[px * 4 + 1] = src[px * 4 + 1];
            dst[px * 4 + 2] = src[px * 4 + 0];
            dst[px * 4 + 3] = src[px * 4 + 3];
        }
    }
    return out;
}
