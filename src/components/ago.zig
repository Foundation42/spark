//! `::ago` — relative-timestamp chip (session 17). Renders the
//! supplied duration string suffixed with " ago", in italic, on a
//! whisper-light slate tint. Static for v1: the author supplies the
//! pre-formatted duration ("3m", "2h", "5d", "3w"); a future version
//! parses an ISO timestamp and self-updates as the clock ticks.
//!
//! Attribute grammar:
//!
//!     ::ago {value="3m"}
//!     ::ago {value="2h"}
//!     ::ago {value="just now"}
//!
//! - `value` (required) — the duration label. Anything reading as
//!   "N units" works ("3m", "2h", "5d", "3w", "2mo", "1y"); the
//!   special-case "just now" / "now" suppresses the " ago" suffix.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");

pub const Error = error{
    AgoMissingValue,
};

pub fn install(registry: *component_mod.Registry) !void {
    try registry.register("ago", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Composed render text: `"3m ago"`, `"just now"`.
    text: []u8,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var value_raw: ?[]const u8 = null;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "value")) {
                value_raw = attr.value;
            }
        }

        const v_raw = value_raw orelse return Error.AgoMissingValue;
        const v = std.mem.trim(u8, v_raw, " \t");

        // "just now" / "now" reads as its own phrase — no " ago"
        // suffix. Anything else gets the conventional trailing " ago".
        const composed: []u8 = if (std.ascii.eqlIgnoreCase(v, "just now") or std.ascii.eqlIgnoreCase(v, "now"))
            try a.dupe(u8, v)
        else
            try std.fmt.allocPrint(a, "{s} ago", .{v});

        a.free(self.text);
        self.text = composed;
        self.version +%= 1;
    }
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
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

const COLOR_TEXT: [4]f32 = .{ 0.60, 0.66, 0.74, 1.0 };

/// The italic cascade carries the "soft / contextual" reading we want
/// for a relative timestamp without us threading an explicit font
/// selection — `applyEmphasis` already maps to the registered italic
/// variant via `Theme`.
fn labelStyle(theme: *const element.Theme) element.Style {
    return theme.applyEmphasis(theme.body);
}

const Geometry = struct {
    width: f32,
    ascender: f32,
    descender: f32,
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

    const m = lc.fonts.metrics(style.font_id);
    return .{
        .geom = .{
            .width = w,
            .ascender = m.ascender,
            .descender = -m.descender,
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

    const style = labelStyle(lc.theme);
    const baseline_y = origin[1] + g.ascender;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        run,
        style.font_id,
        origin[0],
        baseline_y,
        COLOR_TEXT,
        style.hot_color,
        0,
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

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Component: appends ' ago' to durations" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "3m" },
    };
    const spec: components.Spec = .{ .name = "ago", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("3m ago", c.text);
}

test "Component: 'just now' is preserved as-is" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "just now" },
    };
    const spec: components.Spec = .{ .name = "ago", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("just now", c.text);
}

test "Component: 'now' is preserved as-is" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "now" },
    };
    const spec: components.Spec = .{ .name = "ago", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("now", c.text);
}

test "Component: missing value rejected" {
    const spec: components.Spec = .{ .name = "ago" };
    try testing.expectError(Error.AgoMissingValue, create(testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
