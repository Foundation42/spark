//! `::sparkline` — inline data-series glyph (stage 15E.3).
//!
//! A small bar-chart that flows inline with text, sized to fit the
//! surrounding line. Exercises the stage-15E inline_object substrate
//! beyond `::badge`: tall-but-not-text intrinsic metrics + data-driven
//! geometry + state-substitutable `data=` attribute.
//!
//! Attribute grammar:
//!
//!     ::sparkline {data="3,5,7,4,8,6,9" color=cyan width=80 height=14}
//!
//! - `data` (required) — comma-separated numbers. Whitespace tolerated.
//!   Non-numeric tokens silently dropped. Brackets are optional —
//!   `[3, 5, 7]` is the rill literal, and the same wire form `:::curve`
//!   reads and writes — so `data=${state.series}` draws an array a plane
//!   published without the ends being eaten as `[3` and `7]`.
//! - `color` (optional) — bar fill. Named or `#RRGGBB`. Default: accent
//!   blue that reads on the dark editor background.
//! - `width` (optional) — pixel literal. Default 80.
//! - `height` (optional) — pixel literal. Default 14 (≈ one body em
//!   on the demo theme).
//!
//! Visual: bars from 0 to max(data), uniformly spaced across the box.
//! Each bar is `(width - gap*(N-1)) / N` wide with a 1px inter-bar
//! gap. Zero-valued bars still draw a 1px stub so the slot is
//! visible. Min-max baseline (instead of 0..max) deferred until a
//! component genuinely needs it.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const box_helpers = @import("box.zig"); // reuse parseColor + parseLength
const curve = @import("curve.zig"); // the array-on-the-wire parser

pub const Error = error{
    SparklineMissingData,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("sparkline", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

// ── Component state ────────────────────────────────────────────────

const Component = struct {
    allocator: std.mem.Allocator,
    /// Parsed data series. Owned. Re-allocated on every update so
    /// the slice is contiguous (cheap on the small N a sparkline
    /// carries — typically 5-30 samples).
    data: []f32,
    color: [4]f32,
    width: f32,
    height: f32,
    /// Bumped on every spec ingest so the retained layout cache
    /// picks up data / color / size changes on the next walk.
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var data_raw: ?[]const u8 = null;
        var color = self.color;
        var width = self.width;
        var height = self.height;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "data")) {
                data_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| color = c;
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| width = switch (l) {
                    .pixels => |p| p,
                    else => width,
                };
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| height = switch (l) {
                    .pixels => |p| p,
                    else => height,
                };
            }
        }

        const raw = data_raw orelse return Error.SparklineMissingData;
        const parsed = try parseData(a, raw);
        a.free(self.data);
        self.data = parsed;
        self.color = color;
        self.width = width;
        self.height = height;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .data = try allocator.alloc(f32, 0),
        .color = DEFAULT_COLOR,
        .width = 80,
        .height = 14,
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
    allocator.free(c.data);
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

const DEFAULT_COLOR: [4]f32 = .{ 0.40, 0.68, 0.95, 1.0 };
const BAR_GAP_PX: f32 = 1.0;
const MIN_BAR_HEIGHT_PX: f32 = 1.0;

// ── Data parsing ───────────────────────────────────────────────────

/// Parse `"3, 5, 7, 4, 8"` into `[3,5,7,4,8]`. Non-numeric tokens
/// drop silently — sparkline content is summary data, not source
/// code; a stray token shouldn't crash the parse. Whitespace
/// around values is tolerated.
fn parseData(allocator: std.mem.Allocator, raw: []const u8) ![]f32 {
    // One spelling of an array for every span that draws one. `:::curve`
    // owns it because it is the span that also WRITES the form back.
    return curve.parseArray(allocator, raw);
}

// ── Inline measure (wrap pass) ─────────────────────────────────────

fn measureInline(
    ctx: *anyopaque,
    em_px: f32,
    lc: *element.LayoutCtx,
) anyerror!element.IntrinsicMetrics {
    _ = em_px;
    _ = lc;
    const c: *const Component = @ptrCast(@alignCast(ctx));
    // Sparkline sits on the baseline like a tall capital letter —
    // ascender = full height, descender = 0. Caller's line-height
    // resolve takes max(font_ascender, sparkline.ascender), so when
    // height > ascender the line box grows just enough to fit.
    return .{
        .width = c.width,
        .ascender = c.height,
        .descender = 0,
    };
}

// ── Inline paint ───────────────────────────────────────────────────

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    _ = constraints;
    const c: *const Component = @ptrCast(@alignCast(ctx));

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = c.width,
        .h = c.height,
        .baseline = origin[1] + c.height,
    };

    if (c.data.len == 0) return box;

    // Max for normalisation. 0..max scale — sparklines reading
    // "this much of the way to peak" is the canonical meaning.
    var max: f32 = 0;
    for (c.data) |v| {
        if (v > max) max = v;
    }
    if (max <= 0) return box; // all-zero series → no bars to draw

    const n: f32 = @floatFromInt(c.data.len);
    const total_gap = BAR_GAP_PX * @max(n - 1, 0);
    const bar_w: f32 = @max((c.width - total_gap) / n, 1.0);

    var i: usize = 0;
    while (i < c.data.len) : (i += 1) {
        const v = if (c.data[i] < 0) 0 else c.data[i];
        const fi: f32 = @floatFromInt(i);
        const x = origin[0] + fi * (bar_w + BAR_GAP_PX);

        // Bar height proportional to value; bottom-anchored so the
        // bars grow upward from the box's baseline. Empty-but-not-
        // missing values get a 1px stub so the slot stays visible.
        const ratio = v / max;
        var bar_h: f32 = c.height * ratio;
        if (v > 0 and bar_h < MIN_BAR_HEIGHT_PX) bar_h = MIN_BAR_HEIGHT_PX;
        const y = origin[1] + c.height - bar_h;

        try out.appendQuad(lc, .{
            .dst_pos = .{ x, y },
            .dst_size = .{ bar_w, bar_h },
            .color = c.color,
            .radius = 0,
        });
    }

    return box;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "parseData: comma-separated numbers" {
    const a = testing.allocator;
    const out = try parseData(a, "3,5,7,4,8");
    defer a.free(out);
    try testing.expectEqual(@as(usize, 5), out.len);
    try testing.expectEqual(@as(f32, 3), out[0]);
    try testing.expectEqual(@as(f32, 8), out[4]);
}

test "parseData: whitespace and empty tokens tolerated" {
    const a = testing.allocator;
    const out = try parseData(a, " 1 , , 2 ,  3.5 ");
    defer a.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(f32, 1), out[0]);
    try testing.expectEqual(@as(f32, 2), out[1]);
    try testing.expectEqual(@as(f32, 3.5), out[2]);
}

test "parseData: a bracketed rill literal parses the same as a bare list" {
    // `[3, 5, 7]` used to lose both ends — `[3` and `7]` are not numbers
    // and dropped silently — so a series bound straight from the plane
    // drew two bars short and nobody could say which two.
    const a = testing.allocator;
    const lit = try parseData(a, "[3, 5, 7]");
    defer a.free(lit);
    const bare = try parseData(a, "3,5,7");
    defer a.free(bare);
    try testing.expectEqualSlices(f32, bare, lit);
    try testing.expectEqual(@as(usize, 3), lit.len);
}

test "parseData: non-numeric tokens silently dropped" {
    const a = testing.allocator;
    const out = try parseData(a, "1,foo,2,bar,3");
    defer a.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
}

test "Component.ingest: stores data + defaults" {
    const attrs = [_]components.Attr{
        .{ .key = "data", .value = "1,2,3,4" },
    };
    const spec: components.Spec = .{ .name = "sparkline", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(usize, 4), c.data.len);
    try testing.expectEqual(@as(f32, 80), c.width);
    try testing.expectEqual(@as(f32, 14), c.height);
}

test "Component: missing data rejected" {
    const spec: components.Spec = .{ .name = "sparkline" };
    try testing.expectError(Error.SparklineMissingData, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
