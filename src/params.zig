//! Typed param resolver for component factories. Effects-spec Phase A.1
//! — single dispatch point that effect factories use to marshal
//! `:::name {key=value}` attrs into typed values. Comptime-dispatched
//! on the requested type; new types slot in as new arms in `resolve`.
//!
//! Scope discipline. Existing components (box, grid, svg, …) keep
//! their inline marshalling unchanged — this module is the entry
//! point for *effect factories starting at A.5*. It wraps the live
//! helpers (`parseColor`, `parseLength` in `components/box.zig`)
//! without moving or duplicating them, so the 6+ files that already
//! import `box_helpers` see zero churn. A v2 cleanup pulling the
//! helpers into this module is parked, not shipped.
//!
//! Why a centralised resolver now. Pre-A.1 the codebase had no
//! `ParamType` enum or `resolve(T, …)` function: every factory's
//! `fromSpec` hand-rolled its own per-key switch + parse, and
//! `findAttr` was duplicated across five files with subtly different
//! signatures. Effect factories sharing one dispatch point gets us
//! consistent vec2 / vec4 / typed-enum marshalling for free; without
//! it, every effect would inherit ad-hoc marshalling and diverge.

const std = @import("std");
const components = @import("markdown_components.zig");
const box_helpers = @import("components/box.zig");

/// Locate an attr by key, returning its raw value (no trimming, no
/// parsing). Consolidates the five duplicate `findAttr` implementations
/// scattered across `update.zig`, `svg.zig`, `components/embedded_document.zig`,
/// `extras/llm_stream.zig`, `extras/image_stream.zig`. Those keep
/// their own copies (scope discipline — no migration churn); new
/// callers reach for this one.
pub fn find(spec: *const components.Spec, key: []const u8) ?[]const u8 {
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

/// Resolve attr `key` into a value of type `T`, falling back to
/// `default` on missing key or unparseable value. Comptime-dispatched
/// — every type-arm is one switch case, additions stay localised.
///
/// Supported `T`:
///
///   - `[]const u8` ......... raw attr value, no parsing or trimming
///   - `bool` ............... "true"/"false", case-insensitive
///   - any int type ......... `std.fmt.parseInt(T, …, base=10)`, strict
///   - any float type ....... `std.fmt.parseFloat(T, …)`, strict
///   - `[2]f32` (vec2) ...... comma-separated `"x,y"`, whitespace ok
///   - `[4]f32` (vec4) ...... three rungs:
///                              (1) `parseColor` — hex `#rrggbb[aa]`
///                                  / `#rgb` / named color
///                              (2) comma-separated `"r,g,b,a"`
///                              (3) `default`
///   - any enum `E` ......... `std.meta.stringToEnum`, case-sensitive
///                            (enum field names ARE the wire format)
///
/// **Strict full-string parsing.** Every rung consumes the entire
/// trimmed value or rejects it. `parseColor("red,green,blue,1")` does
/// NOT half-match "red" and fall through to CSV — it returns null,
/// and rung 2 (CSV) takes over cleanly. Three rungs, no overlap.
///
/// **vec4 is wire-format-discriminated, not semantically tagged.**
/// `offset=#1a1a2e` resolved as `[4]f32` reads as the hex bytes (a
/// "color" interpreted as a vec4) regardless of whether the factory
/// thinks `offset` means color or raw vec4. No crash, no silent
/// corruption, just weirdness from author error. Factories that need
/// to reject color-syntax for non-color params validate inside their
/// own update path — the resolver stays simple.
///
/// **Alpha contract.** vec4 values from 3-channel sources (3-byte
/// hex, named colors, RGB-without-alpha) normalise to `alpha = 1.0`.
/// The underlying `parseColor` already enforces this; documented
/// here so callers can rely on it without re-checking.
pub fn resolve(
    comptime T: type,
    spec: *const components.Spec,
    key: []const u8,
    default: T,
) T {
    const raw = find(spec, key) orelse return default;
    return parseValue(T, raw) orelse default;
}

fn parseValue(comptime T: type, raw: []const u8) ?T {
    // `[]const u8` returns the raw value unconditionally — the
    // empty-string check below would reject `key=""`, but an explicit
    // empty value is a deliberate author choice for string params.
    if (T == []const u8) return raw;

    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;

    if (T == bool) {
        if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
        if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
        return null;
    }
    if (T == [2]f32) return parseCsvFloat(2, trimmed);
    if (T == [4]f32) {
        // Rung 1: color syntax (hex / named). parseColor is strict —
        // `parseNamedColor` uses `eqlIgnoreCase` on the full slice
        // and `parseHexColor` switches on exact length (3/6/8), so
        // any partial / trailing-garbage input falls through cleanly.
        if (box_helpers.parseColor(trimmed)) |c| return c;
        // Rung 2: CSV "r,g,b,a".
        return parseCsvFloat(4, trimmed);
    }

    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, trimmed, 10) catch null,
        .float => std.fmt.parseFloat(T, trimmed) catch null,
        .@"enum" => std.meta.stringToEnum(T, trimmed),
        else => @compileError("params.resolve: unsupported type " ++ @typeName(T)),
    };
}

fn parseCsvFloat(comptime N: usize, s: []const u8) ?[N]f32 {
    var out: [N]f32 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= N) return null; // too many components — strict
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) return null;
        out[i] = std.fmt.parseFloat(f32, trimmed) catch return null;
    }
    if (i != N) return null; // too few components — strict
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn specWith(attrs: []const components.Attr) components.Spec {
    return .{ .name = "test", .attrs = attrs };
}

test "find: hit + miss" {
    const spec = specWith(&.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "two" },
    });
    try testing.expectEqualStrings("1", find(&spec, "a").?);
    try testing.expectEqualStrings("two", find(&spec, "b").?);
    try testing.expect(find(&spec, "missing") == null);
}

test "resolve: string + default" {
    const spec = specWith(&.{
        .{ .key = "name", .value = "hello" },
    });
    try testing.expectEqualStrings("hello", resolve([]const u8, &spec, "name", "fallback"));
    try testing.expectEqualStrings("fallback", resolve([]const u8, &spec, "missing", "fallback"));
}

test "resolve: bool" {
    const spec = specWith(&.{
        .{ .key = "on", .value = "true" },
        .{ .key = "off", .value = "FALSE" },
        .{ .key = "bad", .value = "maybe" },
    });
    try testing.expectEqual(true, resolve(bool, &spec, "on", false));
    try testing.expectEqual(false, resolve(bool, &spec, "off", true));
    try testing.expectEqual(true, resolve(bool, &spec, "bad", true));
    try testing.expectEqual(false, resolve(bool, &spec, "missing", false));
}

test "resolve: int + float" {
    const spec = specWith(&.{
        .{ .key = "n", .value = "42" },
        .{ .key = "negative", .value = "-7" },
        .{ .key = "x", .value = "3.14" },
        .{ .key = "bad_int", .value = "not-a-number" },
    });
    try testing.expectEqual(@as(u32, 42), resolve(u32, &spec, "n", 0));
    try testing.expectEqual(@as(i32, -7), resolve(i32, &spec, "negative", 0));
    try testing.expectApproxEqAbs(@as(f32, 3.14), resolve(f32, &spec, "x", 0), 0.001);
    try testing.expectEqual(@as(u32, 99), resolve(u32, &spec, "bad_int", 99));
    try testing.expectEqual(@as(u32, 5), resolve(u32, &spec, "missing", 5));
}

test "resolve: vec2" {
    const spec = specWith(&.{
        .{ .key = "p", .value = "4,8" },
        .{ .key = "spaced", .value = " 1.5 , -2.0 " },
        .{ .key = "too_many", .value = "1,2,3" },
        .{ .key = "too_few", .value = "1" },
        .{ .key = "empty_part", .value = "1,," },
    });
    try testing.expectEqual([2]f32{ 4, 8 }, resolve([2]f32, &spec, "p", .{ 0, 0 }));
    try testing.expectEqual([2]f32{ 1.5, -2.0 }, resolve([2]f32, &spec, "spaced", .{ 0, 0 }));
    try testing.expectEqual([2]f32{ 9, 9 }, resolve([2]f32, &spec, "too_many", .{ 9, 9 }));
    try testing.expectEqual([2]f32{ 9, 9 }, resolve([2]f32, &spec, "too_few", .{ 9, 9 }));
    try testing.expectEqual([2]f32{ 9, 9 }, resolve([2]f32, &spec, "empty_part", .{ 9, 9 }));
    try testing.expectEqual([2]f32{ 0, 0 }, resolve([2]f32, &spec, "missing", .{ 0, 0 }));
}

test "resolve: vec4 rung 1 (color syntax)" {
    const spec = specWith(&.{
        .{ .key = "hex6", .value = "#1a1a2e" },
        .{ .key = "hex3", .value = "#f00" },
        .{ .key = "hex8", .value = "#0000ff80" },
        .{ .key = "named", .value = "red" },
    });
    const fallback = [4]f32{ 0, 0, 0, 0 };

    // 6-byte hex — alpha defaults to 1.0 (alpha contract).
    const hex6 = resolve([4]f32, &spec, "hex6", fallback);
    try testing.expectApproxEqAbs(@as(f32, 0x1a) / 255.0, hex6[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hex6[3], 0.001);

    // 3-byte hex — alpha defaults to 1.0.
    const hex3 = resolve([4]f32, &spec, "hex3", fallback);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hex3[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hex3[3], 0.001);

    // 8-byte hex — alpha from the wire.
    const hex8 = resolve([4]f32, &spec, "hex8", fallback);
    try testing.expectApproxEqAbs(@as(f32, 0.5), hex8[3], 0.01);

    // Named — alpha defaults to 1.0.
    const named = resolve([4]f32, &spec, "named", fallback);
    try testing.expect(named[0] > 0.5); // red dominant
    try testing.expectApproxEqAbs(@as(f32, 1.0), named[3], 0.001);
}

test "resolve: vec4 rung 2 (CSV fallback)" {
    const spec = specWith(&.{
        .{ .key = "csv", .value = "0.1,0.2,0.3,0.4" },
        .{ .key = "spaced", .value = " 1 , 0 , 0 , 1 " },
    });
    const csv = resolve([4]f32, &spec, "csv", .{ 0, 0, 0, 0 });
    try testing.expectEqual([4]f32{ 0.1, 0.2, 0.3, 0.4 }, csv);
    const spaced = resolve([4]f32, &spec, "spaced", .{ 0, 0, 0, 0 });
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, spaced);
}

test "resolve: vec4 strict precedence — no partial color match" {
    // Strictness contract: a value that looks like it starts with a
    // color name ("red") but continues into CSV (",green,blue,1")
    // must NOT half-match the color rung. parseColor returns null,
    // CSV rung handles it (and fails because "green" isn't a float),
    // default wins.
    const spec = specWith(&.{
        .{ .key = "ambiguous", .value = "red,green,blue,1" },
    });
    const fallback = [4]f32{ 9, 9, 9, 9 };
    try testing.expectEqual(fallback, resolve([4]f32, &spec, "ambiguous", fallback));
}

test "resolve: vec4 wire-format-discriminated policy" {
    // Policy: vec4 is wire-format-discriminated. `offset=#1a1a2e` on a
    // non-color vec4 param resolves to the hex-derived value; the
    // resolver doesn't know the param "means" offset vs color. This
    // test pins the behavior so nobody mistakes future "weird offset"
    // bug reports for a resolver flaw.
    const spec = specWith(&.{
        .{ .key = "offset", .value = "#1a1a2e" },
    });
    const v = resolve([4]f32, &spec, "offset", .{ 0, 0, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0x1a) / 255.0, v[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), v[3], 0.001);
}

test "resolve: enum" {
    const Direction = enum { vertical, horizontal, diagonal };
    const spec = specWith(&.{
        .{ .key = "dir", .value = "vertical" },
        .{ .key = "bad", .value = "sideways" },
    });
    try testing.expectEqual(Direction.vertical, resolve(Direction, &spec, "dir", .diagonal));
    try testing.expectEqual(Direction.diagonal, resolve(Direction, &spec, "bad", .diagonal));
    try testing.expectEqual(Direction.horizontal, resolve(Direction, &spec, "missing", .horizontal));
}
