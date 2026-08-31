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
///   refraction      : f32  — 0..4
///   edge_softness   : f32  — 4..8
///   rim_brightness  : f32  — 8..12
///   _pad            : f32  — 12..16  (fills the vec4 slot)
///   tint            : vec4 — 16..32  (premultiplied-alpha RGBA)
///
/// **`radius` is not here any more.** It moved to the fixed push head as
/// `element.CornerPush`, in PIXELS, so `radius=8` means the same thing on
/// `:::liquid_glass` as it does on `:::box`. It used to be normalised
/// 0..0.5 of the panel, which made the corner an ellipse on anything but a
/// square panel, and it was the only effect that could round at all.
const Uniforms = extern struct {
    refraction: f32,
    edge_softness: f32,
    rim_brightness: f32,
    _pad: f32 = 0,
    tint: [4]f32,
};

fn applyAttrs(spec: *const components.Spec) Uniforms {
    return .{
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
    try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "refraction"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Uniforms, "edge_softness"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Uniforms, "rim_brightness"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Uniforms, "tint"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Uniforms));

    // `radius` is deliberately absent. It lives in the fixed push head
    // now (`element.CornerPush`) so every effect shares one attribute
    // meaning one thing in one unit. A reader who came here looking for
    // it should find this sentence rather than an empty struct.
    try testing.expect(!@hasField(Uniforms, "radius"));
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
