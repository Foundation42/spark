//! `::kbd` — keyboard-key chrome inline component (stage 15E.4).
//!
//! Renders a key-like chip with the surrounding line: subtle border,
//! a faux bottom shadow stripe for the raised-cap feel, mono label
//! inside. Reads beautifully in technical prose ("press ::kbd{key=
//! \"Ctrl+C\"} to copy").
//!
//! Attribute grammar:
//!
//!     ::kbd {key="Ctrl+C"}
//!     ::kbd {key="Esc" color=red}
//!
//! - `key` (required) — text rendered inside the chip.
//! - `color` (optional) — accent override. Default: a neutral
//!   key-grey that reads on dark backgrounds.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    KbdMissingKey,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("kbd", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    /// Optional accent (border + shadow lerp toward this). Null
    /// falls back to the neutral palette.
    accent: ?[4]f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var key_raw: ?[]const u8 = null;
        var accent = self.accent;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "key")) {
                key_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                accent = box_helpers.parseColor(attr.value);
            }
        }

        const k = key_raw orelse return Error.KbdMissingKey;
        const new_key = try a.dupe(u8, k);
        a.free(self.key);
        self.key = new_key;
        self.accent = accent;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .key = try allocator.dupe(u8, ""),
        .accent = null,
    };
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.key);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .measure_inline = measureInline,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Visual constants ───────────────────────────────────────────────

const PAD_X_EM: f32 = 0.40;
const PAD_Y_EM: f32 = 0.08;
const SHADOW_PX: f32 = 1.5;

const FILL_COLOR: [4]f32 = .{ 0.16, 0.18, 0.22, 1.0 };
const BORDER_COLOR: [4]f32 = .{ 0.42, 0.46, 0.54, 1.0 };
const SHADOW_COLOR: [4]f32 = .{ 0.22, 0.25, 0.30, 1.0 };
const LABEL_COLOR: [4]f32 = .{ 0.92, 0.95, 1.0, 1.0 };

const BORDER_PX: f32 = 1.0;

/// Mono / code-inline cascade for the label — gives the chip the
/// "this is a literal key" reading without us threading custom
/// font setup.
fn labelStyle(theme: *const element.Theme) element.Style {
    return theme.applyCodeInline(theme.body);
}

const Geometry = struct {
    text_w: f32,
    pad_x: f32,
    pad_y: f32,
    ascender: f32,
    descender: f32,
    width: f32,
    height: f32,
};

fn computeGeometry(
    label: []const u8,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun } {
    const style = labelStyle(lc.theme);
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, label);

    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));
    const pad_x = em * PAD_X_EM;
    const pad_y = em * PAD_Y_EM;

    const m = lc.fonts.metrics(style.font_id);
    const desc_abs = -m.descender;

    // Ascender bumps by pad_y + SHADOW_PX so the chip's top edge
    // sits above where a plain label would land. Descender includes
    // the same shadow allowance below baseline.
    const asc = m.ascender + pad_y;
    const desc = desc_abs + pad_y + SHADOW_PX;
    return .{
        .geom = .{
            .text_w = text_w,
            .pad_x = pad_x,
            .pad_y = pad_y,
            .ascender = asc,
            .descender = desc,
            .width = text_w + 2 * pad_x,
            .height = asc + desc,
        },
        .run = run,
    };
}

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = em_px;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const g = (try computeGeometry(c.key, lc, arena.allocator())).geom;
    return .{
        .width = g.width,
        .ascender = g.ascender,
        .descender = g.descender,
    };
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    _ = constraints;
    const c: *const Component = @ptrCast(@alignCast(ctx));

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();

    const result = try computeGeometry(c.key, lc, arena.allocator());
    const g = result.geom;
    const run = result.run;

    // Pick border + shadow colours. With an accent set, lerp the
    // neutral border halfway toward the accent for a tinted chip;
    // shadow stays neutral so the raised-key reading holds.
    const border_color: [4]f32 = if (c.accent) |a| .{
        (BORDER_COLOR[0] + a[0]) * 0.5,
        (BORDER_COLOR[1] + a[1]) * 0.5,
        (BORDER_COLOR[2] + a[2]) * 0.5,
        1.0,
    } else BORDER_COLOR;

    const cap_h = g.height - SHADOW_PX;

    // Shadow stripe (bottom). Drawn first so the cap sits on top.
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] + SHADOW_PX },
        .dst_size = .{ g.width, g.height - SHADOW_PX },
        .color = SHADOW_COLOR,
        .radius = 3,
    });

    // Border (cap, outer).
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ g.width, cap_h },
        .color = border_color,
        .radius = 3,
    });

    // Fill (cap, inset by border thickness).
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + BORDER_PX, origin[1] + BORDER_PX },
        .dst_size = .{ g.width - 2 * BORDER_PX, cap_h - 2 * BORDER_PX },
        .color = FILL_COLOR,
        .radius = @max(0, 3 - BORDER_PX),
    });

    // Label — centred horizontally, baseline-aligned vertically.
    const style = labelStyle(lc.theme);
    const baseline_y = origin[1] + g.ascender;
    const text_x = origin[0] + (g.width - g.text_w) * 0.5;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        run,
        style.font_id,
        text_x,
        baseline_y,
        LABEL_COLOR,
        style.hot_color,
        0,
        lc.zoom,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = g.width,
        .h = g.height,
        .baseline = baseline_y,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "Component.ingest: stores key + accent" {
    const attrs = [_]components.Attr{
        .{ .key = "key", .value = "Ctrl+C" },
        .{ .key = "color", .value = "red" },
    };
    const spec: components.Spec = .{ .name = "kbd", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("Ctrl+C", c.key);
    try testing.expect(c.accent != null);
}

test "Component: missing key rejected" {
    const spec: components.Spec = .{ .name = "kbd" };
    try testing.expectError(Error.KbdMissingKey, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
