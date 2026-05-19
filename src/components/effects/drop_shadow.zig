//! `:::drop_shadow` — wraps child content with a blurred, offset,
//! tinted shadow. Effects-spec Phase B.5 — first user-facing
//! single_source factory.
//!
//! Generated via [[SingleSourceFactory]] (see
//! `src/pass/single_source_factory.zig`); this file is just the
//! per-effect surface: Uniforms layout, attr→uniform mapping, and
//! the inflation math.
//!
//! Attribute grammar:
//!
//!     :::drop_shadow {offset_x=4 offset_y=4 blur=8 color=#000a}
//!       :::box {color=teal width=200 height=80 radius=8}
//!       :::
//!     :::
//!
//! Defaults: offset (4,4), blur 8px, color #00000080 (50% opaque
//! black). The child renders normally; the shadow appears under it
//! shifted by `(offset_x, offset_y)` with a 9-tap box blur of
//! radius `blur` pixels.
//!
//! **Inflation = target_size invariant.** The inflation math runs
//! at create-time (via `.from_params`) and lives on the Component
//! as `inflation: Edges`. Layout reads the Edges to inflate the
//! child's reserved region; the walker reads `box.{w, h}` (the
//! returned inflated box) for the single_source dispatch's
//! `target_size`. Single source of truth — can't drift between
//! channels.
//!
//! Inflation math:
//!     left   = blur - min(0, offset_x)   // blur + extra room for negative offsets
//!     right  = blur + max(0, offset_x)
//!     top    = blur - min(0, offset_y)
//!     bottom = blur + max(0, offset_y)

const std = @import("std");
const component_mod = @import("../../component.zig");
const components = @import("../../markdown_components.zig");
const params = @import("../../params.zig");
const pass = @import("../../pass/root.zig");

/// std140-compatible uniform block. Mirrors `Params` in
/// `shaders/drop_shadow.frag` exactly.
///
/// Layout:
///   offset       : vec2 — 0..8   (pixel offset of shadow from child)
///   blur_radius  : f32  — 8..12  (tap separation in pixels)
///   _pad         : f32  — 12..16 (align next vec4 to 16-byte boundary)
///   shadow_color : vec4 — 16..32 (premultiplied-alpha RGBA tint)
const Uniforms = extern struct {
    offset: [2]f32,
    blur_radius: f32,
    _pad: f32 = 0,
    shadow_color: [4]f32,
};

fn applyAttrs(spec: *const components.Spec) Uniforms {
    const offset_x = params.resolve(f32, spec, "offset_x", 4.0);
    const offset_y = params.resolve(f32, spec, "offset_y", 4.0);
    const blur = params.resolve(f32, spec, "blur", 8.0);
    const color = params.resolve([4]f32, spec, "color", .{ 0, 0, 0, 0.5 });
    return .{
        .offset = .{ offset_x, offset_y },
        .blur_radius = blur,
        .shadow_color = color,
    };
}

/// The load-bearing inflation math. Separate from the spec-driven
/// wrapper so unit tests can exercise the math directly without
/// constructing a Spec.
fn computeInflation(offset_x: f32, offset_y: f32, blur: f32) component_mod.Edges {
    return .{
        .left = blur - @min(@as(f32, 0), offset_x),
        .right = blur + @max(@as(f32, 0), offset_x),
        .top = blur - @min(@as(f32, 0), offset_y),
        .bottom = blur + @max(@as(f32, 0), offset_y),
    };
}

fn computeInflationFromSpec(spec: *const components.Spec) component_mod.Edges {
    const offset_x = params.resolve(f32, spec, "offset_x", 4.0);
    const offset_y = params.resolve(f32, spec, "offset_y", 4.0);
    const blur = params.resolve(f32, spec, "blur", 8.0);
    return computeInflation(offset_x, offset_y, blur);
}

pub const Effect = pass.SingleSourceFactory(.{
    .name = "drop_shadow",
    .shader = "drop_shadow.frag",
    .Uniforms = Uniforms,
    .apply_attrs = applyAttrs,
    .layout_inflation = component_mod.LayoutInflationSpec{ .from_params = computeInflationFromSpec },
    .compute_inflation = computeInflationFromSpec,
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
    try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "offset"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Uniforms, "blur_radius"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Uniforms, "shadow_color"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Uniforms));
}

test "computeInflation: positive offset extends right + bottom" {
    const e = computeInflation(4, 4, 8);
    try testing.expectEqual(@as(f32, 8), e.left);
    try testing.expectEqual(@as(f32, 12), e.right);
    try testing.expectEqual(@as(f32, 8), e.top);
    try testing.expectEqual(@as(f32, 12), e.bottom);
}

test "computeInflation: negative offset extends left + top" {
    const e = computeInflation(-4, -4, 8);
    try testing.expectEqual(@as(f32, 12), e.left);
    try testing.expectEqual(@as(f32, 8), e.right);
    try testing.expectEqual(@as(f32, 12), e.top);
    try testing.expectEqual(@as(f32, 8), e.bottom);
}

test "computeInflation: zero offset is symmetric (blur on all sides)" {
    const e = computeInflation(0, 0, 6);
    try testing.expectEqual(@as(f32, 6), e.left);
    try testing.expectEqual(@as(f32, 6), e.right);
    try testing.expectEqual(@as(f32, 6), e.top);
    try testing.expectEqual(@as(f32, 6), e.bottom);
}

test "factory: pass_shape is .single_source with from_params inflation" {
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .single_source),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .single_source => |ss| {
            const li = ss.layout_inflation orelse return error.MissingInflationSpec;
            try testing.expectEqual(
                @as(std.meta.Tag(component_mod.LayoutInflationSpec), .from_params),
                std.meta.activeTag(li),
            );
        },
        else => unreachable,
    }
}
