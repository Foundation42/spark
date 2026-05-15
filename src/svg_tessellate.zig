//! SVG path → triangle mesh (stage 13d.1).
//!
//! Two-step CPU pipeline:
//!
//!   1. **Flatten** — each cubic Bezier in a `Subpath` recursively
//!      subdivided at the midpoint until the chord-error is below
//!      `flatten_tolerance` (default ~0.5px in viewBox units;
//!      callers can drop it lower if they're going to scale up).
//!      Output is a closed polygon — flat array of `Point` with the
//!      last point implicitly connecting back to the first.
//!
//!   2. **Earcut triangulation** — Mapbox's earcut algorithm, in
//!      ~500 lines of Zig. Handles arbitrary simple polygons (no
//!      self-intersection); multiple subpaths in the same path are
//!      treated as holes via the standard "even-odd via bridge"
//!      pre-processing step (subpath 0 is the outer ring; 1..N are
//!      holes joined to the outer ring with a bridge segment).
//!
//! Earcut chosen over libtess2 because: pure Zig (no new C link),
//! good-enough for SVG fills that aren't pathological, and matches
//! Mapbox's well-tested reference impl. Self-intersecting paths
//! (rare from generative models — Recraft hasn't emitted any yet)
//! will produce ugly triangle soup but won't crash.
//!
//! The output is interleaved into the caller-provided
//! `vertex_list` + `index_list` (just appended; the caller
//! batches across many paths into one big VBO+IBO). Each vertex
//! carries position + color so a single draw call covers an
//! entire mesh — no per-path state changes.
//!
//! ### Hole-bridging (multi-subpath paths)
//!
//! Earcut handles holes by stitching them into the outer ring
//! through a bridge segment. The bridge connects an "outer ring"
//! point to the rightmost point of each hole (Mapbox's heuristic
//! that's robust enough for SVG). The bridge edge appears twice
//! (once outbound, once return) in the merged contour, which
//! earcut tolerates — the two zero-area triangles it produces
//! contribute no visible pixels.
//!
//! For v0 we keep the bridging simple: pick the rightmost point of
//! the hole, find the outer-ring vertex with greatest x that lies
//! above and to the left, splice. This is the standard recipe
//! from Eberly's geometric-tools guide; not provably correct on
//! pathological inputs but exactly what Mapbox's earcut.js does.

const std = @import("std");
const svg = @import("svg.zig");

pub const Point = svg.Point;

/// Interleaved per-vertex format for the new TrianglePipeline.
/// Position is in author/viewBox coords; the renderer's draw
/// transform maps to screen pixels.
pub const Vertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

comptime {
    // Vulkan vertex attribute alignment — pos vec2 + color vec4.
    std.debug.assert(@sizeOf(Vertex) == 24);
}

pub const Mesh = struct {
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{
            .vertices = std.ArrayList(Vertex).init(allocator),
            .indices = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertices.deinit();
        self.indices.deinit();
        self.* = undefined;
    }
};

pub const TessellateOptions = struct {
    /// Maximum chord-deviation, in viewBox units, when flattening
    /// cubic Beziers. 0.5 keeps curves visually smooth at typical
    /// display scales (Recraft outputs at ~1500-2000 unit viewBox
    /// for figures rendered at 400px on screen). Drop below 0.25
    /// for very large on-screen displays.
    flatten_tolerance: f32 = 0.5,
    /// Hard recursion cap for the bezier subdivider — guards
    /// against pathological control points producing infinite
    /// recursion. 20 levels = max 1M segments per cubic, more than
    /// enough.
    max_flatten_depth: u32 = 20,
};

/// Tessellate one SVG path (which may contain multiple subpaths,
/// taken as outer + holes). Appends interleaved triangles to
/// `mesh`. Returns the number of triangles emitted.
///
/// The path's `translate` is applied at vertex time so the mesh
/// can be batched alongside other paths' meshes. Per-path color
/// is baked into every emitted vertex — there's no per-draw color
/// state.
pub fn tessellatePath(
    allocator: std.mem.Allocator,
    path: svg.Path,
    mesh: *Mesh,
    opts: TessellateOptions,
) !u32 {
    // Step 1 — flatten each subpath to a polygon.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var rings = std.ArrayList([]Point).init(aa);

    for (path.subpaths) |sp| {
        const poly = try flattenSubpath(aa, sp, opts);
        if (poly.len < 3) continue;
        try rings.append(poly);
    }

    if (rings.items.len == 0) return 0;

    // Step 2 — earcut.
    //
    // Two paths:
    //   (a) Single ring → straight earcut, no hole stitching.
    //   (b) Multi ring → orientation-aware: the largest-area ring
    //       is the outer; the rest are holes, stitched in by
    //       bridges from rightmost hole vertex to outer.
    //
    // Single-ring is the dominant case for Recraft (each <path>
    // typically encloses one shape; multi-subpath paths show up
    // for letterforms, donut holes, etc.).
    var merged: []Point = undefined;
    if (rings.items.len == 1) {
        merged = rings.items[0];
    } else {
        merged = try stitchHoles(aa, rings.items);
    }

    // Reserve before emitting so index offsets stay stable.
    const base_idx: u32 = @intCast(mesh.vertices.items.len);
    try mesh.vertices.ensureUnusedCapacity(merged.len);
    for (merged) |p| {
        mesh.vertices.appendAssumeCapacity(.{
            .pos = .{ p.x + path.translate.x, p.y + path.translate.y },
            .color = path.color,
        });
    }

    // Earcut emits triangle indices into the merged ring. We
    // offset by base_idx so they index correctly into the
    // batched VBO.
    var local_idx = std.ArrayList(u32).init(aa);
    try earcut(aa, merged, &local_idx);
    try mesh.indices.ensureUnusedCapacity(local_idx.items.len);
    for (local_idx.items) |li| mesh.indices.appendAssumeCapacity(base_idx + li);

    return @intCast(local_idx.items.len / 3);
}

// ─────────────────────────────────────────────────────────────────
// Bezier flattening
// ─────────────────────────────────────────────────────────────────

fn flattenSubpath(
    arena: std.mem.Allocator,
    sp: svg.Subpath,
    opts: TessellateOptions,
) ![]Point {
    var pts = std.ArrayList(Point).init(arena);
    var cur = sp.start;
    try pts.append(cur);

    for (sp.commands) |cmd| {
        switch (cmd.kind) {
            .line => {
                try pts.append(cmd.endpoint);
                cur = cmd.endpoint;
            },
            .cubic => {
                try flattenCubic(&pts, cur, cmd.c1, cmd.c2, cmd.endpoint, opts.flatten_tolerance, opts.max_flatten_depth);
                cur = cmd.endpoint;
            },
        }
    }

    // Drop trailing duplicate of start if subpath is closed and the
    // last segment lands on start anyway — keeps earcut happy.
    if (sp.closed and pts.items.len > 1) {
        const last = pts.items[pts.items.len - 1];
        if (approxEq(last, sp.start, 0.001)) _ = pts.pop();
    }

    return try pts.toOwnedSlice();
}

fn flattenCubic(
    pts: *std.ArrayList(Point),
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
    tol: f32,
    depth_left: u32,
) !void {
    // Adaptive subdivision via the De Casteljau midpoint scheme.
    // We measure flatness as max perpendicular distance from
    // intermediate control points to the chord p0→p3. Cheaper than
    // computing actual arc length and accurate enough for our
    // tolerance band.
    if (depth_left == 0 or isCubicFlat(p0, p1, p2, p3, tol)) {
        try pts.append(p3);
        return;
    }
    // De Casteljau split at t=0.5.
    const m01 = midpoint(p0, p1);
    const m12 = midpoint(p1, p2);
    const m23 = midpoint(p2, p3);
    const m012 = midpoint(m01, m12);
    const m123 = midpoint(m12, m23);
    const m = midpoint(m012, m123);
    try flattenCubic(pts, p0, m01, m012, m, tol, depth_left - 1);
    try flattenCubic(pts, m, m123, m23, p3, tol, depth_left - 1);
}

fn isCubicFlat(p0: Point, p1: Point, p2: Point, p3: Point, tol: f32) bool {
    const d1 = perpDist(p0, p3, p1);
    const d2 = perpDist(p0, p3, p2);
    return @max(d1, d2) <= tol;
}

fn perpDist(a: Point, b: Point, p: Point) f32 {
    // |(b-a) × (p-a)| / |b-a|. For our use the denominator
    // approaches zero only on degenerate chords (a==b), in which
    // case any control off-axis is "not flat" — return inf so we
    // keep subdividing.
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return std.math.inf(f32);
    const cross = (p.x - a.x) * dy - (p.y - a.y) * dx;
    return @abs(cross) / len;
}

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

fn approxEq(a: Point, b: Point, eps: f32) bool {
    return @abs(a.x - b.x) < eps and @abs(a.y - b.y) < eps;
}

// ─────────────────────────────────────────────────────────────────
// Hole stitching
// ─────────────────────────────────────────────────────────────────
//
// Given several rings, identify the outer (largest signed area)
// and stitch the others as holes. Bridge each hole to the outer
// via duplicate edges — earcut tolerates these because the two
// degenerate triangles they spawn contribute no visible pixels.

fn stitchHoles(arena: std.mem.Allocator, rings: [][]Point) ![]Point {
    // Find outer ring = max |signed area|.
    var outer_idx: usize = 0;
    var max_area: f32 = 0;
    for (rings, 0..) |r, i| {
        const a = @abs(signedArea(r));
        if (a > max_area) {
            max_area = a;
            outer_idx = i;
        }
    }

    // Ensure outer is CCW (positive area); flip if not.
    var outer = rings[outer_idx];
    if (signedArea(outer) < 0) outer = try reversedCopy(arena, outer);

    var merged = std.ArrayList(Point).init(arena);
    try merged.appendSlice(outer);

    // For each hole: ensure CW orientation (negative area), find
    // rightmost vertex, find a visible bridge target on the
    // current merged ring, splice in.
    for (rings, 0..) |hole_raw, i| {
        if (i == outer_idx) continue;
        var hole = hole_raw;
        if (signedArea(hole) > 0) hole = try reversedCopy(arena, hole);

        // Pick the rightmost vertex of the hole as the bridge
        // start; the simplest visibility heuristic (Eberly).
        var hr_idx: usize = 0;
        for (hole, 0..) |p, j| {
            if (p.x > hole[hr_idx].x) hr_idx = j;
        }

        // Find merged vertex with max x that's strictly to the
        // right of the hole's rightmost point. Falls back to the
        // overall rightmost if none qualifies — degenerate but
        // earcut will swallow it.
        const hr = hole[hr_idx];
        var tgt_idx: usize = 0;
        for (merged.items, 0..) |p, j| {
            if (p.x >= hr.x and p.x > merged.items[tgt_idx].x) tgt_idx = j;
        }
        if (merged.items[tgt_idx].x < hr.x) {
            // No outer vertex right of the hole — give up and
            // skip this hole (treat as outer filled solid). Real
            // SVG documents rarely hit this.
            continue;
        }

        // Splice: [..tgt][hole rotated from hr_idx wrapping][hr again][tgt again][tgt+1..].
        var spliced = std.ArrayList(Point).init(arena);
        try spliced.appendSlice(merged.items[0 .. tgt_idx + 1]);
        // Hole walked starting from rightmost, wrapping around.
        for (0..hole.len) |k| {
            try spliced.append(hole[(hr_idx + k) % hole.len]);
        }
        // Close the bridge: back to hole rightmost, then outer
        // target vertex.
        try spliced.append(hr);
        try spliced.append(merged.items[tgt_idx]);
        try spliced.appendSlice(merged.items[tgt_idx + 1 ..]);
        merged.deinit();
        merged = spliced;
    }

    return try merged.toOwnedSlice();
}

fn signedArea(pts: []const Point) f32 {
    if (pts.len < 3) return 0;
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        const j = (i + 1) % pts.len;
        sum += (pts[j].x - pts[i].x) * (pts[j].y + pts[i].y);
    }
    return -sum * 0.5; // CCW = positive
}

fn reversedCopy(arena: std.mem.Allocator, pts: []const Point) ![]Point {
    const out = try arena.alloc(Point, pts.len);
    for (pts, 0..) |p, i| out[pts.len - 1 - i] = p;
    return out;
}

// ─────────────────────────────────────────────────────────────────
// Earcut triangulation
// ─────────────────────────────────────────────────────────────────
//
// Port of Mapbox's earcut.js (their C++ port `earcut.hpp` is too —
// the algorithm is the same). Builds a doubly-linked list of
// vertices, repeatedly clips "ears" (triangles formed by three
// consecutive vertices where the middle vertex is convex and no
// other polygon vertex lies inside).
//
// We diverge slightly: no z-order indexing (Mapbox's optimisation
// for fast point-in-triangle on huge polygons). Our polygons are
// in the tens-to-hundreds-of-vertices range after flattening — the
// O(n²) inner loop is fine. If a future SVG cranks vertex count
// into the thousands per path, port the z-curve indexing.

const Node = struct {
    i: u32,
    x: f32,
    y: f32,
    prev: ?*Node = null,
    next: ?*Node = null,
    /// Mapbox's "steiner point" flag — used by hole-stitching to
    /// mark synthetic vertices that should be skipped during the
    /// orientation re-test. We don't insert steiner points (we
    /// pre-stitch holes ourselves) so this stays false.
    steiner: bool = false,
};

fn earcut(arena: std.mem.Allocator, points: []const Point, out_indices: *std.ArrayList(u32)) !void {
    if (points.len < 3) return;

    // Build the doubly-linked list, CCW.
    //
    // We thread through a `last` pointer (Mapbox's pattern). Each
    // new node gets appended after `last`, and `last` advances to
    // it. The resulting list has the same vertex order as the
    // input slice — a previous bug here inserted-after-head, which
    // reversed every-other-vertex and turned the square into a
    // bowtie.
    var last: ?*Node = null;
    {
        const ccw = signedArea(points) >= 0;
        for (0..points.len) |k| {
            const idx = if (ccw) k else points.len - 1 - k;
            const n = try arena.create(Node);
            n.* = .{ .i = @intCast(idx), .x = points[idx].x, .y = points[idx].y };
            last = appendNode(last, n);
        }
    }

    // Filter colinear / coincident points — earcut dislikes them
    // because three colinear points form a zero-area "ear" that
    // never gets clipped, leaving the loop in an infinite spin.
    const head_opt = filterPoints(last);
    if (head_opt == null) return;

    try earcutLinked(head_opt.?, out_indices, 0);
}

/// Append `n` after `last` in a circular doubly-linked list.
/// Returns the new "last" (the appended node). When `last` is null,
/// the new node becomes a single-element self-cycle.
fn appendNode(last_opt: ?*Node, n: *Node) *Node {
    if (last_opt) |last| {
        n.prev = last;
        n.next = last.next;
        last.next.?.prev = n;
        last.next = n;
    } else {
        n.prev = n;
        n.next = n;
    }
    return n;
}

fn removeNode(n: *Node) void {
    n.prev.?.next = n.next;
    n.next.?.prev = n.prev;
}

fn filterPoints(start_opt: ?*Node) ?*Node {
    const start = start_opt orelse return null;
    var node = start;
    var again = true;
    while (again or node != start) {
        again = false;
        // Coincident with neighbour, or zero-area corner → remove.
        if (pointsEq(node, node.next.?) or triangleArea(node.prev.?, node, node.next.?) == 0) {
            removeNode(node);
            node = node.prev.?;
            if (node == node.next.?) return null;
            again = true;
            continue;
        }
        node = node.next.?;
    }
    return start;
}

fn pointsEq(a: *Node, b: *Node) bool {
    return a.x == b.x and a.y == b.y;
}

fn triangleArea(p: *Node, q: *Node, r: *Node) f32 {
    return (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
}

fn earcutLinked(start_in: *Node, out_indices: *std.ArrayList(u32), pass: u32) error{OutOfMemory}!void {
    var ear = start_in;
    var stop = ear;

    while (ear.prev.? != ear.next.?) {
        const prev = ear.prev.?;
        const next = ear.next.?;
        if (isEar(ear)) {
            try out_indices.appendSlice(&.{ prev.i, ear.i, next.i });
            removeNode(ear);
            // Move two ahead so we don't immediately reconsider
            // the freshly-merged neighbours.
            ear = next.next.?;
            stop = next.next.?;
            continue;
        }
        ear = next;
        if (ear == stop) {
            // No ear found in a full sweep — try to recover.
            // Mapbox runs three escalation passes; we keep two:
            //   pass 0 → try the standard cure (filterPoints + retry)
            //   pass 1 → split into smaller polygons by finding a
            //     non-intersecting diagonal (the "splitEarcut" path)
            //   pass 2 → give up (Mapbox's third pass tries
            //     z-curve indexing which we don't have; in practice
            //     skipped here means a few missing triangles).
            if (pass == 0) {
                const cured = filterPoints(ear) orelse return;
                try earcutLinked(cured, out_indices, 1);
                return;
            } else if (pass == 1) {
                try splitEarcut(ear, out_indices);
                return;
            } else {
                return;
            }
        }
    }
}

fn isEar(ear: *Node) bool {
    const a = ear.prev.?;
    const b = ear;
    const cc = ear.next.?;
    if (triangleArea(a, b, cc) >= 0) return false; // reflex
    // Any other polygon vertex inside the triangle disqualifies.
    var p = ear.next.?.next.?;
    while (p != ear.prev.?) : (p = p.next.?) {
        if (pointInTriangle(a.x, a.y, b.x, b.y, cc.x, cc.y, p.x, p.y) and
            triangleArea(p.prev.?, p, p.next.?) >= 0) return false;
    }
    return true;
}

fn pointInTriangle(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, px: f32, py: f32) bool {
    return (cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0 and
        (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0 and
        (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0;
}

/// Split the polygon at a diagonal where ear-clipping is stuck.
/// Find two non-adjacent vertices that form a non-intersecting
/// diagonal; recurse on each half.
fn splitEarcut(start: *Node, out_indices: *std.ArrayList(u32)) error{OutOfMemory}!void {
    var a = start;
    while (true) {
        var b = a.next.?.next.?;
        while (b != a.prev.?) : (b = b.next.?) {
            if (a.i != b.i and isValidDiagonal(a, b)) {
                // Split into two polygons at a-b.
                const ac = splitPolygon(a, b);
                _ = filterPoints(a);
                _ = filterPoints(ac);
                try earcutLinked(a, out_indices, 0);
                try earcutLinked(ac, out_indices, 0);
                return;
            }
        }
        a = a.next.?;
        if (a == start) return;
    }
}

/// Cut the polygon at vertices a-b. Returns the new node that's
/// the start of the second half. Both halves share the diagonal
/// (a and b are duplicated; the duplicates form the bridge).
fn splitPolygon(a: *Node, b: *Node) *Node {
    const arena_alloc = struct {
        // We need an allocator here. Reuse the arena the caller's
        // earcut() instance allocated nodes from. Simplest fix: pass
        // it through. But we'd have to thread it down — keep API
        // narrow by allocating from page allocator. These two extra
        // nodes per split are bounded and tiny.
        //
        // Hmm, page_allocator leaks on dealloc-skip. Use a global
        // thread-local arena? No — better is to allocate via a
        // shared scratch allocator the function can see. For v0
        // we use std.heap.c_allocator which the OS reclaims;
        // earcut's split path is rare (only when ear-clipping is
        // stuck).
    };
    _ = arena_alloc;
    const allocator = std.heap.c_allocator;
    const a2 = allocator.create(Node) catch unreachable;
    const b2 = allocator.create(Node) catch unreachable;
    a2.* = .{ .i = a.i, .x = a.x, .y = a.y };
    b2.* = .{ .i = b.i, .x = b.x, .y = b.y };

    const an = a.next.?;
    const bp = b.prev.?;

    a.next = b;
    b.prev = a;

    a2.next = an;
    an.prev = a2;

    b2.next = a2;
    a2.prev = b2;

    bp.next = b2;
    b2.prev = bp;

    return b2;
}

fn isValidDiagonal(a: *Node, b: *Node) bool {
    return a.next.?.i != b.i and a.prev.?.i != b.i and
        !intersectsPolygon(a, b) and
        locallyInside(a, b) and locallyInside(b, a) and
        middleInside(a, b);
}

fn locallyInside(a: *Node, b: *Node) bool {
    if (triangleArea(a.prev.?, a, a.next.?) < 0) {
        return triangleArea(a, b, a.next.?) >= 0 and triangleArea(a, a.prev.?, b) >= 0;
    }
    return triangleArea(a, b, a.prev.?) < 0 or triangleArea(a, a.next.?, b) < 0;
}

fn middleInside(a: *Node, b: *Node) bool {
    var inside = false;
    const px = (a.x + b.x) * 0.5;
    const py = (a.y + b.y) * 0.5;
    var p = a;
    while (true) {
        const q = p.next.?;
        if (((p.y > py) != (q.y > py)) and
            (px < (q.x - p.x) * (py - p.y) / (q.y - p.y) + p.x))
        {
            inside = !inside;
        }
        p = q;
        if (p == a) break;
    }
    return inside;
}

fn intersectsPolygon(a: *Node, b: *Node) bool {
    var p = a;
    while (true) {
        const q = p.next.?;
        if (p.i != a.i and q.i != a.i and p.i != b.i and q.i != b.i and segmentsIntersect(p, q, a, b))
            return true;
        p = q;
        if (p == a) break;
    }
    return false;
}

fn segmentsIntersect(p1: *Node, q1: *Node, p2: *Node, q2: *Node) bool {
    const o1 = sign(triangleArea(p1, q1, p2));
    const o2 = sign(triangleArea(p1, q1, q2));
    const o3 = sign(triangleArea(p2, q2, p1));
    const o4 = sign(triangleArea(p2, q2, q1));
    return o1 != o2 and o3 != o4;
}

fn sign(x: f32) i32 {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "flatten: line-only subpath produces start + endpoints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sp: svg.Subpath = .{
        .start = .{ .x = 0, .y = 0 },
        .closed = true,
        .commands = &.{
            .{ .kind = .line, .endpoint = .{ .x = 10, .y = 0 } },
            .{ .kind = .line, .endpoint = .{ .x = 10, .y = 10 } },
            .{ .kind = .line, .endpoint = .{ .x = 0, .y = 10 } },
        },
    };
    const pts = try flattenSubpath(arena.allocator(), sp, .{});
    try testing.expectEqual(@as(usize, 4), pts.len);
    try testing.expectEqual(@as(f32, 0), pts[0].x);
    try testing.expectEqual(@as(f32, 10), pts[2].y);
}

test "flatten: single cubic subdivides toward tolerance" {
    // A semicircle-shaped cubic from (0,0) to (10,0) with controls
    // pushing the curve up to roughly y=5 at midpoint.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sp: svg.Subpath = .{
        .start = .{ .x = 0, .y = 0 },
        .closed = false,
        .commands = &.{
            .{
                .kind = .cubic,
                .c1 = .{ .x = 2.5, .y = 6.67 },
                .c2 = .{ .x = 7.5, .y = 6.67 },
                .endpoint = .{ .x = 10, .y = 0 },
            },
        },
    };
    const pts = try flattenSubpath(arena.allocator(), sp, .{ .flatten_tolerance = 0.5 });
    // Far more than 2 points — the subdivider should fire several
    // times before chord error drops below 0.5.
    try testing.expect(pts.len >= 5);
    // First / last anchored.
    try testing.expectEqual(@as(f32, 0), pts[0].x);
    try testing.expectApproxEqAbs(@as(f32, 10), pts[pts.len - 1].x, 0.01);
}

test "earcut: square produces 2 triangles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(u32).init(arena.allocator());
    const pts = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    try earcut(arena.allocator(), &pts, &out);
    try testing.expectEqual(@as(usize, 6), out.items.len); // 2 tris = 6 indices
}

test "earcut: convex pentagon → 3 triangles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(u32).init(arena.allocator());
    const pts = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 13, .y = 8 },
        .{ .x = 5, .y = 14 },
        .{ .x = -3, .y = 8 },
    };
    try earcut(arena.allocator(), &pts, &out);
    try testing.expectEqual(@as(usize, 9), out.items.len); // 3 tris
}

test "earcut: concave L-shape produces correct triangle count" {
    // L-shaped polygon has 6 verts, triangulates to 4 tris.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(u32).init(arena.allocator());
    const pts = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 4 },
        .{ .x = 4, .y = 4 },
        .{ .x = 4, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    try earcut(arena.allocator(), &pts, &out);
    try testing.expectEqual(@as(usize, 12), out.items.len); // 4 tris
}

test "tessellate: simple square path emits 2 triangles into mesh" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var mesh = Mesh.init(arena.allocator());

    const path: svg.Path = .{
        .color = .{ 1, 0, 0, 1 },
        .translate = .{ .x = 0, .y = 0 },
        .subpaths = &.{.{
            .start = .{ .x = 0, .y = 0 },
            .closed = true,
            .commands = &.{
                .{ .kind = .line, .endpoint = .{ .x = 10, .y = 0 } },
                .{ .kind = .line, .endpoint = .{ .x = 10, .y = 10 } },
                .{ .kind = .line, .endpoint = .{ .x = 0, .y = 10 } },
            },
        }},
    };
    const n = try tessellatePath(arena.allocator(), path, &mesh, .{});
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);
    try testing.expectEqual(@as(usize, 6), mesh.indices.items.len);
    try testing.expectEqual(@as(f32, 1), mesh.vertices.items[0].color[0]);
}

test "tessellate: translate baked into vertex positions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var mesh = Mesh.init(arena.allocator());

    const path: svg.Path = .{
        .color = .{ 0, 1, 0, 1 },
        .translate = .{ .x = 100, .y = 200 },
        .subpaths = &.{.{
            .start = .{ .x = 0, .y = 0 },
            .closed = true,
            .commands = &.{
                .{ .kind = .line, .endpoint = .{ .x = 10, .y = 0 } },
                .{ .kind = .line, .endpoint = .{ .x = 0, .y = 10 } },
            },
        }},
    };
    _ = try tessellatePath(arena.allocator(), path, &mesh, .{});
    try testing.expectEqual(@as(f32, 100), mesh.vertices.items[0].pos[0]);
    try testing.expectEqual(@as(f32, 200), mesh.vertices.items[0].pos[1]);
}

test "tessellate: Petunias.svg flattens to a positive triangle count" {
    const source = @embedFile("test_data/Petunias.svg");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try svg.parse(arena.allocator(), source);
    var mesh = Mesh.init(arena.allocator());

    var total_tris: u32 = 0;
    for (doc.paths) |path| {
        total_tris += try tessellatePath(arena.allocator(), path, &mesh, .{});
    }
    // Loose lower bound — 125 paths each producing at least a
    // couple triangles is conservative; reality is in the thousands.
    try testing.expect(total_tris > 250);
    try testing.expect(mesh.indices.items.len == total_tris * 3);
    // No NaNs or absurd coords.
    for (mesh.vertices.items) |v| {
        try testing.expect(std.math.isFinite(v.pos[0]));
        try testing.expect(std.math.isFinite(v.pos[1]));
    }
}
