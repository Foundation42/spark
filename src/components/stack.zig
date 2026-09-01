//! `:::stack` — one bar, several coloured segments, in proportion.
//!
//! Attribute grammar:
//!
//!     :::stack {values="${state.p_sim},${state.p_trav},${state.p_post}"
//!               colors="#5b9bf8,#e8873a,#f87171" height=12}
//!     :::
//!
//! - `values` (required) — comma-separated numbers. Non-numeric and
//!   negative entries read as zero.
//! - `colors` (optional) — comma-separated, one per value. A short list
//!   repeats; an empty one falls back to a built-in wheel.
//! - `total`  (optional) — the width the segments are measured against.
//!   Default: their SUM, which makes the bar always full. Give it
//!   something else — a frame budget — and the bar shows headroom.
//! - `height` / `width` / `gap` / `radius` (optional) — geometry.
//!
//! ## Why the values are one attribute and not a body
//!
//! Because a component's BODY is not interpolated. `preprocess` substitutes
//! `${state.x}` in attribute values and preserves the body verbatim — which
//! is the right split (a body is content, and `:::chart`'s is data it parses
//! itself) and does mean a live series has to arrive through attrs.
//!
//! One attribute rather than `v0..v7` because a stack's whole job is the
//! PROPORTION between its parts, and a grammar that lets a document declare
//! six of eight parts is a grammar that draws a lie. A single list is either
//! right or obviously wrong.
//!
//! ## What it is for, and what it is not
//!
//! It answers "what is this whole made of" in one glance — the shape you
//! read before you read any number. `hud/perf.md` puts one above its eight
//! pass rows: the segments and the rows share a colour, so a fat orange
//! band sends you to `traversal` without reading a single figure.
//!
//! It is NOT a chart of anything over time (`:::chart`) and NOT a reading of
//! one quantity against a scale (`:::meter`). A stack has no y-axis and no
//! history; it has parts and a whole.
//!
//! ## Drawn as quads
//!
//! Unlike `:::meter`, whose track has recess shading beneath its fill and
//! therefore has to be triangles. A stack's segments never overlap anything,
//! so they take `quad.frag`'s rounded corners and anti-aliasing instead.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    StackMissingValues,
    StackNotInstalled,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("stack", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

/// As many segments as a stack will draw. Eight covers the GPU passes,
/// which is what this was built for; past it the tail is dropped rather
/// than crammed, because a segment under a pixel is not information.
pub const MAX_SEGMENTS = 16;

/// The fallback palette, when a document names no colours. Ordered so
/// neighbours differ in hue AND lightness — adjacent segments in a stack
/// touch, and two colours that differ only in hue read as one band to
/// anyone who does not separate reds from greens.
pub const WHEEL = [_][4]f32{
    .{ 0.36, 0.61, 0.97, 1.0 }, // blue
    .{ 0.91, 0.53, 0.23, 1.0 }, // orange
    .{ 0.29, 0.87, 0.50, 1.0 }, // green
    .{ 0.88, 0.63, 0.13, 1.0 }, // amber
    .{ 0.93, 0.28, 0.60, 1.0 }, // pink
    .{ 0.65, 0.55, 0.98, 1.0 }, // violet
    .{ 0.20, 0.77, 0.75, 1.0 }, // teal
    .{ 0.97, 0.44, 0.44, 1.0 }, // red
};

/// Parse a comma-separated list of numbers into `out`, returning how many
/// landed. Blanks and unparseable entries become zero rather than being
/// skipped, so a value keeps its POSITION — and therefore its colour — when
/// the path behind it has not published yet.
pub fn parseValues(text: []const u8, out: []f32) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |tok| {
        if (n >= out.len) break;
        const v = std.fmt.parseFloat(f32, std.mem.trim(u8, tok, " \t\r\n")) catch 0;
        out[n] = if (std.math.isFinite(v) and v > 0) v else 0;
        n += 1;
    }
    return n;
}

/// Parse a comma-separated colour list. Short lists REPEAT rather than
/// leaving segments uncoloured — running out of colours should degrade to
/// an ambiguous picture, never an invisible one.
pub fn parseColors(text: []const u8, out: [][4]f32) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |tok| {
        if (n >= out.len) break;
        const t = std.mem.trim(u8, tok, " \t\r\n");
        if (t.len == 0) continue;
        out[n] = box_helpers.parseColor(t) orelse WHEEL[n % WHEEL.len];
        n += 1;
    }
    return n;
}

pub fn colorAt(i: usize, named: []const [4]f32) [4]f32 {
    if (named.len == 0) return WHEEL[i % WHEEL.len];
    return named[i % named.len];
}

/// The denominator the segments are measured against.
///
/// `total` when the document named one and it is usable, the SUM otherwise.
/// Defaulting to the sum makes the bar always full, which is right for "what
/// is this whole made of"; naming a total instead shows headroom, which is
/// right for "how much of the budget is spent". A `total` smaller than the
/// sum would draw past the end, so it is raised to the sum — the segments
/// are the truth and the budget is the annotation.
pub fn denominatorFor(values: []const f32, total: f32) f32 {
    var sum: f32 = 0;
    for (values) |v| sum += v;
    if (total > 0 and total > sum) return total;
    return sum;
}

const Component = struct {
    allocator: std.mem.Allocator,
    values: [MAX_SEGMENTS]f32 = @splat(0),
    n: usize = 0,
    colors: [MAX_SEGMENTS][4]f32 = @splat(.{ 0, 0, 0, 1 }),
    n_colors: usize = 0,
    total: f32 = 0,
    height: f32 = HEIGHT,
    width: ?box_helpers.Length = null,
    gap: f32 = GAP,
    radius: f32 = RADIUS,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        var saw_values = false;
        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "values")) {
                self.n = parseValues(attr.value, &self.values);
                saw_values = true;
            } else if (std.mem.eql(u8, attr.key, "colors")) {
                self.n_colors = parseColors(attr.value, &self.colors);
            } else if (std.mem.eql(u8, attr.key, "total")) {
                self.total = std.fmt.parseFloat(f32, std.mem.trim(u8, attr.value, " \t")) catch 0;
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| self.height = switch (l) {
                    .pixels => |p| p,
                    else => self.height,
                };
            } else if (std.mem.eql(u8, attr.key, "gap")) {
                if (box_helpers.parseLength(attr.value)) |l| self.gap = switch (l) {
                    .pixels => |p| @max(0, p),
                    else => self.gap,
                };
            } else if (std.mem.eql(u8, attr.key, "radius")) {
                if (box_helpers.parseLength(attr.value)) |l| self.radius = switch (l) {
                    .pixels => |p| @max(0, p),
                    else => self.radius,
                };
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            }
        }
        if (!saw_values and self.n == 0) return Error.StackMissingValues;
        self.version +%= 1;
    }
};

fn create(_: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{ .allocator = allocator };
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

const HEIGHT: f32 = 12;
/// Between segments. A hairline, so the bar still reads as one object.
const GAP: f32 = 1.5;
const RADIUS: f32 = 2;
/// The empty remainder when a `total` leaves headroom — the same neutral
/// darkening every recessed thing in this vocabulary uses.
const REST: [4]f32 = .{ 0, 0, 0, 0.42 };
/// Space under the bar, so a stack sitting above a run of meter rows does
/// not touch the first of them.
const PAD_BOTTOM: f32 = 6;

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const fallback: f32 = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320;
    const w: f32 = if (c.width) |ww| ww.resolve(constraints.max_w, fallback) else fallback;
    const x = @round(origin[0]);
    const y = @round(origin[1]);

    const values = c.values[0..c.n];
    const denom = denominatorFor(values, c.total);

    // The empty track first, so headroom shows when a `total` was named and
    // nothing shows when it was not (the segments cover it exactly).
    try out.appendQuad(lc, .{
        .dst_pos = .{ x, y },
        .dst_size = .{ w, c.height },
        .color = REST,
        .radius = c.radius,
    });

    if (denom > 0) {
        var cursor: f32 = x;
        for (values, 0..) |v, i| {
            const seg_w = (v / denom) * w;
            // A segment narrower than a pixel is dropped rather than
            // rounded up: rounding every crumb to 1px makes eight tiny
            // passes add up to visible width and pushes the big one off
            // the end, which is the lie a proportion bar must not tell.
            if (seg_w < 1) {
                cursor += seg_w;
                continue;
            }
            const draw_w = @max(1, seg_w - c.gap);
            try out.appendQuad(lc, .{
                .dst_pos = .{ @round(cursor), y },
                .dst_size = .{ draw_w, c.height },
                .color = colorAt(i, c.colors[0..c.n_colors]),
                .radius = c.radius,
            });
            cursor += seg_w;
        }
    }

    return .{ .x = origin[0], .y = origin[1], .w = w, .h = c.height + PAD_BOTTOM, .baseline = y + c.height };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "stack: a value that has not published yet keeps its place" {
    // Blanks become zero rather than being skipped. A skipped entry would
    // shift every later value one position left — and therefore into the
    // wrong COLOUR, so the row it is meant to match below would point at a
    // different band. Silent, and exactly the kind of wrong a proportion
    // bar must not be.
    var v: [MAX_SEGMENTS]f32 = @splat(-1);
    try testing.expectEqual(@as(usize, 4), parseValues("1,,3,x", &v));
    try testing.expectEqual(@as(f32, 1), v[0]);
    try testing.expectEqual(@as(f32, 0), v[1]);
    try testing.expectEqual(@as(f32, 3), v[2]);
    try testing.expectEqual(@as(f32, 0), v[3]);
}

test "stack: negative and non-finite values read as zero" {
    // A proportion cannot be negative, and a segment of negative width
    // would wind the geometry backwards over its neighbour.
    var v: [MAX_SEGMENTS]f32 = @splat(-1);
    _ = parseValues("-5, 2, inf, nan", &v);
    try testing.expectEqual(@as(f32, 0), v[0]);
    try testing.expectEqual(@as(f32, 2), v[1]);
    try testing.expectEqual(@as(f32, 0), v[2]);
    try testing.expectEqual(@as(f32, 0), v[3]);
}

test "stack: more values than segments drops the tail, not the head" {
    var v: [MAX_SEGMENTS]f32 = @splat(0);
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    for (0..MAX_SEGMENTS + 5) |i| {
        const s = std.fmt.bufPrint(buf[w..], "{d},", .{i + 1}) catch break;
        w += s.len;
    }
    const n = parseValues(buf[0..w], &v);
    try testing.expectEqual(@as(usize, MAX_SEGMENTS), n);
    try testing.expectEqual(@as(f32, 1), v[0]);
}

test "stack: no total means the bar is exactly full" {
    // "What is this whole made of" — the default, and the segments cover
    // the track so no empty remainder shows.
    const v = [_]f32{ 1, 2, 3 };
    try testing.expectEqual(@as(f32, 6), denominatorFor(&v, 0));
}

test "stack: a total larger than the sum shows headroom" {
    const v = [_]f32{ 1, 2, 3 };
    try testing.expectEqual(@as(f32, 10), denominatorFor(&v, 10));
}

test "stack: a total SMALLER than the sum is raised to it" {
    // Otherwise the segments draw past the end of their own track. The
    // segments are the measurement and the budget is the annotation, so
    // when they disagree the measurement wins — an overspent budget shows
    // as a full bar, which is true, rather than as a bar overflowing its
    // box, which is a rendering artefact pretending to be information.
    const v = [_]f32{ 5, 5, 5 };
    try testing.expectEqual(@as(f32, 15), denominatorFor(&v, 10));
}

test "stack: colours repeat rather than running out" {
    // Degrade to an ambiguous picture, never an invisible one.
    var cols: [MAX_SEGMENTS][4]f32 = @splat(.{ 0, 0, 0, 1 });
    const n = parseColors("#ff0000,#00ff00", &cols);
    try testing.expectEqual(@as(usize, 2), n);
    const named = cols[0..n];
    try testing.expectEqual(named[0], colorAt(0, named));
    try testing.expectEqual(named[1], colorAt(1, named));
    try testing.expectEqual(named[0], colorAt(2, named)); // wraps
}

test "stack: no colours at all falls back to the wheel" {
    const none: []const [4]f32 = &.{};
    try testing.expectEqual(WHEEL[0], colorAt(0, none));
    try testing.expectEqual(WHEEL[1], colorAt(1, none));
    try testing.expectEqual(WHEEL[0], colorAt(WHEEL.len, none));
}

test "stack: an all-zero series draws no segments rather than dividing by it" {
    // Every path unpublished, which is a freshly mounted panel.
    const v = [_]f32{ 0, 0, 0 };
    try testing.expectEqual(@as(f32, 0), denominatorFor(&v, 0));
}
