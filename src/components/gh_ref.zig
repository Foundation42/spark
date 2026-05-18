//! `::issue` and `::pr` — GitHub-style ref chips (session 17). Same
//! shape as `::commit` but for non-hash references: an issue or PR
//! number, optionally prefixed with a repo. The two directives share
//! one module — the only difference between `::issue` and `::pr` is
//! the chip tint, so the kind is recorded on the component at create
//! time and the layout pass switches palette accordingly.
//!
//! Attribute grammar:
//!
//!     ::issue {n=42}
//!     ::issue {n=89 repo="fdn42/text_engine"}
//!     ::pr {n=1042}
//!     ::pr {n=247 repo="fdn42/text_engine"}
//!
//! - `n` (required) — the issue or PR number. Renders prefixed with
//!   `#`.
//! - `repo` (optional) — short repo label. Composes as `repo#N`.
//!
//! Colour distinction follows GitHub convention: issues read purple,
//! PRs read green. Authors can also override with `color=...`.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    GhRefMissingNumber,
};

const Kind = enum { issue, pr };

pub fn install(registry: *component_mod.Registry) !void {
    try registry.register("issue", issue_factory);
    try registry.register("pr", pr_factory);
}

pub const issue_factory: component_mod.Factory = .{
    .create = createIssue,
    .update = update,
    .deinit = deinit_,
};

pub const pr_factory: component_mod.Factory = .{
    .create = createPr,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    /// Composed render text: `"#42"` or `"repo#42"`.
    text: []u8,
    color: ?[4]f32 = null,
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var n_raw: ?[]const u8 = null;
        var repo_raw: ?[]const u8 = null;
        var color_override: ?[4]f32 = null;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "n")) {
                n_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "repo")) {
                repo_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                color_override = box_helpers.parseColor(attr.value);
            }
        }

        const n_str = n_raw orelse return Error.GhRefMissingNumber;
        const n_trimmed = std.mem.trim(u8, n_str, " \t");

        const composed: []u8 = blk: {
            if (repo_raw) |r| {
                const r_trimmed = std.mem.trim(u8, r, " \t");
                if (r_trimmed.len > 0) {
                    break :blk try std.fmt.allocPrint(a, "{s}#{s}", .{ r_trimmed, n_trimmed });
                }
            }
            break :blk try std.fmt.allocPrint(a, "#{s}", .{n_trimmed});
        };

        a.free(self.text);
        self.text = composed;
        self.color = color_override;
        self.version +%= 1;
    }
};

fn createIssue(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    return createKind(allocator, spec, .issue);
}

fn createPr(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    return createKind(allocator, spec, .pr);
}

fn createKind(allocator: std.mem.Allocator, spec: *const components.Spec, kind: Kind) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .kind = kind,
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

const PAD_X_EM: f32 = 0.32;
const PAD_Y_EM: f32 = 0.04;

/// Issues — GitHub-purple plate, lighter text.
const ISSUE_FILL: [4]f32 = .{ 0.30, 0.20, 0.40, 1.0 };
const ISSUE_TEXT: [4]f32 = .{ 0.90, 0.82, 1.00, 1.0 };

/// PRs — GitHub-green plate, lighter text.
const PR_FILL: [4]f32 = .{ 0.18, 0.34, 0.22, 1.0 };
const PR_TEXT: [4]f32 = .{ 0.78, 0.96, 0.82, 1.0 };

const Palette = struct {
    fill: [4]f32,
    text: [4]f32,
};

fn paletteFor(c: *const Component) Palette {
    const base: Palette = switch (c.kind) {
        .issue => .{ .fill = ISSUE_FILL, .text = ISSUE_TEXT },
        .pr => .{ .fill = PR_FILL, .text = PR_TEXT },
    };
    if (c.color) |col| return .{ .fill = base.fill, .text = col };
    return base;
}

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
    const pal = paletteFor(c);

    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ g.width, g.height },
        .color = pal.fill,
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
        pal.text,
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

test "Component: issue with bare n" {
    const attrs = [_]components.Attr{
        .{ .key = "n", .value = "42" },
    };
    const spec: components.Spec = .{ .name = "issue", .attrs = &attrs };
    const inst = try createIssue(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(Kind.issue, c.kind);
    try testing.expectEqualStrings("#42", c.text);
}

test "Component: pr with repo prefix" {
    const attrs = [_]components.Attr{
        .{ .key = "n", .value = "1042" },
        .{ .key = "repo", .value = "fdn42/text_engine" },
    };
    const spec: components.Spec = .{ .name = "pr", .attrs = &attrs };
    const inst = try createPr(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(Kind.pr, c.kind);
    try testing.expectEqualStrings("fdn42/text_engine#1042", c.text);
}

test "Component: missing n rejected" {
    const spec: components.Spec = .{ .name = "issue" };
    try testing.expectError(Error.GhRefMissingNumber, createIssue(testing.allocator, &spec));
}

test "palette: issue + pr differ" {
    const a = testing.allocator;
    const i_c = try a.create(Component);
    defer a.destroy(i_c);
    i_c.* = .{ .allocator = a, .kind = .issue, .text = "" };
    const p_c = try a.create(Component);
    defer a.destroy(p_c);
    p_c.* = .{ .allocator = a, .kind = .pr, .text = "" };

    const pi = paletteFor(i_c);
    const pp = paletteFor(p_c);
    try testing.expect(pi.fill[0] != pp.fill[0] or pi.fill[1] != pp.fill[1] or pi.fill[2] != pp.fill[2]);
}

test "vtable exposes measure_inline" {
    try testing.expect(vtable.measure_inline != null);
}
