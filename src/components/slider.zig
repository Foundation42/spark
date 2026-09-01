//! `:::slider` — first interactive component (stage 7f). Validates
//! the input loop end-to-end: mouse_down on the track / thumb →
//! drag tracking → `state.set(target, new_value)` → registry
//! subscriber fires → `factory.update` on whatever component bound
//! to that path → re-layout → visual feedback.
//!
//! Attribute grammar:
//!
//!     :::slider {target=path min=0 max=100 width=240}
//!     :::
//!
//! - `target` (required) — the state path the slider mutates.
//! - `min` / `max` — numeric range. Defaults 0..1. Floats supported.
//! - `width` — pixel literal or `100%`. Default `100%`.
//! - `height` — pixel literal. Default `28px`.
//! - `value` — initial / displayed value. Usually bound to the same
//!   path via `${state.target}` so the slider sees external
//!   mutations. Missing → midpoint of `[min, max]`.
//! - `color` — the filled part, left of the thumb. Named `color` rather
//!   than `fill` to match `:::box`, since it is the one a document
//!   reaches for most.
//! - `track` — the recess the fill sits in. A neutral DARKENING by
//!   default, so it takes the tint of whatever panel it is on instead of
//!   imposing one; it used to be an opaque blue-grey and put a tint in
//!   every groove that nobody had asked for.
//! - `thumb` — the tack.
//! - `notch` — the ruling along the track.
//!
//! All four take what `:::box {color=}` takes — a name, or hex. Any left
//! unsaid keeps its default, so setting one means one.
//!
//! ## The track is a cut-out, not a bar
//!
//! A channel with a lip shadow along its top edge, a sliver of bounce
//! along the bottom, and notches ruled down it that fade into the recess
//! at either end. Everything but the label is in the TRIANGLE layer —
//! `relief.zig` says why that is load-bearing rather than incidental,
//! and why the thumb is not a rounded quad.
//!
//! Drag model: mouse_down anywhere on the track snaps the thumb to
//! the cursor and starts a drag; subsequent mouse_move (with the
//! button still held) updates value continuously; mouse_up ends the
//! drag. Both mouse_down and mouse_move call `state.set`, so the
//! bound component re-renders smoothly as the cursor moves.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const box_helpers = @import("box.zig"); // reuse parseLength + Length
const relief = @import("relief.zig");

const Component = struct {
    allocator: std.mem.Allocator,
    target: []u8, // owned copy of the state path we mutate
    min: f32,
    max: f32,
    width: box_helpers.Length,
    height: f32,
    value: f32,
    /// The four colours a slider wears. Attributes rather than baked
    /// constants since 2026-09-01 — Chris, at the bench: "are the colors
    /// of the slider and its tack configurable? I can't remember, they
    /// should be."
    fill_color: [4]f32 = TRACK_FILL_COLOR,
    track_color: [4]f32 = TRACK_COLOR,
    thumb_color: [4]f32 = THUMB_COLOR,
    notch_color: [4]f32 = NOTCH_COLOR,
    /// Bumped whenever a colour actually changes. Folded into
    /// `contentVersion` so a `color=${state.x}` re-renders — without it
    /// the palette was invisible to the retained layout cache, which is
    /// the same trap the `disable_cache` note below is about.
    palette_version: u32 = 0,
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    /// Shared by `fromSpec` and `ingest`, which otherwise duplicate
    /// their attribute loops. An absent attribute leaves the current
    /// value alone, so a reactive re-render carrying only `value=` keeps
    /// the palette the document set.
    fn applyColors(self: *Component, spec: *const components.Spec) void {
        const before = [_][4]f32{ self.fill_color, self.track_color, self.thumb_color, self.notch_color };
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "color")) {
                if (box_helpers.parseColor(a.value)) |v| self.fill_color = v;
            } else if (std.mem.eql(u8, a.key, "track")) {
                if (box_helpers.parseColor(a.value)) |v| self.track_color = v;
            } else if (std.mem.eql(u8, a.key, "thumb")) {
                if (box_helpers.parseColor(a.value)) |v| self.thumb_color = v;
            } else if (std.mem.eql(u8, a.key, "notch")) {
                if (box_helpers.parseColor(a.value)) |v| self.notch_color = v;
            }
        }
        const after = [_][4]f32{ self.fill_color, self.track_color, self.thumb_color, self.notch_color };
        if (!std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&after))) {
            self.palette_version +%= 1;
        }
    }

    fn fromSpec(allocator: std.mem.Allocator, spec: *const components.Spec) !Component {
        var min: f32 = 0;
        var max: f32 = 1;
        var width: box_helpers.Length = .{ .percent = 1.0 };
        var height: f32 = 28;
        var value_opt: ?f32 = null;
        var target_raw: ?[]const u8 = null;

        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "min")) {
                min = std.fmt.parseFloat(f32, a.value) catch min;
            } else if (std.mem.eql(u8, a.key, "max")) {
                max = std.fmt.parseFloat(f32, a.value) catch max;
            } else if (std.mem.eql(u8, a.key, "value")) {
                value_opt = std.fmt.parseFloat(f32, a.value) catch null;
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (box_helpers.parseLength(a.value)) |l| width = l;
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (box_helpers.parseLength(a.value)) |l| {
                    height = switch (l) {
                        .pixels => |p| p,
                        else => height,
                    };
                }
            } else if (std.mem.eql(u8, a.key, "target")) {
                target_raw = a.value;
            }
        }

        const target_value = target_raw orelse "";
        var c: Component = .{
            .allocator = allocator,
            .target = try allocator.dupe(u8, target_value),
            .min = min,
            .max = max,
            .width = width,
            .height = height,
            .value = std.math.clamp(value_opt orelse (min + (max - min) * 0.5), min, max),
        };
        c.applyColors(spec);
        return c;
    }

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        // Update path: keep `target` (the slider's identity) but
        // refresh range / dimensions / value from the new spec. The
        // common reactive case is `value=${state.x}` — the registry
        // fires our update with the latest value when x mutates.
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "min")) {
                self.min = std.fmt.parseFloat(f32, a.value) catch self.min;
            } else if (std.mem.eql(u8, a.key, "max")) {
                self.max = std.fmt.parseFloat(f32, a.value) catch self.max;
            } else if (std.mem.eql(u8, a.key, "value")) {
                if (std.fmt.parseFloat(f32, a.value)) |v| {
                    self.value = std.math.clamp(v, self.min, self.max);
                } else |_| {}
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (box_helpers.parseLength(a.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (box_helpers.parseLength(a.value)) |l| {
                    self.height = switch (l) {
                        .pixels => |p| p,
                        else => self.height,
                    };
                }
            }
            // target is intentionally not re-read — changing where
            // the slider writes mid-flight would be confusing.
        }
        self.applyColors(spec);
    }
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    c.* = try Component.fromSpec(allocator, spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.target);
    allocator.destroy(c);
}

/// The thumb's position IS `value`, so the value is the version.
///
/// This used to set `disable_cache = true` instead, on the reasoning that
/// "the value isn't captured in any component-owned counter". It is —
/// `Component.value`, which `update` refreshes from `${state.target}` on
/// every reactive fire. And `disable_cache` was not enough anyway: it stops
/// the slider caching ITSELF, but a cached ANCESTOR still snapshots the
/// slider's output and replays it. So a slider inside `:::drop_shadow` or
/// `:::frosted_glass` was frozen at its create-time position — it drove the
/// plane, the scene changed, and the thumb never moved. Found by Chris at
/// the bench with a backdrop panel; `src/hud/lab.md` only escaped it because
/// its sliders sit outside the shadow block.
///
/// A version fixes both, because it is what the ancestors already aggregate.
fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return @as(u64, @as(u32, @bitCast(c.value))) |
        (@as(u64, c.palette_version) << 32);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
};

// ── Visual constants — local, not theme yet ───────────────────────
// 7c's `:::box` baked its visual constants into the component too.
// When more components arrive we'll move shared ones (track colours,
// thumb radius) onto `Theme`; for stage 7f keeping them here keeps
// the diff focused on the input contract.

/// The recess, as a NEUTRAL darkening rather than a colour of its own.
///
/// This was an opaque blue-grey, which put a tint in every groove that
/// no document had asked for and that fought whatever the panel behind
/// it was. Chris spotted it: "the recessed part seems to be slightly
/// blue tinted, and the dark recess part under the ticks could be darker
/// for more contrast." Black-with-alpha is what `:::color_bars` already
/// used, and it darkens the panel's own tint instead of replacing it —
/// so a groove reads as a hole in THIS panel on every panel.
const TRACK_COLOR: [4]f32 = .{ 0.0, 0.0, 0.0, 0.46 };
const TRACK_FILL_COLOR: [4]f32 = .{ 0.45, 0.72, 1.0, 1.0 };
const THUMB_COLOR: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
const THUMB_RADIUS: f32 = 7;
const TRACK_THICKNESS: f32 = 4;

/// The ruled notches along the track, and how far in from each end they
/// fade out. Ported from `:::trackball`'s dial, where Chris asked for
/// them: "the notches on the sliders are incredible. Could you add those
/// to the regular sliders."
const NOTCH_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.20 };
const NOTCH_STEP: f32 = 7.0;
const NOTCH_EDGE: f32 = 0.035;
/// How tall the notch band is, as a fraction of the groove. Short of
/// full height so the groove still reads as a channel with marks in it
/// rather than a hatched bar.
const NOTCH_INSET: f32 = 0.22;
/// Segments in the thumb's fan. It is 14px across; 28 is a tenth of a
/// pixel of chord error and costs nothing.
const THUMB_SEGMENTS: usize = 28;
/// The groove is taller than the coloured fill, so the fill sits IN a
/// channel. Track thickness plus this, split either side.
const GROOVE_PAD: f32 = 2.0;

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 240;
    const w = c.width.resolve(max_w, fallback_w);
    const h = c.height;

    // Track sits centred vertically inside the component's box,
    // padded on each side so the thumb at extremes doesn't clip
    // past the box edge.
    const thumb_pad = THUMB_RADIUS;
    const track_y = origin[1] + (h - TRACK_THICKNESS) * 0.5;
    const track_x = origin[0] + thumb_pad;
    const track_w = w - 2 * thumb_pad;

    // ── A channel with marks in it, all in the TRIANGLE layer ──
    //
    // Two reasons it is triangles rather than the rounded quads this
    // used to be, and both are about what the quad pipeline cannot do.
    //
    // The renderer draws the whole triangle layer beneath the whole quad
    // layer, so a quad track under a triangle shadow would put the
    // shadow behind the surface it falls on. And a `radius = size / 2`
    // quad is a circle exactly inscribed in its own rect, so the outer
    // half of its anti-aliasing band falls outside the rasterised area
    // and is lost — which is why this thumb used to come out with a flat
    // cap. `relief.disc` keeps the band in the geometry.
    const groove_y = track_y - GROOVE_PAD * 0.5;
    const groove_h = TRACK_THICKNESS + GROOVE_PAD;
    try relief.rect(out, lc, track_x, groove_y, track_w, groove_h, c.track_color);

    // Track-filled (left of thumb, bright). Visualises the current
    // value at a glance — the slider reads as "this much of the
    // range is selected."
    const t = normalised(c);
    const fill_w = track_w * t;
    if (fill_w > 0) {
        try relief.rect(out, lc, track_x, track_y, fill_w, TRACK_THICKNESS, c.fill_color);
    }

    // Notches, over the fill as well as the empty track: a ruler is
    // uniform along its length, and drawing them only on the unfilled
    // part turns the scale into a second progress bar. Faded toward
    // both ends so they sink into the recess instead of stopping dead
    // against the lip.
    const notch_y = groove_y + groove_h * NOTCH_INSET;
    const notch_h = groove_h * (1.0 - NOTCH_INSET * 2.0);
    if (notch_h > 0.5 and track_w > NOTCH_STEP) {
        var nx = track_x + NOTCH_STEP;
        while (nx < track_x + track_w - 1) : (nx += NOTCH_STEP) {
            const u = (nx - track_x) / track_w;
            const fade = relief.edgeFade(u, NOTCH_EDGE);
            if (fade <= 0.01) continue;
            try relief.hairlineV(out, lc, nx, notch_y, notch_h, 1.0, .{
                c.notch_color[0],
                c.notch_color[1],
                c.notch_color[2],
                c.notch_color[3] * fade,
            });
        }
    }


    // The cut-out last, so the lip's shadow falls across the notches and
    // the fill that lie down inside it.
    //
    // `ends = false`, like `:::color_bars`. One light from above means
    // the lip that occludes anything is the TOP one; the left and right
    // walls of a horizontal channel face sideways and catch it equally,
    // so darkening both read as a vignette rather than as depth. Chris:
    // "at the left hand and right hand edges, they are darkened in the
    // notches, but I'm not sure it should be on the right - it should be
    // more like your vertical primary bars."
    try relief.groove(out, lc, track_x, groove_y, track_w, groove_h, false);

    // Thumb. Stable size; centred on the track at `value`.
    const thumb_cx = track_x + fill_w;
    const thumb_cy = track_y + TRACK_THICKNESS * 0.5;
    try relief.disc(out, lc, .{ thumb_cx, thumb_cy }, THUMB_RADIUS, c.thumb_color, THUMB_SEGMENTS);

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = 0,
    };
    c.last_box = box;
    return box;
}

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_raw: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const state: *state_mod.State = @ptrCast(@alignCast(state_raw));

    switch (event) {
        .mouse_down => |m| try applyDrag(c, state, m.local[0]),
        .mouse_move => |m| if (m.button_down) try applyDrag(c, state, m.local[0]),
        .mouse_up => {},
        // Keyboard / focus channels (stage 13c) — sliders don't take
        // focus; ignore.
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

fn applyDrag(c: *Component, state: *state_mod.State, local_x: f32) !void {
    if (c.target.len == 0) return; // no path → noop

    const thumb_pad = THUMB_RADIUS;
    const track_w = c.last_box.w - 2 * thumb_pad;
    if (track_w <= 0) return;

    const t = std.math.clamp((local_x - thumb_pad) / track_w, 0.0, 1.0);
    const new_value = c.min + t * (c.max - c.min);
    c.value = new_value;

    // Format as a short decimal — float→string is the boundary
    // between our typed state internals and the string-only Spec
    // surface. Two decimal places is enough granularity for
    // typical slider ranges; targets that need more precision can
    // be widened later.
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{new_value}) catch return;
    try state.set(c.target, s);
}

fn normalised(c: *const Component) f32 {
    if (c.max == c.min) return 0;
    const t = (c.value - c.min) / (c.max - c.min);
    return std.math.clamp(t, 0.0, 1.0);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Component.fromSpec: defaults" {
    const spec: components.Spec = .{ .name = "slider" };
    const c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    try testing.expectEqual(@as(f32, 0), c.min);
    try testing.expectEqual(@as(f32, 1), c.max);
    try testing.expectEqual(@as(f32, 0.5), c.value); // midpoint
    try testing.expectEqualStrings("", c.target);
}

test "Component.fromSpec: full attrs" {
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "box_radius" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "30" },
        .{ .key = "value", .value = "12" },
        .{ .key = "width", .value = "300" },
        .{ .key = "height", .value = "32" },
    };
    const spec: components.Spec = .{ .name = "slider", .attrs = &attrs };
    const c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    try testing.expectEqualStrings("box_radius", c.target);
    try testing.expectEqual(@as(f32, 0), c.min);
    try testing.expectEqual(@as(f32, 30), c.max);
    try testing.expectEqual(@as(f32, 12), c.value);
    try testing.expectEqual(@as(f32, 32), c.height);
}

test "applyDrag clamps and writes to state" {
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "x" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "10" },
    };
    const spec: components.Spec = .{ .name = "slider", .attrs = &attrs };
    var c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    c.last_box = .{ .x = 0, .y = 0, .w = 100, .h = 28 };

    // Drag to track midpoint: track_w = 100 - 2*7 = 86, midpoint x =
    // 7 + 43 = 50. Value = 0 + 0.5 * 10 = 5.
    try applyDrag(&c, &st, 50);
    try testing.expectEqualStrings("5.00", st.get("x").?);

    // Below track → clamps to min.
    try applyDrag(&c, &st, -100);
    try testing.expectEqualStrings("0.00", st.get("x").?);

    // Above track → clamps to max.
    try applyDrag(&c, &st, 9999);
    try testing.expectEqualStrings("10.00", st.get("x").?);
}

test "applyDrag with empty target is a no-op" {
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();

    const spec: components.Spec = .{ .name = "slider" };
    var c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    c.last_box = .{ .x = 0, .y = 0, .w = 100, .h = 28 };

    try applyDrag(&c, &st, 50);
    try testing.expect(st.get("") == null);
}

test "slider: the palette is configurable, and defaults hold when unsaid" {
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "x" },
        .{ .key = "color", .value = "#ff0000" },
        .{ .key = "thumb", .value = "#00ff00" },
    };
    const spec: components.Spec = .{ .name = "slider", .attrs = &attrs };
    const c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);

    try testing.expectApproxEqAbs(@as(f32, 1), c.fill_color[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fill_color[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), c.thumb_color[1], 1e-6);
    // Unsaid ones keep the built-in look rather than going magenta or
    // transparent — a document should be able to set one and mean one.
    try testing.expectEqual(TRACK_COLOR, c.track_color);
    try testing.expectEqual(NOTCH_COLOR, c.notch_color);
}

test "slider: a reactive re-render carrying only `value` keeps the palette" {
    // The common case: `value=${state.x}` fires an update every frame of
    // a drag, and its spec is the FULL attribute list — but a document
    // that omits the colours must not have them reset out from under it.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "x" },
        .{ .key = "track", .value = "#123456" },
    };
    const spec: components.Spec = .{ .name = "slider", .attrs = &attrs };
    var c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    const set = c.track_color;
    try testing.expect(set[2] > set[0]); // Rule 1: it really took

    const only_value = [_]components.Attr{.{ .key = "value", .value = "0.5" }};
    const next: components.Spec = .{ .name = "slider", .attrs = &only_value };
    try c.ingest(&next);
    try testing.expectEqual(set, c.track_color);
}

test "slider: a palette change invalidates the retained cache" {
    // `contentVersion` used to be the value alone, so a colour driven by
    // state re-rendered into a cached ancestor that never re-walked —
    // the same trap the `disable_cache` note above is about.
    const attrs = [_]components.Attr{.{ .key = "target", .value = "x" }};
    const spec: components.Spec = .{ .name = "slider", .attrs = &attrs };
    var c = try Component.fromSpec(testing.allocator, &spec);
    defer testing.allocator.free(c.target);
    const v0 = contentVersion(@ptrCast(&c));

    const recolour = [_]components.Attr{.{ .key = "color", .value = "#abcdef" }};
    const next: components.Spec = .{ .name = "slider", .attrs = &recolour };
    try c.ingest(&next);
    try testing.expect(contentVersion(@ptrCast(&c)) != v0);

    // And re-ingesting the SAME colour does not churn the version, or
    // every frame would look like a change and defeat the cache.
    const v1 = contentVersion(@ptrCast(&c));
    try c.ingest(&next);
    try testing.expectEqual(v1, contentVersion(@ptrCast(&c)));
}
