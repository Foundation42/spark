//! `::value` — a live readout in running prose.
//!
//! The smallest possible inline component: it renders one attribute as
//! text on the surrounding line, and it exists because a bound
//! attribute is the only thing spark's reactivity can reach.
//!
//! **The gap it closes.** `${state.x}` substitutes into component
//! ATTRIBUTES and not into body text, so a document full of controls
//! could not say what any of them were set to. `demos/hud-lab/xray.md`
//! in matryoshka has eighteen buttons and, until this, no way to print
//! which one you last pressed — a first draft tried and rendered the
//! template literally.
//!
//! `::value{text=${state.surf}}` needs no new machinery: the inline
//! directive scanner already turns `::name{attrs}` into an
//! `Element.inline_object`, `substituteState` already runs on attribute
//! values, and `component.Binding` already subscribes to every path a
//! templated attribute mentions and re-fires `update` on a write. All
//! this component adds is a factory whose whole job is to draw the
//! string it was handed.
//!
//! Attribute grammar:
//!
//!     ::value {text="42" style=code color=#ffcc00}
//!
//! - `text` (required) — the string to draw. Empty is legal and draws
//!   nothing; MISSING is an error, so `::value{}` surfaces as the
//!   inline fallback rather than as an invisible gap.
//! - `style` (optional) — which of the theme's inline styles to wear:
//!   `body` (default), `code`, `strong`/`bold`, `em`/`emphasis`.
//! - `color` (optional) — override the style's colour. Named or hex,
//!   via `box.parseColor`.
//!
//! **Why it is not `::badge`.** A badge draws a pill and is a label
//! ABOUT the prose; a value is part of the sentence. It takes the
//! theme's own styles and adds no chrome of its own, so a readout in
//! the middle of a line reads as a word rather than as a widget.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig"); // reuse parseColor

pub const Error = error{
    ValueMissingText,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("value", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

/// Which of the theme's inline styles the text wears. Deliberately the
/// same four the markdown cascade itself can produce — a readout that
/// could pick an arbitrary font would drift away from the line it sits
/// on, and the point is that it reads as prose.
pub const TextStyle = enum {
    body,
    code,
    strong,
    emphasis,

    pub fn parse(s: []const u8) ?TextStyle {
        if (std.mem.eql(u8, s, "body")) return .body;
        if (std.mem.eql(u8, s, "code") or std.mem.eql(u8, s, "mono")) return .code;
        if (std.mem.eql(u8, s, "strong") or std.mem.eql(u8, s, "bold")) return .strong;
        if (std.mem.eql(u8, s, "em") or std.mem.eql(u8, s, "emphasis") or
            std.mem.eql(u8, s, "italic")) return .emphasis;
        return null;
    }

    /// Resolve against the live theme. Each arm mirrors what the
    /// markdown cascade does for the equivalent inline container, so
    /// `::value{style=code}` and a backtick span land on the same font
    /// and colour.
    pub fn resolve(self: TextStyle, theme: *const element.Theme) element.Style {
        var st = theme.body;
        switch (self) {
            .body => {},
            .code => {
                st.font_id = theme.code_inline_font_id;
                st.color = theme.code_inline_color;
                st.code_inline = true;
            },
            .strong => {
                st.font_id = theme.strong_font_id;
                st.strong = true;
            },
            .emphasis => {
                st.font_id = theme.emphasis_font_id;
                st.emphasis = true;
            },
        }
        return st;
    }
};

// ── Component state ─────────────────────────────────────────────────

const Component = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    style: TextStyle,
    /// Null means "whatever the resolved style says" — an explicit
    /// `color=` is the only thing that overrides the theme, so a
    /// readout follows a theme swap unless the author opted out.
    color_override: ?[4]f32,
    /// Bumped on every spec ingest. This is the whole reason the
    /// component is reactive rather than merely re-fired: the retained
    /// layout cache keys a PARAGRAPH on its children pointer, which
    /// does not move when this text changes, so the paragraph would
    /// replay forever without a version to fold in. See
    /// `layout_cache.aggregateInlineVersions`.
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var text_raw: ?[]const u8 = null;
        var style = self.style;
        var color = self.color_override;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "text")) {
                text_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "style")) {
                if (TextStyle.parse(attr.value)) |s| style = s;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| color = c;
            }
        }

        const text = text_raw orelse return Error.ValueMissingText;
        const new_text = try a.dupe(u8, text);
        a.free(self.text);
        self.text = new_text;
        self.style = style;
        self.color_override = color;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .text = try allocator.dupe(u8, ""),
        .style = .body,
        .color_override = null,
    };
    errdefer allocator.free(c.text);
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.text);
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

// ── Geometry ────────────────────────────────────────────────────────

/// Shared between the wrap pass and the paint pass. Both must agree on
/// width or the line the object was measured into is not the line it
/// gets drawn on.
const Geometry = struct {
    width: f32,
    ascender: f32,
    descender: f32,
};

fn computeGeometry(
    c: *const Component,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun, style: element.Style } {
    const style = c.style.resolve(lc.theme);
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, c.text);

    const fscale = lc.fonts.scale(style.font_id);
    var width: f32 = 0;
    for (run.glyphs) |g| width += g.x_advance * fscale;

    // The line box the readout claims is the FONT's, not the glyphs'.
    // Measuring the drawn ink instead would make a line jump when the
    // value went from "0" to "9" — the whole point is that a live
    // number does not reflow the sentence around it.
    const m = lc.fonts.metrics(style.font_id);
    return .{
        .geom = .{
            .width = width,
            .ascender = m.ascender,
            .descender = -m.descender, // metrics report it negative
        },
        .run = run,
        .style = style,
    };
}

// ── Inline measure (wrap pass) ──────────────────────────────────────

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = em_px;
    const c: *const Component = @ptrCast(@alignCast(ctx));

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();

    const g = (try computeGeometry(c, lc, arena.allocator())).geom;
    return .{
        .width = g.width,
        .ascender = g.ascender,
        .descender = g.descender,
    };
}

// ── Inline paint ────────────────────────────────────────────────────

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

    const result = try computeGeometry(c, lc, arena.allocator());
    const g = result.geom;
    const style = result.style;

    const baseline_y = origin[1] + g.ascender;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        &out.glyph_targets,
        lc.current_target_dispatch_index,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        result.run,
        style.font_id,
        origin[0],
        baseline_y,
        c.color_override orelse style.color,
        style.hot_color,
        style.attention,
        lc.zoom,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = g.width,
        .h = g.ascender + g.descender,
        .baseline = baseline_y,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

/// Rotating spec storage. A single shared `[1]Attr` slot aliases:
/// two specs built back-to-back to be COMPARED end up pointing at the
/// same attr, both reading the second value, and an inequality
/// assertion quietly compares a thing with itself.
var spec_pool: [8][2]components.Attr = undefined;
var spec_next: usize = 0;

fn spec1(key: []const u8, value: []const u8) components.Spec {
    const i = spec_next % spec_pool.len;
    spec_next += 1;
    spec_pool[i][0] = .{ .key = key, .value = value };
    return .{ .name = "value", .id = null, .attrs = spec_pool[i][0..1], .body = "" };
}

fn spec2(k0: []const u8, v0: []const u8, k1: []const u8, v1: []const u8) components.Spec {
    const i = spec_next % spec_pool.len;
    spec_next += 1;
    spec_pool[i][0] = .{ .key = k0, .value = v0 };
    spec_pool[i][1] = .{ .key = k1, .value = v1 };
    return .{ .name = "value", .id = null, .attrs = spec_pool[i][0..2], .body = "" };
}

test "value: create stores the text" {
    const spec = spec1("text", "normal");
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("normal", c.text);
    try testing.expectEqual(TextStyle.body, c.style);
    try testing.expectEqual(@as(?[4]f32, null), c.color_override);
}

test "value: missing text is an error, empty text is not" {
    const empty_spec: components.Spec = .{ .name = "value", .attrs = &.{} };
    try testing.expectError(Error.ValueMissingText, create(&_test_spark, testing.allocator, &empty_spec));

    const spec = spec1("text", "");
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("", c.text);
}

test "value: update replaces the text and bumps the version" {
    const spec = spec1("text", "normal");
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const v0 = contentVersion(inst.ctx);
    const next = spec1("text", "albedo");
    try update(inst.ctx, &next);

    try testing.expectEqualStrings("albedo", c.text);

    // Rule 1: the version has to MOVE, not merely be non-zero. A
    // constant version is exactly the bug — the paragraph holding this
    // object caches on a pointer that never changes, so the version is
    // the only thing that can invalidate it.
    try testing.expect(contentVersion(inst.ctx) != v0);
}

test "value: styles parse, including the aliases" {
    try testing.expectEqual(TextStyle.body, TextStyle.parse("body").?);
    try testing.expectEqual(TextStyle.code, TextStyle.parse("code").?);
    try testing.expectEqual(TextStyle.code, TextStyle.parse("mono").?);
    try testing.expectEqual(TextStyle.strong, TextStyle.parse("bold").?);
    try testing.expectEqual(TextStyle.emphasis, TextStyle.parse("italic").?);
    try testing.expectEqual(@as(?TextStyle, null), TextStyle.parse("shouty"));
}

test "value: style= and color= are ingested" {
    const spec = spec2("text", "42", "style", "code");
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(TextStyle.code, c.style);

    const colored = spec2("text", "42", "color", "#ff0000");
    try update(inst.ctx, &colored);
    try testing.expectEqual(@as(?[4]f32, .{ 1, 0, 0, 1 }), c.color_override);

    // An unparseable colour leaves the previous one alone rather than
    // resetting to the theme — the same policy `::badge` follows.
    const junk = spec2("text", "42", "color", "chartreuse-ish");
    try update(inst.ctx, &junk);
    try testing.expectEqual(@as(?[4]f32, .{ 1, 0, 0, 1 }), c.color_override);
}

test "value: TextStyle.resolve picks the theme's own inline styles" {
    const theme: element.Theme = .{
        .body = .{ .font_id = 1, .color = .{ 1, 1, 1, 1 } },
        .heading = .{element.Style{ .font_id = 2, .color = .{ 1, 1, 1, 1 } }} ** 6,
        .code_block = .{ .font_id = 3, .color = .{ 1, 1, 1, 1 } },
        .list_marker = .{ .font_id = 1, .color = .{ 1, 1, 1, 1 } },
        .emphasis_font_id = 4,
        .strong_font_id = 5,
        .bold_italic_font_id = 6,
        .code_inline_font_id = 7,
    };
    try testing.expectEqual(@as(u32, 1), TextStyle.body.resolve(&theme).font_id);
    try testing.expectEqual(@as(u32, 7), TextStyle.code.resolve(&theme).font_id);
    try testing.expectEqual(theme.code_inline_color, TextStyle.code.resolve(&theme).color);
    try testing.expectEqual(@as(u32, 5), TextStyle.strong.resolve(&theme).font_id);
    try testing.expectEqual(@as(u32, 4), TextStyle.emphasis.resolve(&theme).font_id);
}

test "value: vtable is the inline contract" {
    // An inline_object without `measure_inline` is a construction
    // error at wrap time (`InlineObjectMissingMeasurer`), and without
    // `content_version` it is the stale-paragraph bug.
    try testing.expect(vtable.measure_inline != null);
    try testing.expect(vtable.content_version != null);
}
