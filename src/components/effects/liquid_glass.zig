//! `:::liquid_glass` — rounded-box SDF refraction + chromatic
//! aberration + rim highlight + tint. Effects-spec Phase B.6.d —
//! third single_source factory; first authored via the B.6.c
//! `SingleSourceFactory` generator (proves the API holds up for
//! new effects, not just refactor targets).
//!
//! Inspired by Apple's Liquid Glass on macOS Tahoe / iOS 19 panels.
//! Refraction works on the CHILD's content (not MAIN), so text or
//! patterns inside the panel bend near the corners as if behind
//! curved glass. The "see-through to background" Apple look needs
//! a second sampler bound to MAIN — that's Phase D / future
//! ChainPass territory.
//!
//! Attribute grammar:
//!
//!     :::liquid_glass {radius=0.18 refraction=0.15 rim_brightness=0.4
//!                      edge_softness=0.005 tint=#ffffff10}
//!       :::pattern {type=checker seed=0 width=240 height=80}
//!       :::
//!     :::
//!
//! Defaults: radius=0.15, refraction=0.15, edge_softness=0.005,
//! rim_brightness=0.3, tint=#ffffff0d (~5% white wash).
//!
//! No layout inflation — the effect renders within child bounds.

const std = @import("std");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const params = @import("../../params.zig");
const pass = @import("../../pass/root.zig");

/// std140-compatible uniform block. Mirrors `Params` in
/// `shaders/liquid_glass.frag` exactly.
///
/// Layout:
///   radius          : f32  — 0..4
///   refraction      : f32  — 4..8
///   edge_softness   : f32  — 8..12
///   rim_brightness  : f32  — 12..16   (4 scalars fill one vec4 slot,
///                                       no padding needed)
///   tint            : vec4 — 16..32  (premultiplied-alpha RGBA)
const Uniforms = extern struct {
    radius: f32,
    refraction: f32,
    edge_softness: f32,
    rim_brightness: f32,
    tint: [4]f32,
};

fn applyAttrs(spec: *const components.Spec) Uniforms {
    return .{
        .radius = params.resolve(f32, spec, "radius", 0.15),
        .refraction = params.resolve(f32, spec, "refraction", 0.15),
        .edge_softness = params.resolve(f32, spec, "edge_softness", 0.005),
        .rim_brightness = params.resolve(f32, spec, "rim_brightness", 0.3),
        // Default tint: ~5% white wash — barely visible, lets the
        // refraction + rim do the visual work.
        .tint = params.resolve([4]f32, spec, "tint", .{ 1, 1, 1, 0.05 }),
    };
}

pub const Effect = pass.SingleSourceFactory(.{
    .name = "liquid_glass",
    .shader = "liquid_glass.frag",
    .Uniforms = Uniforms,
    .apply_attrs = applyAttrs,
    // No layout_inflation — effect renders within child bounds.
});

pub const factory = Effect.factory;
pub const install = Effect.install;

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Uniforms: std140 layout offsets" {
    // Lock-in test — the GLSL push_constant block's contract. Silent
    // reorders compile but render GPU garbage. See
    // [[feedback-std140-offset-lockin]].
    try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "radius"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Uniforms, "refraction"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Uniforms, "edge_softness"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Uniforms, "rim_brightness"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Uniforms, "tint"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Uniforms));
}

test "factory: pass_shape is .single_source with null inflation" {
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .single_source),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .single_source => |ss| try testing.expect(ss.layout_inflation == null),
        else => unreachable,
    }
}
