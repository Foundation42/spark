//! `:::frosted_glass` — wraps child content with a blurred + tinted
//! overlay. Effects-spec Phase B.6 — second user-facing single_source
//! factory.
//!
//! Generated via [[SingleSourceFactory]] (see
//! `src/pass/single_source_factory.zig`); this file is just the
//! per-effect surface: Uniforms layout + attr→uniform mapping.
//! No inflation — frosted glass renders within child bounds.
//!
//! Attribute grammar:
//!
//!     :::frosted_glass {blur=12 tint=#ffffff10}
//!       :::box {color=teal width=160 height=80 radius=8}
//!         Tools panel
//!       :::
//!     :::
//!
//! Defaults: blur=12px, tint=#ffffff10 (~6% white overlay — the
//! modern-OS frosted-panel look).

const std = @import("std");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const params = @import("../../params.zig");
const pass = @import("../../pass/root.zig");

/// std140-compatible uniform block. Mirrors `Params` in
/// `shaders/frosted_glass.frag` exactly.
///
/// Layout:
///   blur_radius : f32   — 0..4   (tap separation in pixels)
///   _pad        : f32x3 — 4..16  (align next vec4 to 16-byte boundary)
///   tint_color  : vec4  — 16..32 (premultiplied-alpha RGBA overlay)
const Uniforms = extern struct {
    blur_radius: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
    tint_color: [4]f32,
};

fn applyAttrs(spec: *const components.Spec) Uniforms {
    return .{
        .blur_radius = params.resolve(f32, spec, "blur", 12.0),
        // Default tint: #ffffff10 = white at 6.25% alpha. The
        // modern-OS panel look sits in the 5–15% range.
        .tint_color = params.resolve([4]f32, spec, "tint", .{ 1, 1, 1, 0.0625 }),
    };
}

pub const Effect = pass.SingleSourceFactory(.{
    .name = "frosted_glass",
    .shader = "frosted_glass.frag",
    .Uniforms = Uniforms,
    .apply_attrs = applyAttrs,
    // No layout_inflation — author opts into extra room by wrapping
    // in :::box, not via an inflation knob.
});

pub const factory = Effect.factory;
pub const install = Effect.install;

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Uniforms: std140 layout offsets" {
    // Lock-in test. These offsets ARE the GLSL push_constant block's
    // contract; an "innocent" field reorder that compiles cleanly
    // would push misaligned uniforms to the GPU and render garbage.
    // See [[feedback-std140-offset-lockin]] — generator can't help
    // here, the explicit per-factory test is the load-bearing part.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "blur_radius"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Uniforms, "tint_color"));
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
