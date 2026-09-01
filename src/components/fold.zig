//! `:::fold` — a titled region that can be collapsed away.
//!
//! Attribute grammar:
//!
//!     :::fold {#surfaces title="Surfaces"}
//!     :::checkbox {label="Wireframe" target=state.wire checked=${state.wire}}
//!     :::slider {target=thickness value=${state.thickness}}
//!     :::
//!
//! - `#id`     (required) — the namespace this fold's children resolve
//!   into, same requirement `:::flex` and `:::embedded-document` have
//!   and for the same reason: two unnamed blocks share the empty scope.
//! - `title`   (required) — text in the header bar.
//! - `open`    (optional) — SEEDS and SYNCS the open flag. Truthy by
//!   `button.isTruthy`. Applied whenever it changes, so `open=0` means
//!   "start collapsed" and `open=${state.x}` also tracks the path; in
//!   between, the header click is in charge. See `last_open_attr`.
//! - `target`  (optional) — `state.path` the header click flips, so the
//!   flag can be published rather than kept private.
//! - `color` / `text` (optional) — palette for the header bar.
//!
//! ## Collapse is a VISIBILITY fact, not a document fact
//!
//! Chris, 2026-09-01, when the design was still worrying about where a
//! fold's flag should live and what a hot reload does to it:
//!
//! > My inclination was that the document still exists, it's simply that
//! > you can't see the collapsed section.
//!
//! That dissolves the question rather than answering it. The document is
//! whole: parsed at create time, mounted, its children instantiated and
//! its bindings live. The LAYOUT declines to walk a region. A reload
//! replaces the TEXT, and the visibility was never in the text to lose.
//!
//! `:::embedded-document` had already built this and called it
//! `headless` — "no visual representation; the doc was still parsed,
//! state populated, child components instantiated". A fold is that with
//! a header on it and its body inline instead of on disk.
//!
//! ### Two consequences, on purpose
//!
//! **A collapsed section's bindings stay live.** Its mirrors keep
//! tracking, so expanding shows current values rather than a stale
//! snapshot needing a re-sync — and a rill can drive a knob whose
//! control happens to be folded away. Visibility was never authorship,
//! which is the same equivalence a gesture and a console line have.
//!
//! **A collapsed section emits no hits.** Nothing invisible is
//! clickable, which falls out of not walking the subtree rather than
//! needing a rule of its own.
//!
//! ## The children's state is the PARENT's, not a child scope
//!
//! Unlike `:::embedded-document`, which owns a child `State` chained to
//! its parent. A fold must not: reads would still chain up, but WRITES
//! would land in the fold's own state, and matryoshka's `Panel.writeBack`
//! reads the panel's state and nothing else. Every slider inside a fold
//! would move and nothing would reach the plane. One `State`, the
//! document's, and the fold contributes only a registry scope.
//!
//! ## The cache-freeze trap, and the door it came in by anyway
//!
//! `cache-freeze` is a taxonomy of four instances of one bug: a cached
//! ancestor replays while everything under it works. "A region that
//! exists but does not draw" is an obvious fifth home, so `foldVersion`
//! aggregates the children's versions ALWAYS — including while folded,
//! where by definition nothing is drawn.
//!
//! **And instance five arrived anyway, through the other door.** The
//! prediction was about the CHILDREN. What was left out of the key was
//! the fold's own VISIBILITY — the one thing here that is not a child's
//! business. A header click flipped the flag and marked the host dirty,
//! the frame was re-rendered, and the layout cache replayed the drawlist
//! the fold had when it was shut. Chris, 2026-09-01: "if I try to open
//! the Result sub-panel, it does not open. However, after clicking the
//! group header, I now click on a button like normal … the Result panel
//! now unfolds." A sibling's click bumped a CHILD's version,
//! `foldVersion` XOR'd it in, the key finally moved, and the fold
//! re-walked — arriving already open.
//!
//! So `onInput` bumps `version` as well as setting `dirty`, and the two
//! are not the same thing: a redrawn frame and a re-walked block are
//! different events, and only the second can change shape.
//!
//! The lesson for the next container: **asking "what bumps the key" of
//! your children is half the question.** The other half is what bumps it
//! when the container's OWN state changes and no child's did.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const markdown = @import("../markdown.zig");
const element_layout = @import("../element_layout.zig");
const layout_cache = @import("../layout_cache.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
const button = @import("button.zig");

const relief = @import("relief.zig");

pub const Error = error{
    FoldMissingId,
    FoldMissingTitle,
    FoldNotInstalled,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("fold", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    title: []u8,
    /// State path the header click flips, `state.` prefix stripped.
    /// Empty when the fold keeps its flag to itself.
    target: []u8,
    /// The last `open=` this fold was ingested with, so a CHANGE in it
    /// can be told from a repeat of it.
    ///
    /// **`open=` seeds and syncs; it does not dictate.** It is applied
    /// whenever it changes — at create, and on any later re-resolve
    /// where the value actually moved — and between those moments the
    /// header click is in charge.
    ///
    /// The two simpler rules each fail a case somebody will write. "The
    /// attribute always wins" cannot express *start* closed: a static
    /// `open=0` would be a fold that shuts again the instant you open
    /// it. "The attribute only applies at create" cannot express
    /// `open=${state.x}` at all, because the rill or console line that
    /// moves the path would never reach the fold. Applying it on change
    /// does both, and it is the same shape as the plane's `seed`
    /// binding, which exists for exactly this reason.
    last_open_attr: ?bool = null,
    /// Whether the fold is open. The single source of truth, whether it
    /// was last written by a click or seeded from `open=`.
    ///
    /// It survives a hot reload because the instance does: the registry
    /// matches on `#id` and calls `update`, not `create`. Which is
    /// exactly Chris's framing — a reload replaces the text, and the
    /// visibility was never in the text to be lost.
    open_self: bool = true,

    color: [4]f32 = HEADER_LIGHT,
    text: [4]f32 = TITLE,
    /// `align=` / `text_align=`, passed down to everything under this
    /// fold. A fold inside a centred panel would otherwise centre its
    /// content under a header whose chevron is hard against the left,
    /// and the two would read as unrelated objects.
    alignment: element.AlignAttrs = .{},

    /// Owns every allocation the parsed child tree refers to.
    arena: std.heap.ArenaAllocator,
    /// Parsed child root — a `container.stack_v` of the body's blocks.
    root: element.Element,
    /// Registry namespace for the children. Owned so `deinit` can call
    /// `registry.deinitScope`.
    scope: []u8,
    /// The body text `root` was parsed from.
    body: component_mod.Body = .{},
    version: u64 = 0,
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    spark: ?*spark_mod.Spark = null,

    fn isOpen(self: *const Component) bool {
        return self.open_self;
    }

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var title_raw: ?[]const u8 = null;
        var target_raw: []const u8 = "";
        var open_opt: ?bool = null;

        self.alignment = element.AlignAttrs.readFrom(spec);
        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "title")) {
                title_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "open")) {
                open_opt = button.isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.color = v;
            } else if (std.mem.eql(u8, attr.key, "text")) {
                if (box_helpers.parseColor(attr.value)) |v| self.text = v;
            }
        }

        const title = title_raw orelse return Error.FoldMissingTitle;
        const target = if (std.mem.startsWith(u8, target_raw, "state."))
            target_raw["state.".len..]
        else
            target_raw;

        // `adoptString` because a fold with `open=${state.x}
        // target=state.x` subscribes to the path it writes, and
        // `State.set` notifies synchronously — the header click
        // re-enters this function while `onInput` still holds
        // `self.target`. See `component.adoptString`.
        try component_mod.adoptString(a, &self.title, title);
        try component_mod.adoptString(a, &self.target, target);

        // Seed and sync — see `last_open_attr`. Applied when the value
        // MOVED, which at create is always (the previous is null).
        if (open_opt) |v| {
            const moved = self.last_open_attr == null or self.last_open_attr.? != v;
            if (moved) self.open_self = v;
        }
        self.last_open_attr = open_opt;
        self.version +%= 1;
    }
};

fn create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!component_mod.Instance {
    const id_raw = spec.id orelse return Error.FoldMissingId;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .spark = spark,
        .title = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, ""),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
    };
    errdefer {
        allocator.free(c.title);
        allocator.free(c.target);
        c.arena.deinit();
    }

    c.scope = try allocator.dupe(u8, component_mod.specScope(spec, id_raw));
    errdefer allocator.free(c.scope);

    try c.ingest(spec);

    _ = c.body.adopt(spec.body);
    // The DOCUMENT's state, not a child of it, and not the Spark's root
    // — see the header. A fold owning its own State would swallow every
    // write made inside it.
    c.root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        spec.body,
        spark.theme,
        spark.registry,
        component_mod.specState(spec, spark.host_state),
        c.scope,
    );

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);

    // The body is authored text too, and a hot-reloaded document hands
    // the same `#id` a new one. Re-parse when it changes, and only
    // then — an unchanged body must not throw away this subtree's
    // layout cache on every `:::update`. Same shape as `:::flex`'s.
    if (c.body.adopt(spec.body)) {
        if (c.spark) |sp| {
            // The block cache is keyed by element ADDRESS, which is
            // sound while a parsed tree lives as long as its document
            // and false the instant one is re-parsed into the same
            // arena: the recycled allocations land on the same
            // addresses and the new blocks collide with the old ones'
            // cached draws.
            sp.layout_cache.clear();
            // Empty first, so a parse that fails leaves a valid root
            // rather than one pointing into the arena we just reset.
            c.root = element.Element{ .paragraph = &[_]element.Element{} };
            _ = c.arena.reset(.retain_capacity);
            c.root = try markdown.parseWithStateAndScope(
                c.arena.allocator(),
                spec.body,
                sp.theme,
                sp.registry,
                component_mod.specState(spec, sp.host_state),
                c.scope,
            );
        }
    }
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Children FIRST — their bindings unsubscribe from a State that is
    // not ours to free, but the instances themselves live in the shared
    // registry under our scope and nobody else will sweep them.
    if (c.spark) |sp| sp.registry.deinitScope(c.scope);
    c.arena.deinit();
    allocator.free(c.scope);
    allocator.free(c.title);
    allocator.free(c.target);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
    // **Load-bearing.** A fold's box covers its header AND its content,
    // and the walker's automatic Hit is appended after the component
    // has run — so it lands after every Hit the children emitted, and
    // `findHit` scans backwards. Without this the fold sits on top of
    // everything inside it and the panel stops responding: Chris,
    // 2026-09-01, "nothing is clickable. Buttons, expanders. Seems like
    // something is eating the mouse on the entire panel."
    //
    // `layoutAndRender` appends the header's own Hit BEFORE walking the
    // children, which is the order that makes a click on a control win
    // and a click on the bar reach us.
    .emits_own_hits = true,
};

/// Combine the fold's own version with its children's.
///
/// **`open` is not a parameter, and that is the point.** From
/// `cache-freeze`: a cached ancestor replays while everything under it
/// works, four times over. "A region that exists but does not draw" is
/// the obvious fifth home, and the tempting implementation —
/// `if (open) aggregate(children)` — plants it: a folded section's
/// children go on ingesting writes, the fold's version does not move,
/// and the expand serves whatever was cached when it closed. You open a
/// section and every control inside it is showing a frame-one snapshot.
///
/// Aggregating regardless costs a walk of children nobody is drawing,
/// which is the honest price of a cache key that tells the truth.
pub fn foldVersion(own: u64, children: []const element.Element) u64 {
    return own ^ layout_cache.aggregateChildVersions(children);
}

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return foldVersion(c.version, childrenOf(c));
}

fn childrenOf(c: *const Component) []const element.Element {
    return switch (c.root) {
        .container => |co| co.children,
        else => &[_]element.Element{},
    };
}

// ── Visual constants ────────────────────────────────────────────────

/// The header is a faintly RAISED band — light along its top, nothing at
/// its bottom — where a slider's recess is the same ramp inverted. A
/// section title you can press should read as a surface, not as a slot.
const HEADER_LIGHT: [4]f32 = .{ 1.0, 1.0, 1.0, 0.05 };
/// The seam under the header, which is `theme.thematic_break_color` by
/// another name: the same cut, drawn here because the header needs it
/// ordered among its own triangles.
const HEADER_SEAM: [4]f32 = .{ 0.0, 0.0, 0.0, 0.34 };
const HEADER_SEAM_LIGHT: [4]f32 = .{ 1.0, 1.0, 1.0, 0.05 };
const TITLE: [4]f32 = .{ 0.88, 0.88, 0.90, 1.0 };
/// Chrome, not state — so the chevron is the title's colour softened,
/// not the shell's amber. Amber means "this one is on"; a fold being
/// open is not a thing being on.
const CHEVRON: [4]f32 = .{ 0.70, 0.70, 0.73, 1.0 };
const CHEVRON_WIDTH: f32 = 1.6;
/// Half-width of the chevron's bounding box.
const CHEVRON_HALF: f32 = 3.6;
const HEADER_HEIGHT: f32 = 22;
const HEADER_PAD_X: f32 = 4;
/// Between the chevron and the title.
const CHEVRON_GAP: f32 = 9;
/// Breathing room between the header and the first block under it.
const CONTENT_GAP: f32 = 6;

/// The chevron's three points: `›` when closed, `⌄` when open.
///
/// Two strokes sharing the middle point, and they OVERLAP there rather
/// than butt — `relief.stroke` feathers its caps, and two feathered caps
/// meeting exactly leave a seam of half-alpha down the join.
fn chevronPoints(cx: f32, cy: f32, open: bool) [3][2]f32 {
    const s = CHEVRON_HALF;
    // The tip leads by a little less than the arms spread, which is what
    // keeps a chevron from reading as a right angle.
    const lead = s * 0.62;
    if (open) {
        return .{
            .{ cx - s, cy - lead * 0.5 },
            .{ cx, cy + lead * 0.5 },
            .{ cx + s, cy - lead * 0.5 },
        };
    }
    return .{
        .{ cx - lead * 0.5, cy - s },
        .{ cx + lead * 0.5, cy },
        .{ cx - lead * 0.5, cy + s },
    };
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const style = lc.theme.body;

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hb = lc.fonts.hbFont(style.font_id);
    const m = lc.fonts.metrics(style.font_id);

    const w: f32 = if (std.math.isFinite(constraints.max_w)) constraints.max_w else 320.0;
    const hy = @round(origin[1]);
    const open = c.isOpen();

    // ── Header ──────────────────────────────────────────────────────
    // Triangles, all of it. The chevron is diagonal so it can only be
    // `relief.stroke`, and the renderer draws the WHOLE triangle layer
    // beneath the WHOLE quad layer — a quad header band would hide its
    // own chevron. Same trap the slider's groove hit.
    try relief.shadeV(
        out,
        lc,
        origin[0],
        hy,
        w,
        HEADER_HEIGHT,
        c.color,
        .{ c.color[0], c.color[1], c.color[2], 0 },
    );
    // The seam along the bottom, cut then lit — `element_layout.seamRows`
    // by hand, because this one has to be ordered among the triangles
    // above rather than emitted as a divider block.
    try relief.rect(out, lc, origin[0], hy + HEADER_HEIGHT - 2, w, 1, HEADER_SEAM);
    try relief.rect(out, lc, origin[0], hy + HEADER_HEIGHT - 1, w, 1, HEADER_SEAM_LIGHT);

    const cx = @round(origin[0] + HEADER_PAD_X + CHEVRON_HALF);
    const cy = @round(hy + HEADER_HEIGHT * 0.5);
    const p = chevronPoints(cx, cy, open);
    try relief.stroke(out, lc, p[0], p[1], CHEVRON_WIDTH, CHEVRON);
    try relief.stroke(out, lc, p[1], p[2], CHEVRON_WIDTH, CHEVRON);

    const title_x = origin[0] + HEADER_PAD_X + CHEVRON_HALF * 2 + CHEVRON_GAP;
    const baseline_y = hy + (HEADER_HEIGHT - m.line_height) * 0.5 + m.ascender;
    if (c.title.len > 0) {
        const run = try shape.shapeUtf8(aa, hb, c.title);
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
            &out.glyph_targets,
            lc.current_target_dispatch_index,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            run,
            style.font_id,
            title_x,
            baseline_y,
            c.text,
            style.hot_color,
            style.attention,
            lc.zoom,
        );
    }

    // The header is the hit target, and only the header — clicking
    // inside the content must reach the content.
    const header_box: element.Box = .{
        .x = origin[0],
        .y = hy,
        .w = w,
        .h = HEADER_HEIGHT,
        .baseline = baseline_y,
    };
    try out.hits.append(.{
        .box = header_box,
        .vtable = &vtable,
        .ctx = @ptrCast(c),
        .state = lc.state,
    });

    // ── Content ─────────────────────────────────────────────────────
    // Folded: the subtree is not walked. Nothing draws, nothing takes a
    // hit, and every child instance is still alive with its bindings
    // live — see the header. This is `:::embedded-document`'s `headless`
    // with a title bar.
    if (!open) {
        c.last_box = header_box;
        return header_box;
    }

    const content_y = hy + HEADER_HEIGHT + CONTENT_GAP;
    const child_box = try element_layout.layoutAndRender(
        c.root,
        .{ origin[0], content_y },
        c.alignment.apply(constraints),
        lc,
        out,
    );

    const box: element.Box = .{
        .x = origin[0],
        .y = hy,
        .w = w,
        .h = (content_y + child_box.h) - hy,
        .baseline = baseline_y,
    };
    c.last_box = box;
    return box;
}

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_ptr: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .mouse_up => |mouse| {
            if (mouse.button != 0) return; // primary only

            // Flip the private flag ALWAYS, even when a `target=` is
            // going to be written as well. The two agree in the case
            // that matters (`open=${state.x} target=state.x`), where
            // `open_attr` shadows this anyway — and it means a fold
            // given a `target=` but no `open=` still visibly opens
            // rather than looking broken while writing correctly.
            c.open_self = !c.isOpen();

            // **Both of these, and the version is the one that bites.**
            //
            // `dirty` gets a frame drawn. `version` gets THIS BLOCK
            // re-walked: the retained layout cache is keyed on
            // `contentVersion`, so a fold whose open flag moved without
            // its version moving replays the drawlist it had when it was
            // shut. The frame is re-rendered and the section is still
            // closed.
            //
            // That was `cache-freeze` instance five, and it came in
            // through the door this component was NOT watching. The
            // header predicts a folded child's writes going unnoticed and
            // `foldVersion` aggregates children unconditionally to stop
            // it — while the fold's OWN visibility, which is the one
            // thing here that is not a child's business, was left out of
            // the key entirely.
            //
            // Chris found it, and the report is the mechanism: "if I try
            // to open the Result sub-panel, it does not open. However,
            // after clicking the group header, I now click on a button
            // like normal, or shadow from the previously opened panels,
            // the Result panel now unfolds." A sibling's click bumps a
            // CHILD's version, `foldVersion` XORs it in, the fold's key
            // finally moves, and it re-walks — already open, because the
            // flag flipped correctly two clicks ago.
            c.version +%= 1;
            if (c.spark) |sp| sp.host_state.dirty = true;

            if (c.target.len == 0) return;

            const state: *state_mod.State = @ptrCast(@alignCast(state_ptr));
            // What we write is what we just DID, not the negation of
            // what is at the path. Those differ on the very first click:
            // an unset path reads as closed while a fresh fold is open,
            // so re-deriving would write "open" at the moment of
            // closing. The header is authoritative about its own toggle,
            // and `isOpen()` already consulted the world on the way in.
            const next = button.flagValue(c.open_self);

            // Nothing may touch `c` after this line. `State.set`
            // notifies synchronously, so a fold with `open=${state.x}`
            // on the path it writes re-enters its own `ingest` here —
            // `adoptString` keeps that from freeing `c.target` mid-set.
            state.set(c.target, next) catch |e| {
                std.log.warn(":::fold: state.set failed: err={s}", .{@errorName(e)});
            };
        },
        else => {},
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// A Component with no parsed body, for the attribute and click logic.
/// `create` would need a live theme and registry to parse one; none of
/// what is under test here reads the tree.
fn testComponent() Component {
    return .{
        .allocator = testing.allocator,
        .title = undefined,
        .target = undefined,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = undefined,
    };
}

fn initStrings(c: *Component) !void {
    c.title = try testing.allocator.dupe(u8, "");
    c.target = try testing.allocator.dupe(u8, "");
}

fn freeStrings(c: *Component) void {
    testing.allocator.free(c.title);
    testing.allocator.free(c.target);
    c.arena.deinit();
}

test "fold: with no `open=` it remembers its own state, and starts open" {
    // The zero-plumbing case, which is the whole ergonomic point: a
    // panel with eight sections should not need eight state paths.
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const attrs = [_]components.Attr{.{ .key = "title", .value = "Surfaces" }};
    const spec: components.Spec = .{ .name = "fold", .attrs = &attrs };
    try c.ingest(&spec);

    try testing.expect(c.isOpen());
    c.open_self = false;
    try testing.expect(!c.isOpen());

    // And a re-ingest does NOT reset it. This is Chris's framing made
    // mechanical: a reload replaces the text, and the visibility was
    // never in the text to be lost.
    try c.ingest(&spec);
    try testing.expect(!c.isOpen());
}

test "fold: a static `open=0` starts it closed and then lets go" {
    // The case the "attribute always wins" rule cannot express: a
    // section that starts collapsed would be a section that shuts again
    // the instant you open it, because the unchanged attribute would
    // re-assert on the next re-resolve. That is the same shape as
    // `writeBack` re-asserting every mirror every frame, which is what
    // killed the bars panel — a value with two mouths.
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const attrs = [_]components.Attr{
        .{ .key = "title", .value = "Surfaces" },
        .{ .key = "open", .value = "0" },
    };
    const spec: components.Spec = .{ .name = "fold", .attrs = &attrs };
    try c.ingest(&spec);
    try testing.expect(!c.isOpen()); // seeded closed

    c.open_self = true; // the user opened it
    try c.ingest(&spec); // …and the document is re-resolved
    try testing.expect(c.isOpen()); // it stays open
}

test "fold: an `open=` that MOVES is obeyed, so a rill can fold a section" {
    // The other half. A bound `open=${state.x}` has to reach the fold
    // when something else moves the path, or a console line and a
    // gesture stop being equivalent — which is the shell's whole
    // premise.
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const open_attrs = [_]components.Attr{
        .{ .key = "title", .value = "Surfaces" },
        .{ .key = "open", .value = "1" },
    };
    const shut_attrs = [_]components.Attr{
        .{ .key = "title", .value = "Surfaces" },
        .{ .key = "open", .value = "0" },
    };
    const open_spec: components.Spec = .{ .name = "fold", .attrs = &open_attrs };
    const shut_spec: components.Spec = .{ .name = "fold", .attrs = &shut_attrs };

    try c.ingest(&open_spec);
    try testing.expect(c.isOpen());
    try c.ingest(&shut_spec);
    try testing.expect(!c.isOpen());
    try c.ingest(&open_spec);
    try testing.expect(c.isOpen());
}

test "fold: a click flips the private flag whether or not it also writes" {
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const attrs = [_]components.Attr{
        .{ .key = "title", .value = "Surfaces" },
        .{ .key = "target", .value = "state.fold_surfaces" },
    };
    const spec: components.Spec = .{ .name = "fold", .attrs = &attrs };
    try c.ingest(&spec);
    try testing.expectEqualStrings("fold_surfaces", c.target);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const click: element.InputEvent =
        .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } };

    // A `target=` with no `open=` is the easy mistake, and it must not
    // produce a fold that writes correctly and never visibly opens.
    try onInput(@ptrCast(&c), click, @ptrCast(&state));
    try testing.expect(!c.isOpen());
    try testing.expectEqualStrings("0", state.get("fold_surfaces").?);

    try onInput(@ptrCast(&c), click, @ptrCast(&state));
    try testing.expect(c.isOpen());
    try testing.expectEqualStrings("1", state.get("fold_surfaces").?);
}

test "fold: a title is required, because a bar with no name is a mystery" {
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);
    const spec: components.Spec = .{ .name = "fold" };
    try testing.expectError(Error.FoldMissingTitle, c.ingest(&spec));
}

test "fold: an ingest that changes nothing frees nothing" {
    // Same crash shape as the trackball's: a fold with
    // `open=${state.x} target=state.x` subscribes to the path it
    // writes, and `State.set` notifies synchronously.
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const attrs = [_]components.Attr{
        .{ .key = "title", .value = "Surfaces" },
        .{ .key = "target", .value = "state.f" },
        .{ .key = "open", .value = "1" },
    };
    const spec: components.Spec = .{ .name = "fold", .attrs = &attrs };
    try c.ingest(&spec);

    const title_ptr = c.title.ptr;
    const target_ptr = c.target.ptr;

    const attrs2 = [_]components.Attr{
        .{ .key = "title", .value = "Surfaces" },
        .{ .key = "target", .value = "state.f" },
        .{ .key = "open", .value = "0" }, // the one thing the write moved
    };
    const spec2: components.Spec = .{ .name = "fold", .attrs = &attrs2 };
    try c.ingest(&spec2);

    try testing.expectEqual(title_ptr, c.title.ptr);
    try testing.expectEqual(target_ptr, c.target.ptr);
    try testing.expect(!c.isOpen());
}

// The version-aggregation gate needs children that HAVE versions, so
// here is a custom element whose content_version is a variable.
var t_child_version: u64 = 0;

fn tChildVersion(_: *anyopaque) u64 {
    return t_child_version;
}

const t_child_vtable: element.ElementVTable = .{
    .layout_and_render = undefined,
    .content_version = tChildVersion,
};

test "fold: the version aggregates children even while the fold is closed" {
    // The prediction from `cache-freeze`, planted as a gate before the
    // bug: a cached ancestor replays while everything under it works,
    // and "a region that exists but does not draw" is the obvious fifth
    // home for it.
    //
    // The tempting implementation is `if (open) aggregate(children)` —
    // and it plants exactly that bug. A folded section's children go on
    // ingesting writes, the fold's version does not move, and the
    // expand serves whatever was cached when it closed: you open a
    // section and every control inside it shows a frame-one snapshot.
    //
    // This gate fails against that implementation and passes against
    // the one that aggregates regardless, which is the whole of it.
    var dummy: u8 = 0;
    const kids = [_]element.Element{
        .{ .custom = .{ .vtable = &t_child_vtable, .ctx = @ptrCast(&dummy) } },
    };

    t_child_version = 1;
    const closed_before = foldVersion(7, &kids);

    // The child moves while nobody is drawing it — a mirror binding
    // tracking the plane, which is exactly what a folded control does.
    t_child_version = 2;
    const closed_after = foldVersion(7, &kids);

    try testing.expect(closed_before != closed_after);
}

test "fold: chevron points right when closed and down when open" {
    // The one thing that would read as broken rather than look wrong.
    const closed = chevronPoints(100, 50, false);
    // Tip to the right of both arms, arms level above and below.
    try testing.expect(closed[1][0] > closed[0][0]);
    try testing.expect(closed[1][0] > closed[2][0]);
    try testing.expectApproxEqAbs(closed[0][0], closed[2][0], 1e-4);
    try testing.expect(closed[0][1] < closed[2][1]);

    const open = chevronPoints(100, 50, true);
    // Tip BELOW both arms, arms level left and right.
    try testing.expect(open[1][1] > open[0][1]);
    try testing.expect(open[1][1] > open[2][1]);
    try testing.expectApproxEqAbs(open[0][1], open[2][1], 1e-4);
    try testing.expect(open[0][0] < open[2][0]);
}

test "fold: a header click MOVES the version, or the cache replays it shut" {
    // `cache-freeze` instance five, and it came in through the door this
    // component was not watching. `foldVersion` aggregates children
    // unconditionally, which stops a folded child's writes going
    // unnoticed — and the fold's OWN visibility, the one thing here that
    // is not a child's business, was left out of the key entirely.
    //
    // The retained layout cache is keyed on `contentVersion`. A fold
    // whose open flag moved without its version moving replays the
    // drawlist it had when it was shut: the frame IS re-rendered, and
    // the section is still closed.
    //
    // Chris found it, and the report is the mechanism: "if I try to open
    // the Result sub-panel, it does not open. However, after clicking
    // the group header, I now click on a button like normal, or shadow
    // from the previously opened panels, the Result panel now unfolds."
    // A sibling's click bumps a CHILD's version, `foldVersion` XORs it
    // in, the key finally moves, and the fold re-walks — already open.
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const attrs = [_]components.Attr{.{ .key = "title", .value = "Result" }};
    const spec: components.Spec = .{ .name = "fold", .attrs = &attrs };
    try c.ingest(&spec);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    const click: element.InputEvent =
        .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } };

    const shut = contentVersion(@ptrCast(&c));
    try onInput(@ptrCast(&c), click, @ptrCast(&state));
    const open = contentVersion(@ptrCast(&c));
    try testing.expect(shut != open);

    // And back again — a version that only ever moved on the FIRST click
    // would fail closing just as surely as opening failed.
    try onInput(@ptrCast(&c), click, @ptrCast(&state));
    try testing.expect(contentVersion(@ptrCast(&c)) != open);
}

test "fold: a right-click moves neither the flag nor the version" {
    // The other half of the gate above: bumping unconditionally would
    // invalidate the block on every stray event that reaches it.
    var c = testComponent();
    try initStrings(&c);
    defer freeStrings(&c);

    const attrs = [_]components.Attr{.{ .key = "title", .value = "Result" }};
    const spec: components.Spec = .{ .name = "fold", .attrs = &attrs };
    try c.ingest(&spec);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const before = contentVersion(@ptrCast(&c));
    try onInput(@ptrCast(&c), .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 1, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqual(before, contentVersion(@ptrCast(&c)));
    try testing.expect(c.isOpen());
}
