//! `:::button` — clickable rectangle that fires a `:::update`-style
//! dispatch when its primary mouse button is released inside it
//! (stage 13b).
//!
//! Attribute grammar:
//!
//!     :::button {label="Run" target=#chat_local action=start width=120}
//!     :::
//!
//! - `label`  (required) — text rendered inside the button.
//! - `target` (required) — either:
//!     - `#id` (or bare `id`) of a component → fires
//!       `registry.handleUpdate(id, action, body)`, OR
//!     - `state.path` → writes `body` into the scope-local state at
//!       `path`. `action=` is ignored on this branch (kept for
//!       symmetry with the wire format).
//! - `action` (required for component-target) — the `action=NAME`
//!   passed through to the target's
//!   `Factory.handle_update(ctx, action, body)`.
//! - `body`   (optional) — passed verbatim as the update body / state
//!   value. Default empty.
//! - `width`  (optional) — pixel literal or `100%`. Default: intrinsic
//!   to the label width plus padding.
//! - `height` (optional) — pixel literal. Default 24.
//! - `radius` (optional) — corner radius. Default 1.5, i.e. square.
//!
//! ### The three ways a key says something
//!
//! - `active=` — a truthiness. "Is this thing ON." A toggle, or a dock
//!   button: `active=${state.up}`.
//! - `active_when=` — a value compared against `body=`. "Is this the
//!   CHOSEN one." A radio row: every key carries the same
//!   `active_when=${state.surf}` and a different `body=`.
//! - `flip=` — writes the negation of what is at `target` instead of
//!   `body=`, which is what lets an on/off key turn a thing off as well
//!   as on.
//!
//! ### The look
//!
//! A key on an instrument: square, dark, black-edged, quiet until it is
//! doing something. The fill is a NEUTRAL darkening rather than a colour
//! of its own — the same idiom `:::slider`'s recess uses — so a key takes
//! the tint of whatever panel it is on and looks cut from it rather than
//! glued to it. A hairline of light along the inside of the top edge
//! keeps it from reading as a hole, which is what the groove next to it
//! is deliberately meant to look like.
//!
//! Pressed is WARM, not a second hue: the grip and the dial home mark
//! are the shell'''s only other lit chrome and they are that orange, so
//! "this one is on" is one colour everywhere.
//!
//! ### Click → dispatch
//!
//! Wires `on_input` to receive mouse events; on `mouse_up` of button 0
//! (left):
//!   - **state-target** (`target=state.path`) writes `body` into the
//!     scope-local state passed in by the dispatcher. A button inside
//!     a child `:::embedded-document` therefore mutates *child* state,
//!     not the host's — matching slider scoping (stage-9 follow-up).
//!   - **component-target** (`target=#id`) calls
//!     `registry.handleUpdate(target, action, body)` against the host
//!     registry, which is what we want (a button in a child doc that
//!     triggers a parent-scope or sibling-scope component, etc).
//!
//! Hover state is not yet plumbed — `mouse_move` doesn't propagate
//! until the hit-test layer carries a "mouse entered" event. v0 button
//! is constant colour. Real hover lands when we wire enter/leave
//! signals.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    ButtonMissingLabel,
    ButtonMissingTarget,
    ButtonMissingAction,
    ButtonNotInstalled,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("button", factory);
}

/// Whether an `active=` value means "pressed".
///
/// The values that reach this are whatever a host wrote into state, and
/// the one that matters is a plane readback: `hud/mounted/surfaces`
/// arrives as `{d}` on an f32, so `0` and `1`. The word forms are here
/// because a document may write them by hand with `target=state.x`, and
/// `active=false` rendering as pressed would be a small betrayal.
///
/// Anything unrecognised is TRUE, which is the right way round: `active=`
/// is opt-in, so the attribute is only present when somebody meant
/// something by it, and an unfamiliar truthy spelling should light the
/// button rather than silently do nothing.
pub fn isTruthy(value: []const u8) bool {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len == 0) return false;
    for ([_][]const u8{ "0", "false", "no", "off" }) |falsey| {
        if (std.ascii.eqlIgnoreCase(v, falsey)) return false;
    }
    // `0`, `0.0`, `0.000` — a float that reads as zero is not pressed.
    if (std.fmt.parseFloat(f64, v)) |n| {
        if (n == 0) return false;
    } else |_| {}
    return true;
}

/// How a flag is SPELLED when written back into state.
///
/// One function so `:::button {flip}`, `:::checkbox` and `:::fold` agree,
/// because the spelling is load-bearing rather than cosmetic:
/// matryoshka's `Panel.writeBack` parses document state with `parseFloat`
/// before pushing at the plane, so a `"true"` is a write that silently
/// never lands. `isTruthy` still READS the word forms, because a document
/// may have authored one by hand.
pub fn flagValue(on: bool) []const u8 {
    return if (on) "1" else "0";
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    target: []u8, // stripped of leading `#`
    action: []u8,
    body: []u8,
    /// A host console line, run on click. See the `cmd=` arm in
    /// `onInput` — this is the third target kind, and the only one
    /// that reaches outside the document.
    cmd: []u8,
    width: ?box_helpers.Length, // null = intrinsic
    height: f32,
    /// Corner radius in pixels, same unit as `:::box` and every effect.
    /// Was a hardcoded constant until 2026-08-31, which made the button
    /// the one panel-ish thing in the vocabulary whose corners a document
    /// could not name.
    radius: f32 = BUTTON_RADIUS,
    /// A glyph drawn to the left of the label. Empty for none.
    ///
    /// An attribute rather than a body, deliberately. `:::button` has
    /// never rendered its body — `body=` is the dispatch payload — and
    /// teaching it to lay out arbitrary children would make every button
    /// a layout container to give a handful of them a symbol. One string,
    /// shaped in the same font as the label, is the whole of what a dock
    /// button actually wants.
    icon: []u8,
    /// Write the NEGATION of what is at `target` instead of `body`.
    ///
    /// The missing half of a toggle button. `body=` is a CONSTANT, so an
    /// on/off pair could light its ON half and never its OFF half —
    /// `hud/fx.md` is the worked example and says so in its own
    /// frontmatter. `flip` reads what is there at click time and writes
    /// the other one, which is the whole primitive a checkbox needs too.
    ///
    /// It writes `"1"` / `"0"`, never `"true"` / `"false"`, and that is
    /// not a spelling preference: matryoshka's `Panel.writeBack` parses
    /// document state with `parseFloat` before pushing it at the plane,
    /// so a `"true"` is a write that silently never reaches anything.
    /// `isTruthy` still READS the word forms, because a document may
    /// have authored one by hand.
    flip: bool = false,
    /// Whether to draw the PRESSED look.
    ///
    /// Read from an attribute rather than tracked internally, because
    /// what makes a toggle button look pressed is not the click — it is
    /// whether the thing it toggles is currently on, and only the
    /// document knows that. `active=${state.up}` with
    /// `up: read hud/mounted/surfaces` in the frontmatter is a dock
    /// button that lights up because its applet is open, including when
    /// something else opened it.
    active: bool = false,
    /// Light the key when this value EQUALS its `body=`.
    ///
    /// The missing piece of a RADIO ROW. `active=` takes a truthiness,
    /// which answers "is this thing on" — the right question for a
    /// toggle and the wrong one for one-of-N, where every key in the row
    /// would light at once. `active_when=${state.surf}` on a key whose
    /// `body=albedo` lights exactly when the thing being selected IS
    /// albedo, and the row becomes a control that shows its own value.
    ///
    /// `hud/xray.md` has thirty-four buttons in eight such rows and
    /// until this existed not one of them could say which was chosen;
    /// the panel had to spell it out in a sentence underneath instead.
    ///
    /// A row of these is also what a combo box degrades to, and worth
    /// weighing before building an overlay layer for the real thing.
    active_when: []u8,
    /// The six colours a key wears — resting fill/border/ink, then the
    /// same three for pressed. Attributes for the reason `:::slider`'s
    /// are: a shell that themes its sliders and not its buttons is a
    /// shell with one rule and one exception.
    ///
    /// No `palette_version` here, unlike the slider: `ingest` already
    /// bumps `version` unconditionally, so the retained cache re-walks
    /// on any attribute change including these.
    color: [4]f32 = BUTTON_BG,
    border: [4]f32 = BUTTON_BORDER,
    text: [4]f32 = BUTTON_LABEL,
    active_color: [4]f32 = BUTTON_BG_ACTIVE,
    active_border: [4]f32 = BUTTON_BORDER_ACTIVE,
    active_text: [4]f32 = BUTTON_LABEL_ACTIVE,
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Bumped on every spec ingest so the retained layout cache
    /// re-walks the button when its attrs change.
    version: u64 = 0,
    /// Captured at create time. `onInput` reaches the registry
    /// through it to dispatch component-target actions.
    spark: ?*spark_mod.Spark = null,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var label_raw: ?[]const u8 = null;
        var target_raw: ?[]const u8 = null;
        var action_raw: ?[]const u8 = null;
        var body_raw: []const u8 = "";
        var cmd_raw: []const u8 = "";
        var icon_raw: []const u8 = "";
        var active_opt: bool = false;
        var active_when_raw: []const u8 = "";
        var flip_opt: bool = false;
        var width_opt: ?box_helpers.Length = self.width;
        var height_opt: f32 = self.height;
        var radius_opt: f32 = self.radius;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "action")) {
                action_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "body")) {
                body_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "cmd")) {
                cmd_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "icon")) {
                icon_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "active")) {
                active_opt = isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "active_when")) {
                active_when_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "flip")) {
                flip_opt = isTruthy(attr.value);
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.color = v;
            } else if (std.mem.eql(u8, attr.key, "border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.border = v;
            } else if (std.mem.eql(u8, attr.key, "text")) {
                if (box_helpers.parseColor(attr.value)) |v| self.text = v;
            } else if (std.mem.eql(u8, attr.key, "active_color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.active_color = v;
            } else if (std.mem.eql(u8, attr.key, "active_border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.active_border = v;
            } else if (std.mem.eql(u8, attr.key, "active_text")) {
                if (box_helpers.parseColor(attr.value)) |v| self.active_text = v;
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| width_opt = l;
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    height_opt = switch (l) {
                        .pixels => |p| p,
                        else => height_opt,
                    };
                }
            } else if (std.mem.eql(u8, attr.key, "radius")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    radius_opt = switch (l) {
                        .pixels => |p| @max(0, p),
                        else => radius_opt,
                    };
                }
            }
        }

        const label = label_raw orelse return Error.ButtonMissingLabel;
        // `cmd=` is a target in its own right, so it satisfies the
        // requirement that a button DO something. A button with neither
        // is still refused — it looks like a control and is not one,
        // which is worse than a parse error.
        const target_full = target_raw orelse
            (if (cmd_raw.len > 0) "" else return Error.ButtonMissingTarget);

        const target = if (target_full.len > 0 and target_full[0] == '#')
            target_full[1..]
        else
            target_full;

        // `action=` is required for component-target dispatch (the
        // callee's `handle_update` arms switch on it). State-target
        // dispatch ignores it — there's a single primitive verb (write
        // body into state.path) — so leave it as a courtesy empty
        // string when absent.
        const is_state_target = std.mem.startsWith(u8, target, "state.");
        const action = if (is_state_target or target.len == 0)
            action_raw orelse ""
        else
            action_raw orelse return Error.ButtonMissingAction;

        // `adoptString` rather than free-and-dupe, because a toggle
        // button is its own subscriber: `target=state.x flip=1
        // active=${state.x}` writes a path whose value it also
        // interpolates, and `State.set` notifies synchronously, so the
        // click re-enters this function while `onInput` is still
        // holding a slice of `self.target`. Unconditional frees are how
        // the trackball crashed. See `component.adoptString`.
        //
        // What remains exposed is a target or body that is ITSELF
        // interpolated from the path being written (`body=${state.mode}`
        // on `target=state.mode`) — then the text genuinely differs and
        // the free is genuine. `flip` sidesteps it by writing from a
        // stack buffer rather than from `self.body`; nobody has written
        // the `target=state.${...}` form and it would want its own fix.
        try component_mod.adoptString(a, &self.label, label);
        try component_mod.adoptString(a, &self.target, target);
        try component_mod.adoptString(a, &self.action, action);
        try component_mod.adoptString(a, &self.body, body_raw);
        try component_mod.adoptString(a, &self.cmd, cmd_raw);
        try component_mod.adoptString(a, &self.icon, icon_raw);
        try component_mod.adoptString(a, &self.active_when, active_when_raw);
        // Either route lights the key. `active=` answers "is this on",
        // `active_when=` answers "is this the chosen one"; a key that
        // wanted both would be a toggle inside a radio row, which is not
        // a thing, so OR is the whole of the interaction.
        //
        // An empty `body=` never matches, or a row of `cmd=`-only keys
        // (which carry no body) would all light the moment anything
        // resolved `active_when` to the empty string.
        self.active = active_opt or
            (body_raw.len > 0 and std.mem.eql(u8, active_when_raw, body_raw));
        self.flip = flip_opt;
        self.width = width_opt;
        self.height = height_opt;
        self.radius = radius_opt;
        self.version +%= 1;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .spark = spark,
        .label = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, ""),
        .action = try allocator.dupe(u8, ""),
        .body = try allocator.dupe(u8, ""),
        .cmd = try allocator.dupe(u8, ""),
        .icon = try allocator.dupe(u8, ""),
        .active_when = try allocator.dupe(u8, ""),
        .width = null,
        .height = BUTTON_DEFAULT_HEIGHT,
    };
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.label);
    allocator.free(c.target);
    allocator.free(c.action);
    allocator.free(c.body);
    allocator.free(c.cmd);
    allocator.free(c.icon);
    allocator.free(c.active_when);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Visual constants ────────────────────────────────────────────────

// A button is a KEY on an instrument: square, dark, black-edged, and
// quiet until it is doing something. It used to be a rounded blue pill,
// which read as a web form dropped onto a grading panel — Chris,
// 2026-09-01: "these blue buttons on our gorgeous new panels look a bit
// incongruous and cartoonish. I'm thinking square and dark with a black
// border."
//
// The fill is a NEUTRAL darkening rather than a colour, the same idiom
// `:::slider`'s recess and `:::color_bars`' tracks use: it takes the
// tint of whatever panel it is on instead of imposing one, so a key
// looks like it was cut from that panel rather than glued to it.

const BUTTON_BG: [4]f32 = .{ 0.0, 0.0, 0.0, 0.34 };
/// Nearly black, and opaque. This is the line that makes a key read as a
/// separate object on a translucent panel; letting the panel through it
/// would blur the two together.
const BUTTON_BORDER: [4]f32 = .{ 0.02, 0.02, 0.03, 0.92 };
const BUTTON_LABEL: [4]f32 = .{ 0.86, 0.87, 0.91, 1.0 };
/// A hairline of light along the inside of the top edge. Without it a
/// dark key inside a black border reads as a HOLE — which is exactly
/// what the groove idiom next to it is meant to look like, and a button
/// must not be confusable with a slot.
const BUTTON_TOP_LIGHT: [4]f32 = .{ 1.0, 1.0, 1.0, 0.07 };
/// The same hairline on a lit key, warm and a little stronger.
const BUTTON_LABEL_ACTIVE_EDGE: [4]f32 = .{ 1.0, 0.80, 0.35, 0.16 };

/// The PRESSED palette. Warm, because the only other lit chrome on a
/// panel is the grip and the dial's home mark, and they are this orange
/// — so "this one is on" is the same colour everywhere in the shell.
/// Still dark: a toggle reads from its EDGE and its label, not from
/// becoming a lamp.
const BUTTON_BG_ACTIVE: [4]f32 = .{ 0.42, 0.26, 0.02, 0.55 };
const BUTTON_BORDER_ACTIVE: [4]f32 = .{ 1.0, 0.68, 0.0, 0.90 };
const BUTTON_LABEL_ACTIVE: [4]f32 = .{ 1.0, 0.88, 0.62, 1.0 };
const BUTTON_BORDER_PX: f32 = 1.0;
/// A pressed button's border, thicker so the state survives being read
/// past — the fill alone is a subtle cue on a translucent dock.
const BUTTON_BORDER_PX_ACTIVE: f32 = 1.5;
/// Square, near enough. Not a true zero: at one pixel the corner still
/// gets the quad shader's anti-aliasing, so the edge is clean rather
/// than stair-stepped, and nobody can see the difference in the shape.
const BUTTON_RADIUS: f32 = 1.5;
/// Both of these were nearly twice as big, which is what made a
/// two-word key the size of a slider. Chris: "I notice a lot of padding
/// on the internals."
const BUTTON_PAD_X: f32 = 9;
const BUTTON_DEFAULT_HEIGHT: f32 = 24;
/// Between an `icon=` glyph and the label beside it.
const BUTTON_ICON_GAP: f32 = 6;

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
    const run = try shape.shapeUtf8(aa, hb, c.label);
    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    // The icon is shaped in the same font and treated as a second run, so
    // it advances and centres by the same arithmetic as the label rather
    // than by a guessed square.
    const icon_run = if (c.icon.len > 0) try shape.shapeUtf8(aa, hb, c.icon) else null;
    var icon_w: f32 = 0;
    if (icon_run) |ir| {
        for (ir.glyphs) |g| icon_w += g.x_advance * fscale;
    }
    const gap: f32 = if (icon_run != null and c.label.len > 0) BUTTON_ICON_GAP else 0;
    const content_w = icon_w + gap + text_w;

    const intrinsic_w = content_w + 2 * BUTTON_PAD_X;
    const max_w = constraints.max_w;
    const fallback_w = if (std.math.isFinite(max_w)) max_w else intrinsic_w;
    const w: f32 = if (c.width) |wl| wl.resolve(max_w, fallback_w) else intrinsic_w;
    const h = c.height;

    const border_col = if (c.active) c.active_border else c.border;
    const bg_col = if (c.active) c.active_color else c.color;
    const label_col = if (c.active) c.active_text else c.text;
    const border_px = if (c.active) BUTTON_BORDER_PX_ACTIVE else BUTTON_BORDER_PX;

    // Border + body
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = border_col,
        .radius = c.radius,
    });
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + border_px, origin[1] + border_px },
        .dst_size = .{ w - 2 * border_px, h - 2 * border_px },
        .color = bg_col,
        .radius = @max(0, c.radius - border_px),
    });
    // The lit top edge — see `BUTTON_TOP_LIGHT`. Inset by the border so
    // it sits just inside the black line, which is where a bevel would
    // catch the light if this were a real key.
    if (h > 2 * border_px + 2) {
        try out.appendQuad(lc, .{
            .dst_pos = .{ origin[0] + border_px + 1, origin[1] + border_px },
            .dst_size = .{ @max(0, w - 2 * border_px - 2), 1 },
            .color = if (c.active) BUTTON_LABEL_ACTIVE_EDGE else BUTTON_TOP_LIGHT,
            .radius = 0,
        });
    }

    // Icon then label, centred as ONE group — so adding an icon shifts
    // the label rather than knocking the pair off centre.
    const m = lc.fonts.metrics(style.font_id);
    const baseline_y = origin[1] + (h - m.line_height) * 0.5 + m.ascender;
    const content_x = origin[0] + (w - content_w) * 0.5;
    if (icon_run) |ir| {
        _ = try text_layout.appendShapedRun(
            &out.glyphs,
            &out.glyph_targets,
            lc.current_target_dispatch_index,
            lc.fonts,
            lc.cache,
            lc.mono_atlas,
            lc.color_atlas,
            lc.glyph_cache_lock,
            ir,
            style.font_id,
            content_x,
            baseline_y,
            label_col,
            style.hot_color,
            style.attention,
            lc.zoom,
        );
    }
    const text_x = content_x + icon_w + gap;
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
        text_x,
        baseline_y,
        label_col,
        style.hot_color,
        style.attention,
        lc.zoom,
    );

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = baseline_y,
    };
    c.last_box = box;

    // Register as hit target — emits a Hit so the dispatcher can
    // route mouse events to onInput.
    try out.hits.append(.{
        .box = box,
        .vtable = &vtable,
        .ctx = @ptrCast(c),
        .state = lc.state,
    });

    return box;
}

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_ptr: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .mouse_up => |m| {
            if (m.button != 0) return; // primary only

            // `cmd=` — a HOST console line, run on click. The third
            // target kind, and the only one that reaches outside the
            // document: `hud mount`, `rill mount`, `write`, anything
            // the host's own console takes.
            //
            // FIRST, and deliberately so: a button may carry both a
            // `cmd` and a state write (light a "selected" flag while
            // also doing the thing), and the state write must not be
            // skipped because the command arm returned. They compose.
            //
            // spark hands the line over and stops caring — it does not
            // know what a command is. `Spark.sendCommand` is a no-op on
            // a host that installed no sink, so a document carried
            // somewhere else has visibly-a-button that inertly does
            // nothing, rather than a crash.
            if (c.cmd.len > 0) {
                if (c.spark) |sp| sp.sendCommand(c.cmd);
            }

            if (c.target.len == 0) return;

            // State-target: `target=state.path` writes `body` into the
            // scope-local state. `action` is ignored — the wire format
            // accepts it for symmetry with component-target, but state
            // mutation is a single primitive verb.
            if (std.mem.startsWith(u8, c.target, "state.")) {
                const key = c.target["state.".len..];
                if (key.len == 0) return;
                const state: *state_mod.State = @ptrCast(@alignCast(state_ptr));

                // `flip=` READS before it writes; `body=` does not read
                // at all. The flipped value lives in a stack buffer on
                // purpose — see the ordering note below.
                var flipped: [1]u8 = undefined;
                const value: []const u8 = if (c.flip) blk: {
                    const cur = state.get(key) orelse "";
                    flipped[0] = if (isTruthy(cur)) '0' else '1';
                    break :blk flipped[0..1];
                } else c.body;

                // NOTHING may touch `c` after this line, and nothing
                // does. `State.set` notifies subscribers synchronously,
                // so a button carrying `active=${state.x}` on the path
                // it writes re-enters its own `ingest` from inside this
                // call. `adoptString` keeps that from freeing `key` out
                // from under `set` (which hashes it twice); returning
                // straight after keeps us from needing anything else.
                state.set(key, value) catch |e| {
                    std.log.warn(":::button: state.set failed: err={s}", .{@errorName(e)});
                };
                return;
            }

            // Component-target.
            if (c.action.len == 0) return;
            const sp = c.spark orelse return;
            sp.registry.handleUpdate(c.target, c.action, c.body) catch |e| {
                std.log.warn(":::button: dispatch failed: target=#{s} action={s} err={s}", .{
                    c.target, c.action, @errorName(e),
                });
            };
        },
        else => {},
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

var _test_spark = spark_mod.Spark.testStub(testing.allocator);

test "button: ingest stores label/target/action/body, strips # from target" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Run" },
        .{ .key = "target", .value = "#chat_local" },
        .{ .key = "action", .value = "start" },
        .{ .key = "body", .value = "go" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };

    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("Run", c.label);
    try testing.expectEqualStrings("chat_local", c.target); // # stripped
    try testing.expectEqualStrings("start", c.action);
    try testing.expectEqualStrings("go", c.body);
}

test "button: missing label rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "#x" },
        .{ .key = "action", .value = "go" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    try testing.expectError(Error.ButtonMissingLabel, create(&_test_spark, testing.allocator, &spec));
}

test "button: missing target rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "action", .value = "go" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    try testing.expectError(Error.ButtonMissingTarget, create(&_test_spark, testing.allocator, &spec));
}

test "button: missing action rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "target", .value = "y" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    try testing.expectError(Error.ButtonMissingAction, create(&_test_spark, testing.allocator, &spec));
}

test "button: update re-ingests attrs (label change)" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Old" },
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "New" },
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("New", c.label);
}

test "button: state-target dispatch writes body into state.path" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Hide" },
        .{ .key = "target", .value = "state.config_hidden" },
        .{ .key = "body", .value = "true" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };

    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));

    try testing.expectEqualStrings("true", state.get("config_hidden").?);
    try testing.expect(state.dirty);
}

test "button: state-target accepts missing action" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "target", .value = "state.foo" },
        .{ .key = "body", .value = "bar" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    // No `action=` attr supplied — must NOT return ButtonMissingAction.
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("state.foo", c.target);
    try testing.expectEqualStrings("", c.action);
}

test "button: state-target ignores right-mouse and key events" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "target", .value = "state.foo" },
        .{ .key = "body", .value = "1" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };

    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    // Right button shouldn't fire.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 1, .button_down = false } }, @ptrCast(&state));
    try testing.expect(state.get("foo") == null);
}

// ── `cmd=` — a button that runs a host console line ─────────────────
// The third target kind, and the only one reaching outside the
// document. What makes it safe is that spark HANDS THE LINE OVER and
// stops: the host queues it and runs it where nothing is mid-walk. See
// `spark.CommandSink`.

/// A sink that records what it was handed, so a test can assert on it.
const CmdProbe = struct {
    var seen: [4][128]u8 = undefined;
    var seen_len: [4]usize = .{ 0, 0, 0, 0 };
    var count: usize = 0;

    fn reset() void {
        count = 0;
        seen_len = .{ 0, 0, 0, 0 };
    }

    fn sink(ctx: *anyopaque, line: []const u8) void {
        _ = ctx;
        if (count >= seen.len) return;
        const n = @min(line.len, seen[count].len);
        @memcpy(seen[count][0..n], line[0..n]);
        seen_len[count] = n;
        count += 1;
    }

    fn last() []const u8 {
        if (count == 0) return "";
        return seen[count - 1][0..seen_len[count - 1]];
    }
};

test "button: cmd= hands its line to the host's sink, verbatim" {
    // Verbatim matters. spark does not parse, validate, normalise or
    // even trim a command — it does not know what a command IS. A line
    // that arrives at the host altered is a line the host's own console
    // would have taken and this path would not, which is exactly the
    // kind of divergence that makes a control surface untrustworthy.
    CmdProbe.reset();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    sp.setCommandSink(@ptrCast(&sp), CmdProbe.sink);

    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Normals" },
        .{ .key = "cmd", .value = "write hud/panels/0/x 0.5" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&sp, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));

    try testing.expectEqual(@as(usize, 1), CmdProbe.count);
    try testing.expectEqualStrings("write hud/panels/0/x 0.5", CmdProbe.last());
}

test "button: cmd= alone is a complete button — no target, no action" {
    // `target=` used to be mandatory, and `action=` mandatory after it.
    // A command button has neither and must still build; the failure
    // this guards is a create() that returns ButtonMissingTarget and
    // leaves the author with a placeholder where their button was.
    CmdProbe.reset();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    sp.setCommandSink(@ptrCast(&sp), CmdProbe.sink);

    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Unmount" },
        .{ .key = "cmd", .value = "hud unmount debug" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&sp, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqualStrings("hud unmount debug", CmdProbe.last());

    // ...and a button with NEITHER is still refused. Rule 1: the
    // relaxation above must not have relaxed everything, or a typo'd
    // attribute name produces a control that looks live and is inert.
    const bare = [_]components.Attr{.{ .key = "label", .value = "Nothing" }};
    const bare_spec: components.Spec = .{ .name = "button", .attrs = &bare };
    try testing.expectError(Error.ButtonMissingTarget, create(&sp, testing.allocator, &bare_spec));
}

test "button: cmd= and a state write COMPOSE — one click does both" {
    // A button that lights its own "selected" flag while also running
    // the command. The command arm returns early in the obvious
    // implementation, and then the state write silently never happens —
    // which reads as a button that works but never looks pressed.
    CmdProbe.reset();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    sp.setCommandSink(@ptrCast(&sp), CmdProbe.sink);

    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Albedo" },
        .{ .key = "cmd", .value = "hud mount gb demos/hud-lab/gbuffer-albedo.md" },
        .{ .key = "target", .value = "state.surface" },
        .{ .key = "body", .value = "albedo" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&sp, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));

    try testing.expectEqualStrings("hud mount gb demos/hud-lab/gbuffer-albedo.md", CmdProbe.last());
    try testing.expectEqualStrings("albedo", state.get("surface").?);
}

test "button: a cmd on a host with NO sink does nothing and does not crash" {
    // The portability claim. A `debug.md` written for matryoshka opened
    // on a host that installed no sink is a visible button that inertly
    // does nothing — not a null-call, and not a refusal to parse the
    // document it sits in.
    CmdProbe.reset();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    // No setCommandSink.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Go" },
        .{ .key = "cmd", .value = "hud unmount debug" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&sp, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqual(@as(usize, 0), CmdProbe.count);
}

// ── `active=` and `icon=` — the togglable dock button ───────────────

test "button: active= reads the plane's 0/1 the way a `read` binding writes it" {
    // The value that actually arrives. `hud/mounted/surfaces` is an f32
    // published by the host and formatted `{d}` by the bridge, so these
    // two spellings are the whole contract — and getting `0` wrong means
    // every dock button is lit from the moment the dock opens.
    try testing.expect(!isTruthy("0"));
    try testing.expect(isTruthy("1"));

    // Written by hand with `target=state.x`, which a document may do.
    try testing.expect(!isTruthy("false"));
    try testing.expect(!isTruthy("FALSE"));
    try testing.expect(!isTruthy("off"));
    try testing.expect(!isTruthy("no"));
    try testing.expect(isTruthy("true"));
    try testing.expect(isTruthy("yes"));

    // Absent or blank is not pressed — the overwhelmingly common case,
    // since every button written before `active=` existed has neither.
    try testing.expect(!isTruthy(""));
    try testing.expect(!isTruthy("   "));

    // A float that reads as zero. `{d}` will not produce these, but a
    // document interpolating a slider might, and `active=0.0` lighting
    // the button would be a lie about a number the author can see.
    try testing.expect(!isTruthy("0.0"));
    try testing.expect(!isTruthy("0.000"));
    try testing.expect(isTruthy("0.5"));
}

test "button: active= and icon= survive an ingest, and default to off/none" {
    // The re-ingest is the whole point: `active=${state.up}` is
    // substituted at parse and re-fired when that state changes, so a
    // button that did not pick the new value up on `update` would light
    // once at mount and then never change again.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "X-ray" },
        .{ .key = "cmd", .value = "hud toggle surfaces" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(!c.active);
    try testing.expectEqualStrings("", c.icon);

    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "X-ray" },
        .{ .key = "cmd", .value = "hud toggle surfaces" },
        .{ .key = "icon", .value = "◉" },
        .{ .key = "active", .value = "1" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);
    try testing.expect(c.active);
    try testing.expectEqualStrings("◉", c.icon);

    // And back off again — a toggle has to work in both directions, and
    // a one-way latch would leave every button lit after its first open.
    const attrs3 = [_]components.Attr{
        .{ .key = "label", .value = "X-ray" },
        .{ .key = "cmd", .value = "hud toggle surfaces" },
        .{ .key = "icon", .value = "◉" },
        .{ .key = "active", .value = "0" },
    };
    const spec3: components.Spec = .{ .name = "button", .attrs = &attrs3 };
    try update(inst.ctx, &spec3);
    try testing.expect(!c.active);
}

test "button: an ingest bumps the version, so the retained cache re-walks it" {
    // The cache-freeze family, one more time. The layout cache keys a
    // custom element on `content_version`, so a button whose `active=`
    // changed but whose version did not would keep drawing its old
    // colours — the exact shape of the four bugs the readout campaign
    // closed, and the reason this is asserted rather than assumed.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "X-ray" },
        .{ .key = "cmd", .value = "hud toggle surfaces" },
        .{ .key = "active", .value = "0" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const before = contentVersion(inst.ctx);

    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "X-ray" },
        .{ .key = "cmd", .value = "hud toggle surfaces" },
        .{ .key = "active", .value = "1" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);
    try testing.expect(contentVersion(inst.ctx) != before);
}

test "button: a cmd fires on RELEASE only, and only for the primary button" {
    // A command button reaches outside the document, so the discipline
    // the other arms already keep matters more here: a right-click or a
    // press-without-release must not mount a document or unmount one.
    CmdProbe.reset();
    var sp = spark_mod.Spark.testStub(testing.allocator);
    sp.setCommandSink(@ptrCast(&sp), CmdProbe.sink);
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Go" },
        .{ .key = "cmd", .value = "hud unmount debug" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&sp, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 0, 0 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqual(@as(usize, 0), CmdProbe.count);
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 1, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqual(@as(usize, 0), CmdProbe.count);
    // ...and the release that SHOULD fire, so this is not passing on a
    // button that never fires at all.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqual(@as(usize, 1), CmdProbe.count);
}

test "button: flip writes the negation of what is already at the path" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Grid" },
        .{ .key = "target", .value = "state.grid" },
        .{ .key = "flip", .value = "1" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const click: element.InputEvent =
        .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } };

    // Unset reads as off, so the first click turns it ON. A toggle
    // whose first click did nothing visible is the bug a user reports
    // as "I have to click it twice".
    try onInput(inst.ctx, click, @ptrCast(&state));
    try testing.expectEqualStrings("1", state.get("grid").?);

    try onInput(inst.ctx, click, @ptrCast(&state));
    try testing.expectEqualStrings("0", state.get("grid").?);

    try onInput(inst.ctx, click, @ptrCast(&state));
    try testing.expectEqualStrings("1", state.get("grid").?);
}

test "button: flip reads the plane's float spellings, and writes one back" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Surfaces" },
        .{ .key = "target", .value = "state.up" },
        .{ .key = "flip", .value = "1" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    const click: element.InputEvent =
        .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } };

    // A plane readback arrives as `{d}` on an f32 — `hud/mounted/*` is
    // literally "0" or "1", but a mirror of a real knob can be "0.000".
    try state.set("up", "0.000");
    try onInput(inst.ctx, click, @ptrCast(&state));
    // And what goes back is "1", NOT "true": `Panel.writeBack` parses
    // document state with parseFloat before pushing it at the plane, so
    // a word here is a write that silently never lands.
    try testing.expectEqualStrings("1", state.get("up").?);

    try state.set("up", "true");
    try onInput(inst.ctx, click, @ptrCast(&state));
    try testing.expectEqualStrings("0", state.get("up").?);
}

test "button: an ingest that changes nothing frees nothing" {
    // The trackball segfault, one level down. `State.set` notifies
    // synchronously, so a toggle button (`target=state.x flip=1
    // active=${state.x}`) re-enters its own ingest from inside the
    // click, while `onInput` still holds a slice of `self.target`.
    // Unconditional free-and-dupe is what made that dangle.
    //
    // The gate is pointer identity: same text in, same allocation out.
    // Against the old ingest every one of these differs.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Grid" },
        .{ .key = "target", .value = "state.grid" },
        .{ .key = "flip", .value = "1" },
        .{ .key = "active", .value = "0" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const label_ptr = c.label.ptr;
    const target_ptr = c.target.ptr;
    const body_ptr = c.body.ptr;

    // What a re-entrant update looks like: every string identical, only
    // `active=` flipped — which is exactly what the state write changed.
    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "Grid" },
        .{ .key = "target", .value = "state.grid" },
        .{ .key = "flip", .value = "1" },
        .{ .key = "active", .value = "1" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);

    try testing.expectEqual(label_ptr, c.label.ptr);
    try testing.expectEqual(target_ptr, c.target.ptr);
    try testing.expectEqual(body_ptr, c.body.ptr);
    try testing.expect(c.active); // the one thing that DID change
}

test "button: an ingest that changes the text still replaces it" {
    // The other half — a guard that never replaces is a guard that
    // breaks hot reload, which is worse than the crash it prevents.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Old" },
        .{ .key = "target", .value = "state.a" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "New" },
        .{ .key = "target", .value = "state.b" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);
    try testing.expectEqualStrings("New", c.label);
    try testing.expectEqualStrings("state.b", c.target);
}

test "button: active_when lights exactly the key whose body matches" {
    // The radio row. `hud/xray.md` has eight of them and until this
    // existed not one could say which of its keys was chosen — the panel
    // spelled it out in a sentence underneath instead.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "albedo" },
        .{ .key = "target", .value = "state.surf" },
        .{ .key = "body", .value = "albedo" },
        .{ .key = "active_when", .value = "albedo" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(c.active);

    // The sibling key in the same row, with the same `active_when`.
    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "albedo" },
        .{ .key = "target", .value = "state.surf" },
        .{ .key = "body", .value = "depth" },
        .{ .key = "active_when", .value = "albedo" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);
    try testing.expect(!c.active);
}

test "button: active_when never lights a key with no body" {
    // A row of `cmd=`-only keys carries no `body=`, so an `active_when`
    // resolving to the empty string would light every one of them at
    // once — which is the failure mode `active=` already had and the
    // reason this attribute exists.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "◀" },
        .{ .key = "cmd", .value = "write hud/panels/0/x 0.05" },
        .{ .key = "active_when", .value = "" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(!c.active);
}

test "button: active= still lights on its own, alongside active_when" {
    // Either route lights the key. Adding the radio arm must not break
    // the dock buttons, which are all `active=${state.up}`.
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Surfaces" },
        .{ .key = "cmd", .value = "hud toggle surfaces" },
        .{ .key = "active", .value = "1" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expect(c.active);
}
