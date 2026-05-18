//! `::commit` — git-ref inline chip (session 17). Renders a commit
//! hash in mono, optionally prefixed with `repo@`, on a subtle slate
//! tint. Subtler than `::kbd` (no raised-cap shadow, no border) — it
//! reads like a code span with a hyperlink halo, the way GitHub /
//! Linear style commit refs in prose.
//!
//! Attribute grammar:
//!
//!     ::commit {hash="acf8e7b"}
//!     ::commit {hash="acf8e7b" repo="fdn42/text_engine"}
//!     ::commit {hash="8d6e7a3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9"}
//!
//! - `hash` (required) — full or short hash. Anything longer than 7
//!   characters truncates to the conventional `git log --oneline`
//!   width.
//! - `repo` (optional) — short repo label (e.g. `fdn42/text_engine`).
//!   Renders as `repo@hash`; omitted, the chip is just the hash.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");

pub const Error = error{
    CommitMissingHash,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("commit", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Composed render text: `"acf8e7b"` or `"repo@acf8e7b"`.
    text: []u8,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var hash_raw: ?[]const u8 = null;
        var repo_raw: ?[]const u8 = null;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "hash")) {
                hash_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "repo")) {
                repo_raw = attr.value;
            }
        }

        const h_full = hash_raw orelse return Error.CommitMissingHash;
        const h_trimmed = std.mem.trim(u8, h_full, " \t");
        const h_short = if (h_trimmed.len > SHORT_HASH_LEN)
            h_trimmed[0..SHORT_HASH_LEN]
        else
            h_trimmed;

        const composed: []u8 = blk: {
            if (repo_raw) |r| {
                const r_trimmed = std.mem.trim(u8, r, " \t");
                if (r_trimmed.len > 0) {
                    break :blk try std.fmt.allocPrint(a, "{s}@{s}", .{ r_trimmed, h_short });
                }
            }
            break :blk try a.dupe(u8, h_short);
        };

        a.free(self.text);
        self.text = composed;
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

// ── Visual constants ───────────────────────────────────────────────

/// Conventional git short-hash width — what `git log --oneline` shows.
const SHORT_HASH_LEN: usize = 7;

const PAD_X_EM: f32 = 0.32;
const PAD_Y_EM: f32 = 0.04;

const FILL_COLOR: [4]f32 = .{ 0.20, 0.24, 0.32, 1.0 };
const LABEL_COLOR: [4]f32 = .{ 0.78, 0.86, 0.98, 1.0 };

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
    text: []const u8,
    lc: *element.LayoutCtx,
    arena_alloc: std.mem.Allocator,
) !struct { geom: Geometry, run: shape.ShapedRun } {
    const style = labelStyle(lc.theme);
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, text);

    const fscale = lc.fonts.scale(style.font_id);
    var w: f32 = 0;
    for (run.glyphs) |g| w += g.x_advance * fscale;

    const em: f32 = @floatFromInt(lc.fonts.displayPx(style.font_id));
    const pad_x = em * PAD_X_EM;
    const pad_y = em * PAD_Y_EM;

    const m = lc.fonts.metrics(style.font_id);
    const desc_abs = -m.descender;
    const asc = m.ascender + pad_y;
    const desc = desc_abs + pad_y;
    return .{
        .geom = .{
            .text_w = w,
            .pad_x = pad_x,
            .pad_y = pad_y,
            .ascender = asc,
            .descender = desc,
            .width = w + 2 * pad_x,
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
    const g = (try computeGeometry(c.text, lc, arena.allocator())).geom;
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

    const result = try computeGeometry(c.text, lc, arena.allocator());
    const g = result.geom;
    const run = result.run;

    // Background tint — no border, no shadow. A flat slate plate.
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ g.width, g.height },
        .color = FILL_COLOR,
        .radius = 3,
    });

    const style = labelStyle(lc.theme);
    const baseline_y = origin[1] + g.ascender;
    const text_x = origin[0] + g.pad_x;
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

test "Component: hash-only" {
    const attrs = [_]components.Attr{
        .{ .key = "hash", .value = "acf8e7b" },
    };
    const spec: components.Spec = .{ .name = "commit", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("acf8e7b", c.text);
}

test "Component: long hash truncates to 7" {
    const attrs = [_]components.Attr{
        .{ .key = "hash", .value = "8d6e7a3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9" },
    };
    const spec: components.Spec = .{ .name = "commit", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("8d6e7a3", c.text);
}

test "Component: repo prefix composes" {
    const attrs = [_]components.Attr{
        .{ .key = "hash", .value = "acf8e7b" },
        .{ .key = "repo", .value = "fdn42/text_engine" },
    };
    const spec: components.Spec = .{ .name = "commit", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("fdn42/text_engine@acf8e7b", c.text);
}

test "Component: missing hash rejected" {
    const spec: components.Spec = .{ .name = "commit" };
    try testing.expectError(Error.CommitMissingHash, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
