//! `:::nodegraph` — a pannable, zoomable canvas of nodes, pins and links.
//!
//! Beat 1 settled **draw and navigate**: pan, zoom, drag a node, hover,
//! select, write the moved positions back out. Its four decisions — the
//! transform, hit testing, layering, link rendering — are the four
//! everything after inherits.
//!
//! Beat 2 is **wiring**: a wire is dragged off a pin, every pin in the
//! graph says at once whether it would take it, and the release asks the
//! host to join them. Still no palette, nothing is deleted, there is no
//! marquee and no drill-in.
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
//! ## The grammar — one parser, three doors
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
//!   * `node id= x= y= [w=] [h=] [label=] [tint=] [ring=]` — declares a
//!     node at a graph-space top-left. `w`/`h` override the size the pin
//!     count would otherwise pick; `ring` overrides its resting outline,
//!     which is how a host marks the few nodes in a graph that are not
//!     operators. A node with no LABELLED pin and at most one row is
//!     drawn as its title bar alone, with no body.
//!   * `pin node= id= dir=in|out [label=] [type=<token>]` — hangs a pin
//!     on a declared node. Order within a direction is the order the
//!     lines appear in. `type` is an OPAQUE token; see below.
//!   * `link from=<node>.<pin> to=<node>.<pin> [tint=]` — split on the
//!     LAST dot, so a node id may contain dots and a pin id may not.
//!     Resolved after the whole text is read, so link lines may precede
//!     the pins they name.
//!   * `accept from=<token> to=<token> [mode=exact|coerce]` — one
//!     declared compatibility pair. See "Reachability" below.
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
//!   * `readDescription(gpa, text)` is the door with no component behind
//!     it at all, for the caller that WRITES this grammar rather than
//!     reading it. matryoshka generates a payload from a parsed rill
//!     program and wanted to assert that its nodes and links survive
//!     spark's parser; the only alternative was a second parser over
//!     there, and two answers to "what does this line mean" drift the
//!     first time either side gains a rule. `Description` is what the
//!     component holds and what that door hands out — same struct, same
//!     `read`, one implementation.
//!
//! ## Reachability, and how a type system reaches spark without
//! ## spark learning one
//!
//! With a wire in hand every pin in the graph answers the same question
//! — *can this land on you* — and there are **three** answers, not two.
//! The third is the one worth having: Blade3D's `OutputPort.cs` lit a
//! port LIME when the classes matched and ORANGE when they only matched
//! through `AnyTypeConverter.IsConvertible`, so *yes, and a conversion
//! gets inserted* was visible before you let go. That is a different
//! answer from both yes and no and a reader wants it.
//!
//! spark cannot compute it, because computing it means knowing what a
//! type is. So the host declares the relation as **data**:
//!
//!   * each pin carries an opaque `type=` token — spark only ever
//!     compares two of them for equality or looks the pair up;
//!   * `accept from= to= mode=` rows say which ordered pairs are legal
//!     and at what cost.
//!
//! An earlier design gave pins a token and made the rule *"equal, or
//! either side is `*`"*. It is smaller and it cannot express orange: a
//! relation is not recoverable from equality. rill's whole type table is
//! eight builtins, so declaring the relation costs a handful of rows.
//!
//! Two properties keep this from becoming a trap. **No `accept` rows at
//! all means everything reaches everything** — a description written
//! before this record existed behaves as it always did, and a host with
//! no type system pays nothing. And an **empty token still reaches**,
//! because a pin the host said nothing about is not a pin the host
//! refused. spark refuses only what it was told to refuse.
//!
//! Three rules ARE spark's own, because they are facts about a canvas
//! and not about a language: a wire joins opposite directions, a pin
//! does not reach its own node, and **a wire does not close a loop**.
//!
//! That third one was left out at first, on the argument that whether a
//! cycle is legal is the host's question — rill refuses one, a modular
//! synth patch is made of them. Christian, on seeing it: *"when I start
//! dragging a port, nodes upstream from the node port I'm dragging show
//! as being able to accept. That's cycles — I'm not sure we should be
//! allowing those."* The argument does not survive, because rule 2 is
//! already a cycle of length one: refusing length one and shrugging at
//! length two is not a policy, it is an accident of how far the check
//! happened to look.
//!
//! Christian, on the ruling: *"I think it is the right call — for now.
//! Maybe in future we allow cycles, but with special user facing
//! machinery."* That is the shape, and it is how everyone who allows
//! loops actually does it: Max, Reaktor and Bitwig all make you SAY so,
//! with an explicit unit-delay standing where the loop closes. So the
//! recorded-not-built thing is not a host flag that switches this rule
//! off — it is a node kind whose input is declared to be last tick's
//! value, which the walk then treats as no edge at all. Trigger: a host
//! with such a node.
//!
//! ## The edit channel: the canvas asks, the host answers
//!
//! `positions=` is an echo: the canvas moved the node, and nothing else
//! could have computed where it went. A WIRE is not like that. Whether
//! two pins may be joined is a question about the host's language, so
//! the release writes a REQUEST to `edits=` and the host answers with a
//! whole new graph. The canvas does not apply the edit to itself.
//!
//! That asymmetry is what makes a refusal free. There is no "no" to
//! send, no error path, no rollback: the graph you already had simply
//! arrives again, and because the canvas never diverged there is
//! nothing to reconcile.
//!
//! **Every record is an assignment, never a toggle.** `link` sets an
//! input's source; `unlink` clears one. Applying either twice is
//! applying it once — so a host re-reading the path on a repeated
//! notification cannot double-apply, and the channel needs no sequence
//! number and no acknowledgement.
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
/// How far the right end of a bare node tapers to a point, in graph
/// units.
///
/// **Only a node that OUTPUTS gets one.** Chris, 2026-09-12, once the
/// externals had lost their bodies: *"they do resemble edge connector
/// pins on circuit diagrams quite a lot now. I'm wondering can we make
/// the output port side on the right of these 'pins' slightly
/// triangular."* A taper is an arrow, and an arrow on a node with
/// nothing leaving it points at nothing — `spawn1` and `perish1` are
/// bare too, and they stay rectangular.
const NOSE_W: f32 = 12;
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
/// How much of its tint a node's title bar keeps.
///
/// **A node the host RINGED keeps all of it**, and that is the rule with
/// its own reason applied rather than an exception to it. The darken
/// exists so a header sits WITH the body panel under it instead of
/// shouting over it; a ringed node is bare, has no body to sit with, and
/// has been named by the host as something other than an operator — a
/// connector, which is exactly the thing on a canvas that should shout.
///
/// **Keyed to the ring and not to bareness**, which the first draft got
/// wrong and the picture caught: `spawn1` and `perish1` are bare too —
/// operators that happen to declare no ports — and at full strength they
/// became the loudest things on the canvas while meaning nothing of the
/// sort.
///
/// It is also the only thing that makes a yellow chip possible. Chris
/// asked for bright yellow and got *"more like a mustard yellow"*:
/// yellow is a hue that only exists at high luminance, and 0.55 of any
/// yellow is olive. Red and blue survive the darken, so the palette
/// looked fine and no hex value could have fixed it. *"Well why can't we
/// turn up the luminance?"* — nothing could; that is the whole fix.
const NODE_HEADER_TINT: f32 = 0.55;
/// Text for a bar too light to read light text on, and the luminance at
/// which it takes over. A full-strength yellow or green chip needs dark
/// letters; a red or blue one does not.
const NODE_LABEL_DARK: [4]f32 = .{ 0.10, 0.10, 0.12, 1.0 };
const LABEL_DARK_ABOVE: f32 = 0.55;
const NODE_RING: [4]f32 = .{ 0.0, 0.0, 0.0, 0.55 };
const NODE_RING_HOVER: [4]f32 = .{ 1.0, 1.0, 1.0, 0.30 };
const NODE_RING_SELECTED: [4]f32 = .{ 1.0, 0.78, 0.32, 0.95 };
const NODE_TINT_DEFAULT: [4]f32 = .{ 0.36, 0.44, 0.62, 1.0 };

const PIN_IN_COLOR: [4]f32 = .{ 0.55, 0.72, 0.95, 1.0 };
const PIN_OUT_COLOR: [4]f32 = .{ 0.62, 0.86, 0.68, 1.0 };
const PIN_HOVER_COLOR: [4]f32 = .{ 1.0, 0.95, 0.72, 1.0 };

// ── While a wire is in hand ─────────────────────────────────────────
// Three states, and the third is the one worth having: a pin that can
// be reached only through a conversion is a DIFFERENT answer from both
// yes and no, and saying so before the button comes up is the whole
// point. Blade3D flashed lime and orange and left everything else dark;
// this is that, minus the pulse (see `Reach`).
//
// Neither of these is `PIN_OUT_COLOR`'s pastel green, deliberately: an
// idle out-pin is already greenish, so a reachable pin has to be
// unmistakably MORE than that, not a shade of it.
const PIN_REACH_EXACT: [4]f32 = .{ 0.40, 0.98, 0.45, 1.0 };
const PIN_REACH_COERCE: [4]f32 = .{ 1.0, 0.62, 0.16, 1.0 };
/// What an unreachable pin fades to while a wire is out. Colour alone
/// would be enough on this palette; it is not enough for every reader,
/// which is why a reachable pin also GROWS (`PIN_REACH_R`). Two cues,
/// one of them not colour.
const PIN_DIM: f32 = 0.22;
/// Radius of a reachable pin while a wire is in hand. The size cue.
const PIN_REACH_R: f32 = 6.0;
/// The wire in hand, before it is over anything that will take it.
/// Blade3D's teal, one notch cooler than this palette's link grey so it
/// reads as "live" rather than "drawn".
const WIRE_LOOSE: [4]f32 = .{ 0.40, 0.80, 0.85, 0.95 };

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
/// How far, in SCREEN pixels, a flattened wire may stray from the curve
/// it stands for. The flattening spends points to hold this, so it is
/// the only tuning knob the shape of a wire has.
///
/// **This replaced a segment COUNT, and the difference is where the
/// points go.** A count spread evenly over `t` puts most of them in a
/// cubic's straight middle and starves its ends, which is exactly
/// backwards — a wire's curvature is all in the two bends where it
/// leaves and arrives. Chris, 2026-09-12: *"it's not just the dots —
/// should probably do adaptive refinement of line segment length based
/// on curvature."*
///
/// A pixel tolerance also makes the zoom rule disappear rather than be
/// implemented: flatness is measured on the SCREEN curve, so a graph
/// zoomed out to a fifth is a smaller curve and flattens to fewer
/// points for free. The old `segmentCount` had to multiply by zoom by
/// hand to get that.
///
/// 0.2px against a 1.8px wire with a 1px feather: a fifth of the fade,
/// which is not a thing anyone can see.
const LINK_FLATNESS: f32 = 0.2;
/// The ceiling on one wire's flattened points, and so on its cost.
///
/// Reached only by a curve far longer than a viewport — see
/// `flattenCubic`, which gets COARSER at the far end rather than
/// stopping short of the pin.
const LINK_MAX_PTS: usize = 192;

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
    /// Drawn as its title bar alone, with no body under it — see
    /// `finalise`, which is the only place this is decided.
    bare: bool = false,
    /// The resting ring, when the description asked for one.
    ///
    /// **The host's word about which nodes are special, and spark never
    /// guesses it.** A graph usually has a handful of nodes that are not
    /// operators — a constant, a subscription to something outside, a
    /// note — and only the host knows which. Hover and selection still
    /// win over it: a ring that cannot say "this one is selected" is a
    /// ring that has taken the state channel for decoration.
    ring: ?[4]f32 = null,
};

pub const Pin = struct {
    node: u32,
    id: []const u8,
    label: []const u8,
    dir: Dir,
    /// Row within this node's pins of the same direction.
    slot: u32,
    /// **An opaque compatibility token.** spark does not know what it
    /// means and must never learn: the host names its own types, and
    /// this file only ever compares two of these for equality or looks
    /// the pair up in the `accept` table the host declared beside them.
    ///
    /// Empty is "the host said nothing about this pin", which is not
    /// the same as a type called "" — see `reachOf`, where it is the
    /// difference between refusing and declining to guess.
    ty: []const u8 = "",
};

/// One declared compatibility pair: a wire leaving a `from` pin may
/// land on a `to` pin, and `mode` says at what cost.
///
/// **This is how a lattice reaches spark without spark learning one.**
/// The first design gave each pin a token and made the rule "equal, or
/// either side is `*`" — which cannot express Blade3D's orange, the
/// answer that means *yes, and a conversion is inserted*. A relation
/// cannot be recovered from equality, so the host declares the relation
/// itself, as data, for the pairs its graph actually contains. rill's
/// whole type table is eight builtins, so this is a handful of rows.
pub const Accept = struct {
    from: []const u8,
    to: []const u8,
    mode: Reach,
};

/// **A wire in hand, and everything a pin needs to answer it.**
///
/// The anchor alone was not enough. Christian, 2026-09-10, watching the
/// first version: *"when I start dragging a port, nodes upstream from
/// the node port I'm dragging show as being able to accept. That's
/// cycles — I'm not sure we should be allowing those."*
///
/// He is right, and the argument I had for leaving them is the one that
/// does not survive: this file ALREADY refuses a pin reaching its own
/// node, and that is a cycle of length one. Refusing length one and
/// allowing length two is not a policy, it is an accident of how far
/// the check happened to look. Whether a cycle is legal is still the
/// host's question in principle — a modular-synth patch is made of them
/// — but the honest shape for that is a host that OPTS IN, not a canvas
/// that refuses one length and shrugs at the rest. Recorded, not built;
/// the trigger is the first host that wants feedback.
///
/// So `blocked` is one bit per node, filled once when the wire is
/// picked up. It is computed rather than passed as a rule because the
/// answer depends on which END is in hand: an OUT anchor is the wire's
/// source, so everything already feeding it is blocked (walk upstream);
/// an IN anchor is its sink, so everything it already feeds is blocked
/// (walk downstream). One walk either way.
pub const Probe = struct {
    anchor: u32,
    /// True where a wire from `anchor` would close a loop. Empty is a
    /// legitimate answer meaning "nothing is blocked" — a graph with no
    /// links at all, and what a gate passes when the subject is a rule
    /// other than this one.
    blocked: []const bool = &.{},

    fn blocks(self: Probe, node: u32) bool {
        return node < self.blocked.len and self.blocked[node];
    }
};

/// What a wire in hand may do to a pin. Ordered by permissiveness so
/// `@intFromEnum` can be compared if that is ever wanted.
///
/// **Why this is not a pulse.** Blade3D drove the same three states as
/// a flashing tint out of `gameTime.TotalGameTime`, and a fourth speed
/// for the port under the cursor. spark has no clock at draw time and
/// should not grow one by reading the wall — spindrift's rule ("time is
/// fed, never read") is the house rule and this library is downstream of
/// the same discipline. The information content is identical without the
/// pulse: three colours, a size step, and the pin under the cursor is
/// already `hovered`. If spark is ever fed a frame time, a pulse is one
/// multiply here and nothing else changes.
pub const Reach = enum { none, exact, coerce };

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

/// Flatten a cubic to a polyline that is nowhere further than `tol`
/// from the true curve, **spending points where the curve BENDS**.
///
/// Recursive de Casteljau subdivision, the standard one: a piece whose
/// control points lie within `tol` of its own chord is emitted as that
/// chord, and anything else is split in half and both halves asked
/// again. So a wire's two bends get a point every few pixels and its
/// straight middle gets none — which is the whole difference from
/// sampling `t` uniformly, where the count is set by the bends and then
/// paid for over the straight part as well.
///
/// Called in SCREEN space. `tol` is a pixel tolerance, and that is what
/// makes the zoom rule fall out instead of being written: a graph
/// zoomed out is a smaller curve, closer to its chords, and flattens to
/// fewer points on its own.
///
/// **The flatness test is not only perpendicular distance.** A control
/// point may sit close to the chord's LINE while projecting far off its
/// ends, and that is a curve doubling back, not a flat one. It is
/// reachable here, not theoretical: a wire whose consumer is LEFT of
/// its producer leaves rightwards, comes back, and leaves rightwards
/// again, and its chord points the other way. So the projection is
/// bounded too.
///
/// Returns the prefix of `buf` written, `p0` first and `p1` last. If
/// `buf` runs out the flattening gets COARSER at the far end and the
/// last point is still `p1` — a wire that stopped short of its pin
/// would be a worse failure than a visible chord.
pub fn flattenCubic(
    buf: [][2]f32,
    p0: [2]f32,
    c0: [2]f32,
    c1: [2]f32,
    p1: [2]f32,
    tol: f32,
) []const [2]f32 {
    if (buf.len < 2) return buf[0..0];
    buf[0] = p0;
    var n: usize = 1;

    const Piece = struct { p0: [2]f32, c0: [2]f32, c1: [2]f32, p1: [2]f32, depth: u8 };
    // A binary tree walked depth-first holds at most depth+1 pieces,
    // because each step pops one and pushes two.
    const MAX_DEPTH: u8 = 16;
    var stack: [MAX_DEPTH + 2]Piece = undefined;
    stack[0] = .{ .p0 = p0, .c0 = c0, .c1 = c1, .p1 = p1, .depth = 0 };
    var sp: usize = 1;

    while (sp > 0) {
        sp -= 1;
        const q = stack[sp];
        // Splitting needs a free slot for the extra point and room for
        // the half that is not walked next. Out of either, this piece
        // is taken as flat — the coarsening the doc comment promises.
        const may_split = n + 1 < buf.len and sp + 2 <= stack.len and q.depth < MAX_DEPTH;
        if (may_split and !flatEnough(q.p0, q.c0, q.c1, q.p1, tol)) {
            const m0 = mid(q.p0, q.c0);
            const m1 = mid(q.c0, q.c1);
            const m2 = mid(q.c1, q.p1);
            const m3 = mid(m0, m1);
            const m4 = mid(m1, m2);
            const m5 = mid(m3, m4);
            // Right first, so the LEFT half is the next one popped and
            // the points come out in order along the curve.
            stack[sp] = .{ .p0 = m5, .c0 = m4, .c1 = m2, .p1 = q.p1, .depth = q.depth + 1 };
            stack[sp + 1] = .{ .p0 = q.p0, .c0 = m0, .c1 = m3, .p1 = m5, .depth = q.depth + 1 };
            sp += 2;
            continue;
        }
        buf[n] = q.p1;
        n += 1;
        if (n == buf.len) break;
    }
    // Whatever was dropped, the wire ends on its pin.
    buf[n - 1] = p1;
    return buf[0..n];
}

fn mid(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

/// Is this cubic within `tol` of its own chord, both across and along?
///
/// Conservative on purpose: the curve's own deviation is at most
/// three-quarters of its control points', so holding the control points
/// to `tol` holds the curve to less.
fn flatEnough(p0: [2]f32, c0: [2]f32, c1: [2]f32, p1: [2]f32, tol: f32) bool {
    const ux = p1[0] - p0[0];
    const uy = p1[1] - p0[1];
    const len2 = ux * ux + uy * uy;
    // A chord of no length is a loop closing on itself, never flat.
    // The depth cap, not this, is what stops the recursion.
    if (!(len2 > 1e-12)) return false;
    const len = @sqrt(len2);
    const slack = tol / len;
    for ([2][2]f32{ c0, c1 }) |c| {
        const vx = c[0] - p0[0];
        const vy = c[1] - p0[1];
        if (@abs(vx * -uy + vy * ux) / len > tol) return false;
        const t = (vx * ux + vy * uy) / len2;
        if (t < -slack or t > 1 + slack) return false;
    }
    return true;
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

/// Every maximal run of `pts` that is inside `r`, one run per `next`.
///
/// A polyline cannot be handed to `clipSegment` a segment at a time and
/// stroked piecewise — that is the per-segment drawing this file gave
/// up, and it would bring the seams back at the canvas edge. So the
/// CLIP produces polylines too: a run ends where a segment leaves the
/// rectangle or is wholly outside it, and the next run begins where one
/// comes back.
///
/// `buf` is where a run is assembled and is only valid until the next
/// call. It bounds a run's length; a run longer than it simply breaks
/// into two, which costs one joint and no correctness.
pub const RunIter = struct {
    pts: []const [2]f32,
    r: Rect,
    buf: [][2]f32,
    i: usize = 0,

    pub fn next(self: *RunIter) ?[]const [2]f32 {
        var n: usize = 0;
        while (self.i + 1 < self.pts.len) {
            const vis = clipSegment(.{ .a = self.pts[self.i], .b = self.pts[self.i + 1] }, self.r);
            if (vis) |v| {
                if (n == 0) {
                    if (self.buf.len < 2) return null;
                    self.buf[0] = v.a;
                    self.buf[1] = v.b;
                    n = 2;
                } else if (n < self.buf.len and joins(self.buf[n - 1], v.a)) {
                    self.buf[n] = v.b;
                    n += 1;
                } else {
                    // This piece starts somewhere the run did not end —
                    // the previous segment was trimmed at its far edge —
                    // or the buffer is full. Hand back what there is and
                    // reconsider this same segment next time, WITHOUT
                    // advancing, so it opens the next run.
                    return self.buf[0..n];
                }
            } else if (n > 0) {
                self.i += 1;
                return self.buf[0..n];
            }
            self.i += 1;
        }
        return if (n > 0) self.buf[0..n] else null;
    }
};

/// Did a clipped segment begin exactly where the last one ended?
///
/// `clipSegment` returns an untrimmed end as `a + 0 * d`, which is
/// bit-identical to `a`, so this could be equality. It is a tolerance
/// instead because the alternative to a false join is a false BREAK,
/// and a break puts a seam in the middle of a wire; a quarter of a
/// pixel cannot merge two runs that are really apart, since runs are
/// separated by a canvas edge crossing.
fn joins(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) < 0.25 and @abs(a[1] - b[1]) < 0.25;
}

// ── The description, and the public door to it ──────────────────────

/// Everything a description text says, and nothing about who is reading
/// it: the nodes, the pins, the links, the camera, and the count of
/// lines nobody could read.
///
/// **One implementation, two callers.** `:::nodegraph` holds one of
/// these and puts a reader in front of it — a selection, a hover, a
/// gesture latch, a content version. `readDescription` hands one
/// straight to a caller that has no component and no document, which is
/// what a host GENERATING this grammar needs in order to assert that
/// what it emitted survives spark's own parser. Without that door the
/// host writes a second parser, and two answers to "what does this line
/// mean" drift the first time either side gains a rule.
///
/// The alternative offered was making `Component` public. That is
/// weaker: it exposes a whole component — its gesture latch, its bound
/// state paths, its write-back — to get at a parser.
///
/// Rejected names: `Graph` (this file already means something by that
/// word; `Node`, `Pin` and `Link` ARE the graph, and a thing holding a
/// camera and a bad-line count is not one), `ParsedDescription` (the
/// `read` is what parses — a description is what it produced), `Payload`
/// (what the host calls the text going IN, not the shape coming out).
pub const Description = struct {
    /// Where the three lists live, and where the arena is freed from.
    gpa: std.mem.Allocator,
    /// Owns every string the description produced. Reset wholesale on
    /// re-read; the three lists below keep their capacity across it.
    /// Heap-allocated, so a `Description` can be returned by value
    /// without the vended arena allocator pointing at a dead stack slot.
    arena: *std.heap.ArenaAllocator,

    nodes: std.ArrayList(Node),
    pins: std.ArrayList(Pin),
    links: std.ArrayList(Link),
    /// The host's declared compatibility pairs. EMPTY means the host
    /// declared no lattice at all, which `reachOf` reads as "everything
    /// reaches everything" — not as "nothing does". A description
    /// written before this record existed keeps working unchanged, and
    /// that is the point: spark refuses nothing it was not told about.
    accepts: std.ArrayList(Accept),

    /// The camera a `view` record seeds. In-out across a read: a `view`
    /// line names only the fields it mentions and the rest keep what
    /// they had, which for a live component is wherever the reader has
    /// panned to.
    view: View = .{},

    /// Unreadable description lines, counted rather than swallowed. The
    /// component draws a strip; a host asserting on its own output reads
    /// the number. A `link` naming a pin nobody declared lands here too,
    /// which is why the count is only final once the links resolve.
    bad_lines: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) !Description {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        return .{
            .gpa = gpa,
            .arena = arena,
            .nodes = std.ArrayList(Node).init(gpa),
            .pins = std.ArrayList(Pin).init(gpa),
            .links = std.ArrayList(Link).init(gpa),
            .accepts = std.ArrayList(Accept).init(gpa),
        };
    }

    pub fn deinit(self: *Description) void {
        self.nodes.deinit();
        self.pins.deinit();
        self.links.deinit();
        self.accepts.deinit();
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// Forget every node, pin and link, and every string they hold.
    /// The camera survives: `pan` and `zoom` are where the reader is
    /// looking, and a description that does not mention `view` must not
    /// throw that away.
    fn clearGraph(self: *Description) void {
        self.nodes.clearRetainingCapacity();
        self.pins.clearRetainingCapacity();
        self.links.clearRetainingCapacity();
        self.accepts.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    fn findNode(self: *const Description, id: []const u8) ?u32 {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.id, id)) return @intCast(i);
        }
        return null;
    }

    fn findPin(self: *const Description, node: u32, id: []const u8) ?u32 {
        for (self.pins.items, 0..) |p, i| {
            if (p.node == node and std.mem.eql(u8, p.id, id)) return @intCast(i);
        }
        return null;
    }

    /// Read `text` into this description, replacing what was there.
    /// `positions_only` applies `pos` records to the graph already held
    /// and ignores everything else — the `move` action, and the shape
    /// that makes an echoed write-back a no-op.
    ///
    /// The one parser. `readDescription` is this plus an owner;
    /// `Component.parse` is this plus a reader.
    pub fn read(self: *Description, text: []const u8, positions_only: bool) !void {
        const a = self.arena.allocator();
        if (!positions_only) self.clearGraph();
        self.bad_lines = 0;

        var pending = std.ArrayList(PendingLink).init(self.gpa);
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
                    } else if (std.mem.eql(u8, f.key, "ring")) {
                        if (box_helpers.parseColor(f.value)) |c| n.ring = c;
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
                    } else if (std.mem.eql(u8, f.key, "type")) {
                        p.ty = try a.dupe(u8, f.value);
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
            } else if (std.mem.eql(u8, kind, "accept")) {
                var ac = Accept{ .from = "", .to = "", .mode = .exact };
                while (it.next()) |f| {
                    if (std.mem.eql(u8, f.key, "from")) {
                        ac.from = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "to")) {
                        ac.to = try a.dupe(u8, f.value);
                    } else if (std.mem.eql(u8, f.key, "mode")) {
                        // `exact` is the default and needs no spelling.
                        // An unknown mode is a BAD LINE, not a silent
                        // demotion to exact: a host that misspells
                        // `coerce` would otherwise get green pins where
                        // it asked for amber and never find out.
                        if (std.mem.eql(u8, f.value, "coerce")) {
                            ac.mode = .coerce;
                        } else if (!std.mem.eql(u8, f.value, "exact")) {
                            ac.mode = .none;
                        }
                    }
                }
                if (ac.from.len == 0 or ac.to.len == 0 or ac.mode == .none) {
                    self.bad_lines += 1;
                    continue;
                }
                try self.accepts.append(ac);
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
    }

    fn resolveRef(self: *const Description, ref: []const u8) ?u32 {
        const parts = splitRef(ref) orelse return null;
        const node = self.findNode(parts.node) orelse return null;
        return self.findPin(node, parts.pin);
    }

    /// Size every node that did not state its own. Runs after the whole
    /// description is read, because the pin count that drives the height
    /// is not known until then.
    fn finalise(self: *Description) void {
        for (self.nodes.items, 0..) |*n, i| {
            if (!n.w_given) n.size[0] = NODE_W;
            n.bare = !n.h_given and self.isBare(@intCast(i));
            if (n.bare) {
                n.size[1] = HEADER_H;
            } else if (!n.h_given) {
                const rows: f32 = @floatFromInt(@max(n.in_count, n.out_count));
                const h = HEADER_H + PIN_TOP + @max(rows - 1, 0) * PIN_PITCH + PIN_BOTTOM;
                n.size[1] = @max(h, NODE_MIN_H);
            }
        }
    }

    /// Has this node anything to put in a body?
    ///
    /// A body exists to hold labelled pin rows. A node with none — a
    /// host's chip standing for a constant or a plane path, a sink or a
    /// source whose ports are all implied — currently draws an empty
    /// dark panel under its title bar, which says "there is something
    /// here" about nothing. Chris, 2026-09-12: *"the externals don't
    /// need a body panel. the port can connect straight to the RGB
    /// titlebar. That makes them even more distinct looking on the
    /// graph."*
    ///
    /// **A row count of one is part of the test, not a shortcut.** Two
    /// unlabelled pins would be two rows, and collapsing their node to a
    /// 26px bar stacks them on top of each other. So the rule is what it
    /// says: nothing to write, and nowhere it would have to go.
    ///
    /// This is structural and spark stays out of what a node MEANS — it
    /// has no idea which of these is an external. A host that wants a
    /// body keeps one by labelling a pin, which it had to do anyway for
    /// the label to appear.
    fn isBare(self: *const Description, node: u32) bool {
        if (@max(self.nodes.items[node].in_count, self.nodes.items[node].out_count) > 1) return false;
        for (self.pins.items) |p| {
            if (p.node == node and p.label.len > 0) return false;
        }
        return true;
    }

    /// The link, if any, feeding this INPUT pin.
    ///
    /// An input takes at most one source — that is not a convention
    /// this file invented, it is what a dataflow slot IS, and Blade3D
    /// enforced it by deleting any existing connection to a target pin
    /// before making a new one. Here it is what makes picking a wire up
    /// off an input unambiguous: there is only ever one to pick up.
    pub fn linkInto(self: *const Description, pin: u32) ?u32 {
        for (self.links.items, 0..) |l, i| {
            if (l.to == pin) return @intCast(i);
        }
        return null;
    }

    /// **Which nodes a wire from `anchor` must not land on**, because it
    /// would close a loop. Fills `out` with one bool per node.
    ///
    /// The direction of the walk is the direction the wire is NOT going.
    /// An out-anchor is the wire's source, so a landing on anything that
    /// already feeds it closes the loop — walk upstream. An in-anchor is
    /// its sink, so a landing on anything it already feeds does — walk
    /// downstream. The anchor's own node is marked either way, which
    /// costs nothing and makes rule 2 and this rule agree instead of
    /// overlapping by accident.
    ///
    /// **A wire that is IN HAND needs no special case, and finding out
    /// why is the reason this comment is here.** The first version took
    /// a `lifted` link to skip, on the argument that walking through a
    /// wire the reader is holding would refuse a rehome that is legal
    /// once it is gone. It is inert, and provably so: a lifted link runs
    /// `anchor's node → the pin that was picked up`, the walk starts by
    /// marking the anchor's node, and traversing that link backwards
    /// arrives at exactly that already-marked node. The visited check
    /// skips it every time, in every graph, cyclic or not. Written,
    /// gated, and the gate could not be made to fail — so the parameter
    /// is gone rather than kept as a comment with an argument list.
    ///
    /// Iterative, with `out` doubling as the visited set, so a graph
    /// with a loop already in it (a host may hand us one) terminates. A
    /// naive O(nodes x links) scan per step: 22 nodes and 19 links on
    /// the exemplar, filled once per gesture rather than per frame.
    /// Trigger for an adjacency index: a graph where this shows up.
    pub fn blockCycles(
        self: *const Description,
        out: *std.ArrayList(bool),
        anchor: u32,
    ) !void {
        out.clearRetainingCapacity();
        try out.appendNTimes(false, self.nodes.items.len);
        if (anchor >= self.pins.items.len) return;
        const up = self.pins.items[anchor].dir == .out;

        var stack = std.ArrayList(u32).init(self.gpa);
        defer stack.deinit();
        const start = self.pins.items[anchor].node;
        out.items[start] = true;
        try stack.append(start);

        while (stack.pop()) |node| {
            for (self.links.items) |l| {
                const near = if (up) l.to else l.from;
                const far = if (up) l.from else l.to;
                if (self.pins.items[near].node != node) continue;
                const next = self.pins.items[far].node;
                if (out.items[next]) continue;
                out.items[next] = true;
                try stack.append(next);
            }
        }
    }

    /// **Can a wire anchored at `anchor` land on `pin`?**
    ///
    /// Three rules, and only the third is the host's business:
    ///
    ///   1. *Direction.* An out reaches an in and an in reaches an out.
    ///      A wire between two inputs is not a thing a graph can mean.
    ///   2. *Not its own node.* Blade3D refused this at
    ///      `ReferenceEquals(inputBlock, outputBlock)` and so do we. An
    ///      operator feeding itself is a cycle of length one.
    ///   3. *The token.* With no `accept` records the host declared no
    ///      lattice, so every pair is `.exact` — a graph drawn before
    ///      this record existed behaves as it always did. With records,
    ///      an EMPTY token on either side still reaches: an untyped pin
    ///      is one the host said nothing about, and refusing it would be
    ///      a guess. Everything else must be declared.
    ///
    ///   2b. *No loop.* `probe.blocked` says which nodes a wire from this
    ///      anchor would close a loop through — see `Probe`. Rule 2 is
    ///      the length-one case of this one, kept as its own line
    ///      because it holds even when nobody filled the mask.
    ///
    /// Pure, and takes the description rather than the component, so
    /// every case above is gated without a device.
    pub fn reachOf(self: *const Description, probe: Probe, pin: u32) Reach {
        const anchor = probe.anchor;
        if (anchor >= self.pins.items.len or pin >= self.pins.items.len) return .none;
        const a = self.pins.items[anchor];
        const b = self.pins.items[pin];
        if (a.dir == b.dir) return .none;
        if (a.node == b.node) return .none;
        if (probe.blocks(b.node)) return .none;
        if (self.accepts.items.len == 0) return .exact;

        // The pair is always read source-to-sink, whichever end the
        // reader happened to grab. Without this, dragging backwards off
        // an input would look the pair up the wrong way round and a
        // one-directional coercion would light the wrong pins.
        const from = if (a.dir == .out) a.ty else b.ty;
        const to = if (a.dir == .out) b.ty else a.ty;
        if (from.len == 0 or to.len == 0) return .exact;
        for (self.accepts.items) |ac| {
            if (std.mem.eql(u8, ac.from, from) and std.mem.eql(u8, ac.to, to)) return ac.mode;
        }
        return .none;
    }

    /// The reachable pin nearest `g` on node `node`, or null.
    ///
    /// Releasing a wire has to be forgiving. A pin dot is four graph
    /// units across and aiming at one at 0.4 zoom is a game, not an
    /// edit — so a release anywhere on a node's BODY lands on that
    /// node's nearest pin that would take the wire. Blueprints does
    /// this; Blade3D did not, and its `GetControlAt` returning anything
    /// but an `InputPort` simply dropped the wire.
    pub fn nearestReachable(self: *const Description, probe: Probe, node: u32, g: [2]f32) ?u32 {
        var best: ?u32 = null;
        var best_d2: f32 = std.math.floatMax(f32);
        for (self.pins.items, 0..) |p, i| {
            if (p.node != node) continue;
            if (self.reachOf(probe, @intCast(i)) == .none) continue;
            const c = self.pinCentre(@intCast(i));
            const dx = g[0] - c[0];
            const dy = g[1] - c[1];
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// `<node id>.<pin id>`, the spelling `link from=`/`to=` uses.
    /// Written into the caller's buffer via a writer so the edit channel
    /// composes without a second allocation per record.
    pub fn writeRef(self: *const Description, w: anytype, pin: u32) !void {
        const p = self.pins.items[pin];
        try w.print("{s}.{s}", .{ self.nodes.items[p.node].id, p.id });
    }

    /// A pin's centre, in graph space.
    pub fn pinCentre(self: *const Description, pin: u32) [2]f32 {
        const p = self.pins.items[pin];
        const n = self.nodes.items[p.node];
        // A bare node IS its title bar, so its one pin sits on the bar's
        // centre line. Anywhere else and the wire arrives below a node
        // that stops above it.
        const y = if (n.bare)
            n.pos[1] + HEADER_H * 0.5
        else
            n.pos[1] + HEADER_H + PIN_TOP + @as(f32, @floatFromInt(p.slot)) * PIN_PITCH;
        const x = if (p.dir == .in) n.pos[0] else n.pos[0] + n.size[0];
        return .{ x, y };
    }

    /// What is under a graph-space point. Pins first — they stand proud
    /// of the body and their targets deliberately overlap it — then
    /// nodes in reverse declaration order, so the one drawn last (on
    /// top) is the one picked.
    pub fn pick(self: *const Description, g: [2]f32) Hover {
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
};

/// Read a `:::nodegraph` description and hand back what it says.
///
/// The door the parser was behind. spark RENDERS this grammar and a host
/// GENERATES it, and until now the only way for that host to check its
/// own output was to write a parser of its own. Same text, same rules,
/// one implementation.
///
/// The returned `Description` owns every string in it — nothing points
/// back into `text` — and the caller `deinit`s it.
///
/// Unreadable lines are counted in `bad_lines`, exactly as the component
/// counts them, and are never an error: a description is a picture with
/// a strip along the bottom, not a refusal. A caller that wants a
/// refusal checks the count.
///
/// Rejected names: `parse` (a bare verb, and spark has a dozen of them),
/// `parseDescription` (the same one word longer), `readGraph` (the thing
/// that comes back is not a graph — see `Description`).
pub fn readDescription(gpa: std.mem.Allocator, text: []const u8) !Description {
    var d = try Description.init(gpa);
    errdefer d.deinit();
    try d.read(text, false);
    return d;
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
    /// A wire is in hand.
    ///
    /// **`anchor` is the end that is NOT moving**, and it is not always
    /// the pin that was pressed. Pressing an OUTPUT starts a new wire
    /// anchored there. Pressing an INPUT that already has a link picks
    /// that link UP: the anchor becomes the link's far end and
    /// `detached` remembers which link left the picture, so releasing
    /// over nothing means *disconnect* rather than *nothing happened*.
    /// Pressing a bare input starts a new wire backwards from it.
    ///
    /// Blade3D dragged from outputs only (`InputPort.cs` is fifty-four
    /// lines and does nothing but pulse). Dragging from either end is
    /// free here for the reason the one-source rule makes it free: an
    /// input holds exactly one wire, so "the wire on this input" is
    /// never ambiguous and there is nothing to disambiguate.
    wire: struct {
        anchor: u32,
        /// The link this drag lifted off an input, if any.
        detached: ?u32,
        /// Live cursor, in GRAPH space, so the preview wire is drawn on
        /// the same terms as every real one and needs no second path.
        cursor: [2]f32,
        /// What the cursor is over right now — recomputed on move
        /// rather than read off `hovered`, because hover events are not
        /// guaranteed while a button is held.
        over: Hover,
    },
};

pub const Hover = union(enum) {
    none,
    node: u32,
    pin: u32,
};

const Component = struct {
    allocator: std.mem.Allocator,

    /// What the description text says — nodes, pins, links, the camera
    /// and the unreadable-line count. Everything below is the READER in
    /// front of it: which node is selected, which is under the pointer,
    /// what the hand is doing, where the edits are written back to.
    ///
    /// The split is the whole of `readDescription`: a host that GENERATES
    /// this grammar wants the description and has no use for the reader.
    desc: Description,

    body: component_mod.Body = .{},
    width: box_helpers.Length = .{ .percent = 1.0 },
    height: f32 = 420,

    /// Bare state paths, `:::slider {target=}`-style. Empty means "not
    /// bound", and an unbound channel is simply never written.
    positions_path: []u8,
    selected_path: []u8,
    edits_path: []u8,

    selected: ?u32 = null,
    hovered: Hover = .none,
    grab: Grab = .none,

    /// Where `contextSubject` writes its answer. Long enough for the
    /// longest of them — a `pin:` with a node id and a pin id, both of
    /// which a host mints — and a `bufPrint` that will not fit returns
    /// null, which reads as "nothing claims this point" and is the right
    /// answer for a subject nobody could have parsed anyway.
    subject_buf: [256]u8 = undefined,

    /// `Probe.blocked` for the wire currently in hand — one bool per
    /// node, filled at the press and read by every `reachOf` until the
    /// release. It lives on the component rather than in the `Grab` so
    /// it keeps its capacity across gestures: a reader wiring a graph up
    /// does this once a second, and a fresh allocation per press is a
    /// cost with nothing to show for it.
    cycle_block: std.ArrayList(bool),

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

    version: u64 = 0,

    fn gesturing(self: *const Component) bool {
        return self.grab != .none;
    }

    /// The wire in hand, as every `reachOf` wants it.
    fn probe(self: *const Component) ?Probe {
        return switch (self.grab) {
            .wire => |w| .{ .anchor = w.anchor, .blocked = self.cycle_block.items },
            else => null,
        };
    }

    // ── Reading the description ────────────────────────────────────

    /// Read `text` into this component. The parse itself is
    /// `Description.read`, which `readDescription` calls too; what is
    /// added here is what a READER has and a description does not.
    ///
    /// Both additions are load-bearing. `selected` and `hovered` name
    /// nodes by INDEX into a list the read is about to rebuild, so a
    /// full read has to drop them or they point at whatever now sits in
    /// that slot. And `version` is what the block cache is keyed on: a
    /// new description that did not bump it is a graph that changed and
    /// was drawn from the cache anyway.
    fn parse(self: *Component, text: []const u8, positions_only: bool) !void {
        if (!positions_only) {
            self.selected = null;
            self.hovered = .none;
        }
        try self.desc.read(text, positions_only);
        self.version +%= 1;
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
            } else if (std.mem.eql(u8, k, "edits")) {
                try component_mod.adoptString(a, &self.edits_path, attr.value);
            } else if (std.mem.eql(u8, k, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, k, "height")) {
                if (parseNum(attr.value)) |v| {
                    if (v > 32) self.height = v;
                }
            } else if (std.mem.eql(u8, k, "zoom")) {
                if (parseNum(attr.value)) |v| {
                    self.desc.view.zoom = std.math.clamp(v, ZOOM_MIN, ZOOM_MAX);
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
        for (self.desc.nodes.items) |n| {
            try w.print("pos id={s} x={d:.2} y={d:.2}\n", .{ n.id, n.pos[0], n.pos[1] });
        }
        try state.set(self.positions_path, buf.items);
    }

    /// **The edit channel: what the canvas ASKS the host to do.**
    ///
    /// The canvas does not apply a structural edit to itself. It moves a
    /// node itself — nothing else can compute where a node goes — but
    /// whether two pins may be joined is a question about the host's
    /// language, so the wire is a REQUEST and the host answers with a
    /// whole new graph. A refusal is therefore not a protocol: it is the
    /// graph you already had, arriving again. There is no divergence to
    /// reconcile because the canvas never diverged.
    ///
    /// **Every record is an assignment, never a toggle**, and that is
    /// what makes the channel safe to re-deliver. `link` SETS an input's
    /// source, replacing whatever was there; `unlink` CLEARS one. Apply
    /// either twice and you have applied it once. A host that re-reads
    /// this path on every notification — which is what `State.set`
    /// subscribers do — cannot double-apply an edit, so the channel
    /// needs no sequence number and no acknowledgement.
    ///
    ///     link from=near1.out to=mul3.a
    ///     unlink to=mul3.a
    ///
    /// A gesture may write both: rehoming a wire clears where it was and
    /// sets where it went, and the two name different inputs so their
    /// order does not matter either.
    ///
    /// The kinds this channel will grow, named here so the grammar is
    /// designed rather than accreted — `add op= x= y=` when the palette
    /// lands, `drop id=` when deletion does. Both are assignments too.
    fn writeEdits(self: *Component, state: *state_mod.State, text: []const u8) !void {
        if (self.edits_path.len == 0 or text.len == 0) return;
        try state.set(self.edits_path, text);
    }

    /// Where a wire in hand ends up, and what that asks the host for.
    ///
    /// Four outcomes, and each is a deliberate answer to "what did the
    /// reader mean":
    ///
    ///   * **on a reachable pin** — join them. If the wire was lifted
    ///     off another input, that input is cleared in the same write.
    ///   * **on a node's body** — the nearest pin on it that would take
    ///     the wire (`nearestReachable`). A four-unit dot is not a
    ///     target at 0.4 zoom.
    ///   * **over nothing, carrying a lifted wire** — disconnect. That
    ///     is what picking it up was FOR, and it is why `detached` is
    ///     remembered rather than the drag simply re-anchoring.
    ///   * **over nothing, carrying a new wire** — nothing at all. No
    ///     record is written, so a host subscribed to this path is not
    ///     woken to be told the reader changed their mind.
    ///
    /// Dropped back onto the input it came from is the fourth case by
    /// arithmetic rather than by a branch: the clear and the set name
    /// the same input, so `unlink` is suppressed and `link` restores
    /// exactly what was there. Cancel needs no key, which is why this
    /// component still takes no keyboard focus.
    fn releaseWire(self: *Component, state: *state_mod.State, w: anytype) !void {
        const pr = Probe{ .anchor = w.anchor, .blocked = self.cycle_block.items };
        const landed: ?u32 = switch (w.over) {
            .pin => |i| if (self.desc.reachOf(pr, i) != .none) i else null,
            .node => |n| self.desc.nearestReachable(pr, n, w.cursor),
            .none => null,
        };

        const lifted_from: ?u32 = if (w.detached) |li| self.desc.links.items[li].to else null;
        if (landed == null and lifted_from == null) return;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const out = buf.writer();

        if (lifted_from) |old_in| {
            if (landed == null or landed.? != old_in) {
                try out.writeAll("unlink to=");
                try self.desc.writeRef(out, old_in);
                try out.writeByte('\n');
            }
        }
        if (landed) |target| {
            // Whichever end was grabbed, the record is written
            // source-to-sink. A host reading `from=` should never have
            // to ask which way the reader happened to drag.
            const anchor_out = self.desc.pins.items[w.anchor].dir == .out;
            const src = if (anchor_out) w.anchor else target;
            const dst = if (anchor_out) target else w.anchor;
            try out.writeAll("link from=");
            try self.desc.writeRef(out, src);
            try out.writeAll(" to=");
            try self.desc.writeRef(out, dst);
            try out.writeByte('\n');
        }
        try self.writeEdits(state, buf.items);
    }

    fn writeSelection(self: *Component, state: *state_mod.State) !void {
        if (self.selected_path.len == 0) return;
        const id: []const u8 = if (self.selected) |i| self.desc.nodes.items[i].id else "";
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

    // Each owned string gets its own errdefer BEFORE it lands in the
    // struct. Duping them inline in the initialiser reads better and
    // leaks the earlier ones when a later one fails.
    const positions = try allocator.dupe(u8, "");
    errdefer allocator.free(positions);
    const selected = try allocator.dupe(u8, "");
    errdefer allocator.free(selected);
    const edits = try allocator.dupe(u8, "");
    errdefer allocator.free(edits);
    const last_selected = try allocator.dupe(u8, "");
    errdefer allocator.free(last_selected);

    // The description is built INSIDE the assignment, deliberately.
    // Building it a line earlier needs an `errdefer desc.deinit()` that
    // is still armed after `c.desc` holds the same arena and the same
    // three lists — and an `ingest` failure then runs both and frees it
    // twice. There is no window here: one owner from the moment it
    // exists, and the errdefer below is that owner's.
    c.* = .{
        .allocator = allocator,
        .desc = try Description.init(allocator),
        .cycle_block = std.ArrayList(bool).init(allocator),
        .positions_path = positions,
        .selected_path = selected,
        .edits_path = edits,
        .last_selected_written = last_selected,
    };
    errdefer c.desc.deinit();
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.desc.deinit();
    allocator.free(c.positions_path);
    c.cycle_block.deinit();
    allocator.free(c.selected_path);
    allocator.free(c.edits_path);
    allocator.free(c.last_selected_written);
    if (c.pending) |p| allocator.free(p);
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
    .context_subject = contextSubject,
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

/// The colour of a node's title bar. See `NODE_HEADER_TINT`.
fn headerColor(n: Node) [4]f32 {
    return if (n.ring != null) n.tint else tinted(n.tint, NODE_HEADER_TINT);
}

/// Text that can be read on `bg`: the caller's own colour, unless the
/// bar is light enough to swallow it.
///
/// Rec. 709 luminance, which weights green six times red's and ten times
/// blue's — the reason a full green or yellow bar needs dark letters and
/// a full royal blue one does not, even though all three are "saturated".
fn labelOn(bg: [4]f32, light: [4]f32) [4]f32 {
    const l = 0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2];
    return if (l > LABEL_DARK_ABOVE) NODE_LABEL_DARK else light;
}

fn tinted(c: [4]f32, f: f32) [4]f32 {
    return .{ c[0] * f, c[1] * f, c[2] * f, c[3] };
}

/// A pin that cannot take the wire in hand. Fades the ALPHA and leaves
/// the hue, so a dimmed in-pin still reads as an in-pin — the graph goes
/// quiet, it does not go grey.
fn dimmed(c: [4]f32) [4]f32 {
    return .{ c[0], c[1], c[2], c[3] * PIN_DIM };
}

/// The wire between the anchor and the cursor, coloured by what the
/// cursor is over.
///
/// The colour is the answer BEFORE the button comes up, which is the
/// half of Blade3D's model that made it feel like an editor: teal while
/// it is over nothing, and the target's own green or amber the moment it
/// is over something that would take it. You never have to release to
/// find out.
fn drawWireInHand(
    c: *Component,
    canvas: Rect,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
    origin: [2]f32,
    w: @TypeOf(@as(Grab, undefined).wire),
) !void {
    const anchor_dir = c.desc.pins.items[w.anchor].dir;
    const pr = Probe{ .anchor = w.anchor, .blocked = c.cycle_block.items };
    const landed: ?u32 = switch (w.over) {
        .pin => |i| if (c.desc.reachOf(pr, i) != .none) i else null,
        .node => |n| c.desc.nearestReachable(pr, n, w.cursor),
        .none => null,
    };

    // Snapping the drawn end onto the pin it would land on is not
    // decoration: with body-drop the pin taking the wire is often not
    // the one under the cursor, and a wire drawn to the cursor would
    // not say which.
    const far_g = if (landed) |i| c.desc.pinCentre(i) else w.cursor;
    const col: [4]f32 = if (landed) |i| switch (c.desc.reachOf(pr, i)) {
        .coerce => PIN_REACH_COERCE,
        else => PIN_REACH_EXACT,
    } else WIRE_LOOSE;

    const g_anchor = c.desc.pinCentre(w.anchor);
    // The far end's direction is the anchor's opposite, so the curve
    // leaves and arrives the way a finished one would and the wire does
    // not change shape at the instant it lands.
    const far_dir: Dir = if (anchor_dir == .out) .in else .out;
    var scratch: WireScratch = .{};
    try strokeWire(lc, out, &scratch, canvas, c.desc.view.zoom, .{
        .p0 = c.desc.view.toScreen(origin, g_anchor),
        .p1 = c.desc.view.toScreen(origin, far_g),
        .from_dir = anchor_dir,
        .to_dir = far_dir,
        .color = col,
    });
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

/// The two control points of a wire's cubic, in screen space.
///
/// Tangents follow the PIN's direction rather than the wire's, so a
/// description that wires an output to an output still draws a curve
/// that reads, instead of a knot.
///
/// Its own function so a gate can ask what a wire's curve IS without
/// re-deriving the clamp — a second copy of this arithmetic is a second
/// answer able to drift from the one on screen.
fn wireControls(p0: [2]f32, p1: [2]f32, from_dir: Dir, to_dir: Dir, z: f32) [2][2]f32 {
    const gap = @abs(p1[0] - p0[0]);
    const k = std.math.clamp(gap * LINK_TANGENT_FRAC, LINK_TANGENT_MIN * z, LINK_TANGENT_MAX * z);
    return .{
        .{ p0[0] + (if (from_dir == .out) k else -k), p0[1] },
        .{ p1[0] + (if (to_dir == .out) k else -k), p1[1] },
    };
}

/// One wire, from screen point to screen point, curved and clipped and
/// stroked.
///
/// It is a function rather than two copies because the wire IN HAND and
/// a finished one have to agree about the curve. They did not, in the
/// first draft: the preview used a straight tangent and the wire visibly
/// changed shape at the instant it landed, which reads as the editor
/// deciding something rather than the reader.
fn strokeWire(
    lc: *element.LayoutCtx,
    out: *element.DrawList,
    scratch: *WireScratch,
    canvas: Rect,
    z: f32,
    w: struct {
        p0: [2]f32,
        p1: [2]f32,
        from_dir: Dir,
        to_dir: Dir,
        color: [4]f32,
    },
) !void {
    // Cheap reject: a wire whose control hull cannot touch the canvas
    // costs one rect test instead of twenty-four strokes.
    const pad = LINK_TANGENT_MAX * z + LINK_W;
    if (@max(w.p0[0], w.p1[0]) < canvas.x - pad or @min(w.p0[0], w.p1[0]) > canvas.x + canvas.w + pad) return;
    if (@max(w.p0[1], w.p1[1]) < canvas.y - pad or @min(w.p0[1], w.p1[1]) > canvas.y + canvas.h + pad) return;

    const cs = wireControls(w.p0, w.p1, w.from_dir, w.to_dir, z);
    const c0 = cs[0];
    const c1 = cs[1];

    const pts = flattenCubic(&scratch.pts, w.p0, c0, c1, w.p1, LINK_FLATNESS);
    // One ribbon per visible run, and no joint paid for twice — see
    // `relief.polyline`, which is where the beads down every wire came
    // from and went.
    var runs = RunIter{ .pts = pts, .r = canvas, .buf = &scratch.run };
    while (runs.next()) |run| {
        try relief.polyline(out, lc, run, LINK_W, w.color);
    }
}

/// The two buffers one wire is flattened and clipped through, held by
/// the caller so a canvas full of wires allocates none of it per wire.
const WireScratch = struct {
    pts: [LINK_MAX_PTS][2]f32 = undefined,
    run: [LINK_MAX_PTS][2]f32 = undefined,
};

fn drawCanvas(
    c: *Component,
    canvas: Rect,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) !void {
    const origin = [2]f32{ canvas.x, canvas.y };
    const z = c.desc.view.zoom;

    // ── Ground and grid: TRIANGLES ─────────────────────────────────
    // A quad ground would be drawn on top of every wire, because the
    // renderer puts the whole quad layer over the whole triangle layer
    // regardless of who emitted what first. Same shape as the
    // trackball's recessed dial; same fix.
    try relief.rect(out, lc, canvas.x, canvas.y, canvas.w, canvas.h, CANVAS_BG);
    try drawGrid(c, canvas, lc, out);

    // ── Links: TRIANGLES, over the ground, under everything else ───
    //
    // A link lifted off an input is IN HAND and is not drawn where it
    // used to be. Leaving it there would draw two wires from one source
    // while the reader holds one of them, and the picture would say the
    // disconnect had not happened until the button came up — which is
    // the opposite of what dragging a wire off a pin is supposed to
    // look like.
    const held_link: ?u32 = switch (c.grab) {
        .wire => |w| w.detached,
        else => null,
    };
    var scratch: WireScratch = .{};
    for (c.desc.links.items, 0..) |l, li| {
        if (held_link) |h| if (h == li) continue;
        const g0 = c.desc.pinCentre(l.from);
        const g1 = c.desc.pinCentre(l.to);
        const from_dir = c.desc.pins.items[l.from].dir;
        const to_dir = c.desc.pins.items[l.to].dir;

        const p0 = c.desc.view.toScreen(origin, g0);
        const p1 = c.desc.view.toScreen(origin, g1);

        try strokeWire(lc, out, &scratch, canvas, z, .{
            .p0 = p0,
            .p1 = p1,
            .from_dir = from_dir,
            .to_dir = to_dir,
            .color = l.tint,
        });
    }

    // ── Nodes: QUADS, which puts them over every wire for free ─────
    for (c.desc.nodes.items, 0..) |n, i| {
        const tl = c.desc.view.toScreen(origin, n.pos);
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
            .pin => |hp| c.desc.pins.items[hp].node == i,
            .none => false,
        };
        const is_sel = c.selected != null and c.selected.? == i;
        const ring: [4]f32 = if (is_sel) NODE_RING_SELECTED else if (lit) NODE_RING_HOVER else n.ring orelse NODE_RING;
        const ring_pad = RING_PAD * z;

        // A taper is the shader's, not geometry's: the quad layer draws
        // over the triangle layer no matter who emitted what first, so a
        // diagonal made of triangles would sink under every wire on the
        // canvas. `quad.frag` takes the nose as a distance and the
        // anti-aliasing it already does covers it.
        const nose = if (n.bare and n.out_count > 0) NOSE_W * z else 0;
        // The ring is the same shape grown by `ring_pad`, so its taper
        // has to grow with its height or the two edges are not parallel
        // and the outline reads as a wedge.
        const ring_nose = if (nose > 0) nose * (sh + 2 * ring_pad) / sh else 0;

        // **A tapered node has SQUARE left corners**, which costs nothing
        // to say because the taper has already cut the right pair off —
        // `radius` only ever reaches the left two on one of these. Chris,
        // 2026-09-12: *"can we make the left hand edge not have rounded
        // corners — it's the last thing to match EDA tools."* A part on a
        // schematic is a rectangle with a pin on it; the rounding was the
        // one thing still saying "panel".
        const corner = if (nose > 0) 0 else r;

        try out.appendQuad(lc, .{
            .dst_pos = .{ tl[0] - ring_pad, tl[1] - ring_pad },
            .dst_size = .{ sw + 2 * ring_pad, sh + 2 * ring_pad },
            .color = ring,
            .radius = if (nose > 0) 0 else r + ring_pad,
            .nose = ring_nose,
        });
        // No body under a bare node — the header quad below is the whole
        // of it, and it already covers the same rectangle.
        if (!n.bare) try out.appendQuad(lc, .{
            .dst_pos = .{ tl[0], tl[1] },
            .dst_size = .{ sw, sh },
            .color = NODE_BG,
            .radius = r,
        });
        try out.appendQuad(lc, .{
            .dst_pos = .{ tl[0], tl[1] },
            .dst_size = .{ sw, @min(HEADER_H * z, sh) },
            .color = headerColor(n),
            .radius = corner,
            .nose = nose,
        });
    }

    // ── Pins: QUADS with a radius, so they are anti-aliased discs ──
    //
    // With a wire in hand every pin answers the same question — *can
    // this land on you* — and the graph goes quiet so the ones that can
    // are the only thing left lit. That sweep is Blade3D's
    // `CollectInputPorts`, which walked every port in the graph at
    // mouse-down and set `Flash` on the ones that matched. Here it is
    // recomputed rather than cached: it is O(pins × accepts) with both
    // small, and a cache would have to be invalidated by every path
    // that can change the graph mid-gesture. Trigger for caching it into
    // the grab: a graph where this shows up in a frame time.
    const wire: ?@TypeOf(c.grab.wire) = switch (c.grab) {
        .wire => |w| w,
        else => null,
    };
    const pr = c.probe();
    for (c.desc.pins.items, 0..) |p, i| {
        const reach: Reach = if (pr) |q| c.desc.reachOf(q, @intCast(i)) else .none;
        const r = (if (wire != null and reach != .none) PIN_REACH_R else PIN_R) * z;
        const sc = c.desc.view.toScreen(origin, c.desc.pinCentre(@intCast(i)));
        if (sc[0] + r < canvas.x or sc[0] - r > canvas.x + canvas.w) continue;
        if (sc[1] + r < canvas.y or sc[1] - r > canvas.y + canvas.h) continue;
        const hot = switch (c.hovered) {
            .pin => |hp| hp == i,
            else => false,
        };
        var col: [4]f32 = if (hot) PIN_HOVER_COLOR else if (p.dir == .in) PIN_IN_COLOR else PIN_OUT_COLOR;
        if (wire) |w| {
            col = switch (reach) {
                .exact => PIN_REACH_EXACT,
                .coerce => PIN_REACH_COERCE,
                // The anchor itself is unreachable by rule 2 and must
                // still be visible: it is the end you are holding.
                .none => if (i == w.anchor) col else dimmed(col),
            };
        }
        try out.appendQuad(lc, .{
            .dst_pos = .{ sc[0] - r, sc[1] - r },
            .dst_size = .{ 2 * r, 2 * r },
            .color = col,
            .radius = r,
        });
    }

    // ── The wire in hand ───────────────────────────────────────────
    //
    // Drawn LAST and as a quad-layer stroke would sink under the nodes,
    // so it is `relief.stroke` like every other wire — which puts it in
    // the triangle layer, UNDER the node bodies. That is the right
    // place: a wire dragged across a node should pass behind it, exactly
    // as a connected one does, or the picture says the wire is on top of
    // something it is not attached to.
    //
    // It is emitted after the node loop only because the triangle layer
    // does not care; the order here is for a reader, not the renderer.
    if (wire) |w| try drawWireInHand(c, canvas, lc, out, origin, w);

    // ── Labels: GLYPHS, over everything ────────────────────────────
    if (z >= LABEL_MIN_ZOOM) try drawLabels(c, canvas, lc, out);

    if (c.desc.bad_lines > 0) try drawErrorStrip(c, canvas, lc, out);
}

/// **What is under this point, in the words the host uses.**
///
/// The `context_subject` hook: a right-click asks, spark carries the
/// answer to the host, and the host decides what a menu for it holds.
/// Three answers, exactly the three `pick` can give, and the third has
/// a twist in it:
///
///     node:near1
///     pin:near1.i0
///     canvas@120.50,88.00
///
/// No `link:` answer, because `pick` has no link arm — a wire is a
/// stroke in the triangle layer with no hit box, and giving it one is
/// the beat that also wants "delete this wire" and a hover highlight on
/// it. Recorded, not built.
///
/// **The canvas answer carries the GRAPH POINT.** A menu that creates a
/// node has to put it where the reader clicked, and the reader clicked
/// in graph space — which only this component can compute, because only
/// this component holds the camera. The alternative is the host doing
/// the transform, which means the host holding a copy of `pan` and
/// `zoom` and getting it wrong by a frame whenever the two disagree.
/// Putting it in the subject costs nothing: the subject is opaque to
/// spark, so a component may say whatever its host understands, and
/// this component's host is the one that wrote both halves.
///
/// Two decimal places, and the separator is `@` rather than `:` so a
/// host can split the KIND off every subject with one rule.
///
/// The buffer is the component's own and is overwritten by the next
/// call — same lifetime rule as the rest of this vtable, and the
/// dispatcher copies what it needs into the state record immediately.
fn contextSubject(ctx: *anyopaque, local: [2]f32) ?[]const u8 {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const g = c.desc.view.toGraph(local);
    return switch (c.desc.pick(g)) {
        .node => |i| std.fmt.bufPrint(
            &c.subject_buf,
            "node:{s}",
            .{c.desc.nodes.items[i].id},
        ) catch null,
        .pin => |i| blk: {
            const p = c.desc.pins.items[i];
            break :blk std.fmt.bufPrint(
                &c.subject_buf,
                "pin:{s}.{s}",
                .{ c.desc.nodes.items[p.node].id, p.id },
            ) catch null;
        },
        .none => std.fmt.bufPrint(
            &c.subject_buf,
            "canvas@{d:.2},{d:.2}",
            .{ g[0], g[1] },
        ) catch null,
    };
}

/// A dot-free line grid, in the triangle layer with the ground.
///
/// It exists because a canvas with nothing but nodes on it gives a pan
/// no feedback at all — dragging empty space looks identical to not
/// dragging it. Below `GRID_MIN_PX` between lines it is dropped, which
/// is both a look and the reason a zoomed-out fifty-node graph does not
/// pay for two hundred rules.
fn drawGrid(c: *Component, canvas: Rect, lc: *element.LayoutCtx, out: *element.DrawList) !void {
    const step_px = GRID_STEP * c.desc.view.zoom;
    if (step_px < GRID_MIN_PX) return;

    const g0 = c.desc.view.toGraph(.{ 0, 0 });
    const g1 = c.desc.view.toGraph(.{ canvas.w, canvas.h });

    var ix: i32 = @intFromFloat(@floor(g0[0] / GRID_STEP));
    const ix_end: i32 = @intFromFloat(@ceil(g1[0] / GRID_STEP));
    while (ix <= ix_end) : (ix += 1) {
        const gx = @as(f32, @floatFromInt(ix)) * GRID_STEP;
        const sx = canvas.x + (gx - c.desc.view.pan[0]) * c.desc.view.zoom;
        if (sx < canvas.x or sx > canvas.x + canvas.w) continue;
        const major = @rem(ix, @as(i32, @intCast(GRID_MAJOR))) == 0;
        try relief.rect(out, lc, sx, canvas.y, 1, canvas.h, if (major) GRID_COLOR_MAJOR else GRID_COLOR);
    }

    var iy: i32 = @intFromFloat(@floor(g0[1] / GRID_STEP));
    const iy_end: i32 = @intFromFloat(@ceil(g1[1] / GRID_STEP));
    while (iy <= iy_end) : (iy += 1) {
        const gy = @as(f32, @floatFromInt(iy)) * GRID_STEP;
        const sy = canvas.y + (gy - c.desc.view.pan[1]) * c.desc.view.zoom;
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
    const z = c.desc.view.zoom;
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);

    for (c.desc.nodes.items) |n| {
        const tl = c.desc.view.toScreen(origin, n.pos);
        const sw = n.size[0] * z;
        if (tl[0] + sw < canvas.x or tl[0] > canvas.x + canvas.w) continue;
        if (tl[1] + HEADER_H * z < canvas.y or tl[1] > canvas.y + canvas.h) continue;
        const baseline = centredBaseline(m, tl[1] + HEADER_H * z * 0.5, z);
        const ink = labelOn(headerColor(n), style.color);
        _ = try appendLabel(lc, out, n.label, style.font_id, ink, tl[0] + LABEL_PAD_X * z, baseline, z, .left);
    }

    for (c.desc.pins.items, 0..) |p, i| {
        if (p.label.len == 0) continue;
        const sc = c.desc.view.toScreen(origin, c.desc.pinCentre(@intCast(i)));
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
    const msg = std.fmt.bufPrint(&buf, "{d} unreadable line(s) in the graph description", .{c.desc.bad_lines}) catch return;
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
                c.grab = .{ .pan = .{ .press_local = mev.local, .start_pan = c.desc.view.pan } };
                return;
            }
            if (mev.button != 0) return;

            // `local` is canvas-local screen pixels; the graph is one
            // `toGraph` away and the canvas origin never enters. This is
            // THE boundary — everything below is graph space.
            const g = c.desc.view.toGraph(mev.local);
            const hit = c.desc.pick(g);
            switch (hit) {
                .node => |i| {
                    c.grab = .{ .node = .{
                        .index = i,
                        .press_local = mev.local,
                        .start_pos = c.desc.nodes.items[i].pos,
                        .moved = false,
                    } };
                    c.selected = i;
                    c.hovered = hit;
                },
                .pin => |i| {
                    // A press on a pin takes a wire in hand. It must not
                    // fall through to a pan, which would slide the whole
                    // canvas out from under a deliberate aim — and it
                    // latches, so the write below runs behind the same
                    // closed `ingest` every other press does.
                    //
                    // Pressing an INPUT that already has a wire picks
                    // that wire up rather than starting a second one,
                    // because an input holds exactly one source and a
                    // second would have to evict the first anyway. What
                    // you get in hand is the far end.
                    const held = c.desc.linkInto(i);
                    const anchor = if (held) |li| c.desc.links.items[li].from else i;
                    // Once, here — not per pin and not per frame. The
                    // graph cannot change while a gesture is latched
                    // (`ingest` is closed), so the answer cannot go stale
                    // between this press and its release.
                    try c.desc.blockCycles(&c.cycle_block, anchor);
                    c.grab = .{ .wire = .{
                        .anchor = anchor,
                        .detached = held,
                        .cursor = g,
                        .over = hit,
                    } };
                    c.selected = c.desc.pins.items[i].node;
                    c.hovered = hit;
                },
                .none => {
                    c.selected = null;
                    c.grab = .{ .pan = .{ .press_local = mev.local, .start_pan = c.desc.view.pan } };
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
                .none => {},
                .wire => |*w| {
                    w.cursor = c.desc.view.toGraph(mev.local);
                    w.over = c.desc.pick(w.cursor);
                    c.version +%= 1;
                },
                .pan => |p| {
                    // Drag right, content goes right, so the camera goes
                    // left. In graph units, because a pan measured in
                    // screen pixels drifts under the cursor at any zoom
                    // but 1.
                    c.desc.view.pan = .{
                        p.start_pan[0] - (mev.local[0] - p.press_local[0]) / c.desc.view.zoom,
                        p.start_pan[1] - (mev.local[1] - p.press_local[1]) / c.desc.view.zoom,
                    };
                    c.version +%= 1;
                },
                .node => |*d| {
                    const dx = (mev.local[0] - d.press_local[0]) / c.desc.view.zoom;
                    const dy = (mev.local[1] - d.press_local[1]) / c.desc.view.zoom;
                    c.desc.nodes.items[d.index].pos = .{ d.start_pos[0] + dx, d.start_pos[1] + dy };
                    if (dx != 0 or dy != 0) d.moved = true;
                    c.version +%= 1;
                    // NO write here. A drag is one gesture and gets one
                    // `State.set`, at the end — see `writePositions`.
                },
            }
        },
        .mouse_up => |mev| {
            // Where the button came up is the truth about where the wire
            // landed. The last `mouse_move` is USUALLY the same point
            // and is not guaranteed to be: a host that coalesces motion,
            // a tablet that reports a press-and-lift with no move
            // between them, or a release delivered after the pointer
            // left the canvas all give a stale `over`. Re-picking here
            // costs one hit test per gesture.
            if (c.grab == .wire) {
                c.grab.wire.cursor = c.desc.view.toGraph(mev.local);
                c.grab.wire.over = c.desc.pick(c.grab.wire.cursor);
            }
            const was = c.grab;
            // Both of these run with the latch STILL SET, so the
            // synchronous subscriber storm a `State.set` kicks off finds
            // `ingest` closed and cannot re-parse the graph out from
            // under the hand that just moved it.
            switch (was) {
                .node => |d| if (d.moved) try c.writePositions(state),
                .wire => |w| try c.releaseWire(state, w),
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
        .enter, .move => c.desc.pick(c.desc.view.toGraph(event.local)),
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
    const before = c.desc.view.zoom;
    const factor = @exp(-event.dy * ZOOM_PER_PX);
    const next = std.math.clamp(before * factor, ZOOM_MIN, ZOOM_MAX);
    if (next == before) return false;
    c.desc.view.zoomAbout(event.local, next);
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
    try testing.expectEqual(@as(usize, 2), c.desc.nodes.items.len);
    try testing.expectEqual(@as(usize, 4), c.desc.pins.items.len);
    try testing.expectEqual(@as(usize, 1), c.desc.links.items.len);
    try testing.expectEqual(@as(u32, 0), c.desc.bad_lines);
    try testing.expectEqualStrings("Multiply", c.desc.nodes.items[1].label);
    // The link resolved to real pin indices, not to strings.
    try testing.expectEqual(Dir.out, c.desc.pins.items[c.desc.links.items[0].from].dir);
    try testing.expectEqual(Dir.in, c.desc.pins.items[c.desc.links.items[0].to].dir);
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
    try testing.expectEqual(@as(usize, 1), c.desc.links.items.len);
    try testing.expectEqual(@as(u32, 0), c.desc.bad_lines);
}

test "nodegraph: a ref splits on the LAST dot, so a node id may contain dots" {
    const c = try makeGraph(
        \\node id=math.mul x=0 y=0
        \\pin node=math.mul id=out dir=out
        \\link from=math.mul.out to=math.mul.out
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 1), c.desc.links.items.len);
    try testing.expectEqual(@as(u32, 0), c.desc.bad_lines);
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
    try testing.expectEqual(@as(usize, 1), c.desc.nodes.items.len);
    try testing.expectEqual(@as(u32, 2), c.desc.bad_lines);
}

test "nodegraph: a quoted label keeps its spaces" {
    const c = try makeGraph("node id=a x=0 y=0 label=\"Two Words\" tint=#ff0000", &.{});
    defer dropGraph(c);
    try testing.expectEqualStrings("Two Words", c.desc.nodes.items[0].label);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.desc.nodes.items[0].tint[0], 1e-3);
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
    try testing.expect(c.desc.nodes.items[1].size[1] > c.desc.nodes.items[0].size[1]);
    // And an explicit `h=` is left alone.
    const d = try makeGraph("node id=a x=0 y=0 h=300", &.{});
    defer dropGraph(d);
    try testing.expectApproxEqAbs(@as(f32, 300), d.desc.nodes.items[0].size[1], 1e-3);
}

// ── The public door ────────────────────────────────────────────────

/// A payload in the shape a HOST emits, rather than the shape an author
/// writes by hand. matryoshka's generator projects a parsed rill program
/// into this, and every awkward rule of the grammar is in here on
/// purpose: node ids carrying dots AND colons (`read:row.seed`), so a
/// `link` ref has to split on the last dot and not the first; labels
/// with spaces, which have to be quoted or they truncate; a `view`
/// record; a tint per node.
const host_payload =
    \\view pan=-24,-24 zoom=0.6
    \\node id=read:row.seed x=0 y=0 label="row.seed" tint=#3d5a6e
    \\node id=near1 x=230 y=0 label="near1" tint=#8a5cf0
    \\node id=mul1 x=460 y=0 label="mul1 (k = 0.5)" tint=#4c8fbf
    \\pin node=read:row.seed id=o0 dir=out label="seed"
    \\pin node=near1 id=i0 dir=in label="radius"
    \\pin node=near1 id=o0 dir=out label="count"
    \\pin node=mul1 id=i0 dir=in label="a"
    \\pin node=mul1 id=i1 dir=in label="b"
    \\pin node=mul1 id=o0 dir=out label="v"
    \\link from=read:row.seed.o0 to=near1.i0
    \\link from=near1.o0 to=mul1.i0
;

/// Every field of a description, compared. A count-only comparison is
/// the shape of gate that lets a divergence through: two parsers can
/// agree on how MANY nodes there are and disagree about where they sit.
fn expectSameDescription(a: *const Description, b: *const Description) !void {
    try testing.expectEqual(a.bad_lines, b.bad_lines);
    try testing.expectApproxEqAbs(a.view.zoom, b.view.zoom, 1e-6);
    try testing.expectApproxEqAbs(a.view.pan[0], b.view.pan[0], 1e-6);
    try testing.expectApproxEqAbs(a.view.pan[1], b.view.pan[1], 1e-6);

    try testing.expectEqual(a.nodes.items.len, b.nodes.items.len);
    for (a.nodes.items, b.nodes.items) |x, y| {
        try testing.expectEqualStrings(x.id, y.id);
        try testing.expectEqualStrings(x.label, y.label);
        try testing.expectEqualSlices(f32, &x.pos, &y.pos);
        try testing.expectEqualSlices(f32, &x.size, &y.size);
        try testing.expectEqualSlices(f32, &x.tint, &y.tint);
        try testing.expectEqual(x.in_count, y.in_count);
        try testing.expectEqual(x.out_count, y.out_count);
    }

    try testing.expectEqual(a.pins.items.len, b.pins.items.len);
    for (a.pins.items, b.pins.items) |x, y| {
        try testing.expectEqual(x.node, y.node);
        try testing.expectEqualStrings(x.id, y.id);
        try testing.expectEqualStrings(x.label, y.label);
        try testing.expectEqual(x.dir, y.dir);
        try testing.expectEqual(x.slot, y.slot);
    }

    try testing.expectEqual(a.links.items.len, b.links.items.len);
    for (a.links.items, b.links.items) |x, y| {
        try testing.expectEqual(x.from, y.from);
        try testing.expectEqual(x.to, y.to);
    }
}

test "nodegraph: readDescription and the component read the same text the same way" {
    // The point of the split, executed. There is one parser and two
    // callers, and this is what "one" means: every field, not a count.
    //
    // Mutation — give the component its own copy of one rule, which is
    // exactly the drift a second parser in the host repo would be. In
    // `Component.parse`, after the read:
    //
    //     for (self.desc.nodes.items) |*n| if (!n.w_given) n.size[0] = 200;
    //
    // A single-caller gate cannot see that: every existing test in this
    // file goes through the component and would agree with itself. Here
    // it is red on the first node's size.
    const c = try makeGraph(host_payload, &.{});
    defer dropGraph(c);

    var d = try readDescription(testing.allocator, host_payload);
    defer d.deinit();

    try expectSameDescription(&c.desc, &d);

    // Rule 1: assert the CONTENT before believing the agreement — two
    // empty descriptions agree perfectly.
    try testing.expectEqual(@as(usize, 3), d.nodes.items.len);
    try testing.expectEqual(@as(usize, 6), d.pins.items.len);
    try testing.expectEqual(@as(usize, 2), d.links.items.len);
    try testing.expectEqual(@as(u32, 0), d.bad_lines);
    // The last-dot rule survived the trip: the first link starts at the
    // node whose id has two dots and a colon in it.
    try testing.expectEqualStrings("read:row.seed", d.nodes.items[d.pins.items[d.links.items[0].from].node].id);
    try testing.expectEqualStrings("mul1 (k = 0.5)", d.nodes.items[2].label);
}

test "nodegraph: readDescription counts the lines nobody can read, and never refuses" {
    // `bad_lines` surviving the split is not a detail: it is how a host
    // finds out that what it emitted was not read. A door that returned
    // an error on the first bad line would be a different contract from
    // the component's — the component draws a strip and keeps going —
    // and a host would then get a picture and a gate that disagree.
    //
    // Mutation: `if (d.bad_lines > 0) return error.BadDescription;` in
    // `readDescription`. Red — and the disagreement is the point, not
    // the error.
    const src =
        \\node id=a x=0 y=0
        \\nodes id=b x=0 y=0
        \\node x=10 y=10 label="no id at all"
        \\pin node=nowhere id=p dir=in
        \\link from=a.missing to=a.missing
        \\pos id=ghost x=1 y=1
    ;
    var d = try readDescription(testing.allocator, src);
    defer d.deinit();

    // One good node; five records nobody could resolve — an unknown
    // kind, a node with no id, a pin on a node nobody declared, a link
    // whose pin does not exist, and a `pos` for a ghost.
    try testing.expectEqual(@as(usize, 1), d.nodes.items.len);
    try testing.expectEqual(@as(u32, 5), d.bad_lines);

    // And the component agrees, line for line — the count is one
    // implementation too.
    const c = try makeGraph(src, &.{});
    defer dropGraph(c);
    try expectSameDescription(&c.desc, &d);
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
    c.desc.view = .{ .pan = .{ -100, -50 }, .zoom = 1.6 };

    // The centre of `mul`, taken the long way round: graph → local.
    const n = c.desc.nodes.items[1];
    const centre = [2]f32{ n.pos[0] + n.size[0] * 0.5, n.pos[1] + n.size[1] * 0.5 };
    const local = c.desc.view.toLocal(centre);

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
    const g = c.desc.pinCentre(1);
    try testing.expect(c.desc.pick(.{ g[0] + 2, g[1] }) == .pin);
    // And two pitches down the body, past every pin, is the node.
    const n = c.desc.nodes.items[1];
    try testing.expect(c.desc.pick(.{ n.pos[0] + n.size[0] * 0.5, n.pos[1] + 4 }) == .node);
}

test "nodegraph: the topmost node wins where two overlap" {
    const c = try makeGraph(
        \\node id=under x=0 y=0
        \\node id=over x=20 y=10
    , &.{});
    defer dropGraph(c);
    // Both rects contain this point; `over` is drawn last, so it wins.
    try testing.expectEqual(Hover{ .node = 1 }, c.desc.pick(.{ 40, 20 }));
}

// ── Dragging ───────────────────────────────────────────────────────

test "nodegraph: a press on a pin latches too, so the write is guarded" {
    // Three quarters of a guard is the shape a later beat inherits and
    // cannot see. Mutation: drop the `c.grab = .{ .wire = … };`
    // assignment from the `.pin` arm — red, and `writeSelection` then
    // runs with `ingest` open, which is the window `State.set`'s
    // synchronous notify lands in.
    //
    // It also still asserts what a press on a pin does NOT do. Beat 2
    // gave that press a wire to carry; it must not have quietly given it
    // a node drag or a pan as well.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(two_node_graph, &.{
        .{ .key = "selected", .value = "sel" },
    });
    defer dropGraph(c);

    const g = c.desc.pinCentre(1); // `mul`'s first input
    try onInput(@ptrCast(c), .{ .mouse_down = .{
        .local = c.desc.view.toLocal(g),
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&st));
    try testing.expect(c.grab == .wire);
    try testing.expect(c.gesturing());
    try testing.expectEqualStrings("mul", st.get("sel").?);

    // And it moves nothing, whatever the pointer does next.
    const before = c.desc.nodes.items[1].pos;
    const pan_before = c.desc.view.pan;
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ 900, 900 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&st));
    try testing.expectEqual(before, c.desc.nodes.items[1].pos);
    try testing.expectEqual(pan_before, c.desc.view.pan);

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
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = 2.0 };

    const n0 = c.desc.nodes.items[0];
    const start = n0.pos;
    const press = c.desc.view.toLocal(.{ n0.pos[0] + 10, n0.pos[1] + 6 });

    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&_test_state));
    // 80 screen pixels right, 40 down — 40 and 20 in graph units.
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ press[0] + 80, press[1] + 40 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));

    try testing.expectApproxEqAbs(start[0] + 40, c.desc.nodes.items[0].pos[0], 1e-3);
    try testing.expectApproxEqAbs(start[1] + 20, c.desc.nodes.items[0].pos[1], 1e-3);
}

test "nodegraph: a drag on empty canvas pans, in graph units" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = 0.5 };
    // Far below every node.
    const press = c.desc.view.toLocal(.{ 40, 900 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&_test_state));
    try testing.expect(c.grab == .pan);
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ press[0] + 50, press[1] },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));
    // 50 screen pixels at zoom 0.5 is 100 graph units, and the camera
    // moves the OTHER way so the content follows the hand.
    try testing.expectApproxEqAbs(@as(f32, -100), c.desc.view.pan[0], 1e-3);
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

    const press = c.desc.view.toLocal(.{ 10, 6 });
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
    const press = c.desc.view.toLocal(.{ 10, 6 });
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

    const press = c.desc.view.toLocal(.{ 10, 6 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&st));
    try onInput(@ptrCast(c), .{ .mouse_move = .{
        .local = .{ press[0] + 60, press[1] + 30 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&st));
    const dragged = c.desc.nodes.items[0].pos;
    try testing.expectApproxEqAbs(@as(f32, 60), dragged[0], 1e-3);

    // A whole re-parse lands mid-drag, with the node at its old home.
    const spec = specOf(&.{}, two_node_graph ++ "\npos id=src x=0 y=0");
    try update(@ptrCast(c), &spec);
    try testing.expectApproxEqAbs(dragged[0], c.desc.nodes.items[0].pos[0], 1e-3);
    try testing.expectApproxEqAbs(dragged[1], c.desc.nodes.items[0].pos[1], 1e-3);

    // Between gestures the plane is the truth again, and because the
    // refusal did NOT adopt the digest, the same body lands the moment
    // the button is up and the document is re-delivered.
    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = .{ press[0] + 60, press[1] + 30 }, .button = 0, .button_down = false } }, @ptrCast(&st));
    try update(@ptrCast(c), &spec);
    try testing.expectApproxEqAbs(@as(f32, 0), c.desc.nodes.items[0].pos[0], 1e-3);
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
    c.desc.nodes.items[0].pos = .{ 500, 500 };
    const spec = specOf(&.{}, two_node_graph);
    try update(@ptrCast(c), &spec);
    try testing.expectApproxEqAbs(@as(f32, 500), c.desc.nodes.items[0].pos[0], 1e-3);
}

// ── The host's door ────────────────────────────────────────────────

test "nodegraph: handle_update replaces the graph, and `move` only moves" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    try handleUpdate(@ptrCast(c), "move", "pos id=mul x=1000 y=2000");
    try testing.expectApproxEqAbs(@as(f32, 1000), c.desc.nodes.items[1].pos[0], 1e-3);
    // The labels survived, which is the point of `pos` being its own
    // record kind rather than a `node` line with fields left off.
    try testing.expectEqualStrings("Multiply", c.desc.nodes.items[1].label);

    try handleUpdate(@ptrCast(c), "graph", "node id=only x=5 y=5");
    try testing.expectEqual(@as(usize, 1), c.desc.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), c.desc.links.items.len);

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

    const press = c.desc.view.toLocal(.{ 10, 6 });
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = press, .button = 0, .button_down = true } }, @ptrCast(&st));
    try onInput(@ptrCast(c), .{ .mouse_move = .{ .local = .{ press[0] + 30, press[1] }, .button = 0, .button_down = true } }, @ptrCast(&st));

    try handleUpdate(@ptrCast(c), "graph", "node id=late x=9 y=9");
    try testing.expectEqual(@as(usize, 2), c.desc.nodes.items.len); // still ours

    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = .{ press[0] + 30, press[1] }, .button = 0, .button_down = false } }, @ptrCast(&st));
    try testing.expectEqual(@as(usize, 1), c.desc.nodes.items.len);
    try testing.expectEqualStrings("late", c.desc.nodes.items[0].id);
}

// ── Hover ──────────────────────────────────────────────────────────

test "nodegraph: hover enters and leaves in pairs across node boundaries" {
    // Mutation: make `.leave` fall through to the `.enter` arm and pick
    // at the reported point. Red — the pointer that left the canvas
    // still lights whatever node lies under where it went.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);

    const a = c.desc.nodes.items[0];
    const b = c.desc.nodes.items[1];
    const in_a = c.desc.view.toLocal(.{ a.pos[0] + a.size[0] * 0.5, a.pos[1] + 4 });
    const in_b = c.desc.view.toLocal(.{ b.pos[0] + b.size[0] * 0.5, b.pos[1] + 4 });
    const gap = c.desc.view.toLocal(.{ a.pos[0] + a.size[0] + 30, a.pos[1] + 4 });

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
    const a = c.desc.nodes.items[0];
    const before = c.version;
    try onHover(@ptrCast(c), .{
        .local = c.desc.view.toLocal(.{ a.pos[0] + 10, a.pos[1] + 4 }),
        .phase = .enter,
    }, @ptrCast(&_test_state));
    try testing.expect(c.version != before);
}

// ── The screen actually updating ───────────────────────────────────
//
// The version bump above is half the story and was, for one release,
// the whole of it: the component computed a new picture every move and
// the host never ran a frame to draw it. Christian, using this
// component: *"dragging nodes doesn't update the display until you let
// go of the mouse."* `Spark.takeRedrawRequest` is the seam that fixes
// it and `spark.zig` gates the seam; these two gates are the CUSTOMER's
// side of it — the real component, the real vtable, the real
// dispatcher, no window.

test "nodegraph: a drag through the dispatcher asks for a frame on every move" {
    // Mutation: delete the `defer noteRedraw(sp, hit, before)` in
    // `Spark.dispatchHit`. Five moves, zero frames, red — and the node
    // has still moved, which is exactly what the bug looked like: the
    // graph was right and the screen was a second behind it.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = 1 };

    // Canvas at the world origin, so world coords and `local` coincide
    // and the gate is about the redraw and not about the transform.
    try sp.drawlist.hits.append(.{
        .box = .{ .x = 0, .y = 0, .w = 600, .h = 400 },
        .vtable = &vtable,
        .ctx = @ptrCast(c),
        .state = @ptrCast(&st),
    });

    const start = c.desc.nodes.items[0].pos;
    const press = c.desc.view.toLocal(.{ start[0] + 10, start[1] + 6 });
    try sp.dispatchMouseButtonN(press[0], press[1], true, 0);
    try testing.expect(c.grab == .node);
    _ = sp.takeRedrawRequest(); // the press: not what this gate is about

    var frames: usize = 0;
    for (1..6) |i| {
        const step: f32 = @floatFromInt(i);
        try sp.dispatchMouseMove(press[0] + step * 4, press[1]);
        if (sp.takeRedrawRequest()) frames += 1;
    }
    try testing.expectEqual(@as(usize, 5), frames);
    // The node moved too — otherwise this gate would pass just as well
    // against a dispatcher that raises the flag and delivers nothing.
    try testing.expectApproxEqAbs(start[0] + 20, c.desc.nodes.items[0].pos[0], 1e-3);
}

test "nodegraph: a pointer wandering inside the node it already hovers asks for nothing" {
    // The cost half at the customer. `onHover` bumps the version only
    // when the PICK changes, so twenty moves inside one node are twenty
    // frames nobody needs — and the naive cure (dirty on every move)
    // hands the host exactly those twenty.
    //
    // Mutation: drop the `if (!std.meta.eql(before, c.hovered))` guard in
    // `onHover` and bump unconditionally. Red at 20, and the picture is
    // identical in all twenty.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    sp.drawlist = element.DrawList.init(testing.allocator);
    defer sp.drawlist.deinit();
    sp.host_state = &st;

    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = 1 };
    try sp.drawlist.hits.append(.{
        .box = .{ .x = 0, .y = 0, .w = 600, .h = 400 },
        .vtable = &vtable,
        .ctx = @ptrCast(c),
        .state = @ptrCast(&st),
    });

    // Arriving on the node is a change and costs a frame.
    const n0 = c.desc.nodes.items[0];
    try sp.dispatchHover(n0.pos[0] + 6, n0.pos[1] + 6);
    try testing.expect(sp.takeRedrawRequest());
    try testing.expect(c.hovered == .node);

    // Wandering about inside it is not. The walk stays clear of the
    // pins, which stand proud of the body and ARE a different pick.
    var frames: usize = 0;
    for (0..20) |i| {
        const dx: f32 = 20 + @as(f32, @floatFromInt(i)) * 4;
        try sp.dispatchHover(n0.pos[0] + dx, n0.pos[1] + 8);
        if (sp.takeRedrawRequest()) frames += 1;
    }
    try testing.expectEqual(@as(usize, 0), frames);

    // Leaving for the canvas is a change again — otherwise the ring
    // stays lit on a node the pointer left, which is the bug the
    // enter/leave pairing gate above exists for.
    try sp.dispatchHover(n0.pos[0] + 6, n0.pos[1] + 300);
    try testing.expect(sp.takeRedrawRequest());
}

// ── The wheel ──────────────────────────────────────────────────────

test "nodegraph: the wheel zooms, and gives the notch back at the clamp" {
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    try testing.expect(try onScroll(@ptrCast(c), .{ .local = .{ 100, 100 }, .dy = -120 }, @ptrCast(&_test_state)));
    try testing.expect(c.desc.view.zoom > 1);

    // Pinned at the top, a further notch belongs to the page behind —
    // the `on_scroll` contract read literally. Mutation: `return true`
    // unconditionally, and a graph in the middle of a document becomes a
    // hole you cannot scroll past.
    c.desc.view.zoom = ZOOM_MAX;
    try testing.expect(!try onScroll(@ptrCast(c), .{ .local = .{ 100, 100 }, .dy = -120 }, @ptrCast(&_test_state)));
    c.desc.view.zoom = ZOOM_MIN;
    try testing.expect(!try onScroll(@ptrCast(c), .{ .local = .{ 100, 100 }, .dy = 120 }, @ptrCast(&_test_state)));
}

// ── Link geometry ──────────────────────────────────────────────────

/// Worst distance from a flattened polyline to the cubic it stands for,
/// measured by walking the CURVE densely and asking the polyline. The
/// gates below use it because the claim being made is about the picture
/// — how far the drawn wire is from the real one — and not about how
/// either was built.
fn maxDeviation(pts: []const [2]f32, p0: [2]f32, c0: [2]f32, c1: [2]f32, p1: [2]f32) f32 {
    var worst: f32 = 0;
    for (0..2001) |i| {
        const t = @as(f32, @floatFromInt(i)) / 2000.0;
        const on = cubicAt(p0, c0, c1, p1, t);
        var near: f32 = std.math.floatMax(f32);
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
            near = @min(near, distToSeg(on, a, b));
        }
        worst = @max(worst, near);
    }
    return worst;
}

fn distToSeg(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    const t = if (len2 > 1e-12)
        std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1)
    else
        0;
    const qx = a[0] + t * dx - p[0];
    const qy = a[1] + t * dy - p[1];
    return @sqrt(qx * qx + qy * qy);
}

/// The wire shapes the gates below measure, and what each one is for.
/// Every one of them is a curve `strokeWire` can be asked to draw: the
/// tangents are horizontal because that is what `wireControls` makes,
/// and the clamp to `LINK_TANGENT_MIN` is why a short hop still bulges.
const wire_shapes = [_][4][2]f32{
    // An ordinary wire between two columns of nodes.
    .{ .{ 0, 0 }, .{ 130, 0 }, .{ 70, 140 }, .{ 200, 140 } },
    // A short hop between stacked nodes: a tight bulge on a small chord.
    .{ .{ 0, 0 }, .{ 24, 0 }, .{ -24, 60 }, .{ 0, 60 } },
    // A BACK EDGE — the consumer is left of the producer, so the curve
    // swings out, returns, and swings out again over a 10px chord.
    .{ .{ 0, 0 }, .{ 150, 0 }, .{ -140, 0 }, .{ 10, 0 } },
    // A long back edge across the canvas.
    .{ .{ 0, 0 }, .{ 180, 0 }, .{ -180, 300 }, .{ 20, 300 } },
    // A long, nearly straight run — the cheap case.
    .{ .{ 0, 0 }, .{ 400, 0 }, .{ 500, 20 }, .{ 900, 20 } },
    // A short, nearly straight one.
    .{ .{ 0, 0 }, .{ 24, 0 }, .{ 76, 8 }, .{ 100, 8 } },
};

test "nodegraph: every wire shape is drawn within a pixel tolerance" {
    // The guarantee the adaptive flattener exists to make, checked
    // against the CURVE rather than against how the polyline was built.
    //
    // Mutation: the rule this replaced — segments from the screen chord
    // at 22px each, clamped to [3, 24], sampled uniformly in `t`.
    // Measured, worst deviation per shape above:
    //
    //   shape   chord   adaptive            chord-derived
    //   0        244    29 pts  0.13 px     11 segs  0.90 px
    //   1         60    21 pts  0.12 px      3 segs  4.90 px
    //   2         10    11 pts  0.00 px      3 segs  8.56 px
    //   3        301    49 pts  0.14 px     14 segs  1.69 px
    //   4        900    13 pts  0.13 px     24 segs  0.03 px
    //   5        100     7 pts  0.07 px      5 segs  0.16 px
    //
    // Eight and a half pixels on shape 2 IS the report — Chris,
    // 2026-09-12: *"the wires are a bit janky right now"*. And shape 4
    // is the same rule's other half: twenty-four segments spent to land
    // within a fortieth of a pixel, which nobody has ever seen.
    for (wire_shapes, 0..) |sh, i| {
        var buf: [LINK_MAX_PTS][2]f32 = undefined;
        const pts = flattenCubic(&buf, sh[0], sh[1], sh[2], sh[3], LINK_FLATNESS);
        errdefer std.debug.print("shape {d}\n", .{i});
        try testing.expect(maxDeviation(pts, sh[0], sh[1], sh[2], sh[3]) <= LINK_FLATNESS);
        // The ends are the pins, exactly — a wire that lands near its
        // pin reads as a wire that is not connected.
        try testing.expectApproxEqAbs(sh[0][0], pts[0][0], 1e-4);
        try testing.expectApproxEqAbs(sh[0][1], pts[0][1], 1e-4);
        try testing.expectApproxEqAbs(sh[3][0], pts[pts.len - 1][0], 1e-4);
        try testing.expectApproxEqAbs(sh[3][1], pts[pts.len - 1][1], 1e-4);
    }
}

test "nodegraph: a wire's points follow its CURVATURE, not its length" {
    // The inversion that no chord-derived count can produce, and the
    // reason this is adaptive rather than better-tuned: shape 1 is a
    // 60px hop with a tight bulge and shape 4 is a 900px run that is
    // nearly straight. The short one needs MORE points.
    //
    // Mutation: any count taken from the chord — the old
    // `@round(chord / LINK_PX_PER_SEG)` — which gives 3 and 24. Red by
    // the ordering, not by a tuning constant.
    var tight_buf: [LINK_MAX_PTS][2]f32 = undefined;
    var gentle_buf: [LINK_MAX_PTS][2]f32 = undefined;
    const tight = flattenCubic(&tight_buf, wire_shapes[1][0], wire_shapes[1][1], wire_shapes[1][2], wire_shapes[1][3], LINK_FLATNESS);
    const gentle = flattenCubic(&gentle_buf, wire_shapes[4][0], wire_shapes[4][1], wire_shapes[4][2], wire_shapes[4][3], LINK_FLATNESS);
    try testing.expect(tight.len > gentle.len);

    // And WITHIN one wire the spacing is uneven, because the bends took
    // the points. A uniform flattener holding the same tolerance would
    // pass everything above except this.
    var shortest: f32 = std.math.floatMax(f32);
    var longest: f32 = 0;
    for (tight[0 .. tight.len - 1], tight[1..]) |a, b| {
        const d = distToSeg(a, b, b);
        shortest = @min(shortest, d);
        longest = @max(longest, d);
    }
    try testing.expect(longest > shortest * 4);
}

test "nodegraph: a cubic that doubles back is not mistaken for a flat one" {
    // Both control points sit exactly ON the chord's line, so a flatness
    // test made only of perpendicular distance calls this flat at depth
    // zero and draws a 10px straight line where the curve swings 60px
    // right and back. Reachable, not theoretical: a wire whose consumer
    // is LEFT of its producer leaves rightwards, returns, and leaves
    // again, and its chord points the other way.
    //
    // Mutation: drop the `t < -slack or t > 1 + slack` arm of
    // `flatEnough`. Red — two points instead of twenty-odd.
    const p0 = [2]f32{ 0, 0 };
    const c0 = [2]f32{ 150, 0 };
    const c1 = [2]f32{ -140, 0 };
    const p1 = [2]f32{ 10, 0 };

    var buf: [LINK_MAX_PTS][2]f32 = undefined;
    const pts = flattenCubic(&buf, p0, c0, c1, p1, LINK_FLATNESS);
    try testing.expect(pts.len > 8);
    try testing.expect(maxDeviation(pts, p0, c0, c1, p1) <= LINK_FLATNESS);
}

test "nodegraph: flatness is measured on the SCREEN curve, so zoom pays for itself" {
    // The same curve at a fifth of the size is a fifth as far from its
    // chords, so it flattens to fewer points with nothing written down
    // about zoom. The old segment count had to multiply by it by hand.
    //
    // Mutation: make the tolerance relative — `tol * len` in
    // `flatEnough` — which is the tempting scale-free spelling. Red:
    // the two counts become equal, and a fifty-node graph zoomed out to
    // fit pays full price for every wire in it.
    const p0 = [2]f32{ 0, 0 };
    const c0 = [2]f32{ 130, 0 };
    const c1 = [2]f32{ 70, 140 };
    const p1 = [2]f32{ 200, 140 };
    const k: f32 = 0.2;

    var big: [LINK_MAX_PTS][2]f32 = undefined;
    var small: [LINK_MAX_PTS][2]f32 = undefined;
    const a = flattenCubic(&big, p0, c0, c1, p1, LINK_FLATNESS);
    const b = flattenCubic(&small, .{ p0[0] * k, p0[1] * k }, .{ c0[0] * k, c0[1] * k }, .{ c1[0] * k, c1[1] * k }, .{ p1[0] * k, p1[1] * k }, LINK_FLATNESS);
    try testing.expect(b.len < a.len);
}

test "nodegraph: a wire out of buffer gets coarser, never shorter" {
    // Mutation: drop the `buf[n - 1] = p1` after the walk. Red — and on
    // screen a wire that stops in mid-air near its pin, which reads as
    // a broken connection rather than a rough one.
    const p0 = [2]f32{ 0, 0 };
    const c0 = [2]f32{ 400, -300 };
    const c1 = [2]f32{ -400, 300 };
    const p1 = [2]f32{ 900, 40 };
    var tiny: [6][2]f32 = undefined;
    const pts = flattenCubic(&tiny, p0, c0, c1, p1, LINK_FLATNESS);
    try testing.expect(pts.len <= tiny.len);
    try testing.expectApproxEqAbs(p1[0], pts[pts.len - 1][0], 1e-4);
    try testing.expectApproxEqAbs(p1[1], pts[pts.len - 1][1], 1e-4);
    // And a buffer too small to hold a line at all is refused, not
    // overrun.
    var one: [1][2]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), flattenCubic(&one, p0, c0, c1, p1, 1).len);
}

test "nodegraph: clipping a wire yields RUNS, not loose segments" {
    // A polyline clipped segment-at-a-time and stroked piecewise brings
    // back the per-segment drawing this file gave up — seams and all —
    // at the canvas edge. So the clip produces polylines: one run per
    // visit, broken only where the wire actually leaves the rectangle.
    //
    // Mutation: in `RunIter.next`, return after every segment. Red — 5
    // runs of 2 points instead of 1 run of 6, which is 5 ribbons with
    // 4 feathered caps butting inside the canvas.
    const r = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var run: [LINK_MAX_PTS][2]f32 = undefined;

    const inside = [_][2]f32{ .{ 10, 10 }, .{ 20, 20 }, .{ 30, 30 }, .{ 40, 40 }, .{ 50, 50 }, .{ 60, 60 } };
    var it = RunIter{ .pts = &inside, .r = r, .buf = &run };
    const whole = it.next().?;
    try testing.expectEqual(inside.len, whole.len);
    try testing.expectEqual(@as(?[]const [2]f32, null), it.next());

    // Out and back: two runs, each trimmed at the edge it crossed, and
    // nothing in between.
    const out_and_back = [_][2]f32{ .{ 10, 50 }, .{ 40, 50 }, .{ 200, 50 }, .{ 400, 50 }, .{ 200, 50 }, .{ 40, 60 }, .{ 10, 60 } };
    var it2 = RunIter{ .pts = &out_and_back, .r = r, .buf = &run };
    const first = it2.next().?;
    try testing.expectApproxEqAbs(@as(f32, 10), first[0][0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 100), first[first.len - 1][0], 1e-3);
    const second = it2.next().?;
    try testing.expectApproxEqAbs(@as(f32, 100), second[0][0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 10), second[second.len - 1][0], 1e-3);
    try testing.expectEqual(@as(?[]const [2]f32, null), it2.next());

    // A wire nowhere near the canvas draws nothing at all.
    const far = [_][2]f32{ .{ 500, 500 }, .{ 600, 600 } };
    var it3 = RunIter{ .pts = &far, .r = r, .buf = &run };
    try testing.expectEqual(@as(?[]const [2]f32, null), it3.next());
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
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = GRIDLESS_ZOOM };

    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    var lc = testCtx();
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };
    try drawCanvas(c, canvas, &lc, &dl);

    // What the one link costs, asked of the same arithmetic that drew
    // it: a ribbon is a column of 4 vertices per point plus two end
    // caps, and three quads between each pair of columns.
    const l = c.desc.links.items[0];
    const origin = [2]f32{ canvas.x, canvas.y };
    const wp0 = c.desc.view.toScreen(origin, c.desc.pinCentre(l.from));
    const wp1 = c.desc.view.toScreen(origin, c.desc.pinCentre(l.to));
    const cs = wireControls(wp0, wp1, c.desc.pins.items[l.from].dir, c.desc.pins.items[l.to].dir, c.desc.view.zoom);
    var pt_buf: [LINK_MAX_PTS][2]f32 = undefined;
    const pts = flattenCubic(&pt_buf, wp0, cs[0], cs[1], wp1, LINK_FLATNESS).len;

    // Triangles: the ground's 4 vertices and the wire's. No grid at this
    // zoom, no labels, and — the point — nothing from a node.
    try testing.expectEqual(@as(usize, 4 + (pts + 2) * 4), dl.tris.items.len);
    try testing.expectEqual(@as(usize, 6 + (pts + 1) * 18), dl.tri_indices.items.len);

    // Quads: ring + body + header per node, one per pin.
    try testing.expectEqual(
        @as(usize, 3 * c.desc.nodes.items.len + c.desc.pins.items.len),
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
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = z };

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
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = GRIDLESS_ZOOM };
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
        const owner = c.desc.pins.items[1].node;
        try testing.expectEqual(NODE_RING_HOVER, dl.quads.items[3 * owner].color);
    }
}

test "nodegraph: a node with nothing to say draws as its title bar alone" {
    // A body exists to hold labelled pin rows. A node with none — a
    // host's chip standing for a constant or an outside value — drew an
    // empty dark panel saying "there is something here" about nothing.
    // Chris, 2026-09-12: *"the externals don't need a body panel. the
    // port can connect straight to the RGB titlebar."*
    //
    // Mutation: `n.bare = false` in `finalise`. Red three ways at once —
    // the height, the pin's y, and the body quad — which is the point:
    // they are one decision and they must not be able to disagree.
    const c = try makeGraph(
        \\node id=chip x=0 y=0 label="row.seed"
        \\node id=sink x=200 y=0 label="Sink"
        \\node id=pair x=400 y=0 label="Pair"
        \\pin node=chip id=o0 dir=out
        \\pin node=sink id=a dir=in label="a"
        \\pin node=pair id=o0 dir=out
        \\pin node=pair id=o1 dir=out
    , &.{});
    defer dropGraph(c);

    const chip = c.desc.nodes.items[0];
    const sink = c.desc.nodes.items[1];
    const pair = c.desc.nodes.items[2];

    try testing.expect(chip.bare);
    try testing.expectApproxEqAbs(HEADER_H, chip.size[1], 1e-4);
    // Its one pin sits on the bar's centre line — anywhere else and the
    // wire arrives below a node that stops above it.
    try testing.expectApproxEqAbs(chip.pos[1] + HEADER_H * 0.5, c.desc.pinCentre(0)[1], 1e-4);

    // A LABELLED pin is something to write, so that node keeps its body.
    try testing.expect(!sink.bare);
    try testing.expect(sink.size[1] > HEADER_H);

    // **Two unlabelled pins are two ROWS**, and collapsing their node to
    // a 26px bar would stack them on each other. The row count is part
    // of the test, not a shortcut.
    //
    // Mutation: drop the `> 1` arm of `isBare`. Red here, and on screen
    // two pins in the same place.
    try testing.expect(!pair.bare);
    try testing.expect(c.desc.pinCentre(2)[1] != c.desc.pinCentre(3)[1]);
}

test "nodegraph: a bare node emits no body quad, and a tapered one says so in the SHADER" {
    // Two claims that have to be checked on the draw list, because both
    // are about what reaches the GPU.
    //
    // The taper is the shader's and not geometry's, and that is forced:
    // the quad layer draws OVER the triangle layer whatever order things
    // were emitted in, so a diagonal built from triangles would sink
    // under every wire on the canvas. Chris, 2026-09-12: *"can we do it
    // mathematically in the shader?"*
    //
    // Mutation: drop `.nose` from the two `appendQuad` calls. It
    // compiles and draws rectangles, and the connector look Chris asked
    // for is silently gone with no gate to say so.
    const c = try makeGraph(
        \\node id=chip x=0 y=0 label="row.seed" ring=#c2c8d4
        \\node id=quiet x=200 y=0 label="spawn1"
        \\pin node=chip id=o0 dir=out
    , &.{});
    defer dropGraph(c);
    // Under the label floor: `testCtx` hands out a LayoutCtx with no
    // device behind it, and any glyph path touching it aborts.
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = GRIDLESS_ZOOM };

    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    var lc = testCtx();
    try drawCanvas(c, .{ .x = 0, .y = 0, .w = 600, .h = 400 }, &lc, &dl);

    // Ring + header for each bare node — no body between them — plus one
    // pin. Three quads per node would be a body drawn under a bar that
    // covers it exactly, which costs a quad to look identical.
    try testing.expectEqual(@as(usize, 2 + 2 + 1), dl.quads.items.len);

    // The chip outputs, so it tapers; its ring's taper grows with the
    // ring's height, or the two edges are not parallel and the outline
    // reads as a wedge rather than an outline.
    //
    // Mutation: `.nose = nose` on the ring quad too. Red by the ratio,
    // and on screen a ring that pinches in at the tip.
    const chip_ring = dl.quads.items[0];
    const chip_bar = dl.quads.items[1];
    try testing.expect(chip_bar.nose > 0);

    // **Square left corners**, because the taper has already cut the
    // right pair off — `radius` only ever reaches the left two on one of
    // these. Chris, 2026-09-12: *"can we make the left hand edge not
    // have rounded corners — it's the last thing to match EDA tools."*
    //
    // Mutation: `const corner = r;`. It draws, and the part goes back to
    // looking like a panel instead of a component on a schematic. This
    // gate exists because that mutation SURVIVED the first sweep — the
    // shape was checked and the corner was not.
    try testing.expectEqual(@as(f32, 0), chip_bar.radius);
    try testing.expectEqual(@as(f32, 0), chip_ring.radius);
    // …and a node with a body keeps its rounding.
    try testing.expect(dl.quads.items[3].radius > 0);
    try testing.expect(chip_ring.nose > chip_bar.nose);
    try testing.expectApproxEqAbs(
        chip_bar.nose / chip_bar.dst_size[1],
        chip_ring.nose / chip_ring.dst_size[1],
        1e-4,
    );

    // **A node with nothing leaving it does not taper.** An arrow on a
    // node with no output points at nothing — `spawn1` and `perish1` are
    // bare too, and they stay rectangular.
    //
    // Mutation: drop `and n.out_count > 0`. Red, and the graph grows
    // arrows that mean nothing.
    try testing.expect(c.desc.nodes.items[1].bare);
    try testing.expectEqual(@as(f32, 0), dl.quads.items[3].nose);
}

test "nodegraph: a ringed node wears its WHOLE tint, and its label stays readable on it" {
    // Two halves of one change, and neither works without the other.
    //
    // A connector shouts — it is bare, has no body panel for its header
    // to sit quietly with, and the host has named it as something other
    // than an operator. That is what makes a yellow chip possible at
    // all: yellow only exists at high luminance, and 0.55 of any yellow
    // is olive, so no palette edit could have produced the bright yellow
    // Chris asked for.
    //
    // Mutation: `return tinted(n.tint, NODE_HEADER_TINT);` for every
    // node. Red on the first pair — and the constant chips go back to
    // the mustard he rejected.
    const c = try makeGraph(
        \\node id=sun x=0 y=0 label="c" tint=#f2e02f ring=#c2c8d4
        \\node id=op x=200 y=0 label="o" tint=#f2e02f
        \\pin node=sun id=o0 dir=out
        \\pin node=op id=i0 dir=in label="a"
    , &.{});
    defer dropGraph(c);

    const chip = c.desc.nodes.items[0];
    const op = c.desc.nodes.items[1];
    try testing.expectEqual(chip.tint, headerColor(chip));
    try testing.expect(headerColor(op)[1] < op.tint[1]);

    // **Keyed to the RING, not to bareness** — which the first draft got
    // wrong and only the picture caught. `spawn1` and `perish1` are bare
    // too, operators that happen to declare no ports, and at full
    // strength they became the loudest things on the canvas.
    //
    // Mutation: `if (n.bare)`. Green on everything above, because the
    // chip is bare as well; red only here.
    const plain = try makeGraph(
        \\node id=quiet x=0 y=0 label="spawn1" tint=#d94f86
    , &.{});
    defer dropGraph(plain);
    const q = plain.desc.nodes.items[0];
    try testing.expect(q.bare);
    try testing.expect(headerColor(q)[0] < q.tint[0]);

    // And the ink follows the bar. Rec. 709 weights green six times
    // red's and ten times blue's, which is why a full green or yellow
    // chip needs dark letters and a full royal blue one does not — all
    // three are equally "saturated" and that is not the question being
    // asked.
    //
    // Mutation: weight the three channels equally. Royal blue's
    // luminance then reads 0.44 instead of 0.41 — still light, so most
    // of this passes — but GREEN drops from 0.58 to 0.40 and its chip
    // goes back to unreadable white-on-green. Red is what makes an even
    // weighting look right for the wrong reason.
    const light = [4]f32{ 0.9, 0.9, 0.92, 1 };
    const row_red = [4]f32{ 0xd8.0 / 255.0, 0x32.0 / 255.0, 0x2f.0 / 255.0, 1 };
    const royal = [4]f32{ 0x41.0 / 255.0, 0x69.0 / 255.0, 0xe1.0 / 255.0, 1 };
    const slate = [4]f32{ 0x2f.0 / 255.0, 0xb8.0 / 255.0, 0x4a.0 / 255.0, 1 };
    const yellow = [4]f32{ 0xf2.0 / 255.0, 0xe0.0 / 255.0, 0x2f.0 / 255.0, 1 };
    try testing.expectEqual(light, labelOn(row_red, light));
    try testing.expectEqual(light, labelOn(royal, light));
    try testing.expectEqual(NODE_LABEL_DARK, labelOn(slate, light));
    try testing.expectEqual(NODE_LABEL_DARK, labelOn(yellow, light));
    // A body-panel node is always dark enough to keep the theme's ink,
    // whatever its tag colour — the darken guarantees it.
    try testing.expectEqual(light, labelOn(tinted(yellow, NODE_HEADER_TINT), light));
}

test "nodegraph: `ring=` is the HOST's word, and selection still wins over it" {
    // A graph has a handful of nodes that are not operators, and only
    // the host knows which — spark must not guess. But a ring that
    // cannot say "this one is selected" has taken the state channel for
    // decoration, so hover and selection override it.
    //
    // Mutation: `else n.ring orelse NODE_RING` moved ahead of the
    // selected/hover arms. Red on the second half — and on screen a
    // reader can no longer tell which external they just clicked.
    const c = try makeGraph(
        \\node id=chip x=0 y=0 label="c" ring=#d8ab52
        \\node id=plain x=200 y=0 label="p"
        \\pin node=chip id=o0 dir=out
        \\pin node=plain id=o0 dir=out
    , &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ 0, 0 }, .zoom = GRIDLESS_ZOOM };

    try testing.expect(c.desc.nodes.items[0].ring != null);
    try testing.expectApproxEqAbs(@as(f32, 0xd8) / 255.0, c.desc.nodes.items[0].ring.?[0], 0.01);
    // Said nothing, so spark's own — not a ring of transparent black,
    // which is what a non-optional field defaulting to zero would give.
    try testing.expectEqual(@as(?[4]f32, null), c.desc.nodes.items[1].ring);

    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    var lc = testCtx();
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };
    try drawCanvas(c, canvas, &lc, &dl);
    try testing.expectApproxEqAbs(@as(f32, 0xd8) / 255.0, dl.quads.items[0].color[0], 0.01);

    c.selected = 0;
    dl.clearRetainingCapacity();
    try drawCanvas(c, canvas, &lc, &dl);
    try testing.expectEqual(NODE_RING_SELECTED, dl.quads.items[0].color);
}

test "nodegraph: a node panned off the canvas costs nothing" {
    // Mutation: delete the two `continue` culls in the node loop. Red —
    // and at fifty nodes on a small canvas it is most of the frame.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ 100_000, 100_000 }, .zoom = GRIDLESS_ZOOM };

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

// ── Beat 2: reachability and the wire ───────────────────────────────

/// Two nodes, one wire already in place, and a declared lattice with one
/// coercion in it. `number → tight` is exact both ways; `number → wide`
/// is a coercion; `colour` reaches nothing, which is what makes an
/// unreachable pin gateable at all.
const typed_graph =
    \\node id=src x=0 y=0 label="Source"
    \\node id=mul x=200 y=60 label="Multiply"
    \\pin node=src id=out dir=out label="v" type=number
    \\pin node=src id=hue dir=out label="hue" type=colour
    \\pin node=mul id=a dir=in label="a" type=number
    \\pin node=mul id=b dir=in label="b" type=ratio
    \\pin node=mul id=out dir=out label="v" type=number
    \\link from=src.out to=mul.a
    \\accept from=number to=number
    \\accept from=number to=ratio mode=coerce
;

/// Index of the pin `<node>.<pin>` in `typed_graph`-shaped descriptions,
/// so a gate names pins the way the document does and does not go wrong
/// when a fixture gains a line.
fn pinAt(c: *Component, node: []const u8, pin: []const u8) u32 {
    var buf: [64]u8 = undefined;
    const ref = std.fmt.bufPrint(&buf, "{s}.{s}", .{ node, pin }) catch unreachable;
    return c.desc.resolveRef(ref).?;
}

fn pressPin(c: *Component, st: *state_mod.State, pin: u32) !void {
    const l = c.desc.view.toLocal(c.desc.pinCentre(pin));
    try onInput(@ptrCast(c), .{ .mouse_down = .{ .local = l, .button = 0, .button_down = true } }, @ptrCast(st));
}

fn dragTo(c: *Component, st: *state_mod.State, g: [2]f32) !void {
    const l = c.desc.view.toLocal(g);
    try onInput(@ptrCast(c), .{ .mouse_move = .{ .local = l, .button = 0, .button_down = true } }, @ptrCast(st));
}

fn releaseAt(c: *Component, st: *state_mod.State, g: [2]f32) !void {
    const l = c.desc.view.toLocal(g);
    try onInput(@ptrCast(c), .{ .mouse_up = .{ .local = l, .button = 0, .button_down = false } }, @ptrCast(st));
}

test "nodegraph: reach is a direction, a node and a declared pair" {
    // The three rules, each mutated separately because each has its own
    // way of being wrong.
    //
    // Mutation 1: drop `if (a.dir == b.dir) return .none` — an output
    // reaches another output and the second case goes red.
    // Mutation 2: drop `if (a.node == b.node) return .none` — `mul.out`
    // reaches `mul.a`, a cycle of length one, and the third goes red.
    // Mutation 3: `return .exact` instead of consulting `accepts` — the
    // colour pin reaches a number port and the last two go red.
    const c = try makeGraph(typed_graph, &.{});
    defer dropGraph(c);
    const src_out = pinAt(c, "src", "out");
    const src_hue = pinAt(c, "src", "hue");
    const mul_a = pinAt(c, "mul", "a");
    const mul_b = pinAt(c, "mul", "b");
    const mul_out = pinAt(c, "mul", "out");

    try testing.expectEqual(Reach.exact, c.desc.reachOf(.{ .anchor = src_out }, mul_a));
    // Two outputs are not a wire, whichever way round they are asked.
    try testing.expectEqual(Reach.none, c.desc.reachOf(.{ .anchor = src_out }, mul_out));
    // A node feeding itself is the one cycle a canvas can catch without
    // knowing the host's language.
    try testing.expectEqual(Reach.none, c.desc.reachOf(.{ .anchor = mul_out }, mul_a));
    // Declared, and declared as a coercion — the answer that is neither
    // yes nor no, and the whole reason `accept` carries a mode.
    try testing.expectEqual(Reach.coerce, c.desc.reachOf(.{ .anchor = src_out }, mul_b));
    // `colour → number` was never declared, so it is refused.
    try testing.expectEqual(Reach.none, c.desc.reachOf(.{ .anchor = src_hue }, mul_a));
}

test "nodegraph: the pair is read source-to-sink, whichever end was grabbed" {
    // Dragging BACKWARDS off an input must ask the same question as
    // dragging forwards onto it. The lattice is directed — `number`
    // reaches `ratio` and nothing here says `ratio` reaches `number` —
    // so an implementation that looked the pair up as (grabbed, other)
    // would light the wrong pins on exactly half of all drags.
    //
    // Mutation: in `reachOf`, use `a.ty`/`b.ty` for `from`/`to` instead
    // of ordering them by `dir`. Red — grabbing `mul.b` and asking about
    // `src.out` returns `.none`, so an input you can wire INTO cannot be
    // wired FROM.
    const c = try makeGraph(typed_graph, &.{});
    defer dropGraph(c);
    const src_out = pinAt(c, "src", "out");
    const mul_b = pinAt(c, "mul", "b");

    try testing.expectEqual(Reach.coerce, c.desc.reachOf(.{ .anchor = src_out }, mul_b));
    try testing.expectEqual(Reach.coerce, c.desc.reachOf(.{ .anchor = mul_b }, src_out));
}

test "nodegraph: a host that declared no lattice gets no refusals" {
    // The compatibility argument, and it is what lets every description
    // written before `accept` existed keep working. An empty table is
    // "nothing was said", not "nothing is allowed".
    //
    // Mutation: delete the `if (self.accepts.items.len == 0) return
    // .exact;` early-out. Red — with no rows declared the loop below it
    // finds nothing and every pin goes dark, so a wire can never be made
    // in any document that predates this beat.
    //
    // **The pins here are TYPED and that is the whole fixture.** Written
    // against `two_node_graph`, whose pins carry no `type=`, this gate
    // passed the mutation: the empty-TOKEN early-out further down caught
    // it and the gate could not tell which of the two rules it was
    // watching. Two independent rules need two fixtures — found by the
    // mutation surviving, which is the only way that is ever found.
    const c = try makeGraph(
        \\node id=src x=0 y=0
        \\node id=mul x=200 y=0
        \\pin node=src id=out dir=out type=number
        \\pin node=mul id=b dir=in type=ratio
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 0), c.desc.accepts.items.len);
    try testing.expectEqual(Reach.exact, c.desc.reachOf(
        .{ .anchor = pinAt(c, "src", "out") },
        pinAt(c, "mul", "b"),
    ));
}

test "nodegraph: an untyped pin beside a declared lattice still reaches" {
    // A pin the host said nothing about is not a pin the host refused.
    // Guessing either way is worse than the rule: refuse it and a host
    // that types most of its pins finds the rest mysteriously dead.
    //
    // Mutation: delete the `if (from.len == 0 or to.len == 0) return
    // .exact;` line. Red — `plain` reaches nothing.
    const c = try makeGraph(
        \\node id=src x=0 y=0
        \\node id=dst x=200 y=0
        \\pin node=src id=out dir=out type=number
        \\pin node=dst id=plain dir=in
        \\accept from=number to=number
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(Reach.exact, c.desc.reachOf(
        .{ .anchor = pinAt(c, "src", "out") },
        pinAt(c, "dst", "plain"),
    ));
}

test "nodegraph: a misspelled accept mode is a bad line, not a silent demotion" {
    // A host that writes `mode=coerse` asked for amber and would
    // otherwise get green, with nothing anywhere saying so.
    //
    // Mutation: make the unknown-mode arm leave `ac.mode` at `.exact`
    // instead of setting `.none`. Red — the row is accepted and
    // `bad_lines` stays 0.
    const c = try makeGraph(
        \\node id=src x=0 y=0
        \\node id=dst x=200 y=0
        \\pin node=src id=out dir=out type=number
        \\pin node=dst id=in dir=in type=ratio
        \\accept from=number to=ratio mode=coerse
    , &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(u32, 1), c.desc.bad_lines);
    try testing.expectEqual(@as(usize, 0), c.desc.accepts.items.len);
}

test "nodegraph: a wire in hand lights what would take it and dims the rest" {
    // Blade3D's `CollectInputPorts`, which is the half of its wiring
    // model that made it feel like an editor — and the thing Christian
    // went looking for in this canvas and did not find.
    //
    // Mutation: in the pin loop, drop the `if (wire) |w|` re-colour so
    // pins keep their idle tint. Red on every arm — the graph says
    // nothing at all about where the wire may land.
    const c = try makeGraph(typed_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ -20, -20 }, .zoom = GRIDLESS_ZOOM };
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };

    const src_out = pinAt(c, "src", "out");
    c.grab = .{ .wire = .{
        .anchor = src_out,
        .detached = null,
        .cursor = .{ 100, 100 },
        .over = .none,
    } };

    var lc = testCtx();
    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    try drawCanvas(c, canvas, &lc, &dl);

    // Three quads a node, then one a pin, in pin declaration order.
    const pin_q = 3 * c.desc.nodes.items.len;
    const q = dl.quads.items;
    try testing.expectEqual(PIN_REACH_EXACT, q[pin_q + pinAt(c, "mul", "a")].color);
    try testing.expectEqual(PIN_REACH_COERCE, q[pin_q + pinAt(c, "mul", "b")].color);
    // Unreachable fades but keeps its hue: the graph goes quiet, not grey.
    const hue_q = q[pin_q + pinAt(c, "src", "hue")].color;
    try testing.expectEqual(dimmed(PIN_OUT_COLOR), hue_q);
    // The end in your hand stays lit — it is not a target, and a dark
    // anchor reads as the wire having come loose.
    try testing.expectEqual(PIN_OUT_COLOR, q[pin_q + src_out].color);
}

test "nodegraph: a reachable pin GROWS, so the cue is not colour alone" {
    // Mutation: use `PIN_R` unconditionally for the radius. Red — the
    // reachable pin is the same size as the dead one, and a reader who
    // cannot separate amber from grey has nothing left to go on.
    const c = try makeGraph(typed_graph, &.{});
    defer dropGraph(c);
    // Below `LABEL_MIN_ZOOM`, so no glyph is shaped and the gate needs
    // no font device — the same reason every other draw gate here picks
    // this zoom.
    const z = GRIDLESS_ZOOM;
    c.desc.view = .{ .pan = .{ -20, -20 }, .zoom = z };
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };
    c.grab = .{ .wire = .{
        .anchor = pinAt(c, "src", "out"),
        .detached = null,
        .cursor = .{ 100, 100 },
        .over = .none,
    } };

    var lc = testCtx();
    var dl = element.DrawList.init(testing.allocator);
    defer dl.deinit();
    try drawCanvas(c, canvas, &lc, &dl);

    const pin_q = 3 * c.desc.nodes.items.len;
    const q = dl.quads.items;
    try testing.expectApproxEqAbs(
        2 * PIN_REACH_R * z,
        q[pin_q + pinAt(c, "mul", "a")].dst_size[0],
        1e-3,
    );
    try testing.expectApproxEqAbs(
        2 * PIN_R * z,
        q[pin_q + pinAt(c, "src", "hue")].dst_size[0],
        1e-3,
    );
}

test "nodegraph: releasing on a reachable pin asks the host to join them" {
    // Mutation: have `releaseWire` write only when `landed` is null.
    // Red — the whole gesture produces nothing and the canvas is a
    // viewer again.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c);

    const src_out = pinAt(c, "src", "out");
    const mul_b = pinAt(c, "mul", "b");
    try pressPin(c, &st, src_out);
    try dragTo(c, &st, c.desc.pinCentre(mul_b));
    try releaseAt(c, &st, c.desc.pinCentre(mul_b));

    try testing.expectEqualStrings("link from=src.out to=mul.b\n", st.get("g.edits").?);
}

test "nodegraph: the record is written source-to-sink however it was dragged" {
    // Dragging backwards off an unwired input must produce the same
    // record as dragging forwards onto it. A host reading `from=` should
    // never have to work out which way the reader's hand went.
    //
    // Mutation: write `from=` as the anchor unconditionally. Red — the
    // record comes out `link from=mul.b to=src.out`, which names an
    // input as a source.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c);

    const mul_b = pinAt(c, "mul", "b");
    try pressPin(c, &st, mul_b);
    try dragTo(c, &st, c.desc.pinCentre(pinAt(c, "src", "out")));
    try releaseAt(c, &st, c.desc.pinCentre(pinAt(c, "src", "out")));

    try testing.expectEqualStrings("link from=src.out to=mul.b\n", st.get("g.edits").?);
}

test "nodegraph: pressing a wired input picks the wire UP and rehoming clears it" {
    // The reason `detached` exists rather than the press simply
    // re-anchoring. Both halves of a rehome are one write, and they name
    // different inputs so their order does not matter.
    //
    // Mutation: set `.detached = null` at the press site. Red — the
    // `unlink` is gone and the source ends up feeding both inputs, which
    // is a graph the reader never asked for.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c);

    const mul_a = pinAt(c, "mul", "a"); // already fed by src.out
    const mul_b = pinAt(c, "mul", "b");
    try pressPin(c, &st, mul_a);
    // What is in hand is the FAR end — the source — not the input.
    try testing.expectEqual(pinAt(c, "src", "out"), c.grab.wire.anchor);
    try dragTo(c, &st, c.desc.pinCentre(mul_b));
    try releaseAt(c, &st, c.desc.pinCentre(mul_b));

    try testing.expectEqualStrings(
        "unlink to=mul.a\nlink from=src.out to=mul.b\n",
        st.get("g.edits").?,
    );
}

test "nodegraph: a lifted wire dropped on nothing DISCONNECTS; a new one does nothing" {
    // The two halves of "released over empty canvas", which mean
    // opposite things and are told apart only by `detached`.
    //
    // Mutation: `if (landed == null) return;` at the top of
    // `releaseWire`. Red on the first arm — a wire dragged off a pin and
    // dropped springs back, so there is no way to break a link at all.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c);

    try pressPin(c, &st, pinAt(c, "mul", "a"));
    try dragTo(c, &st, .{ 400, 300 });
    try releaseAt(c, &st, .{ 400, 300 });
    try testing.expectEqualStrings("unlink to=mul.a\n", st.get("g.edits").?);

    // A NEW wire abandoned in space writes nothing — a host subscribed
    // to this path is not woken to be told the reader changed their
    // mind. A second, untouched state, because "nothing was written" is
    // only readable on a path that has never been written.
    var st2 = state_mod.State.init(testing.allocator);
    defer st2.deinit();
    const c2 = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c2);
    try pressPin(c2, &st2, pinAt(c2, "src", "out"));
    try dragTo(c2, &st2, .{ 400, 300 });
    try releaseAt(c2, &st2, .{ 400, 300 });
    try testing.expect(st2.get("g.edits") == null);
}

test "nodegraph: a lifted wire put back where it came from is a no-op" {
    // Cancel, with no key and no focus. The clear and the set name the
    // same input, so the `unlink` is suppressed and the `link` restores
    // exactly what was there — the host applies an assignment that was
    // already true.
    //
    // Mutation: drop the `landed.? != old_in` condition. Red — the write
    // becomes `unlink to=mul.a` followed by the same link, which is
    // still correct but tells the host to take a wire out and put it
    // back; and a host that logs its edits now logs a change that did
    // not happen.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c);

    const mul_a = pinAt(c, "mul", "a");
    try pressPin(c, &st, mul_a);
    try dragTo(c, &st, .{ 400, 300 });
    try releaseAt(c, &st, c.desc.pinCentre(mul_a));
    try testing.expectEqualStrings("link from=src.out to=mul.a\n", st.get("g.edits").?);
}

test "nodegraph: released on a node's BODY, the wire finds its nearest pin" {
    // A pin is four graph units across. At 0.4 zoom that is under two
    // screen pixels, and aiming at it is a game rather than an edit.
    //
    // Mutation: make the `.node` arm of `releaseWire` return null. Red —
    // a release anywhere but exactly on the dot does nothing.
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    const c = try makeGraph(typed_graph, &.{.{ .key = "edits", .value = "g.edits" }});
    defer dropGraph(c);

    // Low in the node's body: `b` is the lower of its two inputs, so the
    // nearest REACHABLE pin there is `b` and not `a`.
    const mul = c.desc.nodes.items[c.desc.pins.items[pinAt(c, "mul", "b")].node];
    const deep: [2]f32 = .{ mul.pos[0] + mul.size[0] * 0.5, mul.pos[1] + mul.size[1] - 2 };

    try pressPin(c, &st, pinAt(c, "src", "out"));
    try dragTo(c, &st, deep);
    try releaseAt(c, &st, deep);
    try testing.expectEqualStrings("link from=src.out to=mul.b\n", st.get("g.edits").?);
}

test "nodegraph: the wire in hand is not also drawn where it came from" {
    // Two wires out of one source while the reader holds one of them
    // would say the disconnect had not happened yet, which is the
    // opposite of what dragging a wire off a pin should look like.
    //
    // Mutation: delete the `if (held_link) |h| if (h == li) continue;`
    // skip. Red — the segment count goes back up by a whole wire.
    const c = try makeGraph(typed_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ -20, -20 }, .zoom = GRIDLESS_ZOOM };
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };
    var lc = testCtx();

    var idle = element.DrawList.init(testing.allocator);
    defer idle.deinit();
    try drawCanvas(c, canvas, &lc, &idle);

    // The same graph with that one link in hand, held at its own far
    // end so the preview wire is exactly where the real one was: the
    // ONLY difference between the two pictures is the skip.
    const mul_a = pinAt(c, "mul", "a");
    c.grab = .{ .wire = .{
        .anchor = pinAt(c, "src", "out"),
        .detached = c.desc.linkInto(mul_a),
        .cursor = c.desc.pinCentre(mul_a),
        .over = .{ .pin = mul_a },
    } };
    var held = element.DrawList.init(testing.allocator);
    defer held.deinit();
    try drawCanvas(c, canvas, &lc, &held);

    try testing.expectEqual(idle.tris.items.len, held.tris.items.len);
}

test "nodegraph: the wire in hand takes the colour of what it is over" {
    // The answer before the button comes up, which is the other half of
    // Blade3D's model: teal over nothing, the target's own colour the
    // moment it is over something that would take it.
    //
    // Mutation: always use `WIRE_LOOSE`. Red on the second and third
    // arms — the wire never says yes and never distinguishes a
    // conversion from a clean join.
    const c = try makeGraph(typed_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ -20, -20 }, .zoom = GRIDLESS_ZOOM };
    const canvas = Rect{ .x = 0, .y = 0, .w = 600, .h = 400 };
    var lc = testCtx();
    const src_out = pinAt(c, "src", "out");

    const cases = [_]struct { over: Hover, want: [4]f32 }{
        .{ .over = .none, .want = WIRE_LOOSE },
        .{ .over = .{ .pin = pinAt(c, "mul", "a") }, .want = PIN_REACH_EXACT },
        .{ .over = .{ .pin = pinAt(c, "mul", "b") }, .want = PIN_REACH_COERCE },
        // Over a pin that would refuse it, the wire stays loose — the
        // picture must not promise a join that the release will not make.
        .{ .over = .{ .pin = pinAt(c, "src", "hue") }, .want = WIRE_LOOSE },
    };
    for (cases) |case| {
        c.grab = .{ .wire = .{
            .anchor = src_out,
            .detached = null,
            .cursor = .{ 260, 140 },
            .over = case.over,
        } };
        var dl = element.DrawList.init(testing.allocator);
        defer dl.deinit();
        try drawCanvas(c, canvas, &lc, &dl);
        // Probe by colour, not by position: `relief.stroke` feathers,
        // so the last triangle in the layer is an edge at alpha zero and
        // the wire's own colour is several triangles back.
        try testing.expect(hasTriColor(&dl, case.want));
        // …and the colours it is NOT. Without this the gate passes for
        // an implementation that draws all four at once.
        for (cases) |other| {
            if (std.meta.eql(other.want, case.want)) continue;
            try testing.expect(!hasTriColor(&dl, other.want));
        }
    }
}

/// Does the triangle layer carry a stroke of exactly this colour?
///
/// `relief.stroke` lays a solid core and feathers out to alpha zero, so
/// every stroke contributes triangles at the colour AND triangles at
/// every alpha down to nothing. Asking "is this colour present" is the
/// only question about a feathered stroke that has a stable answer.
fn hasTriColor(dl: *const element.DrawList, want: [4]f32) bool {
    for (dl.tris.items) |t| {
        if (std.meta.eql(t.color, want)) return true;
    }
    return false;
}

// ── Loops ───────────────────────────────────────────────────────────

/// A chain: a → b → c, plus a spare node nothing is wired to.
const chain_graph =
    \\node id=a x=0 y=0
    \\node id=b x=200 y=0
    \\node id=c x=400 y=0
    \\node id=free x=200 y=200
    \\pin node=a id=in dir=in
    \\pin node=a id=out dir=out
    \\pin node=b id=in dir=in
    \\pin node=b id=out dir=out
    \\pin node=c id=in dir=in
    \\pin node=c id=out dir=out
    \\pin node=free id=in dir=in
    \\pin node=free id=out dir=out
    \\link from=a.out to=b.in
    \\link from=b.out to=c.in
;

test "nodegraph: a wire out of c cannot land back on a or b" {
    // Christian, 2026-09-10, on the first version: *"when I start dragging a
    // port, nodes upstream from the node port I'm dragging show as being able
    // to accept. That's cycles — I'm not sure we should be allowing those."*
    //
    // The argument for leaving them was that a cycle might be legal in some
    // host's language. It does not survive contact with the code: rule 2
    // already refuses a pin reaching its own node, which is a cycle of length
    // ONE. Refusing length one and shrugging at length two is not a policy.
    //
    // Mutation: drop `if (probe.blocks(b.node)) return .none;` from `reachOf`.
    // Red on both upstream arms — `c`'s output reaches `a`'s and `b`'s inputs,
    // which is a graph that cannot be evaluated in any order.
    const c = try makeGraph(chain_graph, &.{});
    defer dropGraph(c);
    var mask = std.ArrayList(bool).init(testing.allocator);
    defer mask.deinit();

    const c_out = pinAt(c, "c", "out");
    try c.desc.blockCycles(&mask, c_out);
    const pr = Probe{ .anchor = c_out, .blocked = mask.items };

    try testing.expectEqual(Reach.none, c.desc.reachOf(pr, pinAt(c, "a", "in")));
    try testing.expectEqual(Reach.none, c.desc.reachOf(pr, pinAt(c, "b", "in")));
    // …and a node NOT in the chain is untouched. Without this the gate passes
    // for a mask that blocks everything, which is a canvas you cannot wire.
    try testing.expectEqual(Reach.exact, c.desc.reachOf(pr, pinAt(c, "free", "in")));

    // **The mask is the whole answer, including the anchor's own node.**
    // Asserted on the MASK rather than through `reachOf`, deliberately: rule 2
    // refuses that node anyway, so a `reachOf` assertion here passes whether
    // the walk seeds it or not — which is exactly what happened. Dropping
    // `out.items[start] = true` survived a `reachOf`-shaped gate and changes
    // nothing about what a reader sees; it changes what `Probe.blocked` MEANS,
    // from "every node this wire must not reach" to "…except one, which
    // another rule happens to cover". A palette asking the mask "where could
    // this wire go" would get the wrong answer for one node and have no way
    // to know. Mutation: delete that line. Red, here and only here.
    try testing.expect(mask.items[c.desc.pins.items[c_out].node]);
}

test "nodegraph: dragged backwards off an input, the block walks the other way" {
    // The direction of the walk is the direction the wire is NOT going. An
    // out-anchor is the wire's source and everything feeding it is blocked; an
    // IN-anchor is its sink, so everything it already FEEDS is blocked
    // instead. Same loop, opposite walk, and an implementation that only ever
    // walked upstream would let a reader draw it from the other end.
    //
    // Mutation: make `blockCycles` walk upstream unconditionally (`const up =
    // true;`). Red — `a`'s input accepts a wire from `c`'s output, which is
    // the same cycle the gate above refuses, reached by dragging the other way.
    const c = try makeGraph(chain_graph, &.{});
    defer dropGraph(c);
    var mask = std.ArrayList(bool).init(testing.allocator);
    defer mask.deinit();

    const a_in = pinAt(c, "a", "in");
    try c.desc.blockCycles(&mask, a_in);
    const pr = Probe{ .anchor = a_in, .blocked = mask.items };

    try testing.expectEqual(Reach.none, c.desc.reachOf(pr, pinAt(c, "b", "out")));
    try testing.expectEqual(Reach.none, c.desc.reachOf(pr, pinAt(c, "c", "out")));
    try testing.expectEqual(Reach.exact, c.desc.reachOf(pr, pinAt(c, "free", "out")));
}

test "nodegraph: a graph that already loops does not hang the walk" {
    // A host may hand us anything, and a description is a picture rather than
    // a refusal — `bad_lines` is a count, not an error. So the walk must
    // terminate on a graph that already contains a loop.
    //
    // Mutation: drop the `if (out.items[next]) continue;` visited check. The
    // gate does not go red, it HANGS — which is the failure being prevented,
    // and is why this one is written as a bounded assertion rather than a
    // comparison. Confirmed by running it with the check removed and killing
    // the runner.
    const c = try makeGraph(
        \\node id=a x=0 y=0
        \\node id=b x=200 y=0
        \\pin node=a id=in dir=in
        \\pin node=a id=out dir=out
        \\pin node=b id=in dir=in
        \\pin node=b id=out dir=out
        \\link from=a.out to=b.in
        \\link from=b.out to=a.in
    , &.{});
    defer dropGraph(c);
    var mask = std.ArrayList(bool).init(testing.allocator);
    defer mask.deinit();
    try c.desc.blockCycles(&mask, pinAt(c, "a", "out"));
    try testing.expectEqual(@as(usize, 2), mask.items.len);
    try testing.expect(mask.items[0] and mask.items[1]);
}

// ── The context question ────────────────────────────────────────────

test "nodegraph: right-click names what is under it, and the canvas names WHERE" {
    // The host has to put a created node where the reader clicked, and the
    // reader clicked in GRAPH space — which only this component can compute,
    // because only this component holds the camera. A host doing the transform
    // itself needs a copy of `pan` and `zoom` and gets it wrong by a frame
    // whenever the two disagree.
    //
    // Mutation: return `local` instead of `g` in the `.none` arm — i.e. hand
    // back canvas pixels and let the host sort it out. Red at any pan or zoom
    // but the identity one, which is why this gate sets both.
    const c = try makeGraph(two_node_graph, &.{});
    defer dropGraph(c);
    c.desc.view = .{ .pan = .{ 40, 25 }, .zoom = 2.0 };

    // **Through the vtable, not through the function.** Calling
    // `contextSubject` directly gates the answer and not the WIRING, and
    // deleting `.context_subject = contextSubject` from the vtable then leaves
    // every gate here green while a right-click reaches nothing at all. Found
    // by that mutation surviving.
    const ask = vtable.context_subject orelse return error.HookNotRegistered;

    // A node.
    const on_node = c.desc.view.toLocal(.{ 10, 6 });
    try testing.expectEqualStrings("node:src", ask(@ptrCast(c), on_node).?);

    // A pin — named as the DESCRIPTION spells it, so a host that generated
    // the payload recognises its own ids coming back.
    const on_pin = c.desc.view.toLocal(c.desc.pinCentre(1));
    const p = c.desc.pins.items[1];
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&want, "pin:{s}.{s}", .{ c.desc.nodes.items[p.node].id, p.id }),
        ask(@ptrCast(c), on_pin).?,
    );

    // Empty canvas: the answer carries the graph point, not the screen one.
    const empty_g: [2]f32 = .{ 620.5, 410.25 };
    const on_empty = c.desc.view.toLocal(empty_g);
    try testing.expectEqualStrings(
        "canvas@620.50,410.25",
        ask(@ptrCast(c), on_empty).?,
    );
}

test "nodegraph: a subject too long to write is no subject at all" {
    // `bufPrint` failing must not truncate — a half-written `node:` names a
    // node that may well exist, and the host would open a menu about the
    // wrong thing. Returning null reads as "nothing claims this point", which
    // is the only safe answer for an id nobody could have parsed.
    //
    // Mutation: `catch unreachable`. The gate does not go red, it PANICS,
    // which is the failure being prevented; confirmed by running it that way.
    // The compiling, non-panicking mutation is `catch "node:"`, and that is
    // red here.
    var long: [400]u8 = undefined;
    @memset(&long, 'n');
    var body = std.ArrayList(u8).init(testing.allocator);
    defer body.deinit();
    try body.writer().print("node id={s} x=0 y=0\n", .{long});

    const c = try makeGraph(body.items, &.{});
    defer dropGraph(c);
    try testing.expectEqual(@as(usize, 1), c.desc.nodes.items.len);
    const ask = vtable.context_subject orelse return error.HookNotRegistered;
    try testing.expect(ask(@ptrCast(c), .{ 4, 4 }) == null);
}
