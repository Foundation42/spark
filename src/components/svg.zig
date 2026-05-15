//! `:::svg` — vector graphic embedded in the document (stage 13d.1).
//!
//! Loads an SVG from disk, parses the subset that Recraft V4.1
//! emits (M/L/C/z paths with rgb fills + translate), tessellates
//! once at create-time, and renders the cached triangle mesh into
//! the host's `DrawList.tris` each layout pass — transformed from
//! viewBox coords to the component's screen box.
//!
//! Attribute grammar:
//!
//!     :::svg {src="petunias.svg" width=400 height=400}
//!     :::
//!
//! - `src`     (required) — local filesystem path. Relative paths
//!   are resolved against the running binary's CWD for now (next
//!   sub-stage will let the IoChannel pull URL sources, mirroring
//!   `:::embedded-document`'s remote path).
//! - `width`   (optional) — pixel literal or `100%`. Default 400.
//! - `height`  (optional) — pixel literal. Default: chosen to
//!   preserve the SVG's viewBox aspect ratio against the resolved
//!   width.
//!
//! ### Failure modes
//!
//! Disk read failure / parse failure / tessellation failure → the
//! component flips to `.failed` and renders a red placeholder
//! instead of triangles. Same shape as the LLM stream's failure
//! card; the error name appears in the placeholder text.
//!
//! ### Memory
//!
//! The parsed SVG + tessellated mesh live in a per-component
//! arena that's freed on `deinit`. A 125-path bouquet flattens to
//! ~5–10k triangles which is comfortable RAM-wise (~250 KB).

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const svg = @import("../svg.zig");
const tess = @import("../svg_tessellate.zig");
const jobs_mod = @import("../jobs.zig");
const box_helpers = @import("box.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");

pub const Error = error{
    SvgMissingSrc,
};

/// Module global — set by install() (stage 13d.2). When present,
/// loadAndTessellate uses parallel fork-join across the worker
/// pool; when null (component used in a host that doesn't install
/// a JobSystem), falls back to the single-threaded serial path.
var job_system_ref: ?*jobs_mod.JobSystem = null;

pub fn install(
    registry: *component_mod.Registry,
    job_system: *jobs_mod.JobSystem,
) !void {
    job_system_ref = job_system;
    try registry.register("svg", factory);
}

pub fn deinitGlobals() void {
    job_system_ref = null;
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Phase = enum { ready, failed };

const Component = struct {
    allocator: std.mem.Allocator,
    /// Holds the parsed SVG + tessellated mesh. One arena to free
    /// the lot at deinit / re-tessellate.
    arena: *std.heap.ArenaAllocator,

    src: []u8,
    width: box_helpers.Length,
    height: ?box_helpers.Length, // null = preserve aspect

    // Cached mesh in viewBox coords. Layout transforms each
    // vertex to screen at render time. Owned by `arena`.
    vertices: []const tess.Vertex = &.{},
    indices: []const u32 = &.{},
    view_x: f32 = 0,
    view_y: f32 = 0,
    view_w: f32 = 1,
    view_h: f32 = 1,

    phase: Phase = .ready,
    err_name: ?[]u8 = null, // owned by allocator (NOT arena)

    /// Bumped on src= change / re-tessellate so the retained layout
    /// cache invalidates the block. Static SVGs (no src changes
    /// post-create) stay at version 0 → permanent cache hit.
    version: u64 = 0,
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const src_raw = findAttr(spec.attrs, "src") orelse return Error.SvgMissingSrc;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const src_dup = try allocator.dupe(u8, src_raw);
    errdefer allocator.free(src_dup);

    c.* = .{
        .allocator = allocator,
        .arena = arena,
        .src = src_dup,
        .width = if (findAttr(spec.attrs, "width")) |s|
            box_helpers.parseLength(s) orelse .{ .pixels = 400 }
        else
            .{ .pixels = 400 },
        .height = if (findAttr(spec.attrs, "height")) |s|
            box_helpers.parseLength(s) orelse null
        else
            null,
    };

    loadAndTessellate(c) catch |e| {
        c.phase = .failed;
        c.err_name = c.allocator.dupe(u8, @errorName(e)) catch null;
    };

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // If `src` changed, reload + re-tessellate; otherwise just
    // re-read width/height.
    const new_src = findAttr(spec.attrs, "src") orelse return Error.SvgMissingSrc;
    const src_changed = !std.mem.eql(u8, new_src, c.src);

    if (findAttr(spec.attrs, "width")) |s| if (box_helpers.parseLength(s)) |l| {
        c.width = l;
    };
    if (findAttr(spec.attrs, "height")) |s| {
        c.height = box_helpers.parseLength(s);
    }

    if (src_changed) {
        const new_dup = try c.allocator.dupe(u8, new_src);
        c.allocator.free(c.src);
        c.src = new_dup;

        _ = c.arena.reset(.retain_capacity);
        c.vertices = &.{};
        c.indices = &.{};
        c.phase = .ready;
        if (c.err_name) |e| {
            c.allocator.free(e);
            c.err_name = null;
        }
        loadAndTessellate(c) catch |e| {
            c.phase = .failed;
            c.err_name = c.allocator.dupe(u8, @errorName(e)) catch null;
        };
        c.version +%= 1;
    }
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.src);
    if (c.err_name) |e| allocator.free(e);
    c.arena.deinit();
    allocator.destroy(c.arena);
    allocator.destroy(c);
}

fn loadAndTessellate(c: *Component) !void {
    const aa = c.arena.allocator();
    // Read the file. For v0 the path is taken at face value; CWD-
    // relative paths Just Work because the demo's run from the
    // project root. URL fetch lands in a follow-up.
    const max_bytes: usize = 4 * 1024 * 1024; // 4 MB cap — generative SVGs are tiny in practice
    const source = std.fs.cwd().readFileAlloc(aa, c.src, max_bytes) catch |e| {
        return e;
    };
    const doc = try svg.parse(aa, source);

    var mesh = tess.Mesh{
        .vertices = std.ArrayList(tess.Vertex).init(aa),
        .indices = std.ArrayList(u32).init(aa),
    };

    // Stage 13d.2 — fan-out across the JobSystem if installed.
    // The serial fallback path stays in place for tests + any host
    // that doesn't wire a pool.
    if (job_system_ref) |js| {
        try tess.tessellateParallel(c.allocator, doc.paths, &mesh, js, .{});
    } else {
        try tess.tessellateSerial(aa, doc.paths, &mesh, .{});
    }
    c.vertices = mesh.vertices.items;
    c.indices = mesh.indices.items;
    c.view_x = doc.view_x;
    c.view_y = doc.view_y;
    c.view_w = doc.view_w;
    c.view_h = doc.view_h;
    c.phase = .ready;
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

const ERR_BORDER: [4]f32 = .{ 0.85, 0.30, 0.30, 0.95 };
const ERR_BG: [4]f32 = .{ 0.30, 0.08, 0.08, 0.60 };
const ERR_RADIUS: f32 = 6;
const ERR_BORDER_PX: f32 = 2;
const ERR_PAD_X: f32 = 12;
const ERR_PAD_Y: f32 = 8;

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 400;
    const w: f32 = c.width.resolve(max_w, fallback_w);
    const h: f32 = blk: {
        if (c.height) |hl| break :blk hl.resolve(max_w, fallback_w);
        // Preserve aspect: h = w * view_h / view_w. Falls back to
        // a square if the viewBox is degenerate.
        if (c.view_w > 0 and c.view_h > 0) break :blk w * c.view_h / c.view_w;
        break :blk w;
    };

    if (c.phase == .failed) {
        return renderError(c, origin, w, lc, out);
    }

    if (c.vertices.len == 0 or c.indices.len == 0) {
        // Nothing to draw — still return a box so layout stack
        // budgets the space.
        return .{ .x = origin[0], .y = origin[1], .w = w, .h = h };
    }

    // Transform viewBox → screen box. Scale + translate, no rotate.
    const sx = w / c.view_w;
    const sy = h / c.view_h;
    const tx = origin[0] - c.view_x * sx;
    const ty = origin[1] - c.view_y * sy;

    const base_idx: u32 = @intCast(out.tris.items.len);
    try out.tris.ensureUnusedCapacity(c.vertices.len);
    for (c.vertices) |v| {
        out.tris.appendAssumeCapacity(.{
            .pos = .{ v.pos[0] * sx + tx, v.pos[1] * sy + ty },
            .color = v.color,
        });
    }
    try out.tri_indices.ensureUnusedCapacity(c.indices.len);
    for (c.indices) |i| out.tri_indices.appendAssumeCapacity(base_idx + i);

    return .{ .x = origin[0], .y = origin[1], .w = w, .h = h };
}

fn renderError(
    c: *const Component,
    origin: [2]f32,
    w: f32,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var buf: [256]u8 = undefined;
    const detail: []const u8 = c.err_name orelse "unknown";
    const msg = std.fmt.bufPrint(&buf, "SVG failed: {s} ({s})", .{ c.src, detail }) catch "SVG failed";
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(aa, hb, msg);

    const total_w = w;
    const total_h = m.line_height + 2 * ERR_PAD_Y;
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ total_w, total_h },
        .color = ERR_BORDER,
        .radius = ERR_RADIUS,
    });
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + ERR_BORDER_PX, origin[1] + ERR_BORDER_PX },
        .dst_size = .{ total_w - 2 * ERR_BORDER_PX, total_h - 2 * ERR_BORDER_PX },
        .color = ERR_BG,
        .radius = @max(0, ERR_RADIUS - ERR_BORDER_PX),
    });
    const baseline_y = origin[1] + ERR_PAD_Y + m.ascender;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        run,
        style.font_id,
        origin[0] + ERR_PAD_X,
        baseline_y,
        style.color,
        style.hot_color,
        style.attention,
    );
    return .{ .x = origin[0], .y = origin[1], .w = total_w, .h = total_h, .baseline = baseline_y };
}

fn findAttr(attrs: []const components.Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "svg component: missing src is an error" {
    const attrs = [_]components.Attr{};
    const spec: components.Spec = .{ .name = "svg", .attrs = &attrs };
    try testing.expectError(Error.SvgMissingSrc, create(testing.allocator, &spec));
}

test "svg component: bad src falls into .failed but doesn't panic" {
    const attrs = [_]components.Attr{
        .{ .key = "src", .value = "/nonexistent/path/to/missing.svg" },
    };
    const spec: components.Spec = .{ .name = "svg", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(Phase.failed, c.phase);
    try testing.expect(c.err_name != null);
}

test "svg component: real Petunias.svg loads + tessellates" {
    const attrs = [_]components.Attr{
        .{ .key = "src", .value = "src/test_data/Petunias.svg" },
    };
    const spec: components.Spec = .{ .name = "svg", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(Phase.ready, c.phase);
    try testing.expect(c.vertices.len > 0);
    try testing.expect(c.indices.len > 0);
    try testing.expect(c.view_w > 1000);
}
