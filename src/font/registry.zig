//! Font registry: indexes loaded `(face, hb_font, px_size, metrics)`
//! quadruples by an opaque `FontId` (u32). Each `load(path, px)` call
//! adds a new entry — same file at two pixel sizes becomes two
//! entries, because FreeType's `FT_Set_Pixel_Sizes` mutates the face
//! globally and we don't want to interleave rasterisations at
//! different sizes through one face.
//!
//! Each entry owns its FT face and HB font; deinit destroys all of
//! them in registration order. Holds the FT `Library` borrowed —
//! caller is responsible for keeping that alive for the registry's
//! lifetime.
//!
//! IDs are *stable* — registering N fonts gives ids 0..N-1, and we
//! never compact. Phase 4 doesn't need unload (we register at
//! startup and live with it); when fonts become user-controllable
//! (Phase 7+), we'll either intern by path+size or generation-tag
//! the ids.

const std = @import("std");
const face_mod = @import("face.zig");
const shape = @import("shape.zig");

pub const FontId = u32;

const Entry = struct {
    face: face_mod.Face,
    hb: shape.Font,
    px_size: u32,
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

    /// Load a TTF/OTF font file at `px_size` pixels, returning its
    /// FontId. The same (path, px_size) loaded twice gives two
    /// independent entries — we don't intern.
    pub fn load(
        self: *FontRegistry,
        path: [*:0]const u8,
        px_size: u32,
    ) !FontId {
        var new_face = try face_mod.Face.init(self.ft, path, 0);
        errdefer new_face.deinit();
        try new_face.setPixelSize(px_size);

        var hb = try shape.Font.fromFreetypeFace(new_face);
        errdefer hb.deinit();

        try self.entries.append(.{
            .face = new_face,
            .hb = hb,
            .px_size = px_size,
            .metrics = new_face.metrics(),
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

    pub fn pxSize(self: *const FontRegistry, id: FontId) u32 {
        return self.entries.items[id].px_size;
    }
};
