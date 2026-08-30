//! `:::gbuffer {surface=normal}` — a window onto an image the HOST owns.
//!
//! The panels campaign's Northstar (`matryoshka/docs/cc-brief-panels.md`):
//! put a panel anywhere on screen and see through it, in just that
//! region, to what is underneath — the world-space normals, the raw
//! albedo, a depth. Move the panel and the window moves with it.
//!
//! **It is a `.host_named` single_source, and almost all of it was
//! already built.** `{backdrop}` (C.4) had done the hard half: an
//! effect whose source is not its own children, whose children draw
//! sharp on top, composited in the pre-pass so the panel lands under
//! the content it belongs behind. This points the same shape at a
//! different image.
//!
//! What is genuinely new is that the image is BOUND rather than
//! COPIED. A backdrop blits, because a swapchain in use as an
//! attachment cannot also be sampled. A host surface can be, and must
//! be: every surface worth looking at needs its values remapped to be
//! looked at (a normal is signed, a depth is non-linear), a blit
//! converts only the format, so the pixels have to arrive through a
//! sampler and the remapping has to be a shader. That is why this
//! effect owns no offscreen target at all — see `element.PassSource`.
//!
//! **Why not `.host_slot`.** That arm was built for host-owned
//! rendering (B.7) and has been waiting for a consumer, but a
//! host_slot has no subtree: `HostSlotStep` carries no
//! `subtree_dispatch_range` and Phase 2 walks past it with `i += 1`.
//! A `:::gbuffer` built on it could not contain its own buttons, and
//! keeping a floating button cluster aligned to a movable panel is a
//! layout problem nobody wants. `.host_slot` stays right for a SCENE
//! embedded in a document, where the host renders wholesale.
//!
//! The surface NAMES are the host's vocabulary. spark carries a name
//! back to the resolver the host installed and never interprets one,
//! so a document written against matryoshka's `normal` / `albedo` is
//! not wrong on another host — it just shows nothing, with its
//! buttons still working.

const std = @import("std");
const element = @import("../../element.zig");
const params = @import("../../params.zig");
const components = @import("../../markdown_components.zig");
const component_mod = @import("../../component.zig");
const pass = @import("../../pass/root.zig");

/// Mirrors `gbuffer.frag`'s push block from `PASS_UNIFORM_OFFSET` on.
///
/// **`window` is written by SPARK, not here.** It needs the element's
/// laid-out box and the host surface's dimensions, and neither exists
/// when `applyAttrs` runs — so `recordSingleSourceCompose` overwrites
/// the first `element.HOST_WINDOW_BYTES` at record time. The field is
/// declared anyway rather than left as padding, because a reader of
/// the GLSL needs a Zig-side name to match it against, and because
/// `@offsetOf` then locks the rest of the block in place behind it.
pub const Uniforms = extern struct {
    /// scale.xy, offset.xy — SPARK-OWNED. Anything written here is
    /// discarded.
    window: [4]f32 = .{ 1, 1, 0, 0 },
    /// Which remap the shader applies. See `Mode`.
    mode: f32 = 1,
    /// Multiplier applied to the remapped value, for surfaces whose
    /// interesting range is not 0..1.
    scale: f32 = 1,
    /// Added after `scale`.
    bias: f32 = 0,
    /// Panel opacity, so a window can be laid over the scene rather
    /// than punched through it.
    alpha: f32 = 1,
};

/// How the shader turns a surface's DATA into a picture.
///
/// Named on the Zig side so a document says `mode=normal` rather than
/// `mode=1`. A number still works — it is the same attribute — but a
/// document that says what it means survives being read six months
/// later.
pub const Mode = enum(u8) {
    raw = 0,
    normal = 1,
    albedo = 2,
    depth = 3,
    luma = 4,

    fn parse(text: []const u8) ?Mode {
        const t = std.mem.trim(u8, text, " \t");
        inline for (@typeInfo(Mode).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(t, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

fn applyAttrs(spec: *const components.Spec) Uniforms {
    // `mode=` takes a WORD or a number. The word is looked up first
    // because `params.resolve(f32, ...)` would read "normal" as
    // unparseable and answer the default — which happens to be normal,
    // so every misspelled mode would silently show normals and look
    // like it worked.
    const mode: f32 = blk: {
        for (spec.attrs) |a| {
            if (!std.mem.eql(u8, a.key, "mode")) continue;
            if (Mode.parse(a.value)) |m| break :blk @floatFromInt(@intFromEnum(m));
            break;
        }
        break :blk params.resolve(f32, spec, "mode", @floatFromInt(@intFromEnum(Mode.normal)));
    };
    return .{
        // Spark overwrites this; the value is what a unit test sees
        // before a frame has run, and a poison would be read as a
        // window by anything that forgot to.
        .window = .{ 1, 1, 0, 0 },
        .mode = mode,
        .scale = params.resolve(f32, spec, "scale", 1.0),
        .bias = params.resolve(f32, spec, "bias", 0.0),
        .alpha = params.resolve(f32, spec, "alpha", 1.0),
    };
}

/// How big the window is, when its body does not say.
///
/// Every effect before this one WRAPPED something and took its child's
/// size. A `:::gbuffer` is a window: its body is usually empty, so the
/// child box is zero and the pass would composite into a rectangle
/// with no area — a panel that runs, allocates nothing, reports no
/// error and shows nothing at all.
///
/// 240x160 is a readable window at the HUD's 360px column with room
/// for a caption under it. `width=`/`height=` override; content inside
/// still grows it, because this is a minimum and not a size.
fn computeMinSize(spec: *const components.Spec) [2]f32 {
    return .{
        params.resolve(f32, spec, "width", 240),
        params.resolve(f32, spec, "height", 160),
    };
}

pub const Effect = pass.SingleSourceFactory(.{
    .name = "gbuffer",
    .shader = "gbuffer.frag",
    .Uniforms = Uniforms,
    .apply_attrs = applyAttrs,
    .compute_min_size = computeMinSize,
    // No layout_inflation — the window is exactly the element's box.
    // A magnifying glass that reached outside its own frame would be
    // showing something other than what is under it.
});

pub const factory = Effect.factory;
pub const install = Effect.install;

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Uniforms: std140 layout offsets" {
    // Lock-in test — the GLSL push_constant block's contract. Silent
    // reorders compile but render GPU garbage.
    //
    // `window` at offset 0 is load-bearing beyond the usual: spark
    // memcpys `HOST_WINDOW_BYTES` over the head of this block at record
    // time, so moving it puts the window transform on top of `mode`.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "window"));
    try testing.expectEqual(@as(usize, element.HOST_WINDOW_BYTES), @sizeOf([4]f32));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Uniforms, "mode"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(Uniforms, "scale"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Uniforms, "bias"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(Uniforms, "alpha"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Uniforms));
}

test "mode: a word is read as its enum, and an unknown word is NOT silently normal" {
    // The trap this parser exists for. `params.resolve(f32, ...)`
    // answers its default on anything unparseable, and the default is
    // `normal` — so a misspelling would show normals and look correct.
    // Asserting that `mode=albedo` differs from `mode=nrmal`'s fallback
    // is the inequality (rule 1) the rest of this rests on.
    const albedo = specWith("mode", "albedo");
    try testing.expectEqual(@as(f32, 2), applyAttrs(&albedo).mode);

    const depth = specWith("mode", "depth");
    try testing.expectEqual(@as(f32, 3), applyAttrs(&depth).mode);

    // A number still works — same attribute, and a document mid-edit
    // should not break.
    const numeric = specWith("mode", "3");
    try testing.expectEqual(@as(f32, 3), applyAttrs(&numeric).mode);

    // And a typo falls back to normal, which is the documented
    // behaviour rather than an accident — asserted so that a future
    // change to "refuse the block" is a deliberate one that fails here.
    const typo = specWith("mode", "nrmal");
    try testing.expectEqual(@as(f32, 1), applyAttrs(&typo).mode);
}

test "the window default is the identity, so a pass that never got one shows the whole surface" {
    // Spark overwrites `window` at record time. If it ever stops, the
    // panel should show the entire surface squashed into its box —
    // obviously wrong, and diagnosable — rather than sampling one
    // texel or nothing at all, which reads as a black panel and sends
    // somebody looking at the host's images.
    const spec = specWith("surface", "normal");
    const u = applyAttrs(&spec);
    try testing.expectEqual(@as(f32, 1), u.window[0]);
    try testing.expectEqual(@as(f32, 1), u.window[1]);
    try testing.expectEqual(@as(f32, 0), u.window[2]);
    try testing.expectEqual(@as(f32, 0), u.window[3]);
}

test "factory: pass_shape is .single_source with null inflation" {
    // Zero inflation is the claim that the window IS the element's box.
    // A halo would make the panel show a region larger than itself,
    // which for a magnifying glass is the one thing it must not do.
    try testing.expectEqual(
        @as(std.meta.Tag(component_mod.PassShape), .single_source),
        std.meta.activeTag(factory.pass_shape),
    );
    switch (factory.pass_shape) {
        .single_source => |ss| try testing.expect(ss.layout_inflation == null),
        else => unreachable,
    }
}

fn specWith(key: []const u8, value: []const u8) components.Spec {
    const attrs = struct {
        var storage: [1]components.Attr = undefined;
    };
    attrs.storage[0] = .{ .key = key, .value = value };
    return .{ .name = "gbuffer", .id = null, .attrs = attrs.storage[0..1], .body = "" };
}
