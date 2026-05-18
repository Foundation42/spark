//! `::price` — inline currency + amount (session 17). Renders a
//! symbol-prefixed monetary value on a subtle plate, with mono digits
//! so columns of prices align in tabular contexts.
//!
//! Attribute grammar:
//!
//!     ::price {value=12.99 currency=USD}
//!     ::price {value=499 currency=EUR}
//!     ::price {value=1299 currency=JPY}
//!     ::price {value=29 currency=GBP color=cyan}
//!
//! - `value` (required) — numeric amount. Integer for zero-decimal
//!   currencies (JPY), two decimals otherwise.
//! - `currency` (optional, default USD) — ISO 4217-ish code. Picks
//!   the symbol, the decimal style, and the symbol placement.
//! - `color` (optional) — tint for the symbol + amount text. Default
//!   neutral.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    PriceMissingValue,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("price", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Composed render text: `"$12.99"` / `"€12,99"` / `"¥1299"`.
    text: []u8,
    color: [4]f32,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var value_raw: ?[]const u8 = null;
        var currency: []const u8 = "USD";
        var color = COLOR_DEFAULT;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "value")) {
                value_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "currency")) {
                currency = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |c| color = c;
            }
        }

        const v_str = value_raw orelse return Error.PriceMissingValue;
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, v_str, " \t")) catch 0;

        const fmt = pickFormat(std.mem.trim(u8, currency, " \t"));
        const composed = try formatAmount(a, v, fmt);

        a.free(self.text);
        self.text = composed;
        self.color = color;
        self.version +%= 1;
    }
};

const CurrencyFormat = struct {
    /// Symbol bytes (e.g. "$" / "€" / "£" / "¥"). May be multi-byte.
    symbol: []const u8,
    /// True when the symbol prefixes the amount; false when it
    /// follows (currently always true — no trailing-symbol locales
    /// surface in the v1 currency set).
    prefix: bool,
    /// Decimal separator (`.` or `,`) inserted between integer and
    /// fractional parts.
    decimal: u8,
    /// Number of fractional digits. 0 for zero-decimal currencies
    /// (JPY); otherwise 2.
    decimals: u8,
};

fn pickFormat(currency: []const u8) CurrencyFormat {
    if (std.mem.eql(u8, currency, "EUR")) {
        return .{ .symbol = "\u{20AC}", .prefix = true, .decimal = ',', .decimals = 2 };
    }
    if (std.mem.eql(u8, currency, "GBP")) {
        return .{ .symbol = "\u{00A3}", .prefix = true, .decimal = '.', .decimals = 2 };
    }
    if (std.mem.eql(u8, currency, "JPY")) {
        return .{ .symbol = "\u{00A5}", .prefix = true, .decimal = '.', .decimals = 0 };
    }
    // USD + unknown → conventional `$N.NN`.
    return .{ .symbol = "$", .prefix = true, .decimal = '.', .decimals = 2 };
}

fn formatAmount(a: std.mem.Allocator, value: f64, fmt: CurrencyFormat) ![]u8 {
    // Round to the right number of decimals before splitting integer
    // / fractional parts so 12.999 → 13.00 / 12.345 → 12.35.
    const scale = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(fmt.decimals)));
    const rounded = @round(value * scale) / scale;
    const integer_part: i64 = @intFromFloat(@trunc(rounded));
    const fractional = @abs(rounded - @as(f64, @floatFromInt(integer_part)));

    if (fmt.decimals == 0) {
        if (fmt.prefix) {
            return std.fmt.allocPrint(a, "{s}{d}", .{ fmt.symbol, integer_part });
        }
        return std.fmt.allocPrint(a, "{d}{s}", .{ integer_part, fmt.symbol });
    }

    const frac_int: u64 = @intFromFloat(@round(fractional * scale));
    // Pad fractional part to `fmt.decimals` digits. Only the 2-digit
    // case ships today, so the special-case is enough.
    var frac_buf: [4]u8 = undefined;
    const frac_str = if (fmt.decimals == 2)
        try std.fmt.bufPrint(&frac_buf, "{d:0>2}", .{frac_int})
    else
        try std.fmt.bufPrint(&frac_buf, "{d}", .{frac_int});

    if (fmt.prefix) {
        return std.fmt.allocPrint(a, "{s}{d}{c}{s}", .{ fmt.symbol, integer_part, fmt.decimal, frac_str });
    }
    return std.fmt.allocPrint(a, "{d}{c}{s}{s}", .{ integer_part, fmt.decimal, frac_str, fmt.symbol });
}

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .text = try allocator.dupe(u8, ""),
        .color = COLOR_DEFAULT,
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

const PAD_X_EM: f32 = 0.32;
const PAD_Y_EM: f32 = 0.04;

const PLATE_COLOR: [4]f32 = .{ 0.18, 0.22, 0.28, 1.0 };
const COLOR_DEFAULT: [4]f32 = .{ 0.86, 0.92, 0.98, 1.0 };

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

    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ g.width, g.height },
        .color = PLATE_COLOR,
        .radius = 3,
    });

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
        origin[0] + g.pad_x,
        baseline_y,
        c.color,
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

test "format: USD two-decimal" {
    const a = testing.allocator;
    const s = try formatAmount(a, 12.99, pickFormat("USD"));
    defer a.free(s);
    try testing.expectEqualStrings("$12.99", s);
}

test "format: EUR uses comma + euro symbol" {
    const a = testing.allocator;
    const s = try formatAmount(a, 12.5, pickFormat("EUR"));
    defer a.free(s);
    try testing.expectEqualStrings("\u{20AC}12,50", s);
}

test "format: GBP uses pound sign" {
    const a = testing.allocator;
    const s = try formatAmount(a, 29, pickFormat("GBP"));
    defer a.free(s);
    try testing.expectEqualStrings("\u{00A3}29.00", s);
}

test "format: JPY zero-decimal" {
    const a = testing.allocator;
    const s = try formatAmount(a, 1299, pickFormat("JPY"));
    defer a.free(s);
    try testing.expectEqualStrings("\u{00A5}1299", s);
}

test "format: rounds to two decimals" {
    const a = testing.allocator;
    const s = try formatAmount(a, 12.999, pickFormat("USD"));
    defer a.free(s);
    try testing.expectEqualStrings("$13.00", s);
}

test "format: pads fractional to two digits" {
    const a = testing.allocator;
    const s = try formatAmount(a, 12.1, pickFormat("USD"));
    defer a.free(s);
    try testing.expectEqualStrings("$12.10", s);
}

test "Component: composes from attrs" {
    const attrs = [_]components.Attr{
        .{ .key = "value", .value = "499" },
        .{ .key = "currency", .value = "EUR" },
    };
    const spec: components.Spec = .{ .name = "price", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("\u{20AC}499,00", c.text);
}

test "Component: missing value rejected" {
    const spec: components.Spec = .{ .name = "price" };
    try testing.expectError(Error.PriceMissingValue, create(&_test_spark, testing.allocator, &spec));
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
