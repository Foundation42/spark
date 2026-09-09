//! `:::nodegraph` — a pannable, zoomable canvas of nodes, pins and links.
//!
//! Beat 1 of the graph editor: **draw and navigate**. Pan, zoom, drag a
//! node, hover, select, write the moved positions back out. There is no
//! palette, nothing creates or breaks a link, nothing is deleted, there
//! is no marquee and no drill-in. Each of those needs a decision that is
//! not made yet, and the four things this beat DOES settle — the
//! transform, hit testing, layering, link rendering — are the four
//! everything after inherits.
//!
//! ## The name
//!
//! Read aloud beside its neighbours. `:::graph` was the working name and
//! is the one thing this file rejects: spark already has `:::chart`,
//! `:::sparkline` and `:::trend`, and a reader meeting `:::graph` in that
//! company reads "another chart". `:::nodegraph` is what Blender,
//! Houdini and Unreal all call the thing, so an author arrives knowing
//! it. Also rejected: `:::patch` (Max / PD / Reaktor's word — charming,
//! but it means "diff" to everyone else and spark HAS `:::diff`),
//! `:::wires` (names the links, not the nodes), `:::canvas` (names the
//! substrate and says nothing about what is on it — the right name for a
//! future free-draw surface, so spending it here would be theft), and
//! `:::ice` (Softimage's, and a private joke in a library that must stay
//! domain-free).
//!
//! ## spark does not learn the language
//!
//! This component is fed a description of nodes, pins, links and
//! positions and knows nothing about what they mean. The host owns the
//! language; it translates a parsed program into the grammar below and
//! translates edits back. Nothing in this file mentions rill.
//!
//! ## The grammar — one parser, two doors
//!
//! Line-oriented, `kind key=value …`, the same shape as a `:::name {…}`
//! header so an author reads it with the eye they already have. Blank
//! lines and `#` comments are skipped. One entity per line and the
//! position on the entity's own line, so a drag changes exactly one line
//! of a diff.
//!
//!     node id=src  x=0   y=40  label="Source"
//!     node id=mul  x=220 y=20  label="Multiply" tint=#5c7cff
//!     pin  node=src id=out dir=out label="v"
//!     pin  node=mul id=a   dir=in  label="a"
//!     pin  node=mul id=b   dir=in  label="b"
//!     pin  node=mul id=out dir=out label="v"
//!     link from=src.out to=mul.a
//!     view pan=-20,-10 zoom=1.0
//!
//! Records:
//!
//!   * `node id= x= y= [w=] [h=] [label=] [tint=]` — declares a node at a
//!     graph-space top-left. `w`/`h` override the size the pin count
//!     would otherwise pick.
//!   * `pin node= id= dir=in|out [label=]` — hangs a pin on a declared
//!     node. Order within a direction is the order the lines appear in.
//!   * `link from=<node>.<pin> to=<node>.<pin> [tint=]` — split on the
//!     LAST dot, so a node id may contain dots and a pin id may not.
//!     Resolved after the whole text is read, so link lines may precede
//!     the pins they name.
//!   * `pos id= x= y=` — MOVES an existing node and declares nothing.
//!     This is the write-back's own record, and the reason it is a
//!     separate kind: the positions this component emits can be fed
//!     straight back in without erasing the labels.
//!   * `view pan=x,y zoom=z` — seeds the camera. Optional.
//!
//! **Both channels carry this same text through this same parser**, and
//! that is the argument for having both rather than a reason to worry
//! about both:
//!
//!   * `Spec.body` is the STATIC door. A document with a graph in it is
//!     self-contained — an author, a demo and a gate can each make one
//!     with no host at all, which is what makes this beat testable and
//!     lookable-at. `Body.adopt` makes the ordinary re-parse (nothing
//!     changed) cost one hash.
//!   * `Factory.handle_update` is the HOST's door, for the two cases the
//!     body cannot serve: a host that re-translates its program at
//!     streaming rate must not re-parse a whole markdown document to
//!     push a new graph, and must not round-trip a position echo through
//!     a document rewrite. `action=graph` replaces everything;
//!     `action=move` applies `pos` records only and leaves the structure
//!     alone.
//!
//! ## The transform, and where graph space stops
//!
//! There is no transform stack in this library — `:::svg` multiplies
//! every vertex by hand and so does this. The camera is
//!
//!     local  = (graph - pan) * zoom          `View.toLocal`
//!     graph  = pan + local / zoom            `View.toGraph`
//!     screen = origin + local                `View.toScreen`
//!
//! `pan` is the graph point sitting at the canvas's top-left; `zoom` is
//! screen pixels per graph unit.
//!
//! **The boundary is `local`.** `onInput` and `on_hover` hand out
//! `world - hit.box.xy`, which is canvas-local screen pixels — so the
//! origin cancels and every input path converts with `toGraph` alone.
//! The draw path is the only place the origin appears, and it appears
//! once, in `toScreen`. That is why `toLocal`/`toGraph` is the pair the
//! round-trip gate exercises: it is the whole of the invertible part.
//!
//! Two consequences that are easy to get wrong and are gated:
//!
//!   * `Spark.endFrame` scales a quad's `radius` by the GLOBAL zoom and
//!     knows nothing about this one, so every radius emitted here is
//!     pre-multiplied by `view.zoom`.
//!   * a drag is `(local - press_local) / zoom` — a graph-space delta.
//!     Using the screen delta makes the node lag the cursor at zoom > 1
//!     and outrun it below 1, and a gate at zoom = 1 routes around it.
//!
//! ## Layering — obeyed, not fought
//!
//! The renderer draws tris, then images, then quads, then glyphs, per
//! layer in array order and NOT in emission order. So:
//!
//!   * the canvas ground and the grid are **triangles** (`relief.rect`),
//!     because a quad ground would be drawn on top of the links;
//!   * the links are **triangles**, emitted after the ground;
//!   * node bodies, headers and pins are **rounded quads**, which puts
//!     every one of them above every link for free and buys anti-
//!     aliasing and corner radii from `quad.frag`;
//!   * labels are **glyphs**, above everything.
//!
//! The corollary is the trap: node chrome must never reach for `relief`,
//! or it sinks under the wires. That is the trackball's recessed dial
//! again, one vocabulary along.
//!
//! ## What the clip does and does not reach
//!
//! `DrawList` scissors quads and glyphs and does NOT scissor triangles —
//! `sealClips` fills `quad_clips` and `glyph_clips` and there is no
//! `tri_clips`. The links are triangles. So this component clips its own
//! link segments, per segment, against the canvas rect (`clipSegment`),
//! and culls whole links whose bounds miss it. A stroke running along
//! the canvas edge still bleeds its half-width plus a feather — about
//! two and a half pixels — because the clip is on the segment's axis and
//! not its silhouette. Recorded, not built: a silhouette clip, when a
//! graph first sits flush against another panel.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
const relief = @import("relief.zig");

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("nodegraph", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

// ── Visual constants ────────────────────────────────────────────────
// Everything here is in GRAPH units. The camera turns them into
// pixels; nothing below has an opinion about zoom.

/// Default node width. Not measured from the label, deliberately: a
/// width that depended on the font would make the hit boxes depend on
/// the font too, and then every geometry gate in this file would need a
/// device to run. A host that knows its labels says `w=`.
pub const NODE_W: f32 = 160;
/// The title bar's height, and where the first pin row starts under it.
///
/// **These are graph units and the labels are in the host's font**, and
/// there is no measure pass to reconcile them — see `NODE_W`. So they
/// are sized generously for a body face around 20px: a header that
/// clears one line of it, and a pin pitch that clears another. A host
/// running a much larger face gets crowding, and its answer is `w=`/`h=`
/// per node. The alternative — measuring, and letting the font decide
/// the hit boxes — is what would make every geometry gate in this file
/// need a device to run.
const HEADER_H: f32 = 26;
/// Vertical distance between two pin rows.
const PIN_PITCH: f32 = 22;
/// Where the first pin's centre sits below the header.
const PIN_TOP: f32 = 16;
/// Space under the last pin row.
const PIN_BOTTOM: f32 = 12;
/// A node with no pins at all is still a node you can grab.
const NODE_MIN_H: f32 = HEADER_H + 18;
const NODE_RADIUS: f32 = 5;
/// How far the selection / hover ring stands out past the body.
const RING_PAD: f32 = 2.0;

/// Pin dot radius, and the generous radius a press or a hover tests
/// against — a 4px dot is not a 4px target.
const PIN_R: f32 = 4.0;
const PIN_HIT_R: f32 = 8.0;

const CANVAS_BG: [4]f32 = .{ 0.075, 0.082, 0.098, 1.0 };
const GRID_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.045 };
const GRID_COLOR_MAJOR: [4]f32 = .{ 1.0, 1.0, 1.0, 0.085 };
/// Grid spacing in graph units, and the major line every N of them.
const GRID_STEP: f32 = 32;
const GRID_MAJOR: u32 = 4;
/// Below this many screen pixels between lines the grid is noise, so it
/// is not drawn at all. Zooming out a big graph stops paying for it.
const GRID_MIN_PX: f32 = 7.0;

const NODE_BG: [4]f32 = .{ 0.16, 0.175, 0.205, 1.0 };
const NODE_HEADER_TINT: f32 = 0.55;
const NODE_RING: [4]f32 = .{ 0.0, 0.0, 0.0, 0.55 };
const NODE_RING_HOVER: [4]f32 = .{ 1.0, 1.0, 1.0, 0.30 };
const NODE_RING_SELECTED: [4]f32 = .{ 1.0, 0.78, 0.32, 0.95 };
const NODE_TINT_DEFAULT: [4]f32 = .{ 0.36, 0.44, 0.62, 1.0 };

const PIN_IN_COLOR: [4]f32 = .{ 0.55, 0.72, 0.95, 1.0 };
const PIN_OUT_COLOR: [4]f32 = .{ 0.62, 0.86, 0.68, 1.0 };
const PIN_HOVER_COLOR: [4]f32 = .{ 1.0, 0.95, 0.72, 1.0 };

const LINK_COLOR: [4]f32 = .{ 0.62, 0.70, 0.84, 0.85 };
/// Link stroke width, in SCREEN pixels — a wire is chrome, so it keeps
/// its weight when you zoom out and the graph does not turn to fog.
const LINK_W: f32 = 1.8;
/// Horizontal pull on a link's control points, as a fraction of the
/// horizontal gap, clamped so a very short hop still bulges and a very
/// long one does not loop.
const LINK_TANGENT_FRAC: f32 = 0.55;
const LINK_TANGENT_MIN: f32 = 24;
const LINK_TANGENT_MAX: f32 = 180;
/// Roughly how many screen pixels of arc one flattened segment covers,
/// and the bounds either side. The count is derived from the SCREEN
/// chord, so a zoomed-out graph costs proportionally less.
const LINK_PX_PER_SEG: f32 = 22.0;
const LINK_MIN_SEGS: usize = 3;
const LINK_MAX_SEGS: usize = 24;
/// How far past each joint a segment is extended, in screen pixels.
///
/// `relief.stroke` feathers its CAPS as well as its sides, so two
/// segments that butt exactly leave a seam of half-alpha down the join —
/// the same "two edge treatments a pixel apart" artefact the trackball's
/// rims had. `:::curve` hides its joints under pucks; a wire has no
/// pucks, so the segments have to overlap instead. It must exceed
/// `relief.FEATHER`, or the overlap lands inside the feather and the
/// seam survives.
const LINK_JOINT_OVERLAP: f32 = relief.FEATHER + 0.75;

/// Below this zoom a label is a smudge, and rasterising it at that size
/// costs a fresh face per zoom level. So labels have a floor and simply
/// stop being drawn under it — the standard level-of-detail move, and
/// the thing that makes a fifty-node graph cheap when it is zoomed out
/// to fit.
const LABEL_MIN_ZOOM: f32 = 0.45;
const LABEL_PAD_X: f32 = 8;
const PIN_LABEL_GAP: f32 = 9;

const ZOOM_MIN: f32 = 0.2;
const ZOOM_MAX: f32 = 4.0;
/// Zoom multiplier per wheel notch. `dy` arrives in pixels (the host
/// multiplies its notch size once), so this is per-pixel and small.
const ZOOM_PER_PX: f32 = 0.0022;

const ERR_STRIP_H: f32 = 20;
const ERR_STRIP_BG: [4]f32 = .{ 0.42, 0.12, 0.14, 0.92 };

// ── The camera ──────────────────────────────────────────────────────

/// Where the canvas is looking. `pan` is the GRAPH point that sits at
/// the canvas's top-left corner; `zoom` is screen pixels per graph unit.
///
/// Rejected shapes: a screen-space offset (`screen = graph*zoom +
/// offset`), which makes zoom-at-cursor a two-term correction instead of
/// one substitution; and a centre-plus-zoom, which needs the canvas size
/// to mean anything and so cannot be inverted from `local` alone.
pub const View = struct {
    pan: [2]f32 = .{ 0, 0 },
    zoom: f32 = 1,

    /// Graph → canvas-local, i.e. screen pixels measured from the
    /// canvas's own top-left. This is the half of the transform the
    /// input edge speaks, because `MouseEvent.local` is already in it.
    pub fn toLocal(self: View, g: [2]f32) [2]f32 {
        return .{
            (g[0] - self.pan[0]) * self.zoom,
            (g[1] - self.pan[1]) * self.zoom,
        };
    }

    /// Canvas-local → graph. The inverse of `toLocal`, and the only
    /// place in this file that divides by zoom.
    pub fn toGraph(self: View, l: [2]f32) [2]f32 {
        return .{
            self.pan[0] + l[0] / self.zoom,
            self.pan[1] + l[1] / self.zoom,
        };
    }

    /// Graph → spark world coords. The ONE place the canvas's origin
    /// enters, which is what keeps every input path origin-free.
    pub fn toScreen(self: View, origin: [2]f32, g: [2]f32) [2]f32 {
        const l = self.toLocal(g);
        return .{ origin[0] + l[0], origin[1] + l[1] };
    }

    /// Re-aim so that `anchor_local` keeps showing the same graph point
    /// at the new zoom. Zooming about the canvas corner instead is the
    /// difference between a camera and a slider.
    pub fn zoomAbout(self: *View, anchor_local: [2]f32, new_zoom: f32) void {
        const g = self.toGraph(anchor_local);
        self.zoom = new_zoom;
        self.pan = .{
            g[0] - anchor_local[0] / new_zoom,
            g[1] - anchor_local[1] / new_zoom,
        };
    }
};

// ── The graph ───────────────────────────────────────────────────────

pub const Dir = enum { in, out };

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    /// Graph-space top-left.
    pos: [2]f32,
    size: [2]f32,
    tint: [4]f32,
    /// Set when the description gave an explicit `w=` / `h=`, so
    /// `finalise` leaves them alone.
    w_given: bool = false,
    h_given: bool = false,
    in_count: u32 = 0,
    out_count: u32 = 0,
};

pub const Pin = struct {
    node: u32,
    id: []const u8,
    label: []const u8,
    dir: Dir,
    /// Row within this node's pins of the same direction.
    slot: u32,
};

pub const Link = struct {
    from: u32,
    to: u32,
    tint: [4]f32,
};

/// A link as it was written, before the pins it names exist. Resolved
/// after the whole description is read so link lines may precede pin
/// lines — a host that emits its records in declaration order should not
/// have to topologically sort them first.
const PendingLink = struct {
    from: []const u8,
    to: []const u8,
    tint: [4]f32,
};

// ── The description parser ──────────────────────────────────────────

/// One `key=value` from a record line. Values may be bare (up to the
/// next space) or `"quoted"` (up to the closing quote, no escapes — the
/// same rule `markdown_components.parseDirectiveLine` uses, and
/// deliberately the same, because an author reads both).
const Field = struct { key: []const u8, value: []const u8 };

const FieldIter = struct {
    rest: []const u8,

    fn next(self: *FieldIter) ?Field {
        var s = self.rest;
        var i: usize = 0;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        s = s[i..];
        if (s.len == 0) {
            self.rest = s;
            return null;
        }
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse {
            // A bare token with no `=`. Consume it so the iterator
            // terminates rather than spinning, and report nothing.
            self.rest = "";
            return null;
        };
        const key = s[0..eq];
        var v = s[eq + 1 ..];
        if (v.len > 0 and v[0] == '"') {
            const close = std.mem.indexOfScalar(u8, v[1..], '"') orelse {
                self.rest = "";
                return .{ .key = key, .value = v[1..] };
            };
            const value = v[1 .. 1 + close];
            self.rest = v[close + 2 ..];
            return .{ .key = key, .value = value };
        }
        const end = std.mem.indexOfAny(u8, v, " \t") orelse v.len;
        const value = v[0..end];
        v = v[end..];
        self.rest = v;
        return .{ .key = key, .value = value };
    }
};

fn parseNum(s: []const u8) ?f32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t\r\n")) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// Split `node.pin` on the LAST dot. Node ids may contain dots; pin ids
/// may not. Stated in the module header because it is the one place the
/// grammar is not obvious from a line of it.
fn splitRef(ref: []const u8) ?struct { node: []const u8, pin: []const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, ref, '.') orelse return null;
    if (dot == 0 or dot + 1 >= ref.len) return null;
    return .{ .node = ref[0..dot], .pin = ref[dot + 1 ..] };
}

// ── Geometry, all of it pure ────────────────────────────────────────

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn nodeRect(n: Node) Rect {
    return .{ .x = n.pos[0], .y = n.pos[1], .w = n.size[0], .h = n.size[1] };
}

fn rectContains(r: Rect, p: [2]f32) bool {
    return p[0] >= r.x and p[0] <= r.x + r.w and p[1] >= r.y and p[1] <= r.y + r.h;
}

/// A segment of a flattened link, in whatever space its caller built it.
pub const Seg = struct { a: [2]f32, b: [2]f32 };

fn cubicAt(p0: [2]f32, c0: [2]f32, c1: [2]f32, p1: [2]f32, t: f32) [2]f32 {
    const u = 1 - t;
    const w0 = u * u * u;
    const w1 = 3 * u * u * t;
    const w2 = 3 * u * t * t;
    const w3 = t * t * t;
    return .{
        p0[0] * w0 + c0[0] * w1 + c1[0] * w2 + p1[0] * w3,
        p0[1] * w0 + c0[1] * w1 + c1[1] * w2 + p1[1] * w3,
    };
}

/// Flatten a cubic into `n` straight segments, each **extended past both
/// of its joints by `overlap`** along its own direction.
///
/// The extension is the whole point and is why this is not three lines
/// inline at the call site. `relief.stroke` feathers its caps, so
/// segments that butt exactly leave a half-alpha seam down every joint —
/// visible as a dotted line along a wire. Extending both ends puts each
/// segment's solid body over its neighbour's feather.
///
/// Called in SCREEN space, because `overlap` has to be compared against
/// `relief.FEATHER`, which is a pixel.
///
/// Returns the prefix of `buf` that was written. `n` is clamped to what
/// `buf` can hold, so a caller cannot overrun by asking for more.
pub fn linkSegments(
    buf: []Seg,
    p0: [2]f32,
    c0: [2]f32,
    c1: [2]f32,
    p1: [2]f32,
    n_in: usize,
    overlap: f32,
) []Seg {
    const n = @min(@max(n_in, 1), buf.len);
    var prev = p0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
        const next = if (i + 1 == n) p1 else cubicAt(p0, c0, c1, p1, t);
        const dx = next[0] - prev[0];
        const dy = next[1] - prev[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len > 1e-6) {
            const ux = dx / len * overlap;
            const uy = dy / len * overlap;
            buf[i] = .{
                .a = .{ prev[0] - ux, prev[1] - uy },
                .b = .{ next[0] + ux, next[1] + uy },
            };
        } else {
            buf[i] = .{ .a = prev, .b = next };
        }
        prev = next;
    }
    return buf[0..n];
}

/// How many segments a link is worth, from its SCREEN chord. A wire
/// stretched across the viewport gets more than a stub between adjacent
/// nodes, and a graph zoomed out to fit pays proportionally less.
pub fn segmentCount(p0: [2]f32, p1: [2]f32, zoom: f32) usize {
    const dx = (p1[0] - p0[0]) * zoom;
    const dy = (p1[1] - p0[1]) * zoom;
    const chord = @sqrt(dx * dx + dy * dy);
    const n: f32 = @round(chord / LINK_PX_PER_SEG);
    if (!(n > @as(f32, @floatFromInt(LINK_MIN_SEGS)))) return LINK_MIN_SEGS;
    if (n > @as(f32, @floatFromInt(LINK_MAX_SEGS))) return LINK_MAX_SEGS;
    return @intFromFloat(n);
}

/// Liang–Barsky. Trim a segment to `r`, or report that none of it is
/// inside. This is here because the DrawList scissors quads and glyphs
/// and NOT triangles, and the links are triangles — see the module
/// header.
pub fn clipSegment(seg: Seg, r: Rect) ?Seg {
    var t0: f32 = 0;
    var t1: f32 = 1;
    const dx = seg.b[0] - seg.a[0];
    const dy = seg.b[1] - seg.a[1];

    const ps = [4]f32{ -dx, dx, -dy, dy };
    const qs = [4]f32{
        seg.a[0] - r.x,
        r.x + r.w - seg.a[0],
        seg.a[1] - r.y,
        r.y + r.h - seg.a[1],
    };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return null; // parallel to this edge, outside it
            continue;
        }
        const t = q / p;
        if (p < 0) {
            if (t > t1) return null;
            if (t > t0) t0 = t;
        } else {
            if (t < t0) return null;
            if (t < t1) t1 = t;
        }
    }
    return .{
        .a = .{ seg.a[0] + t0 * dx, seg.a[1] + t0 * dy },
        .b = .{ seg.a[0] + t1 * dx, seg.a[1] + t1 * dy },
    };
}

// ── Component ───────────────────────────────────────────────────────

/// What a press grabbed, latched at `mouse_down` and held until the
/// button comes up.
///
/// The latch is not a convenience. It is the gate on `ingest`: while a
/// grab is live the widget is the truth and a description arriving from
/// the plane is refused, because `State.set` notifies synchronously and
/// a re-parse landing between a drag's two writes would move the node
/// out from under the finger holding it. Between gestures the plane is
/// the truth; during one, we are.
const Grab = union(enum) {
    none,
    /// A node is being dragged. `press_local` and `start_pos` together
    /// make the drag a pure graph-space delta, so it tracks the cursor
    /// at any zoom and does not accumulate error over a long drag.
    node: struct {
        index: u32,
        press_local: [2]f32,
        start_pos: [2]f32,
        moved: bool,
    },
    /// The canvas is being panned.
    pan: struct {
        press_local: [2]f32,
        start_pan: [2]f32,
    },
    /// A pin is held. It moves nothing in this beat — making and
    /// breaking links is a later one — and it exists anyway so that
    /// EVERY press latches something.
    ///
    /// Without it a press on a pin is the one route into
    /// `writeSelection` that runs with `ingest` still open, which is
    /// three quarters of a guard. The beat that makes this press start
    /// a link drag would have inherited that hole with no sign of it.
    pin: u32,
};

pub const Hover = union(enum) {
    none,
    node: u32,
    pin: u32,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Owns every string the description produced. Reset wholesale on
    /// re-parse; the three lists below keep their capacity across it.
    arena: *std.heap.ArenaAllocator,

    nodes: std.ArrayList(Node),
    pins: std.ArrayList(Pin),
    links: std.ArrayList(Link),

    body: component_mod.Body = .{},
    view: View = .{},
    width: box_helpers.Length = .{ .percent = 1.0 },
    height: f32 = 420,

    /// Bare state paths, `:::slider {target=}`-style. Empty means "not
    /// bound", and an unbound channel is simply never written.
    positions_path: []u8,
    selected_path: []u8,

    selected: ?u32 = null,
    hovered: Hover = .none,
    grab: Grab = .none,

    /// What we last wrote to each path, so a write that would change
    /// nothing is not made at all — the same gate `:::trackball`
    /// keeps, and for the same reason.
    last_selected_written: []u8,

    /// Set aside by `handleUpdate` when a push lands mid-gesture, applied
    /// when the gesture ends. The body channel needs no such queue: it is
    /// re-delivered on every re-parse, and the drag's own `State.set`
    /// guarantees one. A `handle_update` is a one-shot, so dropping it
    /// would be data loss.
    pending: ?[]u8 = null,
    pending_positions_only: bool = false,

    /// Unreadable description lines, shown as a strip rather than
    /// swallowed. A host that ships a malformed record should find out
    /// from the picture.
    bad_lines: u32 = 0,

    version: u64 = 0,

    fn gesturing(self: *const Component) bool {
        return self.grab != .none;
    }

    // ── Reading the description ────────────────────────────────────

    fn clearGraph(self: *Component) void {
        self.nodes.clearRetainingCapacity();
        self.pins.clearRetainingCapacity();
        self.links.clearRetainingCapacity();
        self.selected = null;
        self.hovered = .none;
        _ = self.arena.reset(.retain_capacity);
    }

    fn findNode(self: *const Component, id: []const u8) ?u32 {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.id, id)) return @intCast(i);
        }
        return null;
    }

    fn findPin(self: *const Component, node: u32, id: []const u8) ?u32 {
        for (self.pins.items, 0..) |p, i| {
            if (p.node == node and std.mem.eql(u8, p.id, id)) return @intCast(i);
        }
        return null;
    }

    /// Parse `text`. `positions_only` applies `pos` records to the graph
    /// that is already there and ignores everything else — the `move`
    /// action, and the shape that makes an echoed write-back a no-op.
    fn parse(self: *Component, text: []const u8, positions_only: bool) !void {
        const a = self.arena.allocator();
        if (!positions_only) self.clearGraph();
        self.bad_lines = 0;

        var pending = std.ArrayList(PendingLink).init(self.allocator);
        defer pending.deinit();

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const kind_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            const kind = line[0..kind_end];
            var it = FieldIter{ .rest = line[kind_end..] };

            if (std.mem.eql(u8, kind, "pos")) {
                var id: []const u8 = "";
                var x: ?f32 = null;
                var y: ?f32 = null;
                while (it.next()) |f| {
                    if (std.mem.eql(u8, f.key, "id")) id = f.value;
                    if (std.mem.eql(u8, f.key, "x")) x = parseNum(f.value);
                    if (std.mem.eql(u8, f.key, "y")) y = parseNum(f.value);
                }
                const idx = self.findNode(id) orelse {
                    self.bad_lines += 1;
                    continue;
                };
                if (x) |v| self.nodes.items[idx].pos[0] = v;
                if (y) |v| self.nodes.items[idx].pos[1] = v;
                continue;
            }

            if (positions_only) continue;

            if (std.mem.eql(u8, kind, "node")) {
                var n = Node{
                    .id = "",
                    .label = "",
                    .pos = .{ 0, 0 },
                    .size = .{ NODE_W, NODE_MIN_H },
                    .tint = NODE_TINT_DEFAULT,
                };
                while (it.next()) |f| {
                    if (std.mem.eql(u8, f.key, "id")) {
                        n.id = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "label")) {
                        n.label = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "x")) {
                        if (parseNum(f.value)) |v| n.pos[0] = v;
                    } else if (std.mem.eql(u8, f.key, "y")) {
                        if (parseNum(f.value)) |v| n.pos[1] = v;
                    } else if (std.mem.eql(u8, f.key, "w")) {
                        if (parseNum(f.value)) |v| {
                            n.size[0] = @max(v, 8);
                            n.w_given = true;
                        }
                    } else if (std.mem.eql(u8, f.key, "h")) {
                        if (parseNum(f.value)) |v| {
                            n.size[1] = @max(v, 8);
                            n.h_given = true;
                        }
                    } else if (std.mem.eql(u8, f.key, "tint")) {
                        if (box_helpers.parseColor(f.value)) |c| n.tint = c;
                    }
                }
                if (n.id.len == 0) {
                    self.bad_lines += 1;
                    continue;
                }
                if (n.label.len == 0) n.label = n.id;
                try self.nodes.append(n);
            } else if (std.mem.eql(u8, kind, "pin")) {
                var node_id: []const u8 = "";
                var p = Pin{ .node = 0, .id = "", .label = "", .dir = .in, .slot = 0 };
                while (it.next()) |f| {
                    if (std.mem.eql(u8, f.key, "node")) {
                        node_id = f.value;
                    } else if (std.mem.eql(u8, f.key, "id")) {
                        p.id = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "label")) {
                        p.label = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "dir")) {
                        p.dir = if (std.mem.eql(u8, f.value, "out")) .out else .in;
                    }
                }
                const owner = self.findNode(node_id) orelse {
                    self.bad_lines += 1;
                    continue;
                };
                if (p.id.len == 0) {
                    self.bad_lines += 1;
                    continue;
                }
                p.node = owner;
                const n = &self.nodes.items[owner];
                p.slot = switch (p.dir) {
                    .in => n.in_count,
                    .out => n.out_count,
                };
                switch (p.dir) {
                    .in => n.in_count += 1,
                    .out => n.out_count += 1,
                }
                try self.pins.append(p);
            } else if (std.mem.eql(u8, kind, "link")) {
                var pl = PendingLink{ .from = "", .to = "", .tint = LINK_COLOR };
                while (it.next()) |f| {
                    if (std.mem.eql(u8, f.key, "from")) {
                        pl.from = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "to")) {
                        pl.to = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "tint")) {
                        if (box_helpers.parseColor(f.value)) |c| pl.tint = c;
                    }
                }
                if (pl.from.len == 0 or pl.to.len == 0) {
                    self.bad_lines += 1;
                    continue;
                }
                try pending.append(pl);
            } else if (std.mem.eql(u8, kind, "view")) {
                while (it.next()) |f| {
                    if (std.mem.eql(u8, f.key, "zoom")) {
                        if (parseNum(f.value)) |v| {
                            self.view.zoom = std.math.clamp(v, ZOOM_MIN, ZOOM_MAX);
                        }
                    } else if (std.mem.eql(u8, f.key, "pan")) {
                        const comma = std.mem.indexOfScalar(u8, f.value, ',') orelse continue;
                        if (parseNum(f.value[0..comma])) |x| self.view.pan[0] = x;
                        if (parseNum(f.value[comma + 1 ..])) |y| self.view.pan[1] = y;
                    }
                }
            } else {
                self.bad_lines += 1;
            }
        }

        if (!positions_only) {
            self.finalise();
            for (pending.items) |pl| {
                const from = self.resolveRef(pl.from) orelse {
                    self.bad_lines += 1;
                    continue;
                };
                const to = self.resolveRef(pl.to) orelse {
                    self.bad_lines += 1;
                    continue;
                };
                try self.links.append(.{ .from = from, .to = to, .tint = pl.tint });
            }
        }
        self.version +%= 1;
    }

    fn resolveRef(self: *const Component, ref: []const u8) ?u32 {
        const parts = splitRef(ref) orelse return null;
        const node = self.findNode(parts.node) orelse return null;
        return self.findPin(node, parts.pin);
    }

    /// Size every node that did not state its own. Runs after the whole
    /// description is read, because the pin count that drives the height
    /// is not known until then.
    fn finalise(self: *Component) void {
        for (self.nodes.items) |*n| {
            if (!n.w_given) n.size[0] = NODE_W;
            if (!n.h_given) {
                const rows: f32 = @floatFromInt(@max(n.in_count, n.out_count));
                const h = HEADER_H + PIN_TOP + @max(rows - 1, 0) * PIN_PITCH + PIN_BOTTOM;
                n.size[1] = @max(h, NODE_MIN_H);
            }
        }
    }

    /// A pin's centre, in graph space.
    pub fn pinCentre(self: *const Component, pin: u32) [2]f32 {
        const p = self.pins.items[pin];
        const n = self.nodes.items[p.node];
        const y = n.pos[1] + HEADER_H + PIN_TOP + @as(f32, @floatFromInt(p.slot)) * PIN_PITCH;
        const x = if (p.dir == .in) n.pos[0] else n.pos[0] + n.size[0];
        return .{ x, y };
    }

    /// What is under a graph-space point. Pins first — they stand proud
    /// of the body and their targets deliberately overlap it — then
    /// nodes in reverse declaration order, so the one drawn last (on
    /// top) is the one picked.
    pub fn pick(self: *const Component, g: [2]f32) Hover {
        var i = self.pins.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.pinCentre(@intCast(i));
            const dx = g[0] - c[0];
            const dy = g[1] - c[1];
            if (dx * dx + dy * dy <= PIN_HIT_R * PIN_HIT_R) return .{ .pin = @intCast(i) };
        }
        var j = self.nodes.items.len;
        while (j > 0) {
            j -= 1;
            if (rectContains(nodeRect(self.nodes.items[j]), g)) return .{ .node = @intCast(j) };
        }
        return .none;
    }

    // ── Attributes ─────────────────────────────────────────────────

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        // ── The gate that keeps a drag honest ──────────────────────
        //
        // `State.set` notifies synchronously, so writing this
        // component's own bound path re-enters the registry, which
        // re-substitutes the attrs and calls `update`, which lands here
        // — with the drag still in progress. Re-parsing the description
        // there would put every node back where the PLANE thinks it is,
        // which is where it was before the drag started: the node snaps
        // home under the finger holding it, and the next `mouse_move`
        // drags it out again. That is `:::trackball`'s puck jumping, in
        // a canvas.
        //
        // Note the body digest is NOT adopted on this path. A refusal
        // that swallowed the change would lose it; leaving the digest
        // stale means the very next re-parse — and the drag's own write
        // guarantees one — delivers it again and it lands then.
        if (self.gesturing()) return;

        const a = self.allocator;
        for (spec.attrs) |attr| {
            const k = attr.key;
            if (std.mem.eql(u8, k, "positions")) {
                try component_mod.adoptString(a, &self.positions_path, attr.value);
            } else if (std.mem.eql(u8, k, "selected")) {
                try component_mod.adoptString(a, &self.selected_path, attr.value);
            } else if (std.mem.eql(u8, k, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, k, "height")) {
                if (parseNum(attr.value)) |v| {
                    if (v > 32) self.height = v;
                }
            } else if (std.mem.eql(u8, k, "zoom")) {
                if (parseNum(attr.value)) |v| {
                    self.view.zoom = std.math.clamp(v, ZOOM_MIN, ZOOM_MAX);
                }
            }
        }

        if (self.body.adopt(spec.body)) try self.parse(spec.body, false);
        self.version +%= 1;
    }

    // ── Writing back ───────────────────────────────────────────────

    /// Emit every node's position as `pos` records and set the bound
    /// path to it, in ONE `State.set`.
    ///
    /// Once per gesture, not once per frame and not once per node: three
    /// writes a frame during a sixty-hertz drag is three synchronous
    /// re-entries a frame into a registry that is about to re-substitute
    /// attributes and call back into this component. The whole set every
    /// time rather than just the node that moved, because the host then
    /// never has to accumulate: what arrives is the complete, current,
    /// idempotent layout, in the same record kind it can feed straight
    /// back.
    fn writePositions(self: *Component, state: *state_mod.State) !void {
        if (self.positions_path.len == 0) return;
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();
        for (self.nodes.items) |n| {
            try w.print("pos id={s} x={d:.2} y={d:.2}\n", .{ n.id, n.pos[0], n.pos[1] });
        }
        try state.set(self.positions_path, buf.items);
    }

    fn writeSelection(self: *Component, state: *state_mod.State) !void {
        if (self.selected_path.len == 0) return;
        const id: []const u8 = if (self.selected) |i| self.nodes.items[i].id else "";
        if (std.mem.eql(u8, id, self.last_selected_written)) return;
        const dup = try self.allocator.dupe(u8, id);
        self.allocator.free(self.last_selected_written);
        self.last_selected_written = dup;
        try state.set(self.selected_path, id);
    }

    /// Apply whatever a `handle_update` had to set aside because a
    /// gesture was live. Called from `mouse_up`, BEFORE the latch is
    /// cleared, so the apply itself cannot be re-entered.
    fn drainPending(self: *Component) !void {
        const p = self.pending orelse return;
        self.pending = null;
        defer self.allocator.free(p);
        try self.parse(p, self.pending_positions_only);
        // Same precedence as the immediate path in `handleUpdate`: the
        // digest now describes text this component no longer holds, so
        // the next document re-parse re-adopts and the DOCUMENT wins
        // again. A stream is a faster picture of the same thing, not a
        // fork of it.
        self.body.digest = 0;
    }
};

// ── Factory ─────────────────────────────────────────────────────────

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    _ = spark;
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Each owned string gets its own errdefer BEFORE it lands in the
    // struct. Duping them inline in the initialiser reads better and
    // leaks the earlier ones when a later one fails — and leaks all
    // three, plus the lists, when `ingest` does.
    const positions = try allocator.dupe(u8, "");
    errdefer allocator.free(positions);
    const selected = try allocator.dupe(u8, "");
    errdefer allocator.free(selected);
    const last_selected = try allocator.dupe(u8, "");
    errdefer allocator.free(last_selected);

    c.* = .{
        .allocator = allocator,
        .arena = arena,
        .nodes = std.ArrayList(Node).init(allocator),
        .pins = std.ArrayList(Pin).init(allocator),
        .links = std.ArrayList(Link).init(allocator),
        .positions_path = positions,
        .selected_path = selected,
        .last_selected_written = last_selected,
    };
    errdefer {
        c.nodes.deinit();
        c.pins.deinit();
        c.links.deinit();
    }
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.nodes.deinit();
    c.pins.deinit();
    c.links.deinit();
    allocator.free(c.positions_path);
    allocator.free(c.selected_path);
    allocator.free(c.last_selected_written);
    if (c.pending) |p| allocator.free(p);
    c.arena.deinit();
    allocator.destroy(c.arena);
    allocator.destroy(c);
}

/// The host's door. `graph` replaces the description wholesale; `move`
/// applies `pos` records to the graph already on screen.
///
/// A push that arrives mid-gesture is SET ASIDE, not dropped and not
/// applied: applying it moves the node out from under the finger, and
/// dropping it loses structure a host will never send again. The body
/// channel needs no queue — it is re-delivered on the next re-parse, and
/// the drag's own write guarantees one — but this channel is a one-shot.
fn handleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const positions_only = std.mem.eql(u8, action, "move");
    if (!positions_only and !std.mem.eql(u8, action, "graph")) return error.UnknownGraphAction;

    if (c.gesturing()) {
        const dup = try c.allocator.dupe(u8, body);
        if (c.pending) |old| c.allocator.free(old);
        c.pending = dup;
        c.pending_positions_only = positions_only;
        return;
    }
    try c.parse(body, positions_only);
    // The body digest now describes text this component no longer holds.
    // Clearing it means the next document re-parse re-adopts and the
    // DOCUMENT wins again, which is the right precedence: a stream is a
    // faster picture of the same thing, not a fork of it.
    c.body.digest = 0;
}

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .on_hover = onHover,
    .on_scroll = onScroll,
    .content_version = contentVersion,
    // The canvas appends its own hit, for the reason `emits_own_hits`
    // exists: the walker's hit lands AFTER anything inside and
    // `findHit` scans backwards. Nothing is inside a graph yet, but a
    // beat that puts an inline editor on a node would inherit a canvas
    // that ate every click meant for it.
    .emits_own_hits = true,
    // The block cache cannot see the camera. Pan and zoom are internal
    // state that changes the output of every primitive without changing
    // any attribute, which is exactly the case this flag names.
    .disable_cache = true,
};

// ── Render ──────────────────────────────────────────────────────────

fn tinted(c: [4]f32, f: f32) [4]f32 {
    return .{ c[0] * f, c[1] * f, c[2] * f, c[3] };
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 720;
    const w = c.width.resolve(max_w, fallback_w);
    const h = c.height;
    const canvas = Rect{ .x = origin[0], .y = origin[1], .w = w, .h = h };

    // Seal what came before under the clip already in force, so the
    // canvas's own clip cannot reach backwards over its siblings.
    try out.sealClips(lc.current_clip);

    try out.hits.append(.{
        .box = .{ .x = canvas.x, .y = canvas.y, .w = canvas.w, .h = canvas.h },
        .vtable = &vtable,
        .ctx = ctx,
        .state = lc.state,
    });

    const outer = lc.current_clip;
    const clip = try out.pushClip(outer, .{ .x = canvas.x, .y = canvas.y, .w = canvas.w, .h = canvas.h });
    lc.current_clip = clip;

    drawCanvas(c, canvas, lc, out) catch |e| {
        try out.sealClips(clip);
        lc.current_clip = outer;
        return e;
    };

    try out.sealClips(clip);
    lc.current_clip = outer;

    return .{ .x = canvas.x, .y = canvas.y, .w = w, .h = h, .baseline = canvas.y + h };
}

fn drawCanvas(
    c: *Component,
    canvas: Rect,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) !void {
    const origin = [2]f32{ canvas.x, canvas.y };
    const z = c.view.zoom;

    // ── Ground and grid: TRIANGLES ─────────────────────────────────
    // A quad ground would be drawn on top of every wire, because the
    // renderer puts the whole quad layer over the whole triangle layer
    // regardless of who emitted what first. Same shape as the
    // trackball's recessed dial; same fix.
    try relief.rect(out, lc, canvas.x, canvas.y, canvas.w, canvas.h, CANVAS_BG);
    try drawGrid(c, canvas, lc, out);

    // ── Links: TRIANGLES, over the ground, under everything else ───
    var seg_buf: [LINK_MAX_SEGS]Seg = undefined;
    for (c.links.items) |l| {
        const g0 = c.pinCentre(l.from);
        const g1 = c.pinCentre(l.to);
        const from_dir = c.pins.items[l.from].dir;
        const to_dir = c.pins.items[l.to].dir;

        const p0 = c.view.toScreen(origin, g0);
        const p1 = c.view.toScreen(origin, g1);

        // Cheap reject: a link whose control hull cannot touch the
        // canvas costs one rect test instead of twenty-four strokes.
        const pad = LINK_TANGENT_MAX * z + LINK_W;
        if (@max(p0[0], p1[0]) < canvas.x - pad or @min(p0[0], p1[0]) > canvas.x + canvas.w + pad) continue;
        if (@max(p0[1], p1[1]) < canvas.y - pad or @min(p0[1], p1[1]) > canvas.y + canvas.h + pad) continue;

        // Tangents follow the PIN's direction rather than the link's, so
        // a description that wires an output to an output still draws a
        // curve that reads, instead of a knot.
        const gap = @abs(p1[0] - p0[0]);
        const k = std.math.clamp(gap * LINK_TANGENT_FRAC, LINK_TANGENT_MIN * z, LINK_TANGENT_MAX * z);
        const c0: [2]f32 = .{ p0[0] + (if (from_dir == .out) k else -k), p0[1] };
        const c1: [2]f32 = .{ p1[0] + (if (to_dir == .out) k else -k), p1[1] };

        const n = segmentCount(g0, g1, z);
        const segs = linkSegments(&seg_buf, p0, c0, c1, p1, n, LINK_JOINT_OVERLAP);
        for (segs) |s| {
            const vis = clipSegment(s, canvas) orelse continue;
            try relief.stroke(out, lc, vis.a, vis.b, LINK_W, l.tint);
        }
    }

    // ── Nodes: QUADS, which puts them over every wire for free ─────
    for (c.nodes.items, 0..) |n, i| {
        const tl = c.view.toScreen(origin, n.pos);
        const sw = n.size[0] * z;
        const sh = n.size[1] * z;
        if (tl[0] + sw < canvas.x or tl[0] > canvas.x + canvas.w) continue;
        if (tl[1] + sh < canvas.y or tl[1] > canvas.y + canvas.h) continue;

        // `endFrame` multiplies a quad's radius by the HOST's zoom and
        // knows nothing about this one, so the graph zoom goes on by
        // hand. Without it a node zoomed to 3× has 1/3 of the corner it
        // should, which reads as the corners getting sharper as you
        // approach.
        const r = NODE_RADIUS * z;
        const lit = switch (c.hovered) {
            .node => |hn| hn == i,
            .pin => |hp| c.pins.items[hp].node == i,
            .none => false,
        };
        const is_sel = c.selected != null and c.selected.? == i;
        const ring: [4]f32 = if (is_sel) NODE_RING_SELECTED else if (lit) NODE_RING_HOVER else NODE_RING;
        const ring_pad = RING_PAD * z;

        try out.appendQuad(lc, .{
            .dst_pos = .{ tl[0] - ring_pad, tl[1] - ring_pad },
            .dst_size = .{ sw + 2 * ring_pad, sh + 2 * ring_pad },
            .color = ring,
            .radius = r + ring_pad,
        });
        try out.appendQuad(lc, .{
            .dst_pos = .{ tl[0], tl[1] },
            .dst_size = .{ sw, sh },
            .color = NODE_BG,
            .radius = r,
        });
        try out.appendQuad(lc, .{
            .dst_pos = .{ tl[0], tl[1] },
            .dst_size = .{ sw, @min(HEADER_H * z, sh) },
            .color = tinted(n.tint, NODE_HEADER_TINT),
            .radius = r,
        });
    }

    // ── Pins: QUADS with a radius, so they are anti-aliased discs ──
    for (c.pins.items, 0..) |p, i| {
        const sc = c.view.toScreen(origin, c.pinCentre(@intCast(i)));
        const r = PIN_R * z;
        if (sc[0] + r < canvas.x or sc[0] - r > canvas.x + canvas.w) continue;
        if (sc[1] + r < canvas.y or sc[1] - r > canvas.y + canvas.h) continue;
        const hot = switch (c.hovered) {
            .pin => |hp| hp == i,
            else => false,
        };
        const col: [4]f32 = if (hot) PIN_HOVER_COLOR else if (p.dir == .in) PIN_IN_COLOR else PIN_OUT_COLOR;
        try out.appendQuad(lc, .{
            .dst_pos = .{ sc[0] - r, sc[1] - r },
            .dst_size = .{ 2 * r, 2 * r },
            .color = col,
            .radius = r,
        });
    }

    // ── Labels: GLYPHS, over everything ────────────────────────────
    if (z >= LABEL_MIN_ZOOM) try drawLabels(c, canvas, lc, out);

    if (c.bad_lines > 0) try drawErrorStrip(c, canvas, lc, out);
}

/// A dot-free line grid, in the triangle layer with the ground.
///
/// It exists because a canvas with nothing but nodes on it gives a pan
/// no feedback at all — dragging empty space looks identical to not
/// dragging it. Below `GRID_MIN_PX` between lines it is dropped, which
/// is both a look and the reason a zoomed-out fifty-node graph does not
/// pay for two hundred rules.
fn drawGrid(c: *Component, canvas: Rect, lc: *element.LayoutCtx, out: *element.DrawList) !void {
    const step_px = GRID_STEP * c.view.zoom;
    if (step_px < GRID_MIN_PX) return;

    const g0 = c.view.toGraph(.{ 0, 0 });
    const g1 = c.view.toGraph(.{ canvas.w, canvas.h });

    var ix: i32 = @intFromFloat(@floor(g0[0] / GRID_STEP));
    const ix_end: i32 = @intFromFloat(@ceil(g1[0] / GRID_STEP));
    while (ix <= ix_end) : (ix += 1) {
        const gx = @as(f32, @floatFromInt(ix)) * GRID_STEP;
        const sx = canvas.x + (gx - c.view.pan[0]) * c.view.zoom;
        if (sx < canvas.x or sx > canvas.x + canvas.w) continue;
        const major = @rem(ix, @as(i32, @intCast(GRID_MAJOR))) == 0;
        try relief.rect(out, lc, sx, canvas.y, 1, canvas.h, if (major) GRID_COLOR_MAJOR else GRID_COLOR);
    }

    var iy: i32 = @intFromFloat(@floor(g0[1] / GRID_STEP));
    const iy_end: i32 = @intFromFloat(@ceil(g1[1] / GRID_STEP));
    while (iy <= iy_end) : (iy += 1) {
        const gy = @as(f32, @floatFromInt(iy)) * GRID_STEP;
        const sy = canvas.y + (gy - c.view.pan[1]) * c.view.zoom;
        if (sy < canvas.y or sy > canvas.y + canvas.h) continue;
        const major = @rem(iy, @as(i32, @intCast(GRID_MAJOR))) == 0;
        try relief.rect(out, lc, canvas.x, sy, canvas.w, 1, if (major) GRID_COLOR_MAJOR else GRID_COLOR);
    }
}

/// Shape a run and drop it into the glyph layer at a SCREEN position,
/// scaled by the graph zoom.
///
/// `appendShapedRun` emits world-space positions and sizes at the base
/// display size, rasterising at `display_px × zoom` so the host's own
/// zoom multiply samples at 1:1. There is no channel to tell it about a
/// second, component-local zoom — so this rasterises at the product and
/// then rescales the range it appended about the pen. That is the same
/// "multiply it yourself" bargain `:::svg` takes with its vertices, one
/// layer along.
/// Which side of `x` the run sits on.
///
/// `.right` exists because an output pin's label belongs INSIDE its
/// node, hard against the right edge, and right-aligning normally wants
/// a measure pass this component does not have. It gets one for free:
/// the range has already been walked once to apply the graph zoom, and
/// `appendShapedRun` hands back the advance, so the shift is the same
/// loop with one more term. The first draft hung output labels outside
/// the node instead, and they collided with their own wires.
const Anchor = enum { left, right };

fn appendLabel(
    lc: *element.LayoutCtx,
    out: *element.DrawList,
    text: []const u8,
    style_font: @TypeOf(@as(element.Theme, undefined).body.font_id),
    color: [4]f32,
    x: f32,
    baseline: f32,
    scale: f32,
    anchor: Anchor,
) !f32 {
    if (text.len == 0) return x;
    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const hb = lc.fonts.hbFont(style_font);
    const run = try shape.shapeUtf8(arena.allocator(), hb, text);

    const first = out.glyphs.items.len;
    const advance = try text_layout.appendShapedRun(
        &out.glyphs,
        &out.glyph_targets,
        lc.current_target_dispatch_index,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        run,
        style_font,
        x,
        baseline,
        color,
        color,
        0,
        lc.zoom * scale,
    );
    const width = (advance - x) * scale;
    const shift: f32 = if (anchor == .right) -width else 0;
    for (out.glyphs.items[first..]) |*g| {
        g.dst_pos[0] = x + (g.dst_pos[0] - x) * scale + shift;
        g.dst_pos[1] = baseline + (g.dst_pos[1] - baseline) * scale;
        g.dst_size[0] *= scale;
        g.dst_size[1] *= scale;
    }
    return x + width + shift;
}

/// The baseline that centres one line of `m` vertically on `cy`.
///
/// `descender` is negative (below the baseline), so the run spans
/// `[baseline - ascender, baseline - descender]` and its centre is
/// `baseline - (ascender + descender)/2`. Getting this wrong by the
/// obvious guess — `cy + ascender/2` — is what put the first draft's
/// node title straight through its own first pin label.
fn centredBaseline(m: anytype, cy: f32, scale: f32) f32 {
    return cy + (m.ascender + m.descender) * scale * 0.5;
}

fn drawLabels(c: *Component, canvas: Rect, lc: *element.LayoutCtx, out: *element.DrawList) !void {
    const origin = [2]f32{ canvas.x, canvas.y };
    const z = c.view.zoom;
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);

    for (c.nodes.items) |n| {
        const tl = c.view.toScreen(origin, n.pos);
        const sw = n.size[0] * z;
        if (tl[0] + sw < canvas.x or tl[0] > canvas.x + canvas.w) continue;
        if (tl[1] + HEADER_H * z < canvas.y or tl[1] > canvas.y + canvas.h) continue;
        const baseline = centredBaseline(m, tl[1] + HEADER_H * z * 0.5, z);
        _ = try appendLabel(lc, out, n.label, style.font_id, style.color, tl[0] + LABEL_PAD_X * z, baseline, z, .left);
    }

    for (c.pins.items, 0..) |p, i| {
        if (p.label.len == 0) continue;
        const sc = c.view.toScreen(origin, c.pinCentre(@intCast(i)));
        if (sc[0] < canvas.x - 80 or sc[0] > canvas.x + canvas.w + 80) continue;
        if (sc[1] < canvas.y or sc[1] > canvas.y + canvas.h) continue;
        const baseline = centredBaseline(m, sc[1], z);
        // Both labels sit INSIDE the node, each set in from its own dot:
        // an input reads left-to-right away from the left edge, an
        // output right-to-left away from the right one. Hanging an
        // output outside the node — the first draft — puts it straight
        // across the wire leaving that very pin.
        const anchor: Anchor = if (p.dir == .in) .left else .right;
        const gap = PIN_LABEL_GAP * z;
        const x = if (p.dir == .in) sc[0] + gap else sc[0] - gap;
        _ = try appendLabel(lc, out, p.label, style.font_id, style.color, x, baseline, z, anchor);
    }
}

fn drawErrorStrip(c: *Component, canvas: Rect, lc: *element.LayoutCtx, out: *element.DrawList) !void {
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);
    const y = canvas.y + canvas.h - ERR_STRIP_H;
    try out.appendQuad(lc, .{
        .dst_pos = .{ canvas.x, y },
        .dst_size = .{ canvas.w, ERR_STRIP_H },
        .color = ERR_STRIP_BG,
        .radius = 0,
    });
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{d} unreadable line(s) in the graph description", .{c.bad_lines}) catch return;
    _ = try appendLabel(lc, out, msg, style.font_id, .{ 1, 1, 1, 1 }, canvas.x + 8, centredBaseline(m, y + ERR_STRIP_H * 0.5, 1.0), 1.0, .left);
}

// ── Input ───────────────────────────────────────────────────────────

/// Which mouse button pans anywhere, including over a node. Left-drag on
/// empty canvas pans too; the middle button is the one that works when
/// the graph is dense enough that "empty canvas" is hard to find.
const PAN_BUTTON: u8 = 2;

fn onInput(ctx: *anyopaque, event: element.InputEvent, state_raw: *anyopaque) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const state: *state_mod.State = @ptrCast(@alignCast(state_raw));

    switch (event) {
        .mouse_down => |mev| {
            if (mev.button == PAN_BUTTON) {
                c.grab = .{ .pan = .{ .press_local = mev.local, .start_pan = c.view.pan } };
                return;
            }
            if (mev.button != 0) return;

            // `local` is canvas-local screen pixels; the graph is one
            // `toGraph` away and the canvas origin never enters. This is
            // THE boundary — everything below is graph space.
            const g = c.view.toGraph(mev.local);
            const hit = c.pick(g);
            switch (hit) {
                .node => |i| {
                    c.grab = .{ .node = .{
                        .index = i,
                        .press_local = mev.local,
                        .start_pos = c.nodes.items[i].pos,
                        .moved = false,
                    } };
                    c.selected = i;
                    c.hovered = hit;
                },
                .pin => |i| {
                    // A press on a pin selects its node and moves
                    // nothing. It must not fall through to a pan, which
                    // would slide the whole canvas out from under a
                    // deliberate aim — and it latches, so the write
                    // below runs behind the same closed `ingest` every
                    // other press does.
                    c.grab = .{ .pin = i };
                    c.selected = c.pins.items[i].node;
                    c.hovered = hit;
                },
                .none => {
                    c.selected = null;
                    c.grab = .{ .pan = .{ .press_local = mev.local, .start_pan = c.view.pan } };
                },
            }
            c.version +%= 1;
            // Written with the latch already set, so the synchronous
            // re-entry this may cause finds `ingest` closed.
            try c.writeSelection(state);
        },
        .mouse_move => |mev| {
            if (!mev.button_down) return;
            switch (c.grab) {
                .none, .pin => {},
                .pan => |p| {
                    // Drag right, content goes right, so the camera goes
                    // left. In graph units, because a pan measured in
                    // screen pixels drifts under the cursor at any zoom
                    // but 1.
                    c.view.pan = .{
                        p.start_pan[0] - (mev.local[0] - p.press_local[0]) / c.view.zoom,
                        p.start_pan[1] - (mev.local[1] - p.press_local[1]) / c.view.zoom,
                    };
                    c.version +%= 1;
                },
                .node => |*d| {
                    const dx = (mev.local[0] - d.press_local[0]) / c.view.zoom;
                    const dy = (mev.local[1] - d.press_local[1]) / c.view.zoom;
                    c.nodes.items[d.index].pos = .{ d.start_pos[0] + dx, d.start_pos[1] + dy };
                    if (dx != 0 or dy != 0) d.moved = true;
                    c.version +%= 1;
                    // NO write here. A drag is one gesture and gets one
                    // `State.set`, at the end — see `writePositions`.
                },
            }
        },
        .mouse_up => |mev| {
            _ = mev;
            const was = c.grab;
            // Both of these run with the latch STILL SET, so the
            // synchronous subscriber storm a `State.set` kicks off finds
            // `ingest` closed and cannot re-parse the graph out from
            // under the hand that just moved it.
            switch (was) {
                .node => |d| if (d.moved) try c.writePositions(state),
                else => {},
            }
            try c.drainPending();
            c.grab = .none;
            c.version +%= 1;
        },
        .char_input, .key_down, .focus_gained, .focus_lost => {},
    }
}

fn onHover(ctx: *anyopaque, event: element.HoverEvent, state_raw: *anyopaque) anyerror!void {
    _ = state_raw;
    const c: *Component = @ptrCast(@alignCast(ctx));
    const before = c.hovered;
    c.hovered = switch (event.phase) {
        // On `.leave` the pointer is reported where it now is, which is
        // outside the canvas. Picking there would light whatever node
        // happens to lie under a point the pointer has already left.
        .leave => .none,
        .enter, .move => c.pick(c.view.toGraph(event.local)),
    };
    if (!std.meta.eql(before, c.hovered)) c.version +%= 1;
}

/// The wheel zooms about the cursor.
///
/// It returns FALSE at the clamp, which is the `on_scroll` contract read
/// literally: consumption is a per-notch answer, so a further notch at
/// maximum zoom belongs to the page behind. Without that, a graph in the
/// middle of a long document is a hole you cannot scroll past.
fn onScroll(ctx: *anyopaque, event: element.ScrollEvent, state_raw: *anyopaque) anyerror!bool {
    _ = state_raw;
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (c.gesturing()) return true;
    const before = c.view.zoom;
    const factor = @exp(-event.dy * ZOOM_PER_PX);
    const next = std.math.clamp(before * factor, ZOOM_MIN, ZOOM_MAX);
    if (next == before) return false;
    c.view.zoomAbout(event.local, next);
    c.version +%= 1;
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_state = state_mod.State.init(testing.allocator);
var _test_spark = blk: {
    var s = spark_mod.Spark.testStub(testing.allocator);
    s.host_state = &_test_state;
    break :blk s;
};

var attr_pool: [16][8]components.Attr = undefined;
var attr_next: usize = 0;

fn specOf(attrs: []const components.Attr, body: []const u8) components.Spec {
    const i = attr_next % attr_pool.len;
    attr_next += 1;
    for (attrs, 0..) |a, n| attr_pool[i][n] = a;
    return .{ .name = "nodegraph", .id = null, .attrs = attr_pool[i][0..attrs.len], .body = body };
}

const two_node_graph =
    \\node id=src x=0 y=0 label="Source"
    \\node id=mul x=200 y=60 label="Multiply"
    \\pin node=src id=out dir=out label="v"
    \\pin node=mul id=a dir=in label="a"
    \\pin node=mul id=b dir=in label="b"
    \\pin node=mul id=out dir=out label="v"
    \\link from=src.out to=mul.a
;

fn makeGraph(body: []const u8, attrs: []const components.Attr) !*Component {
    const spec = specOf(attrs, body);
    const inst = try create(&_test_spark, testing.allocator, &spec);
    return @ptrCast(@alignCast(inst.ctx));
}

fn dropGraph(c: *Component) void {
    deinit_(@ptrCast(c), testing.allocator);
}

// ── The transform ──────────────────────────────────────────────────

test "nodegraph: local and graph round-trip at every pan and zoom" {
    // Mutation that paid for this: drop the `/ self.zoom` from
    // `View.toGraph`, so it reads `pan + l`. Every case with zoom != 1
    // goes red — and every case at zoom == 1 still passes, which is the
    // whole reason the table has four rows and not one. A gate written
    // at the identity transform would have shipped that bug.
    const views = [_]View{
        .{ .pan = .{ 0, 0 }, .zoom = 1 },
        .{ .pan = .{ -40, 17.5 }, .zoom = 1 },
        .{ .pan = .{ 120, -60 }, .zoom = 2.5 },
        .{ .pan = .{ -13.25, 88 }, .zoom = 0.37 },
    };
    const pts = [_][2]f32{ .{ 0, 0 }, .{ 10, -20 }, .{ 333.5, 91.25 }, .{ -7, -7 } };
    for (views) |v| {
        for (pts) |g| {
            const back = v.toGraph(v.toLocal(g));
            try testing.expectApproxEqAbs(g[0], back[0], 1e-3);
            try testing.expectApproxEqAbs(g[1], back[1], 1e-3);
        }
        for (pts) |l| {
            const back = v.toLocal(v.toGraph(l));
            try testing.expectApproxEqAbs(l[0], back[0], 1e-3);
            try testing.expectApproxEqAbs(l[1], back[1], 1e-3);
        }
    }
}

test "nodegraph: toScreen is toLocal plus the origin, and only toScreen knows it" {
    // The boundary claim, executed: every input path can use `toGraph`
    // on a raw `local` because the origin cancels. If `toScreen` ever
    // grows a term that is not the origin, this goes red and the
    // input paths have to learn about it.
    const v = View{ .pan = .{ 30, -12 }, .zoom = 1.8 };
    const origin = [2]f32{ 64, 400 };
    const g = [2]f32{ 55, 5 };
    const s = v.toScreen(origin, g);
    const l = v.toLocal(g);
    try testing.expectApproxEqAbs(origin[0] + l[0], s[0], 1e-4);
    try testing.expectApproxEqAbs(origin[1] + l[1], s[1], 1e-4);
}

test "nodegraph: the wheel keeps the point under the cursor still" {
    var v = View{ .pan = .{ 10, 10 }, .zoom = 1 };
    const anchor = [2]f32{ 220, 130 };
    const before = v.toGraph(anchor);
    v.zoomAbout(anchor, 2.4);
    const after = v.toGraph(anchor);
    // Mutation: set `self.pan` to `g` (zoom about the canvas corner
    // instead of the cursor). Red by 128 graph units.
    try testing.expectApproxEqAbs(before[0], after[0], 1e-3);
    try testing.expectApproxEqAbs(before[1], after[1], 1e-3);
}

// ── The description ────────────────────────────────────────────────

test "nodegraph: the description parses into nodes, pins and links" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 2), c.nodes.items.len);
    try testing.expectEqual(@as(usize, 4), c.pins.items.len);
    try testing.expectEqual(@as(usize, 1), c.links.items.len);
    try testing.expectEqual(@as(u32, 0), c.bad_lines);
    try testing.expectEqualStrings("Multiply", c.nodes.items[1].label);
    // The link resolved to real pin indices, not to strings.
    try testing.expectEqual(Dir.out, c.pins.items[c.links.items[0].from].dir);
    try testing.expectEqual(Dir.in, c.pins.items[c.links.items[0].to].dir);
}

test "nodegraph: a link may be written before the pins it names" {
    // Mutation: resolve each `link` line inline where it is read instead
    // of after the whole description. Red — the link is dropped and
    // `bad_lines` is 1, because `src.out` does not exist yet.
    const c = try makeGraph(
        \\link from=src.out to=dst.in
        \\node id=src x=0 y=0
        \\node id=dst x=100 y=0
        \\pin node=src id=out dir=out
        \\pin node=dst id=in dir=in
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 1), c.links.items.len);
    try testing.expectEqual(@as(u32, 0), c.bad_lines);
}

test "nodegraph: a ref splits on the LAST dot, so a node id may contain dots" {
    const c = try makeGraph(
        \\node id=math.mul x=0 y=0
        \\pin node=math.mul id=out dir=out
        \\link from=math.mul.out to=math.mul.out
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 1), c.links.items.len);
    try testing.expectEqual(@as(u32, 0), c.bad_lines);
}

test "nodegraph: a line nobody can read is counted, not swallowed" {
    // A host that ships a malformed record should find out from the
    // picture. Mutation: `continue` instead of `bad_lines += 1` on the
    // unknown-kind arm — red, and the strip stops being drawn.
    const c = try makeGraph(
        \\node id=a x=0 y=0
        \\nodes id=b x=0 y=0
        \\pin node=nowhere id=p dir=in
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 1), c.nodes.items.len);
    try testing.expectEqual(@as(u32, 2), c.bad_lines);
}

test "nodegraph: a quoted label keeps its spaces" {
    const c = try makeGraph("node id=a x=0 y=0 label=\"Two Words\" tint=#ff0000", &.{});
    defer dropGraph(c);
    try testing.expectEqualStrings("Two Words", c.nodes.items[0].label);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.nodes.items[0].tint[0], 1e-3);
}

test "nodegraph: node height follows the busier side's pin count" {
    const c = try makeGraph(
        \\node id=a x=0 y=0
        \\node id=b x=0 y=200
        \\pin node=b id=1 dir=in
        \\pin node=b id=2 dir=in
        \\pin node=b id=3 dir=in
        \\pin node=b id=o dir=out
    , &.{});
    defer dropGraph(c);
    try testing.expect(c.nodes.items[1].size[1] > c.nodes.items[0].size[1]);
    // And an explicit `h=` is left alone.
    const d = try makeGraph("node id=a x=0 y=0 h=300", &.{});
    defer dropGraph(d);
    try testing.expectApproxEqAbs(@as(f32, 300), d.nodes.items[0].size[1], 1e-3);
}

// ── Hit testing ────────────────────────────────────────────────────

test "nodegraph: a click lands on the node under the cursor at a real pan AND zoom" {
    // Mutation: use `mev.local` directly as the graph point (drop the
    // `toGraph`). Red — the press at the node's on-screen position picks
    // nothing, because at pan (-100, -50) and zoom 1.6 the screen point
    // and the graph point are 250 units apart. A gate at pan (0,0) zoom
    // 1 would pass against that mutation, which is why neither is 0 or 1
    // here.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.view = .{ .pan = .{ -100, -50 }, .zoom = 1.6 };

    // The centre of `mul`, taken the long way round: graph → local.
    const n = c.nodes.items[1];
    const centre = [2]f32{ n.pos[0] + n.size[0] * 0.5, n.pos[1] + n.size[1] * 0.5 };
    const local = c.view.toLocal(centre);

    try onInput(@ptrCast(c), .{ .mouse_down = .{
        .local = local,
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));

    try testing.expectEqual(@as(?u32, 1), c.selected);
    try testing.expect(c.grab == .node);
    try testing.expectEqual(@as(u32, 1), c.grab.node.index);
}

test "nodegraph: a pin wins over the node body it overlaps" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    // `mul`'s first input pin sits ON the node's left edge, so a pick
    // there is ambiguous unless pins are tested first.
    const g = c.pinCentre(1);
    try testing.expect(c.pick(.{ g[0] + 2, g[1] }) == .pin);
    // And two pitches down the body, past every pin, is the node.
    const n = c.nodes.items[1];
    try testing.expect(c.pick(.{ n.pos[0] + n.size[0] * 0.5, n.pos[1] + 4 }) == .node);
}

test "nodegraph: the topmost node wins where two overlap" {
    const c = try makeGraph(
        \\node id=under x=0 y=0
        \\node id=over x=20 y=10
    , &.{});
    defer dropGraph(c);
    // Both rects contain this point; `over` is drawn last, so it wins.
    try testing.expectEqual(Hover{ .node = 1 }, c.pick(.{ 40, 20 }));
}

// ── Dragging ───────────────────────────────────────────────────────

test "nodegraph: a press on a pin latches too, so the write is guarded" {
    // Three quarters of a guard is the shape a later beat inherits and
    // cannot see. Mutation: drop `c.grab = .{ .pin = i };` from the
    // `.pin` arm — red, and `writeSelection` then runs with `ingest`
    // open, which is the window `State.set`'s synchronous notify lands
    // in.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(two_node_graph, &.{
        .{ .key = "selected", .value = "sel" },
    });
    defer dropGraph(c);

    const g = c.pinCentre(1); // `mul`'s first input
    try onInput(@ptrCast(c), .{ .mouse_down = .{
        .local = c.view.toLocal(g),
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&st));
    try testing.expect(c.grab == .pin);
    try testing.expect(c.gesturing());
    try testing.expectEqualStrings("mul", st.get("sel").?);

    // And it moves nothing, whatever the pointer does next.
    const before = c.nodes.items[1].pos;
    const pan_before = c.view.pan;
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ 900, 900 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&st));
    try testing.expectEqual(before, c.nodes.items[1].pos);
    try testing.expectEqual(pan_before, c.view.pan);

    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = .{ 900, 900 }, .button = 0, .button_down = false } }, @ptrCast(&st));
    try testing.expect(c.grab == .none);
}

test "nodegraph: a drag moves the node by the pointer's delta in GRAPH space" {
    // Mutation: use the raw `(local - press_local)` as the delta. Red at
    // zoom 2 — the node travels 80 graph units for a 40-unit gesture and
    // outruns the cursor. The gate is deliberately at zoom != 1; at
    // zoom 1 the mutation is invisible.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.view = .{ .pan = .{ 0, 0 }, .zoom = 2.0 };

    const n0 = c.nodes.items[0];
    const start = n0.pos;
    const press = c.view.toLocal(.{ n0.pos[0] + 10, n0.pos[1] + 6 });

    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&_test_state));
    // 80 screen pixels right, 40 down — 40 and 20 in graph units.
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ press[0] + 80, press[1] + 40 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));

    try testing.expectApproxEqAbs(start[0] + 40, c.nodes.items[0].pos[0], 1e-3);
    try testing.expectApproxEqAbs(start[1] + 20, c.nodes.items[0].pos[1], 1e-3);
}

test "nodegraph: a drag on empty canvas pans, in graph units" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.view = .{ .pan = .{ 0, 0 }, .zoom = 0.5 };
    // Far below every node.
    const press = c.view.toLocal(.{ 40, 900 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&_test_state));
    try testing.expect(c.grab == .pan);
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ press[0] + 50, press[1] },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));
    // 50 screen pixels at zoom 0.5 is 100 graph units, and the camera
    // moves the OTHER way so the content follows the hand.
    try testing.expectApproxEqAbs(@as(f32, -100), c.view.pan[0], 1e-3);
}

test "nodegraph: exactly one State.set per drag gesture" {
    // Mutation: move the `writePositions` call from `mouse_up` into the
    // `.node` arm of `mouse_move`. Red — five moves become five writes,
    // and every one of them is a synchronous re-entry into the registry.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var counter = SetCounter{ .state = &st };

    const c = try makeGraph(two_node_graph, &.{
        .{ .key = "positions", .value = "graph.pos" },
    });
    defer dropGraph(c);

    const press = c.view.toLocal(.{ 10, 6 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&st));
    counter.mark();
    var i: usize = 1;
    while (i <= 5) : (i += 1) {
        const dx: f32 = @floatFromInt(i * 4);
        try onInput(@ptrCast(c), .{ .mouse_move = .{
            .local = .{ press[0] + dx, press[1] },
            .button = 0,
            .button_down = true,
        } }, @ptrCast(&st));
    }
    try testing.expectEqual(@as(usize, 0), counter.since());
    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = .{ press[0] + 20, press[1] }, .button = 0, .button_down = false } }, @ptrCast(&st));
    try testing.expectEqual(@as(usize, 1), counter.since());

    // And what landed is re-feedable: it is `pos` records, so parsing it
    // back changes nothing at all.
    const written = st.get("graph.pos").?;
    try testing.expect(std.mem.startsWith(u8, written, "pos id=src"));
}

/// Counts writes to the positions path by watching the value change. A
/// real subscriber would be better and cannot be had: `State.subscribe`
/// wants a component, and this gate is about how many times a component
/// calls `set`, not what anybody heard.
const SetCounter = struct {
    state: *state_mod.State,
    last: []const u8 = "",
    seen: usize = 0,
    marked: usize = 0,

    fn mark(self: *SetCounter) void {
        self.tick();
        self.marked = self.seen;
    }
    fn tick(self: *SetCounter) void {
        const v = self.state.get("graph.pos") orelse "";
        if (!std.mem.eql(u8, v, self.last)) {
            self.seen += 1;
            self.last = v;
        }
    }
    fn since(self: *SetCounter) usize {
        self.tick();
        return self.seen - self.marked;
    }
};

test "nodegraph: a drag that did not move writes nothing" {
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(two_node_graph, &.{
        .{ .key = "positions", .value = "graph.pos" },
    });
    defer dropGraph(c);
    const press = c.view.toLocal(.{ 10, 6 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&st));
    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = press, .button = 0, .button_down = false } }, @ptrCast(&st));
    try testing.expect(st.get("graph.pos") == null);
}

test "nodegraph: an ingest arriving mid-gesture does not move the node" {
    // The trackball trap, in a canvas. `State.set` notifies
    // synchronously, so the drag's own write re-enters `update` — and a
    // re-parse there puts every node back where the PLANE says it is,
    // which is where it was before the drag started.
    //
    // Mutation: delete the `if (self.gesturing()) return;` guard at the
    // top of `ingest`. Red — the node snaps back to (0, 0).
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);

    const press = c.view.toLocal(.{ 10, 6 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&st));
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ press[0] + 60, press[1] + 30 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&st));
    const dragged = c.nodes.items[0].pos;
    try testing.expectApproxEqAbs(@as(f32, 60), dragged[0], 1e-3);

    // A whole re-parse lands mid-drag, with the node at its old home.
    const spec = specOf(&.{}, two_node_graph ++ "\npos id=src x=0 y=0");
    try update(@ptrCast(c), &spec);
    try testing.expectApproxEqAbs(dragged[0], c.nodes.items[0].pos[0], 1e-3);
    try testing.expectApproxEqAbs(dragged[1], c.nodes.items[0].pos[1], 1e-3);

    // Between gestures the plane is the truth again, and because the
    // refusal did NOT adopt the digest, the same body lands the moment
    // the button is up and the document is re-delivered.
    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = .{ press[0] + 60, press[1] + 30 }, .button = 0, .button_down = false } }, @ptrCast(&st));
    try update(@ptrCast(c), &spec);
    try testing.expectApproxEqAbs(@as(f32, 0), c.nodes.items[0].pos[0], 1e-3);
}

test "nodegraph: a body that has not changed is not re-parsed" {
    // `Body.adopt` is what keeps a re-parse per `:::update` from
    // throwing the graph away sixty times a second. Mutation: parse
    // unconditionally in `ingest` — red, because the drag's position is
    // lost on the very next document re-parse.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.nodes.items[0].pos = .{ 500, 500 };
    const spec = specOf(&.{}, two_node_graph);
    try update(@ptrCast(c), &spec);
    try testing.expectApproxEqAbs(@as(f32, 500), c.nodes.items[0].pos[0], 1e-3);
}

// ── The host's door ────────────────────────────────────────────────

test "nodegraph: handle_update replaces the graph, and `move` only moves" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    try handleUpdate(@ptrCast(c), "move", "pos id=mul x=1000 y=2000");
    try testing.expectApproxEqAbs(@as(f32, 1000), c.nodes.items[1].pos[0], 1e-3);
    // The labels survived, which is the point of `pos` being its own
    // record kind rather than a `node` line with fields left off.
    try testing.expectEqualStrings("Multiply", c.nodes.items[1].label);

    try handleUpdate(@ptrCast(c), "graph", "node id=only x=5 y=5");
    try testing.expectEqual(@as(usize, 1), c.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), c.links.items.len);

    try testing.expectError(error.UnknownGraphAction, handleUpdate(@ptrCast(c), "wat", ""));
}

test "nodegraph: a push mid-gesture is set aside and lands when the hand lets go" {
    // Applying it immediately moves the graph out from under the finger;
    // dropping it loses structure a stream will never send twice. So it
    // waits. Mutation: parse it immediately instead of queueing — red,
    // the dragged node is gone before `mouse_up`.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);

    const press = c.view.toLocal(.{ 10, 6 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&st));
    try onInput(@ptrCast(c), .{ .mouse_move = .{ .local = .{ press[0] + 30, press[1] }, .button = 0, .button_down = true } }, @ptrCast(&st));

    try handleUpdate(@ptrCast(c), "graph", "node id=late x=9 y=9");
    try testing.expectEqual(@as(usize, 2), c.nodes.items.len); // still ours

    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = .{ press[0] + 30, press[1] }, .button = 0, .button_down = false } }, @ptrCast(&st));
    try testing.expectEqual(@as(usize, 1), c.nodes.items.len);
    try testing.expectEqualStrings("late", c.nodes.items[0].id);
}

// ── Hover ──────────────────────────────────────────────────────────

test "nodegraph: hover enters and leaves in pairs across node boundaries" {
    // Mutation: make `.leave` fall through to the `.enter` arm and pick
    // at the reported point. Red — the pointer that left the canvas
    // still lights whatever node lies under where it went.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);

    const a = c.nodes.items[0];
    const b = c.nodes.items[1];
    const in_a = c.view.toLocal(.{ a.pos[0] + a.size[0] * 0.5, a.pos[1] + 4 });
    const in_b = c.view.toLocal(.{ b.pos[0] + b.size[0] * 0.5, b.pos[1] + 4 });
    const gap = c.view.toLocal(.{ a.pos[0] + a.size[0] + 30, a.pos[1] + 4 });

    try onHover(@ptrCast(c), .{ .local = in_a, .phase = .enter }, @ptrCast(&_test_state));
    try testing.expectEqual(Hover{ .node = 0 }, c.hovered);
    // Crossing the gap must un-light A before B lights: two nodes
    // hovered at once is the failure this pairing exists to prevent.
    try onHover(@ptrCast(c), .{ .local = gap, .phase = .move }, @ptrCast(&_test_state));
    try testing.expect(c.hovered == .none);
    try onHover(@ptrCast(c), .{ .local = in_b, .phase = .move }, @ptrCast(&_test_state));
    try testing.expectEqual(Hover{ .node = 1 }, c.hovered);
    // And the pointer leaving the canvas clears it, wherever it went.
    try onHover(@ptrCast(c), .{ .local = in_a, .phase = .leave }, @ptrCast(&_test_state));
    try testing.expect(c.hovered == .none);
}

test "nodegraph: a hover change bumps the content version" {
    // Without this the highlight is computed and never drawn: the block
    // cache is keyed on the version and the walker would blit the
    // unlit frame back. Mutation: drop the `version +%= 1` in `onHover`.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    const a = c.nodes.items[0];
    const before = c.version;
    try onHover(@ptrCast(c), .{
        .local = c.view.toLocal(.{ a.pos[0] + 10, a.pos[1] + 4 }),
        .phase = .enter,
    }, @ptrCast(&_test_state));
    try testing.expect(c.version != before);
}

// ── The wheel ──────────────────────────────────────────────────────

test "nodegraph: the wheel zooms, and gives the notch back at the clamp" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    try testing.expect(try onScroll(@ptrCast(c), .{ .local = .{ 100, 100 }, .dy = -120 }, @ptrCast(&_test_state)));
    try testing.expect(c.view.zoom > 1);

    // Pinned at the top, a further notch belongs to the page behind —
    // the `on_scroll` contract read literally. Mutation: `return true`
    // unconditionally, and a graph in the middle of a document becomes a
    // hole you cannot scroll past.
    c.view.zoom = ZOOM_MAX;
    try testing.expect(!try onScroll(@ptrCast(c), .{ .local = .{ 100, 100 }, .dy = -120 }, @ptrCast(&_test_state)));
    c.view.zoom = ZOOM_MIN;
    try testing.expect(!try onScroll(@ptrCast(c), .{ .local = .{ 100, 100 }, .dy = 120 }, @ptrCast(&_test_state)));
}

// ── Link geometry ──────────────────────────────────────────────────

test "nodegraph: consecutive link segments OVERLAP past the joint" {
    // `relief.stroke` feathers its caps as well as its sides, so two
    // segments that butt exactly leave a seam of half-alpha down the
    // join — a wire that looks dotted. `:::curve` hides its joints under
    // pucks; a wire has none.
    //
    // Mutation: in `linkSegments`, write `.a = prev, .b = next` and drop
    // the `ux`/`uy` extension. Red on every joint, by exactly the
    // overlap.
    var buf: [LINK_MAX_SEGS]Seg = undefined;
    const segs = linkSegments(
        &buf,
        .{ 0, 0 },
        .{ 60, 0 },
        .{ 140, 100 },
        .{ 200, 100 },
        8,
        LINK_JOINT_OVERLAP,
    );
    try testing.expectEqual(@as(usize, 8), segs.len);
    var i: usize = 0;
    while (i + 1 < segs.len) : (i += 1) {
        const cur = segs[i];
        const nxt = segs[i + 1];
        // How far `cur` reaches PAST where `nxt` begins, measured along
        // `nxt`'s own direction. Butt-jointed this is 0; it has to
        // exceed a feather or the overlap lands inside the fade.
        const dx = nxt.b[0] - nxt.a[0];
        const dy = nxt.b[1] - nxt.a[1];
        const len = @sqrt(dx * dx + dy * dy);
        const ux = dx / len;
        const uy = dy / len;
        const reach = (cur.b[0] - nxt.a[0]) * ux + (cur.b[1] - nxt.a[1]) * uy;
        try testing.expect(reach > relief.FEATHER);
    }
    // The ends are still the ends, give or take the same overlap — a
    // wire that stopped short of its pin would be worse than a seam.
    try testing.expect(@abs(segs[0].a[0] - 0) <= LINK_JOINT_OVERLAP + 1e-3);
    try testing.expect(@abs(segs[segs.len - 1].b[0] - 200) <= LINK_JOINT_OVERLAP + 1e-3);
}

test "nodegraph: the flattened curve tracks the cubic it came from" {
    // Mutation: evaluate the cubic at `t = i / n` instead of
    // `(i + 1) / n` — the last segment then never reaches `p1` and the
    // wire stops a joint short of its pin.
    var buf: [LINK_MAX_SEGS]Seg = undefined;
    const p0 = [2]f32{ 0, 0 };
    const c0 = [2]f32{ 50, 0 };
    const c1 = [2]f32{ 50, 100 };
    const p1 = [2]f32{ 100, 100 };
    const segs = linkSegments(&buf, p0, c0, c1, p1, 12, 0);
    try testing.expectApproxEqAbs(p0[0], segs[0].a[0], 1e-3);
    try testing.expectApproxEqAbs(p1[1], segs[segs.len - 1].b[1], 1e-3);
    // Every joint sits on the curve.
    for (segs[0 .. segs.len - 1], 1..) |s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 12.0;
        const on = cubicAt(p0, c0, c1, p1, t);
        try testing.expectApproxEqAbs(on[0], s.b[0], 1e-3);
        try testing.expectApproxEqAbs(on[1], s.b[1], 1e-3);
    }
}

test "nodegraph: segment count follows the SCREEN chord, not the graph one" {
    // Mutation: drop the `* zoom` in `segmentCount`. Red — a graph
    // zoomed out to a tenth still pays full price for every wire, which
    // is the cost that matters at fifty nodes.
    const a = [2]f32{ 0, 0 };
    const b = [2]f32{ 400, 0 };
    try testing.expect(segmentCount(a, b, 1.0) > segmentCount(a, b, 0.2));
    try testing.expectEqual(LINK_MIN_SEGS, segmentCount(a, .{ 4, 0 }, 1.0));
    try testing.expectEqual(LINK_MAX_SEGS, segmentCount(a, .{ 9000, 0 }, 1.0));
    // And `linkSegments` never writes past the buffer, whatever it is
    // told.
    var buf: [4]Seg = undefined;
    try testing.expectEqual(@as(usize, 4), linkSegments(&buf, a, a, b, b, 99, 0).len);
}

test "nodegraph: a label centres on its row, descender and all" {
    // The obvious guess — `cy + ascender/2` — is what put the first
    // draft's node title straight through its own first pin label, and
    // it is wrong because a descender is NEGATIVE and a run is not
    // symmetric about its baseline.
    //
    // Mutation: `return cy + m.ascender * scale * 0.5;`. Red by two and
    // a half pixels at scale 1, which on screen is a title sitting on
    // the pin under it.
    const m = .{ .ascender = @as(f32, 18.6), .descender = @as(f32, -4.7) };
    const cy: f32 = 100;
    const b = centredBaseline(m, cy, 1.0);
    const top = b - m.ascender;
    const bottom = b - m.descender;
    try testing.expectApproxEqAbs(cy, (top + bottom) * 0.5, 1e-4);
    // And the scale multiplies the offset, not the anchor: a label at
    // half size still centres on the same row.
    const half = centredBaseline(m, cy, 0.5);
    try testing.expectApproxEqAbs(cy, (half - m.ascender * 0.5 + half + m.descender * -0.5) * 0.5, 1e-4);
}

// ── Layering ───────────────────────────────────────────────────────

/// A LayoutCtx is a big struct full of GPU-side handles, and the draw
/// path below reads exactly one field of it as long as no glyph is
/// emitted — which is what `zoom < LABEL_MIN_ZOOM` and `bad_lines == 0`
/// buy. Same trick `relief.zig`'s own gates use.
///
/// The dependency is load-bearing and worth saying out loud: a change
/// that made a label render below the zoom floor would send these gates
/// through a font registry that is literally uninitialised memory, and
/// they ABORT rather than fail. Still red — red with a signal instead of
/// a message. The device-backed gate in `tests/nodegraph_render.zig` is
/// the one that names it.
fn testCtx() element.LayoutCtx {
    var lc: element.LayoutCtx = undefined;
    lc.current_target_dispatch_index = element.MAIN_TARGET;
    return lc;
}

/// Under `GRID_MIN_PX / GRID_STEP` the grid is not drawn, which leaves
/// the triangle layer holding nothing but the ground and the links —
/// exactly the two things the layering gate needs to count.
const GRIDLESS_ZOOM: f32 = 0.21;

test "nodegraph: links are TRIANGLES and node chrome is QUADS" {
    // This is the layering trap from `CLAUDE.md`, in the one shape that
    // matters here. The renderer draws the whole triangle layer under
    // the whole quad layer, in array order per layer and NOT in
    // emission order — so links-under-nodes is not something to arrange,
    // it is something to obey by choosing the right primitive. Node
    // chrome that reached for `relief` would sink beneath every wire.
    //
    // Mutation: replace the node body's `out.appendQuad` with
    // `relief.rect(out, lc, tl[0], tl[1], sw, sh, NODE_BG)`. It
    // compiles, it draws, and it is red here by 8 vertices — which on
    // screen is a node with the wires running over the top of it.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.view = .{ .pan = .{ 0, 0 }, .zoom = GRIDLESS_ZOOM };

    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    var lc = testCtx();
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };
    try drawCanvas(c, canvas, &lc, &dl);

    const l = c.links.items[0];
    const segs = segmentCount(c.pinCentre(l.from), c.pinCentre(l.to), c.view.zoom);

    // Triangles: the ground's 4 vertices and 16 per link segment. No
    // grid at this zoom, no labels, and — the point — nothing from a
    // node.
    try testing.expectEqual(@as(usize, 4 + 16 * segs), dl.tris.items.len);
    try testing.expectEqual(@as(usize, 6 + 54 * segs), dl.tri_indices.items.len);

    // Quads: ring + body + header per node, one per pin.
    try testing.expectEqual(
        @as(usize, 3 * c.nodes.items.len + c.pins.items.len),
        dl.quads.items.len,
    );
    try testing.expectEqual(@as(usize, 0), dl.glyphs.items.len);
    // Every index addresses a vertex that exists.
    for (dl.tri_indices.items) |i| try testing.expect(i < dl.tris.items.len);
}

test "nodegraph: a quad's radius carries the graph zoom itself" {
    // `Spark.endFrame` multiplies `q.radius` by the HOST's zoom and
    // knows nothing about this component's. Mutation: emit
    // `.radius = NODE_RADIUS` on the node body. Red — and on screen a
    // node zoomed to 3× has a third of the corner it should, which reads
    // as the corners sharpening as you approach.
    const c = try makeGraph("node id=a x=0 y=0", &.{});
    defer dropGraph(c);
    const z: f32 = 0.4;
    c.view = .{ .pan = .{ 0, 0 }, .zoom = z };

    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    var lc = testCtx();
    try drawCanvas(c, .{ .x = 0, .y = 0, .w = 400, .h = 300 }, &lc, &dl);

    // [0] ring, [1] body, [2] header.
    try testing.expectApproxEqAbs(NODE_RADIUS * z, dl.quads.items[1].radius, 1e-4);
    try testing.expectApproxEqAbs(NODE_RADIUS * z + RING_PAD * z, dl.quads.items[0].radius, 1e-4);
    // And the body is the node's size in screen pixels, not in graph
    // units — the same multiply, one field over.
    try testing.expectApproxEqAbs(NODE_W * z, dl.quads.items[1].dst_size[0], 1e-3);
}

test "nodegraph: selection and hover reach the picture" {
    // A highlight computed and not drawn is the failure mode a
    // hit-testing gate cannot see — `pick` would still be right and the
    // node would still look dead. Mutation: emit `NODE_RING`
    // unconditionally for the ring quad. Red on both arms.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.view = .{ .pan = .{ 0, 0 }, .zoom = GRIDLESS_ZOOM };
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };

    var lc = testCtx();
    {
        var dl = element.DrawList.init(testing.allocator);
        defer dl.deinit();
        try drawCanvas(c, canvas, &lc, &dl);
        try testing.expectEqual(NODE_RING, dl.quads.items[0].color);
    }
    {
        c.hovered = .{ .node = 0 };
        var dl = element.DrawList.init(testing.allocator);
        defer dl.deinit();
        try drawCanvas(c, canvas, &lc, &dl);
        try testing.expectEqual(NODE_RING_HOVER, dl.quads.items[0].color);
    }
    {
        // Selection outranks hover: a node you are pointing at and have
        // already chosen should read as chosen.
        c.selected = 0;
        var dl = element.DrawList.init(testing.allocator);
        defer dl.deinit();
        try drawCanvas(c, canvas, &lc, &dl);
        try testing.expectEqual(NODE_RING_SELECTED, dl.quads.items[0].color);
    }
    {
        // Hovering a PIN lights the node it belongs to — the pointer is
        // on that node, and a node that went dark because you touched
        // one of its own pins would read as a flicker.
        c.selected = null;
        c.hovered = .{ .pin = 1 };
        var dl = element.DrawList.init(testing.allocator);
        defer dl.deinit();
        try drawCanvas(c, canvas, &lc, &dl);
        const owner = c.pins.items[1].node;
        try testing.expectEqual(NODE_RING_HOVER, dl.quads.items[3 * owner].color);
    }
}

test "nodegraph: a node panned off the canvas costs nothing" {
    // Mutation: delete the two `continue` culls in the node loop. Red —
    // and at fifty nodes on a small canvas it is most of the frame.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.view = .{ .pan = .{ 100_000, 100_000 }, .zoom = GRIDLESS_ZOOM };

    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    var lc = testCtx();
    try drawCanvas(c, .{ .x = 0, .y = 0, .w = 600, .h = 400 }, &lc, &dl);

    try testing.expectEqual(@as(usize, 0), dl.quads.items.len);
    // The ground is still drawn — a canvas panned off its own content is
    // still a canvas, and a hole in the document would be worse.
    try testing.expectEqual(@as(usize, 4), dl.tris.items.len);
}

test "nodegraph: a segment is trimmed to the canvas, because tris are not scissored" {
    // `DrawList.sealClips` fills `quad_clips` and `glyph_clips` and
    // there is no `tri_clips` — the GPU scissor never sees a triangle.
    // Mutation: `return seg` from `clipSegment` unchanged. Red, and on
    // screen a wire from an off-canvas node draws straight across the
    // prose next to it.
    const r = Rect{ .x = 100, .y = 100, .w = 200, .h = 100 };
    const trimmed = clipSegment(.{ .a = .{ 0, 150 }, .b = .{ 400, 150 } }, r).?;
    try testing.expectApproxEqAbs(@as(f32, 100), trimmed.a[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300), trimmed.b[0], 1e-3);
    // Wholly outside is nothing at all, not a zero-length stub.
    try testing.expect(clipSegment(.{ .a = .{ 0, 0 }, .b = .{ 50, 20 } }, r) == null);
    // Wholly inside is untouched.
    const inside = clipSegment(.{ .a = .{ 120, 120 }, .b = .{ 280, 180 } }, r).?;
    try testing.expectApproxEqAbs(@as(f32, 120), inside.a[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 280), inside.b[0], 1e-3);
}
