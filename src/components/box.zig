//! `:::box` — the first concrete component (stage 7c). Validates the
//! end-to-end loop: directive parse → registry resolve → factory
//! create → cached instance → layout returns Box → quad emit.
//!
//! Attribute grammar:
//!
//!     :::box {#optional-id color=red width=200 height=80 radius=8}
//!     :::
//!
//! Supported values:
//!
//!   * `color` — named (red, green, blue, yellow, orange, purple,
//!     cyan, magenta, white, black, gray) or hex (`#RGB`, `#RRGGBB`,
//!     `#RRGGBBAA`). Missing or unparseable → opaque magenta so the
//!     author notices the typo. `rgb()` / `rgba()` syntax deferred.
//!   * `width` / `height` — `200` or `200px` → pixel literal,
//!     `100%` → fraction of `constraints.max_w` (or 0 if unbounded).
//!     Missing → `width=100%`, `height=80px` as banner-strip
//!     defaults.
//!   * `radius` — pixel literal, defaults to 0.
//!
//! The component's per-instance state lives in the registry's
//! allocator (NOT the parse arena) so it persists across re-parses.
//! `update` is wired so attr edits in subsequent parses mutate the
//! cached instance in place instead of triggering a destroy + create
//! cycle — this is the "cheap edit" path the live-documents vision
//! relies on.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");

pub const Length = union(enum) {
    pixels: f32,
    percent: f32, // 0..1 (so 100% is 1.0)
    auto,

    pub fn resolve(self: Length, max: f32, fallback: f32) f32 {
        return switch (self) {
            .pixels => |p| p,
            .percent => |f| if (std.math.isFinite(max)) max * f else fallback,
            .auto => fallback,
        };
    }
};

const Component = struct {
    color: [4]f32,
    width: Length,
    height: Length,
    radius: f32,

    fn fromSpec(spec: *const components.Spec) Component {
        var c: Component = .{
            .color = MAGENTA,
            .width = .{ .percent = 1.0 },
            .height = .{ .pixels = 80 },
            .radius = 0,
        };
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "color")) {
                if (parseColor(a.value)) |col| c.color = col;
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (parseLength(a.value)) |l| c.width = l;
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (parseLength(a.value)) |l| c.height = l;
            } else if (std.mem.eql(u8, a.key, "radius")) {
                if (parseLength(a.value)) |l| {
                    c.radius = switch (l) {
                        .pixels => |p| p,
                        .percent => |_| 0, // percent radius makes no sense without a context
                        .auto => 0,
                    };
                }
            }
        }
        return c;
    }
};

const MAGENTA: [4]f32 = .{ 1.0, 0.0, 1.0, 1.0 };

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

fn create(
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    c.* = Component.fromSpec(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.* = Component.fromSpec(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.destroy(c);
}

/// Component-target update path. Each action targets one field; body
/// is the new value as a string. Unknown actions are silent no-ops at
/// this stage — production telemetry / logging is the next refinement.
///
/// Conflict with `${state.x}`-templated attrs: the host's slider /
/// state.set path goes through `factory.update`, which calls
/// `fromSpec` and re-reads every templated attr. A subsequent
/// `state.set` of any templated path will therefore stomp these
/// direct-set values. That's by design — the binding is the source
/// of truth for templated components. `handle_update` is the cheap
/// path for *non-templated* attrs or for components that own their
/// state opaquely (charts, scrolling logs, …).
fn handleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const value = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.eql(u8, action, "set-color")) {
        if (parseColor(value)) |col| c.color = col;
    } else if (std.mem.eql(u8, action, "set-width")) {
        if (parseLength(value)) |l| c.width = l;
    } else if (std.mem.eql(u8, action, "set-height")) {
        if (parseLength(value)) |l| c.height = l;
    } else if (std.mem.eql(u8, action, "set-radius")) {
        if (parseLength(value)) |l| {
            c.radius = switch (l) {
                .pixels => |p| p,
                else => 0,
            };
        }
    }
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
};

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    _: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *const Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 320.0;
    const w = c.width.resolve(max_w, fallback_w);
    const h = c.height.resolve(max_w, 80.0); // height doesn't really resolve against max_w but the fallback is honest

    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = c.color,
        .radius = c.radius,
    });

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = 0,
    };
}

// ── Parsing helpers ────────────────────────────────────────────────

pub fn parseColor(s: []const u8) ?[4]f32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '#') return parseHexColor(trimmed[1..]);
    return parseNamedColor(trimmed);
}

fn parseHexColor(hex: []const u8) ?[4]f32 {
    return switch (hex.len) {
        3 => decodeHex(.{
            expandHexDigit(hex[0]) orelse return null,
            expandHexDigit(hex[1]) orelse return null,
            expandHexDigit(hex[2]) orelse return null,
            255,
        }),
        6 => decodeHex(.{
            (hexNibble(hex[0]) orelse return null) * 16 + (hexNibble(hex[1]) orelse return null),
            (hexNibble(hex[2]) orelse return null) * 16 + (hexNibble(hex[3]) orelse return null),
            (hexNibble(hex[4]) orelse return null) * 16 + (hexNibble(hex[5]) orelse return null),
            255,
        }),
        8 => decodeHex(.{
            (hexNibble(hex[0]) orelse return null) * 16 + (hexNibble(hex[1]) orelse return null),
            (hexNibble(hex[2]) orelse return null) * 16 + (hexNibble(hex[3]) orelse return null),
            (hexNibble(hex[4]) orelse return null) * 16 + (hexNibble(hex[5]) orelse return null),
            (hexNibble(hex[6]) orelse return null) * 16 + (hexNibble(hex[7]) orelse return null),
        }),
        else => null,
    };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Expand a single hex digit to a byte by doubling (CSS `#RGB`
/// shorthand): "f" → 0xff, "a" → 0xaa, "0" → 0x00.
fn expandHexDigit(c: u8) ?u8 {
    const n = hexNibble(c) orelse return null;
    return n * 16 + n;
}

fn decodeHex(bytes: [4]u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(bytes[0])) / 255.0,
        @as(f32, @floatFromInt(bytes[1])) / 255.0,
        @as(f32, @floatFromInt(bytes[2])) / 255.0,
        @as(f32, @floatFromInt(bytes[3])) / 255.0,
    };
}

fn parseNamedColor(name: []const u8) ?[4]f32 {
    const Named = struct { n: []const u8, c: [4]f32 };
    const table = [_]Named{
        .{ .n = "red", .c = .{ 0.90, 0.30, 0.30, 1.0 } },
        .{ .n = "green", .c = .{ 0.30, 0.78, 0.40, 1.0 } },
        .{ .n = "blue", .c = .{ 0.36, 0.55, 0.95, 1.0 } },
        .{ .n = "yellow", .c = .{ 0.96, 0.85, 0.30, 1.0 } },
        .{ .n = "orange", .c = .{ 0.96, 0.60, 0.25, 1.0 } },
        .{ .n = "purple", .c = .{ 0.68, 0.45, 0.92, 1.0 } },
        .{ .n = "cyan", .c = .{ 0.30, 0.85, 0.92, 1.0 } },
        .{ .n = "magenta", .c = .{ 0.92, 0.40, 0.78, 1.0 } },
        .{ .n = "white", .c = .{ 0.95, 0.95, 0.98, 1.0 } },
        .{ .n = "black", .c = .{ 0.02, 0.02, 0.03, 1.0 } },
        .{ .n = "gray", .c = .{ 0.50, 0.52, 0.58, 1.0 } },
        .{ .n = "grey", .c = .{ 0.50, 0.52, 0.58, 1.0 } },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.n, name)) return entry.c;
    }
    return null;
}

pub fn parseLength(s: []const u8) ?Length {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;

    if (trimmed[trimmed.len - 1] == '%') {
        const num = std.fmt.parseFloat(f32, trimmed[0 .. trimmed.len - 1]) catch return null;
        return .{ .percent = num / 100.0 };
    }
    const numeric_end = blk: {
        // Strip an optional `px` suffix; everything else parses as
        // the raw float, which catches both `200` and `200.5`.
        if (std.mem.endsWith(u8, trimmed, "px"))
            break :blk trimmed.len - 2;
        break :blk trimmed.len;
    };
    const num = std.fmt.parseFloat(f32, trimmed[0..numeric_end]) catch return null;
    return .{ .pixels = num };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseColor: named" {
    const red = parseColor("red") orelse unreachable;
    try testing.expect(red[0] > 0.5);
    try testing.expect(red[1] < 0.5);
    try testing.expect(parseColor("RED") != null);
    try testing.expect(parseColor("not-a-color") == null);
    try testing.expect(parseColor("") == null);
}

test "parseColor: hex" {
    const six = parseColor("#ff0000") orelse unreachable;
    try testing.expectApproxEqAbs(@as(f32, 1.0), six[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), six[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), six[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), six[3], 0.001);

    // Short form expands by digit-doubling.
    const short = parseColor("#f00") orelse unreachable;
    try testing.expectApproxEqAbs(@as(f32, 1.0), short[0], 0.001);

    // With alpha.
    const with_alpha = parseColor("#0000ff80") orelse unreachable;
    try testing.expectApproxEqAbs(@as(f32, 1.0), with_alpha[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), with_alpha[3], 0.01);

    try testing.expect(parseColor("#zzzz") == null);
    try testing.expect(parseColor("#12") == null); // wrong length
}

test "parseLength: pixels" {
    try testing.expectEqual(@as(f32, 200), parseLength("200").?.pixels);
    try testing.expectEqual(@as(f32, 200), parseLength("200px").?.pixels);
    try testing.expectEqual(@as(f32, 12.5), parseLength("12.5").?.pixels);
}

test "parseLength: percent" {
    const p = parseLength("100%") orelse unreachable;
    try testing.expectEqual(@as(f32, 1.0), p.percent);
    try testing.expectEqual(@as(f32, 0.5), parseLength("50%").?.percent);
}

test "parseLength: garbage returns null" {
    try testing.expect(parseLength("apples") == null);
    try testing.expect(parseLength("") == null);
}

test "Length.resolve" {
    const px: Length = .{ .pixels = 200 };
    try testing.expectEqual(@as(f32, 200), px.resolve(400, 0));

    const pc: Length = .{ .percent = 0.5 };
    try testing.expectEqual(@as(f32, 200), pc.resolve(400, 0));
    // Unbounded max_w → fallback.
    try testing.expectEqual(@as(f32, 99), pc.resolve(std.math.inf(f32), 99));

    const a: Length = .auto;
    try testing.expectEqual(@as(f32, 42), a.resolve(400, 42));
}

test "Component.fromSpec: defaults" {
    const spec: components.Spec = .{ .name = "box" };
    const c = Component.fromSpec(&spec);
    try testing.expectEqual(MAGENTA, c.color); // missing color → magenta indicator
    try testing.expect(c.width == .percent);
    try testing.expectEqual(@as(f32, 1.0), c.width.percent);
    try testing.expect(c.height == .pixels);
    try testing.expectEqual(@as(f32, 80), c.height.pixels);
    try testing.expectEqual(@as(f32, 0), c.radius);
}

test "Component.fromSpec: full attrs" {
    const attrs = [_]components.Attr{
        .{ .key = "color", .value = "blue" },
        .{ .key = "width", .value = "300" },
        .{ .key = "height", .value = "120px" },
        .{ .key = "radius", .value = "12" },
    };
    const spec: components.Spec = .{ .name = "box", .attrs = &attrs };
    const c = Component.fromSpec(&spec);
    try testing.expect(c.color[2] > 0.5); // blue dominant
    try testing.expectEqual(@as(f32, 300), c.width.pixels);
    try testing.expectEqual(@as(f32, 120), c.height.pixels);
    try testing.expectEqual(@as(f32, 12), c.radius);
}

test "handleUpdate: set-color mutates instance color" {
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 50 },
        .radius = 0,
    };
    try handleUpdate(@ptrCast(&c), "set-color", "orange");
    try testing.expect(c.color[0] > 0.5); // orange has dominant red+green
    try testing.expect(c.color[1] > 0.4);

    // Trailing whitespace trimmed from body.
    try handleUpdate(@ptrCast(&c), "set-color", "  green  \n");
    try testing.expect(c.color[1] > 0.5);
    try testing.expect(c.color[0] < 0.5);
}

test "handleUpdate: set-radius / set-width / set-height" {
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 50 },
        .radius = 0,
    };
    try handleUpdate(@ptrCast(&c), "set-radius", "20");
    try testing.expectEqual(@as(f32, 20), c.radius);

    try handleUpdate(@ptrCast(&c), "set-width", "250px");
    try testing.expectEqual(@as(f32, 250), c.width.pixels);

    try handleUpdate(@ptrCast(&c), "set-height", "75%");
    try testing.expect(c.height == .percent);
    try testing.expectEqual(@as(f32, 0.75), c.height.percent);
}

test "handleUpdate: unknown action is silent no-op" {
    var c: Component = .{
        .color = MAGENTA,
        .width = .{ .pixels = 100 },
        .height = .{ .pixels = 50 },
        .radius = 0,
    };
    try handleUpdate(@ptrCast(&c), "explode", "boom");
    try testing.expectEqual(MAGENTA, c.color);
}
