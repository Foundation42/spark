//! `:::input` — single-line editable text field that dispatches on
//! Enter (stage 13c). Counterpart to `:::button`: button fires a
//! fixed `body=...` literal at its target; input fires whatever the
//! user typed.
//!
//! Attribute grammar:
//!
//!     :::input {target=#chat_local action=start placeholder="Ask…" width=480}
//!     :::
//!
//! - `target` (required) — either:
//!     - `#id` (or bare `id`) of a component → fires
//!       `registry.handleUpdate(id, action, buffer)`, OR
//!     - `state.path` → writes the buffer into the scope-local state at
//!       `path`. `action=` is ignored on this branch.
//! - `action` (required for component-target) — verb passed to the
//!   target's `Factory.handle_update(ctx, action, body)`. Pair this with
//!   the already-supported `start` action on `:::llm-stream` (which now
//!   replaces its prompt from `body` when body is non-empty — see
//!   `llm_stream.handleUpdate`).
//!
//! - `placeholder` (optional) — greyed-out text shown when the
//!   buffer is empty. Default `""`.
//! - `initial` (optional) — pre-fill text. Default `""`.
//! - `width`  (optional) — pixel literal or `100%`. Default 480.
//! - `height` (optional) — pixel literal. Default 24, matching
//!   `:::button`, because a field and a key now sit side by side in a
//!   panel and a field half again as tall reads as a different
//!   vocabulary. A chat prompt wants more and asks for it.
//! - `color` / `border` / `text` / `active_border` (optional) — the
//!   field's palette, same shape as `:::button`'s and `:::slider`'s.
//!
//! ### The state arm, and why it is the same one `:::button` grew
//!
//! `:::button` has fired at `state.path` since stage 13b and `:::input`
//! could only reach a component, which made the field the one control in
//! the vocabulary that could not drive a knob. A HUD panel needs exactly
//! that: `target=state.exposure` with `exposure: mirror
//! render/grade/exposure` in the frontmatter puts a typed number on the
//! plane through machinery that already exists, with no new verb and no
//! console line in between.
//!
//! A field bound to the path it writes (`initial=${state.x}
//! target=state.x`) is its own subscriber, which is the re-entrancy that
//! crashed the trackball — `ingest` routes through
//! `component.adoptString` for that reason, and `handleKey` touches
//! nothing after the write.
//!
//! ### Focus + keyboard
//!
//! Emits a `Hit` with `focusable=true`. Click → dispatcher grabs
//! focus (previous focus-holder receives `.focus_lost`). Once
//! focused:
//!
//!   * `.char_input`         → insert codepoint as UTF-8 at cursor
//!   * `.key_down BACKSPACE` → delete codepoint before cursor
//!   * `.key_down DELETE`    → delete codepoint at cursor
//!   * `.key_down LEFT/RIGHT`→ move cursor by one codepoint
//!   * `.key_down HOME/END`  → cursor to buffer ends
//!   * `.key_down ENTER`     → dispatch
//!     `registry.handleUpdate(target, action, buffer.items)`
//!   * `.key_down ESC`       → handled by the host dispatcher,
//!     which clears focus → we get `.focus_lost`
//!
//! Selection / multiline / IME are deferred — v0 is single-line,
//! caret-only. The codepoint walks step by UTF-8 byte length so
//! multi-byte chars don't split. No history (undo/redo) yet either.
//!
//! ### `numeric` — drag to scrub
//!
//!     :::input {numeric target=state.speed initial=${state.speed} min=0.1 max=200}
//!
//! A bare `numeric` flag makes the field a number: right-aligned, in the
//! mono face, and **draggable**. Resolve's fields all work this way and it
//! is the single biggest ergonomic win the edit box was missing — a knob
//! you can nudge without opening a slider, in the same rectangle you can
//! still type an exact value into.
//!
//! Optional with it: `min` / `max` (clamp), `step` (the linear-equivalent
//! gain), `decimals` (display precision).
//!
//! **The drag is curved, not linear.** Near the press point a pixel is
//! worth `FINE` × what a straight-line scrub would give it, so a value
//! can be walked one unit at a time; further out the curve overtakes, so
//! the whole range is still one gesture. `curveG` carries the arithmetic
//! and the nit that paid for it. The calibration worth holding on to:
//! `g(1) = 1` exactly, so a full-span drag crosses precisely the declared
//! range and `step`, `min` and `max` all keep the meanings they had
//! before the curve existed.
//!
//! **The gesture is ambiguous at press, so it latches in three states,
//! not two.** `:::trackball` latches a ZONE at `mouse_down` because where
//! you pressed decides what you grabbed. Here *where* you pressed decides
//! nothing — a press on a numeric field is either the start of a scrub or
//! a click asking for a caret, and which one it is only becomes known when
//! the pointer does or does not move. So `mouse_down` latches `.pending`,
//! the first move past `SCRUB_SLOP` promotes it to `.scrubbing`, and a
//! release still in `.pending` was a click. Below the slop nothing is
//! written, which is what keeps a slightly-shaky click from nudging a
//! knob.
//!
//! **The field focuses either way, and that is not a compromise.**
//! `Spark.dispatchMouseButton` grants focus to a focusable hit on the
//! press, *before* the component sees the `mouse_down`, so a component
//! cannot decline it. Rather than fight the dispatcher: a scrub leaves the
//! caret sitting in the number it just changed, which is exactly where you
//! want it when the drag got you close and you want to type the last two
//! digits.
//!
//! **Precision is inherited, not defaulted.** A field seeded
//! `initial=${state.sens}` with `0.015` in it scrubs in thousandths,
//! because `decimalsOf` reads the precision off the text it was given.
//! Defaulting to two would have rounded the value to `0.02` the first time
//! anyone touched it — a silent loss of a digit the document had troubled
//! itself to write. An explicit `decimals=` still wins.
//!
//! ### Cursor rendering
//!
//! Caret is a 2-pixel-wide vertical bar at the cursor's screen x,
//! computed by shaping the buffer prefix `[0..cursor]` and summing
//! its advances. Cheap because v0 buffers are short (`prompt` /
//! `query` scale, not document scale). Blink is time-based — half-
//! second on, half-second off — driven by `std.time.milliTimestamp`
//! from layoutAndRender, so it animates on every layout pass (which
//! happens every frame while focused because we mark
//! `state.dirty = true` to drive the blink).

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
/// For `formatValue` only. A numeric field and a `:::meter` row show the
/// same number in the same panel, so they had better round it the same
/// way — one formatter, not two that agree until someone edits one.
const meter = @import("meter.zig");

pub const Error = error{
    InputMissingTarget,
    InputMissingAction,
    InputNotInstalled,
};

// ── The numeric mode's pure half ────────────────────────────────────
//
// Everything here is arithmetic over plain numbers, so the gestures can
// be gated without a window, a font or a mouse.

/// What a press on a numeric field turned out to be. `.pending` is the
/// state that makes a click and a drag distinguishable at all — see the
/// header.
pub const Gesture = enum { none, pending, scrubbing };

/// Pixels of travel before a press becomes a scrub. Paid for by hand
/// tremor and trackpads: a click that moves two pixels is a click, and a
/// field that nudged its knob on every click would be unusable for typing
/// into. Three is the smallest number that felt like a click still worked.
pub const SCRUB_SLOP: f32 = 3.0;

/// The travel a bounded field's whole range is spread over. A slider's
/// range is its width; a field has no width to speak of, so it borrows a
/// notional one — far enough that the ends are reachable in one gesture,
/// short enough that the middle is not a marathon.
pub const SPAN_PX: f32 = 240;

/// How much of the linear gain survives at the centre of the gesture.
///
/// **The nit this is paid for.** Chris, 2026-09-02: *"I think personally I
/// prefer rubber band, physics based scrubbing — the further you drag the
/// faster it goes. I find it easier to zero in on small increments."* A
/// straight-line scrub spreads a 0..200 range over 240 pixels, so every
/// pixel is 0.83 and there is no way to ask for 12.5 — the control is
/// only as fine as its coarsest job needs it to be. Near the press point
/// a pixel is now worth FINE × what it was, so a value can be walked one
/// unit at a time; by `SPAN_PX` the curve has caught up, and past it, it
/// overtakes.
pub const FINE: f32 = 0.15;

/// The response curve, dimensionless: odd, `g(0) = 0`, `g(±1) = ±1`, and
/// `g'(0) = FINE`. A line blended with a cubic — the gamepad curve, for
/// the gamepad's reason: two sensitivities in one gesture with no
/// deadzone and no mode switch between them.
///
/// Odd rather than `sign(u) * f(|u|)` so that it is smooth THROUGH zero.
/// A curve with a corner at the origin reads as a catch when a drag
/// crosses back over the press point, which is exactly where the fine
/// control is supposed to be.
pub fn curveG(u: f32) f32 {
    return u * FINE + u * u * u * (1 - FINE);
}

/// Value units for a drag of `dx` pixels.
///
/// `step` keeps its old meaning — the LINEAR-equivalent gain — and the
/// curve is calibrated so `g(1) = 1` exactly. That is what lets the curve
/// be added without recalibrating anything: a bounded field still crosses
/// its whole range in one full-span drag, precisely as it did before,
/// while the middle of that drag became some six times finer.
pub fn scrubOffset(dx: f32, step: f32) f32 {
    return step * SPAN_PX * curveG(dx / SPAN_PX);
}

/// What an unbounded field moves per pixel. Small, because a field with
/// no declared range is as likely to hold 0.5 as 500 and overshooting is
/// the more annoying failure.
pub const DEFAULT_STEP: f32 = 0.01;

/// The number in `text`, or null when it is not one. Null is the answer
/// for an empty field and for prose: a scrub needs somewhere to start
/// from, and inventing zero would silently discard whatever was there.
pub fn parseNumber(text: []const u8) ?f32 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f32, t) catch null;
}

/// Units per pixel. An explicit `step=` wins; with both bounds the range
/// spreads over `SPAN_PX`, the way a slider's range spreads over its
/// width; otherwise `DEFAULT_STEP`.
///
/// A `step=` of zero or less is ignored rather than honoured — it would
/// make the field look draggable and do nothing, which is worse than the
/// default it was trying to override.
pub fn stepFor(step_attr: ?f32, min_v: ?f32, max_v: ?f32) f32 {
    if (step_attr) |s| {
        if (s > 0) return s;
    }
    if (min_v) |lo| {
        if (max_v) |hi| {
            if (hi > lo) return (hi - lo) / SPAN_PX;
        }
    }
    return DEFAULT_STEP;
}

/// The value a drag of `dx` from `press_value` lands on, clamped to
/// whichever bounds were declared. Absolute in `dx`, never incremental —
/// see `Component.press_value`.
pub fn scrubTo(press_value: f32, dx: f32, step: f32, min_v: ?f32, max_v: ?f32) f32 {
    var v = press_value + scrubOffset(dx, step);
    if (min_v) |lo| v = @max(v, lo);
    if (max_v) |hi| v = @min(v, hi);
    return v;
}

/// Digits after the decimal point in `text`, which is a numeric field's
/// DEFAULT precision — a field seeded `0.015` scrubs in thousandths. See
/// the header for why inheriting beats defaulting.
///
/// Capped at 3 because `meter.formatValue` renders 0, 1, 2 and 3 places
/// and falls back to 2 above that; asking for 4 would silently produce
/// fewer digits than asking for 3.
pub fn decimalsOf(text: []const u8) u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse return 0;
    var n: u8 = 0;
    for (t[dot + 1 ..]) |ch| {
        if (ch < '0' or ch > '9') break;
        n += 1;
        if (n == 3) break;
    }
    return n;
}

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("input", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    target: []u8, // stripped of leading `#`
    action: []u8,
    placeholder: []u8,
    width: box_helpers.Length,
    height: f32,

    /// Raw UTF-8 buffer; cursor is a byte offset that must always
    /// land on a codepoint boundary.
    buffer: std.ArrayListUnmanaged(u8) = .{},
    cursor: usize = 0,

    /// The four colours a field wears. Attributes for the reason
    /// `:::slider`'s and `:::button`'s are: a shell that themes its keys
    /// and not its fields is a shell with one rule and one exception.
    color: [4]f32 = FIELD_BG,
    border: [4]f32 = FIELD_BORDER,
    text: [4]f32 = TEXT_COLOR,
    /// The border while focused. Amber by default, because it is the
    /// shell's one lit colour — see the constant.
    active_border: [4]f32 = FIELD_BORDER_FOCUSED,

    focused: bool = false,

    /// `numeric` — the field is a number, drawn right-aligned in the mono
    /// face and draggable. See the header.
    numeric: bool = false,
    min: ?f32 = null,
    max: ?f32 = null,
    /// Units per pixel of drag. Null means derive — see `stepFor`.
    step: ?f32 = null,
    decimals: u8 = 2,
    /// Whether `decimals` came from the document. When it did not, the
    /// seeding branch reads it off `initial` instead of leaving the
    /// default in place. See `decimalsOf`.
    decimals_explicit: bool = false,

    gesture: Gesture = .none,
    /// Where in the box the press landed, and the value the buffer held at
    /// that moment. A scrub is always measured from the PRESS rather than
    /// integrated move-to-move: integrating accumulates its own rounding,
    /// so dragging out and back would not return the value you started
    /// with. `:::trackball`'s dial learned this first.
    press_x: f32 = 0,
    press_value: f32 = 0,

    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Captured at create time. `onInput` reaches the registry +
    /// host state through it (Enter-fire dispatch + caret-blink dirty).
    spark: ?*spark_mod.Spark = null,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var target_raw: ?[]const u8 = null;
        var action_raw: ?[]const u8 = null;
        var placeholder_raw: []const u8 = "";
        var initial_raw: ?[]const u8 = null;
        var width_opt: box_helpers.Length = self.width;
        var height_opt: f32 = self.height;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "action")) {
                action_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "placeholder")) {
                placeholder_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "initial")) {
                initial_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.color = v;
            } else if (std.mem.eql(u8, attr.key, "border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.border = v;
            } else if (std.mem.eql(u8, attr.key, "text")) {
                if (box_helpers.parseColor(attr.value)) |v| self.text = v;
            } else if (std.mem.eql(u8, attr.key, "active_border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.active_border = v;
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| width_opt = l;
            } else if (std.mem.eql(u8, attr.key, "numeric")) {
                // A bare flag, like `:::frosted_glass {backdrop}`. An
                // explicit `numeric=0` turns it off so a templated
                // `numeric=${state.x}` can decide either way.
                self.numeric = attr.value.len == 0 or !std.mem.eql(u8, attr.value, "0");
            } else if (std.mem.eql(u8, attr.key, "min")) {
                self.min = parseNumber(attr.value);
            } else if (std.mem.eql(u8, attr.key, "max")) {
                self.max = parseNumber(attr.value);
            } else if (std.mem.eql(u8, attr.key, "step")) {
                self.step = parseNumber(attr.value);
            } else if (std.mem.eql(u8, attr.key, "decimals")) {
                if (parseNumber(attr.value)) |d| {
                    if (d >= 0 and d <= 3) {
                        self.decimals = @intFromFloat(d);
                        self.decimals_explicit = true;
                    }
                }
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    height_opt = switch (l) {
                        .pixels => |p| p,
                        else => height_opt,
                    };
                }
            }
        }

        const target_full = target_raw orelse return Error.InputMissingTarget;
        const target = if (target_full.len > 0 and target_full[0] == '#')
            target_full[1..]
        else
            target_full;

        // `action=` is required for component-target dispatch — the
        // callee's `handle_update` arms switch on it. State-target
        // dispatch ignores it: there is a single primitive verb (write
        // the buffer into `state.path`), so an absent action is not a
        // missing argument, it is an argument that has no meaning here.
        // Exactly `:::button`'s rule, and it has to be exactly that rule
        // or the two controls disagree about their own grammar.
        const is_state_target = std.mem.startsWith(u8, target, "state.");
        const action = if (is_state_target)
            action_raw orelse ""
        else
            action_raw orelse return Error.InputMissingAction;

        // Only seed buffer from `initial` on first ingest (i.e. when
        // buffer is empty AND cursor is 0). A subsequent attr update
        // mustn't wipe what the user typed.
        if (initial_raw) |init_text| {
            if (self.buffer.items.len == 0 and self.cursor == 0 and init_text.len > 0) {
                try self.buffer.appendSlice(a, init_text);
                self.cursor = init_text.len;
                // Read the precision off the seed, ONCE, here — and only
                // here. Doing it on every ingest would re-derive it from a
                // buffer the user has since scrubbed, so a value that
                // happened to land on a round number would drop a digit
                // and never get it back.
                if (!self.decimals_explicit) self.decimals = decimalsOf(init_text);
            }
        }

        // `adoptString`, not free-and-dupe: a field with
        // `target=state.x` and `initial=${state.x}` subscribes to the
        // path it writes, and `State.set` notifies synchronously — so
        // Enter re-enters this function while `handleKey` is still
        // holding a slice of `self.target`. See `component.adoptString`.
        try component_mod.adoptString(a, &self.target, target);
        try component_mod.adoptString(a, &self.action, action);
        try component_mod.adoptString(a, &self.placeholder, placeholder_raw);
        self.width = width_opt;
        self.height = height_opt;
    }
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .spark = spark,
        .target = try allocator.dupe(u8, ""),
        .action = try allocator.dupe(u8, ""),
        .placeholder = try allocator.dupe(u8, ""),
        .width = .{ .pixels = 480 },
        .height = DEFAULT_HEIGHT,
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
    allocator.free(c.target);
    allocator.free(c.action);
    allocator.free(c.placeholder);
    c.buffer.deinit(allocator);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .focusable = true,
    // Caret blinks on a wall-clock timer + the field re-renders every
    // keystroke. Either could be plumbed through a version counter,
    // but the field is cheap to walk (one quad, one underline, one
    // shape() of the buffer) and caching it would mean bumping per
    // frame anyway. Walk fresh, save the bookkeeping.
    .disable_cache = true,
};

// ── Visual constants ────────────────────────────────────────────────

// A field is CUT from the panel, the same way a groove and a key are:
// neutral darkening, black edge, square. It was a rounded box with a
// blue-grey border and a blue focus ring — the web-form look the buttons
// were sent away for on 2026-09-01, still sitting next to them.
//
// The fill is a neutral darkening rather than a colour of its own, so a
// field takes the tint of whatever panel it is on. Same rule as
// `:::button`'s fill and `:::slider`'s recess.
const FIELD_BG: [4]f32 = .{ 0.0, 0.0, 0.0, 0.34 };
/// A focused field sits a little deeper. The state is carried by the
/// BORDER — this is the supporting half, and pushing it further would
/// make focus read as "disabled".
const FIELD_BG_FOCUSED: [4]f32 = .{ 0.0, 0.0, 0.0, 0.42 };
const FIELD_BORDER: [4]f32 = .{ 0.02, 0.02, 0.03, 0.92 };
/// Focus is the shell's ONE lit colour — the same amber as the grip, the
/// dial's home mark and a pressed key. "This one is live" is one colour
/// everywhere or it is decoration.
const FIELD_BORDER_FOCUSED: [4]f32 = .{ 1.0, 0.68, 0.0, 0.90 };
const TEXT_COLOR: [4]f32 = .{ 0.88, 0.89, 0.91, 1.0 };
/// Warm-neutral rather than blue-grey: on the panel ground `#3b3434`, a
/// cool placeholder reads as a different material.
const PLACEHOLDER_COLOR: [4]f32 = .{ 0.52, 0.50, 0.49, 1.0 };
const CARET_COLOR: [4]f32 = .{ 0.95, 0.95, 0.96, 1.0 };
/// A catch-light along the inside of the BOTTOM edge — the inverse of
/// `:::button`'s top hairline, and inverted for the reason the button's
/// exists at all: a key is raised so its light lands on top, a field is
/// a hole so its light lands at the bottom. Without this the two are the
/// same rectangle.
const FIELD_BOTTOM_LIGHT: [4]f32 = .{ 1.0, 1.0, 1.0, 0.08 };
/// Matched to `:::button`'s, because a field and a key sit side by side
/// in a panel now and a field half again as tall reads as a different
/// vocabulary. Was 36 — a chat prompt's height, from when the only
/// `:::input` in existence was one.
const DEFAULT_HEIGHT: f32 = 24;
const BORDER_PX: f32 = 1.0;
const BORDER_PX_FOCUSED: f32 = 1.5;
const RADIUS: f32 = 1.5;
const PAD_X: f32 = 9;
const CARET_W: f32 = 2.0;
const BLINK_PERIOD_MS: i64 = 1000; // half on, half off

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // The mono face for a numeric field, and it is chosen HERE rather
    // than at the draw call so the metrics, the caret height and the
    // prefix measurement all come from the face the glyphs are in. A
    // caret sized from the proportional face over mono text is the kind
    // of half-applied change that looks like a rendering bug.
    const style = if (c.numeric) lc.theme.applyCodeInline(lc.theme.body) else lc.theme.body;

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const hb = lc.fonts.hbFont(style.font_id);
    const fscale = lc.fonts.scale(style.font_id);
    const m = lc.fonts.metrics(style.font_id);

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 480;
    const w: f32 = c.width.resolve(max_w, fallback_w);
    const h = c.height;

    const border_px = if (c.focused) BORDER_PX_FOCUSED else BORDER_PX;
    const border_rgba = if (c.focused) c.active_border else c.border;
    const bg_rgba = if (c.focused) FIELD_BG_FOCUSED else c.color;

    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = border_rgba,
        .radius = RADIUS,
    });
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + border_px, origin[1] + border_px },
        .dst_size = .{ w - 2 * border_px, h - 2 * border_px },
        .color = bg_rgba,
        .radius = @max(0, RADIUS - border_px),
    });
    // The catch-light on the inside of the bottom edge. Inset by the
    // border on both sides so it stops where the border does rather than
    // running out over the rounded corners.
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + border_px, origin[1] + h - border_px - 1 },
        .dst_size = .{ w - 2 * border_px, 1 },
        .color = FIELD_BOTTOM_LIGHT,
        .radius = 0,
    });

    const baseline_y = origin[1] + (h - m.line_height) * 0.5 + m.ascender;
    var text_x = origin[0] + PAD_X;

    // Draw buffer (or placeholder if empty).
    const show_buffer = c.buffer.items.len > 0;
    const display_text: []const u8 = if (show_buffer) c.buffer.items else c.placeholder;
    const display_color: [4]f32 = if (show_buffer) c.text else PLACEHOLDER_COLOR;

    var prefix_w: f32 = 0;
    if (display_text.len > 0) {
        const run = try shape.shapeUtf8(aa, hb, display_text);
        if (c.numeric) {
            // Right-aligned, so a column of fields lines its points up and
            // a value growing a digit does not shuffle the ones beside it.
            // Same reason `:::meter` right-aligns its readout.
            var run_w: f32 = 0;
            for (run.glyphs) |g| run_w += g.x_advance * fscale;
            // …but never past the left pad: a number too long for the
            // field runs off the RIGHT, where the digits that matter least
            // are, rather than out of the left edge past the caret.
            text_x = @max(origin[0] + w - PAD_X - run_w, origin[0] + PAD_X);
        }
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
            display_color,
            style.hot_color,
            style.attention,
            lc.zoom,
        );
        if (show_buffer and c.cursor > 0 and c.cursor <= c.buffer.items.len) {
            // Shape the prefix separately to get caret x. Cheap for
            // the lengths a v0 input field deals with; if this ever
            // hurts we can sum advances from `run` based on cluster
            // index instead.
            const prefix_run = try shape.shapeUtf8(aa, hb, c.buffer.items[0..c.cursor]);
            for (prefix_run.glyphs) |g| prefix_w += g.x_advance * fscale;
        }
    }

    // Caret — only when focused, and only on the "on" half of the
    // blink cycle. Drives `state.dirty` next frame so the next layout
    // pass re-evaluates the blink (otherwise the box would stay
    // frozen mid-cycle).
    if (c.focused) {
        const ms = std.time.milliTimestamp();
        const phase = @mod(ms, BLINK_PERIOD_MS);
        const blink_on = phase < @divTrunc(BLINK_PERIOD_MS, 2);
        if (blink_on) {
            const caret_x = text_x + prefix_w;
            const caret_y = origin[1] + (h - m.line_height) * 0.5 + 2;
            const caret_h = m.line_height - 4;
            try out.appendQuad(lc, .{
                .dst_pos = .{ caret_x, caret_y },
                .dst_size = .{ CARET_W, caret_h },
                .color = CARET_COLOR,
                .radius = 0,
            });
        }
        if (c.spark) |sp| sp.host_state.dirty = true;
    }

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = baseline_y,
    };
    c.last_box = box;
    // No manual `out.hits.append` — the element_layout walker emits
    // a Hit for any custom whose vtable has `on_input != null`, and
    // it now also propagates `vtable.focusable` onto that Hit. A
    // second append here would just duplicate (and the walker's
    // would shadow ours anyway since it appends last).
    return box;
}

// GLFW key codes we care about. Re-declared here as private
// constants to keep this file independent of `win.zig` (component
// modules don't depend on GLFW directly). These values are stable
// across GLFW 3.x.
const KEY_BACKSPACE: i32 = 259;
const KEY_DELETE: i32 = 261;
const KEY_LEFT: i32 = 263;
const KEY_RIGHT: i32 = 262;
const KEY_HOME: i32 = 268;
const KEY_END: i32 = 269;
const KEY_ENTER: i32 = 257;
const KEY_KP_ENTER: i32 = 335;

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    state_ptr: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .focus_gained => {
            c.focused = true;
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        .focus_lost => {
            c.focused = false;
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        .char_input => |cp| {
            try insertCodepoint(c, cp);
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        .key_down => |k| {
            try handleKey(c, k, state_ptr);
        },
        .mouse_down => |m| {
            // Cleared unconditionally: a press that is not the start of a
            // scrub must not leave a stale latch for the NEXT drag over
            // this field to pick up.
            c.gesture = .none;
            if (!c.numeric or m.button != 0) return;
            // A field holding prose (or nothing) has no value to scrub
            // from, so the press stays an ordinary click. Inventing a zero
            // here would discard whatever was in it on the first drag.
            const v = parseNumber(c.buffer.items) orelse return;
            c.press_x = m.local[0];
            c.press_value = v;
            c.gesture = .pending;
        },
        .mouse_move => |m| {
            if (c.gesture == .none or !m.button_down) return;
            const dx = m.local[0] - c.press_x;
            if (c.gesture == .pending) {
                if (@abs(dx) < SCRUB_SLOP) return;
                c.gesture = .scrubbing;
            }
            const v = scrubTo(c.press_value, dx, stepFor(c.step, c.min, c.max), c.min, c.max);
            try commitNumeric(c, state_ptr, v);
        },
        .mouse_up => |m| {
            if (m.button == 0) c.gesture = .none;
        },
    }
}

/// Put `value` in the buffer and send it wherever the field points.
///
/// Order matters and is the same rule `handleKey`'s Enter arm follows:
/// the buffer is written FIRST, because `dispatchBuffer` may re-enter
/// `ingest` through a synchronous `State.set`, and nothing may touch `c`
/// after that call.
fn commitNumeric(c: *Component, state_ptr: *anyopaque, value: f32) !void {
    var buf: [32]u8 = undefined;
    const text = meter.formatValue(&buf, value, c.decimals, "");
    c.buffer.clearRetainingCapacity();
    try c.buffer.appendSlice(c.allocator, text);
    c.cursor = c.buffer.items.len;
    if (c.spark) |sp| sp.host_state.dirty = true;
    dispatchBuffer(c, state_ptr);
}

fn insertCodepoint(c: *Component, cp: u32) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return;
    try c.buffer.ensureUnusedCapacity(c.allocator, n);
    // Shift tail right by n, then write.
    const old_len = c.buffer.items.len;
    c.buffer.items.len = old_len + n;
    if (c.cursor < old_len) {
        std.mem.copyBackwards(
            u8,
            c.buffer.items[c.cursor + n .. old_len + n],
            c.buffer.items[c.cursor..old_len],
        );
    }
    @memcpy(c.buffer.items[c.cursor .. c.cursor + n], buf[0..n]);
    c.cursor += n;
}

fn handleKey(c: *Component, k: element.KeyEvent, state_ptr: *anyopaque) !void {
    switch (k.key) {
        KEY_BACKSPACE => {
            if (c.cursor == 0) return;
            const start = prevCodepointStart(c.buffer.items, c.cursor);
            const drop = c.cursor - start;
            std.mem.copyForwards(
                u8,
                c.buffer.items[start..],
                c.buffer.items[c.cursor..],
            );
            c.buffer.items.len -= drop;
            c.cursor = start;
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        KEY_DELETE => {
            if (c.cursor >= c.buffer.items.len) return;
            const end = nextCodepointEnd(c.buffer.items, c.cursor);
            const drop = end - c.cursor;
            std.mem.copyForwards(
                u8,
                c.buffer.items[c.cursor..],
                c.buffer.items[end..],
            );
            c.buffer.items.len -= drop;
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        KEY_LEFT => {
            if (c.cursor == 0) return;
            c.cursor = prevCodepointStart(c.buffer.items, c.cursor);
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        KEY_RIGHT => {
            if (c.cursor >= c.buffer.items.len) return;
            c.cursor = nextCodepointEnd(c.buffer.items, c.cursor);
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        KEY_HOME => {
            c.cursor = 0;
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        KEY_END => {
            c.cursor = c.buffer.items.len;
            if (c.spark) |sp| sp.host_state.dirty = true;
        },
        KEY_ENTER, KEY_KP_ENTER => dispatchBuffer(c, state_ptr),
        else => {},
    }
}

/// Send the buffer wherever the field points. Enter's arm and a numeric
/// scrub are the same act with different triggers, so they are the same
/// function — a scrub that reached the plane by a second route would be a
/// second thing to keep in step with `target=`'s two arms.
fn dispatchBuffer(c: *Component, state_ptr: *anyopaque) void {
    if (c.target.len == 0) return;

    // State-target: `target=state.path` writes the buffer into
    // the scope-local state — the same primitive `:::button`
    // fires, with the typed text where the button's constant
    // `body=` would be. A field inside a child
    // `:::embedded-document` therefore mutates CHILD state, not
    // the host's, which is what the walker's `Hit.state` is for.
    if (std.mem.startsWith(u8, c.target, "state.")) {
        const key = c.target["state.".len..];
        if (key.len == 0) return;
        const state: *state_mod.State = @ptrCast(@alignCast(state_ptr));

        // Nothing may touch `c` after this line. `State.set`
        // notifies synchronously, so a field bound to the path
        // it writes re-enters its own `ingest` from inside this
        // call — `adoptString` keeps that from freeing `key`
        // mid-`set`, and returning immediately keeps us from
        // needing anything more than that.
        state.set(key, c.buffer.items) catch |e| {
            std.log.warn(":::input: state.set failed: err={s}", .{@errorName(e)});
        };
        return;
    }

    // Component-target.
    if (c.action.len == 0) return;
    const sp = c.spark orelse return;
    sp.registry.handleUpdate(c.target, c.action, c.buffer.items) catch |e| {
        std.log.warn(":::input: dispatch failed: target=#{s} action={s} err={s}", .{
            c.target, c.action, @errorName(e),
        });
    };
}

/// Walk back from byte offset `pos` to the previous UTF-8 codepoint
/// start. Buffer is assumed well-formed (we only insert validated
/// UTF-8). Returns 0 if pos is 0 or buffer is malformed.
fn prevCodepointStart(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Walk forward from byte offset `pos` to the start of the next
/// codepoint (i.e. the byte after the current one).
fn nextCodepointEnd(bytes: []const u8, pos: usize) usize {
    if (pos >= bytes.len) return bytes.len;
    const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch 1;
    const end = pos + len;
    return if (end > bytes.len) bytes.len else end;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// Input tests exercise onInput which dirties `spark.host_state` —
// the default testStub leaves that field undefined, so build a real
// backing State and patch it onto the stub. Leaks at module exit by
// design (test-only memory).
var _test_state = state_mod.State.init(testing.allocator);
var _test_spark = blk: {
    var s = spark_mod.Spark.testStub(testing.allocator);
    s.host_state = &_test_state;
    break :blk s;
};

test "input: prevCodepointStart steps over ASCII" {
    try testing.expectEqual(@as(usize, 0), prevCodepointStart("hello", 1));
    try testing.expectEqual(@as(usize, 2), prevCodepointStart("hello", 3));
    try testing.expectEqual(@as(usize, 0), prevCodepointStart("hello", 0));
}

test "input: prevCodepointStart steps over multi-byte UTF-8" {
    // "é" = 0xC3 0xA9 (2 bytes); "🎉" = 0xF0 0x9F 0x8E 0x89 (4 bytes).
    const s = "aé🎉";
    try testing.expectEqual(@as(usize, 0), prevCodepointStart(s, 1)); // before 'é'
    try testing.expectEqual(@as(usize, 1), prevCodepointStart(s, 3)); // before '🎉'
    try testing.expectEqual(@as(usize, 3), prevCodepointStart(s, 7)); // before end
}

test "input: nextCodepointEnd steps forward over multi-byte" {
    const s = "aé🎉";
    try testing.expectEqual(@as(usize, 1), nextCodepointEnd(s, 0));
    try testing.expectEqual(@as(usize, 3), nextCodepointEnd(s, 1));
    try testing.expectEqual(@as(usize, 7), nextCodepointEnd(s, 3));
    try testing.expectEqual(@as(usize, 7), nextCodepointEnd(s, 7));
}

test "input: ingest requires target + action; strips # prefix" {

    const ok_attrs = [_]components.Attr{
        .{ .key = "target", .value = "#chat" },
        .{ .key = "action", .value = "start" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &ok_attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("chat", c.target);
    try testing.expectEqualStrings("start", c.action);
}

test "input: missing target rejected" {

    const attrs = [_]components.Attr{
        .{ .key = "action", .value = "start" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    try testing.expectError(Error.InputMissingTarget, create(&_test_spark, testing.allocator, &spec));
}

test "input: missing action rejected" {

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "x" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    try testing.expectError(Error.InputMissingAction, create(&_test_spark, testing.allocator, &spec));
}

test "input: char_input + backspace + cursor moves" {

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    // Focus → type "hi" → backspace → type "ello"
    var dummy_state: u8 = 0;
    try onInput(inst.ctx, .focus_gained, @ptrCast(&dummy_state));
    try testing.expect(c.focused);

    try onInput(inst.ctx, .{ .char_input = 'h' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'i' }, @ptrCast(&dummy_state));
    try testing.expectEqualStrings("hi", c.buffer.items);
    try testing.expectEqual(@as(usize, 2), c.cursor);

    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_BACKSPACE, .mods = 0 } }, @ptrCast(&dummy_state));
    try testing.expectEqualStrings("h", c.buffer.items);
    try testing.expectEqual(@as(usize, 1), c.cursor);

    try onInput(inst.ctx, .{ .char_input = 'e' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'l' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'l' }, @ptrCast(&dummy_state));
    try onInput(inst.ctx, .{ .char_input = 'o' }, @ptrCast(&dummy_state));
    try testing.expectEqualStrings("hello", c.buffer.items);
}

test "input: arrows + home + end move cursor" {

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
        .{ .key = "initial", .value = "abc" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(usize, 3), c.cursor); // initial seeds cursor at end

    var ds: u8 = 0;
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_LEFT, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 2), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_HOME, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 0), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_RIGHT, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 1), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_END, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 3), c.cursor);
}

test "input: multi-byte char + backspace removes whole codepoint" {

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    var ds: u8 = 0;
    try onInput(inst.ctx, .{ .char_input = 0x1F389 }, @ptrCast(&ds)); // 🎉
    try testing.expectEqual(@as(usize, 4), c.buffer.items.len);
    try testing.expectEqual(@as(usize, 4), c.cursor);
    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_BACKSPACE, .mods = 0 } }, @ptrCast(&ds));
    try testing.expectEqual(@as(usize, 0), c.buffer.items.len);
    try testing.expectEqual(@as(usize, 0), c.cursor);
}

test "input: initial attr seeds buffer + cursor" {

    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
        .{ .key = "initial", .value = "preset" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("preset", c.buffer.items);
    try testing.expectEqual(@as(usize, 6), c.cursor);
}

test "input: state-target writes the buffer on Enter" {
    // The arm that made `:::input` able to drive a knob. Before it, a
    // field could only reach a component, so the one control shaped
    // like "type a number here" was the one control that could not put
    // a number anywhere.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.exposure" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    for ("1.85") |ch| {
        try onInput(inst.ctx, .{ .char_input = ch }, @ptrCast(&state));
    }
    // Nothing lands until Enter — a field that wrote per keystroke would
    // push "1", "1.", "1.8" at the plane on the way to "1.85".
    try testing.expect(state.get("exposure") == null);

    try onInput(inst.ctx, .{ .key_down = .{ .key = KEY_ENTER, .mods = 0 } }, @ptrCast(&state));
    try testing.expectEqualStrings("1.85", state.get("exposure").?);
    try testing.expect(state.dirty);
}

test "input: state-target accepts a missing action" {
    // `action=` names a verb on a component's `handle_update`. A state
    // write has one verb and no callee, so requiring it would be
    // requiring an argument with nothing to mean — and `:::button`
    // already settled that. The two grammars have to agree.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.foo" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("state.foo", c.target);
    try testing.expectEqualStrings("", c.action);
}

test "input: component-target still demands an action" {
    // The other half of the rule above: relaxing it for `state.` must
    // not relax it for everyone. A `#chat` with no verb dispatches
    // nothing and looks like it works.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "#chat" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    try testing.expectError(Error.InputMissingAction, create(&_test_spark, testing.allocator, &spec));
}

test "input: an ingest that changes nothing frees nothing" {
    // Same gate as `:::button`'s, for the same crash. A field with
    // `target=state.x initial=${state.x}` is its own subscriber, and
    // `State.set` notifies synchronously — so Enter re-enters this
    // ingest while `handleKey` still holds a slice of `self.target`.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.x" },
        .{ .key = "placeholder", .value = "1.0" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));

    const target_ptr = c.target.ptr;
    const placeholder_ptr = c.placeholder.ptr;
    try update(inst.ctx, &spec);
    try testing.expectEqual(target_ptr, c.target.ptr);
    try testing.expectEqual(placeholder_ptr, c.placeholder.ptr);

    // And the guard still lets a real edit through — a guard that never
    // replaces breaks hot reload, which is worse than the crash.
    const attrs2 = [_]components.Attr{
        .{ .key = "target", .value = "state.y" },
        .{ .key = "placeholder", .value = "2.0" },
    };
    const spec2: components.Spec = .{ .name = "input", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);
    try testing.expectEqualStrings("state.y", c.target);
    try testing.expectEqualStrings("2.0", c.placeholder);
}

// ── numeric mode ────────────────────────────────────────────────────

test "input: the numeric mode's arithmetic" {
    // `stepFor`'s three answers, in precedence order.
    try testing.expectEqual(@as(f32, 0.5), stepFor(0.5, 0, 200)); // explicit wins
    try testing.expectEqual(@as(f32, 200.0 / SPAN_PX), stepFor(null, 0, 200));
    try testing.expectEqual(DEFAULT_STEP, stepFor(null, null, null));
    // A step of zero would render the field draggable and inert, which is
    // worse than the default it tried to override.
    try testing.expectEqual(DEFAULT_STEP, stepFor(0, null, null));
    try testing.expectEqual(DEFAULT_STEP, stepFor(-1, null, null));
    // An inverted or empty range cannot be spread over the travel.
    try testing.expectEqual(DEFAULT_STEP, stepFor(null, 200, 0));
    try testing.expectEqual(DEFAULT_STEP, stepFor(null, 5, 5));
    // Only ONE bound is not enough to derive a range from.
    try testing.expectEqual(DEFAULT_STEP, stepFor(null, 0, null));

    // The response curve. `g(1) = 1` EXACTLY is the calibration that let
    // the curve be added without recalibrating `step`, `min` or `max`, so
    // it is the assertion that matters most here.
    try testing.expectEqual(@as(f32, 0), curveG(0));
    try testing.expectEqual(@as(f32, 1), curveG(1));
    try testing.expectEqual(@as(f32, -1), curveG(-1));
    // Odd, so it is smooth THROUGH the press point rather than having a
    // corner there.
    try testing.expectApproxEqAbs(-curveG(0.37), curveG(-0.37), 1e-7);
    // Near the centre the gain is FINE × linear — the whole nit.
    try testing.expectApproxEqAbs(@as(f32, 0.01 * FINE), curveG(0.01), 1e-6);
    // …and past the reference displacement it overtakes rather than
    // saturating: a scrub must still be able to cross a big range.
    try testing.expect(curveG(2) > 2);

    // `scrubTo` clamps to whichever bounds exist, and to neither when
    // there are none.
    try testing.expectEqual(@as(f32, 0), scrubTo(10, -1000, 1, 0, 200));
    try testing.expectEqual(@as(f32, 200), scrubTo(10, 1000, 1, 0, 200));
    // Unbounded below, clamped above.
    try testing.expect(scrubTo(10, -1000, 1, null, 200) < -100);
    // A full-span drag crosses exactly the declared range, curve or no
    // curve — this is `g(1) = 1` seen from the outside.
    try testing.expectApproxEqAbs(@as(f32, 200), scrubTo(0, SPAN_PX, 200.0 / SPAN_PX, null, null), 1e-3);

    // `parseNumber` says no rather than zero — see its comment.
    try testing.expectEqual(@as(?f32, 1.5), parseNumber("1.5"));
    try testing.expectEqual(@as(?f32, -3), parseNumber("  -3 "));
    try testing.expectEqual(@as(?f32, null), parseNumber(""));
    try testing.expectEqual(@as(?f32, null), parseNumber("hello"));
    try testing.expectEqual(@as(?f32, null), parseNumber("1.5m"));
}

test "input: decimalsOf reads a seed's precision, capped at what the formatter has" {
    try testing.expectEqual(@as(u8, 3), decimalsOf("0.015"));
    try testing.expectEqual(@as(u8, 1), decimalsOf("1.5"));
    try testing.expectEqual(@as(u8, 0), decimalsOf("10"));
    try testing.expectEqual(@as(u8, 0), decimalsOf(""));
    // Capped at 3: `meter.formatValue` renders 0..3 and falls back to TWO
    // above that, so returning 4 would quietly produce fewer digits than
    // returning 3.
    try testing.expectEqual(@as(u8, 3), decimalsOf("0.123456"));
    // A trailing unit stops the count rather than being counted.
    try testing.expectEqual(@as(u8, 2), decimalsOf("1.25ms"));
}

test "input: a click is not a scrub — the slop, end to end" {
    // The bug this is paid for: a field that nudged its knob on every
    // click would be unusable for the other half of its job, which is
    // typing an exact value into it. Below SCRUB_SLOP nothing is written
    // AT ALL — not the same value, nothing — because a write is what
    // wakes the plane.
    const attrs = [_]components.Attr{
        .{ .key = "numeric", .value = "" },
        .{ .key = "target", .value = "state.speed" },
        .{ .key = "initial", .value = "10" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "200" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    // Two pixels: a click with a shaky hand.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 52, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expect(state.get("speed") == null);

    // Twelve: a drag, and the response curve is the point of the number.
    // A straight-line scrub puts 200 over 240 pixels, so twelve pixels
    // would be TEN units and 12.5 would be unaskable. Through the curve
    // the same twelve pixels are worth about one and a half.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 62, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("12", state.get("speed").?);
}

test "input: a scrub is absolute from the press — out and back returns the value it started with" {
    // Integrating move-to-move would accumulate its own rounding, so a
    // drag out and back would land NEAR the start rather than on it. On a
    // knob you nudge all day, "near" is a value that walks.
    const attrs = [_]components.Attr{
        .{ .key = "numeric", .value = "" },
        .{ .key = "target", .value = "state.speed" },
        .{ .key = "initial", .value = "10" },
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "200" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 74, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("13", state.get("speed").?);
    // …and all the way home. The slop does not re-apply once the gesture
    // has been promoted, or a drag back through the press point would go
    // dead for six pixels either side of it.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("10", state.get("speed").?);

    // Both ends clamp, and the field stops there rather than remembering
    // how far past it the pointer went.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ -900, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("0", state.get("speed").?);
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 900, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("200", state.get("speed").?);

    // **Back to the press point after BOTH bounds, and it is 10 again.**
    // This is the assertion that tells absolute from incremental, and the
    // out-and-back above is not: with clean numbers the two agree, so the
    // first draft of this gate passed against an incremental scrub. A
    // clamp is where they diverge structurally — an incremental scrub
    // folds the clamped value into its own origin, so dragging past a
    // bound throws away where the gesture started and the knob never
    // finds its way home. Every UI that has ever done this is annoying in
    // exactly this way.
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("10", state.get("speed").?);
}

test "input: the release ends the gesture, and a plain text field never scrubs at all" {
    // Rule 7 — the ordinary path is a test case too. Every field in the
    // shell that is NOT numeric receives these same mouse events, and a
    // scrub leaking into one would rewrite what the user typed.
    //
    // The seed is `42` and that is the whole point: this field must be
    // stopped by the `numeric` guard, not by `parseNumber` failing. The
    // first draft seeded it `hello`, which parses as nothing — so
    // deleting the numeric check left the gate green and the gate was
    // testing the other guard. A text field holding digits is also the
    // realistic case: a name, a count, a port number.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.msg" },
        .{ .key = "initial", .value = "42" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();

    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 300, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expect(state.get("msg") == null);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("42", c.buffer.items);

    // A numeric field holding prose has nothing to scrub FROM, so the
    // press stays an ordinary click rather than inventing a zero.
    const nattrs = [_]components.Attr{
        .{ .key = "numeric", .value = "" },
        .{ .key = "target", .value = "state.n" },
        .{ .key = "initial", .value = "not a number" },
    };
    const nspec: components.Spec = .{ .name = "input", .attrs = &nattrs };
    const ninst = try create(&_test_spark, testing.allocator, &nspec);
    defer deinit_(ninst.ctx, testing.allocator);
    try onInput(ninst.ctx, .{ .mouse_down = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(ninst.ctx, .{ .mouse_move = .{ .local = .{ 300, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expect(state.get("n") == null);

    // And the release clears the latch, so the next drag over the field
    // starts from its own press instead of the previous one's.
    const nc: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 300, 10 }, .button = 0, .button_down = false } }, @ptrCast(&state));
    try testing.expectEqual(Gesture.none, nc.gesture);
}

test "input: a numeric field scrubs at the precision it was seeded with" {
    // `initial=${state.sens}` arrives as `0.015`. Defaulting to two
    // decimals would write `0.02` back on the first drag — a digit the
    // document had troubled itself to publish, gone, and not recoverable
    // by dragging further.
    const attrs = [_]components.Attr{
        .{ .key = "numeric", .value = "" },
        .{ .key = "target", .value = "state.sens" },
        .{ .key = "initial", .value = "0.015" },
        .{ .key = "step", .value = "0.001" },
    };
    const spec: components.Spec = .{ .name = "input", .attrs = &attrs };
    const inst = try create(&_test_spark, testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqual(@as(u8, 3), c.decimals);

    var state = state_mod.State.init(testing.allocator);
    defer state.deinit();
    try onInput(inst.ctx, .{ .mouse_down = .{ .local = .{ 50, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try onInput(inst.ctx, .{ .mouse_move = .{ .local = .{ 110, 10 }, .button = 0, .button_down = true } }, @ptrCast(&state));
    try testing.expectEqualStrings("0.027", state.get("sens").?);

    // An explicit `decimals=` still wins over the seed.
    const eattrs = [_]components.Attr{
        .{ .key = "numeric", .value = "" },
        .{ .key = "target", .value = "state.x" },
        .{ .key = "initial", .value = "0.015" },
        .{ .key = "decimals", .value = "1" },
    };
    const espec: components.Spec = .{ .name = "input", .attrs = &eattrs };
    const einst = try create(&_test_spark, testing.allocator, &espec);
    defer deinit_(einst.ctx, testing.allocator);
    const ec: *Component = @ptrCast(@alignCast(einst.ctx));
    try testing.expectEqual(@as(u8, 1), ec.decimals);
}
