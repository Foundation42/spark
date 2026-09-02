//! `:::textarea` — a real multi-line text editor: caret, selection, word
//! wrap, an internal scroll window, undo, and the clipboard.
//!
//!     :::textarea {target=state.program submit=ctrl_enter wrap=none mono rows=14}
//!     spin = osc 0.4
//!     cube.rot.y = spin
//!     :::
//!
//! ### Two customers, and they differ in exactly two places
//!
//! This was designed against both of the things that wanted it, at once,
//! because retrofitting the second onto the first is where a text widget
//! goes wrong:
//!
//! * **A chat prompt** soft-wraps, Enter sends, Shift+Enter makes a
//!   newline. `wrap=word submit=enter clear_on_submit`.
//! * **A rill console** does NOT wrap, Enter makes a newline, and running
//!   is a separate act. `wrap=none submit=ctrl_enter mono`.
//!
//! rill's half of that is not a preference. **Parse order is topological
//! order** — a line IS a statement — so a soft-wrapped program would draw
//! a picture of a structure it does not have. A reader counting statements
//! down the left edge would be counting wrong.
//!
//! Everything else the two want is the same widget, so it is one widget.
//!
//! ### Attribute grammar
//!
//! - `target` (optional) — either `#id` of a component (paired with
//!   `action=`) or `state.path`. Unlike `:::input`, this is **optional**:
//!   the default submit policy never fires, so the common textarea is a
//!   writing surface with nowhere to send yet, and demanding a target for
//!   it would be grammar for grammar's sake.
//! - `action` — the verb, required only for a `#component` target.
//! - `wrap` — `word` (default) or `none`.
//! - `submit` — `none` (default), `enter`, or `ctrl_enter`.
//! - `live` (bare flag) — publish to a `state.` target on **every** edit,
//!   not only on submit. This is what lets a separate Run button exist: a
//!   `:::button` can only fire a literal `body=`, so the text has to be
//!   somewhere the button's target can already read.
//! - `clear_on_submit` (bare flag) — empty the box after dispatching. Chat
//!   wants it; a console emphatically does not.
//! - `rows` — height in LINES (default 6). `height=` in pixels overrides.
//! - `width`, `placeholder`, `initial`, `color`, `border`, `text`,
//!   `active_border` — as `:::input`.
//! - `mono` (bare flag) — the code face. Code in a proportional face is
//!   the other half of the lie `wrap=none` is preventing.
//!
//! The **body** seeds the buffer, verbatim, newlines and all — which is
//! the whole reason a multi-line control should have one. `initial=` still
//! works and wins over the body when both are present, because `initial=`
//! is the one that can carry a `${state.x}`.
//!
//! ### Why the defaults are the pair they are
//!
//! `wrap=word` with `submit=none` is what a bare `:::textarea {}` gives
//! you, and the two defaults were chosen by different arguments rather
//! than by taste:
//!
//! * **Wrap defaults ON** because the failure of `wrap=none` is text that
//!   silently leaves the right-hand edge. The failure of wrapping is a
//!   visual line break, which you can see.
//! * **Submit defaults OFF** because a multi-line box whose Enter does not
//!   make a new line can only ever hold one line until you discover Shift.
//!   The surprising behaviour is the one that has to be asked for.
//!
//! ### The caret's affinity, and why there is such a thing
//!
//! A soft wrap gives one byte offset two screen positions — the end of the
//! line above and the start of the line below are the same place in the
//! text. Clicking at the right-hand end of a wrapped line and having the
//! caret appear one line lower is the visible form of that, and it is the
//! kind of small wrongness that makes an editor feel untrustworthy. So the
//! cursor carries a one-bit `affinity_before`, set by the two gestures that
//! mean "the end of THIS line" (a click past the end, and End), cleared by
//! everything else.
//!
//! ### What is deliberately not here
//!
//! * **Shift+click to extend a selection.** `element.MouseEvent` carries
//!   no modifier mask, and the host dispatches key events on press only, so
//!   there is no honest way to know whether Shift is down at the moment of
//!   a click. Drag-select and Shift+arrow both work. The cure is a `mods`
//!   field on MouseEvent, not a guess in here.
//! * **IME / composition.** `char_input` is already post-IME, so typing in
//!   a composed script works; the pre-edit underline does not exist.
//! * **Bidi and complex-script caret motion.** The line model assumes
//!   monotonic clusters, exactly as `:::input` does.
//! * **A gutter of line numbers.** Wanted by the console and genuinely
//!   cheap on top of this — the visual-line table already knows which rows
//!   are hard lines — but nothing has paid for it yet.
//!
//! ### The undo stack is whole-buffer snapshots, on purpose
//!
//! A textarea holds a prompt or a program: kilobytes, not a document. At
//! that size a snapshot is cheaper to take, cheaper to reason about and
//! impossible to get subtly wrong, which a piece-table is not. The same
//! argument `:::input` makes about re-shaping its prefix on every frame.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");
/// The palette, the codepoint walkers, and the geometry of a field cut
/// from a panel. Shared rather than copied — see the note on the visual
/// constants over there.
const input = @import("input.zig");

pub const Error = error{TextareaMissingAction};

// ── The pure half ───────────────────────────────────────────────────
//
// Everything down to `Component` is arithmetic over bytes and pixel
// positions. No font, no window, no allocator beyond a list — which is
// what lets the line model, the wrapper and the word walk be gated with
// a made-up monospace ruler instead of a GPU.

/// What happens to a line too long for the box.
pub const Wrap = enum {
    /// Break at word boundaries. What a prompt wants.
    word,
    /// Never break. What a program wants — see the header.
    none,
};

/// Which keystroke dispatches the buffer.
pub const Submit = enum {
    /// Nothing does. Enter always makes a newline.
    none,
    /// Enter dispatches; Shift+Enter makes a newline. Chat.
    enter,
    /// Ctrl+Enter dispatches; Enter makes a newline. A console.
    ctrl_enter,
};

pub fn parseWrap(s: []const u8) ?Wrap {
    if (std.mem.eql(u8, s, "word")) return .word;
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "off")) return .none;
    return null;
}

pub fn parseSubmit(s: []const u8) ?Submit {
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "off")) return .none;
    if (std.mem.eql(u8, s, "enter")) return .enter;
    if (std.mem.eql(u8, s, "ctrl_enter") or std.mem.eql(u8, s, "ctrl-enter")) return .ctrl_enter;
    return null;
}

/// One row as it is DRAWN. A hard line with no wrapping is one of these;
/// a wrapped one is several.
pub const VisLine = struct {
    /// Byte offsets into the buffer. `end` excludes the `\n` for a hard
    /// line and equals the next line's `start` for a soft one.
    start: u32,
    end: u32,
    /// Pixel width of `[start, end)`. Kept rather than recomputed because
    /// `xs` cannot answer for the end of a SOFT line — that slot belongs
    /// to the line below, holding a zero. See `layoutLines`.
    width: f32,
    /// True when the line ends at a `\n` or at the end of the buffer,
    /// false when the wrapper broke it.
    hard: bool,
};

/// Where a line too long for `content_w` should break, scanning from
/// `start`. Returns `end` when the rest fits.
///
/// **A break opportunity is the position AFTER a run of spaces**, so the
/// spaces stay on the line they ended and the next line starts at a word.
/// A space is also never itself a reason to wrap — it hangs past the right
/// edge, which is what every text engine does and what stops a line from
/// breaking one word early whenever it happens to end in a space.
///
/// **A word longer than the whole box breaks mid-word.** Refusing to would
/// mean drawing outside the box, and the guarantee that matters more is
/// that this always makes progress: the returned break is strictly greater
/// than `start`, so `layoutLines` cannot loop.
pub fn nextBreak(
    text: []const u8,
    xs_hard: []const f32,
    start: usize,
    end: usize,
    content_w: f32,
) usize {
    // A box with no width to speak of would otherwise break after every
    // codepoint and build a line table as long as the buffer.
    if (content_w <= 0) return end;
    var last_break: ?usize = null;
    var i = start;
    while (i < end) {
        const step = @min(std.unicode.utf8ByteSequenceLength(text[i]) catch 1, end - i);
        const nxt = i + step;
        const is_space = text[i] == ' ' or text[i] == '\t';
        if (!is_space and i > start and (xs_hard[nxt] - xs_hard[start]) > content_w) {
            return last_break orelse i;
        }
        if (is_space) last_break = nxt;
        i = nxt;
    }
    return end;
}

/// Build the visual-line table and the per-byte x table.
///
/// `xs_hard[i]` is the x of byte `i` measured from the start of its HARD
/// line — i.e. what shaping produces before anything knows where the soft
/// breaks are. `xs` comes back rebased onto the VISUAL line, which is what
/// the caret, the click and the selection all actually want.
///
/// **The shared byte at a soft break is written twice, and the second
/// write wins.** Offset `b` is both the end of one visual line and the
/// start of the next, and `xs[b]` ends up 0 — the position on the lower
/// line. That is deliberate and it is the same answer `lineOf` gives, so
/// the two never disagree; `VisLine.width` is what carries the other
/// reading, for the two places that need it.
pub fn layoutLines(
    gpa: std.mem.Allocator,
    text: []const u8,
    xs_hard: []const f32,
    wrap: Wrap,
    content_w: f32,
    lines: *std.ArrayListUnmanaged(VisLine),
    xs: *std.ArrayListUnmanaged(f32),
) !void {
    std.debug.assert(xs_hard.len == text.len + 1);
    lines.clearRetainingCapacity();
    xs.clearRetainingCapacity();
    try xs.resize(gpa, text.len + 1);
    @memset(xs.items, 0);

    var hard_start: usize = 0;
    while (true) {
        const hard_end = std.mem.indexOfScalarPos(u8, text, hard_start, '\n') orelse text.len;
        var seg = hard_start;
        while (true) {
            const brk = if (wrap == .none)
                hard_end
            else
                nextBreak(text, xs_hard, seg, hard_end, content_w);
            const soft = brk < hard_end;
            try lines.append(gpa, .{
                .start = @intCast(seg),
                .end = @intCast(brk),
                .width = xs_hard[brk] - xs_hard[seg],
                .hard = !soft,
            });
            var i = seg;
            while (i <= brk) : (i += 1) xs.items[i] = xs_hard[i] - xs_hard[seg];
            if (!soft) break;
            seg = brk;
        }
        if (hard_end >= text.len) break;
        hard_start = hard_end + 1;
    }
}

/// The visual line `offset` sits on: the last one that starts at or before
/// it. At a soft break that is the LOWER line — see `layoutLines`.
pub fn lineOf(lines: []const VisLine, offset: usize) usize {
    if (lines.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = lines.len - 1;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (lines[mid].start <= offset) lo = mid else hi = mid - 1;
    }
    return lo;
}

/// The byte offset on line `li` nearest to `x`, snapped to a codepoint
/// boundary. What a click and what a vertical arrow both resolve through,
/// so the two can never disagree about where a column is.
pub fn offsetAtX(
    text: []const u8,
    lines: []const VisLine,
    xs: []const f32,
    li: usize,
    x: f32,
) usize {
    if (lines.len == 0) return 0;
    const ln = lines[@min(li, lines.len - 1)];
    var best: usize = ln.start;
    var best_d: f32 = @abs(x);
    var o: usize = ln.start;
    while (o < ln.end) {
        o = input.nextCodepointEnd(text, o);
        // At `ln.end` the table holds the LOWER line's zero, so the width
        // is the only honest answer for this line's right-hand edge.
        const at: f32 = if (o == ln.end) ln.width else xs[o];
        const d = @abs(at - x);
        if (d < best_d) {
            best_d = d;
            best = o;
        }
    }
    return best;
}

/// A byte that belongs to a word for the purposes of Ctrl+arrow and
/// double-click. Everything non-ASCII counts, which keeps a multi-byte
/// codepoint whole and is right for every language whose words are made
/// of letters — the alternative is a Unicode word-break table, and this
/// widget is not where that gets paid for.
pub fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_' or
        b >= 0x80;
}

/// Where the word before `pos` starts: skip separators, then the word.
///
/// **Never crosses a newline, except by exactly one step from a line's
/// start.** A Ctrl+Left that hopped a blank line and landed three lines up
/// looks like a bug even when it is a policy; landing on the end of the
/// line above is what a person expects and is one keystroke from anywhere
/// else they meant.
pub fn wordStartBefore(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    if (text[pos - 1] == '\n') return pos - 1;
    var i = pos;
    while (i > 0 and text[i - 1] != '\n' and !isWordByte(text[i - 1])) : (i -= 1) {}
    while (i > 0 and text[i - 1] != '\n' and isWordByte(text[i - 1])) : (i -= 1) {}
    return i;
}

/// Where the word after `pos` ends. Mirror of `wordStartBefore`.
pub fn wordEndAfter(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    if (text[pos] == '\n') return pos + 1;
    var i = pos;
    while (i < text.len and text[i] != '\n' and !isWordByte(text[i])) : (i += 1) {}
    while (i < text.len and text[i] != '\n' and isWordByte(text[i])) : (i += 1) {}
    return i;
}

/// The word around `pos`, for a double-click. A click in the run of spaces
/// between two words selects the spaces, not the word to one side of them
/// — picking a side would be a coin toss the user did not ask you to flip.
pub fn wordAround(text: []const u8, pos: usize) struct { start: usize, end: usize } {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    const p = @min(pos, text.len);
    // Anchor on the byte under the caret, or the one before it at the end
    // of a line, so a double-click past the last word still picks it.
    const probe = if (p < text.len and text[p] != '\n') p else if (p > 0) p - 1 else p;
    if (probe >= text.len or text[probe] == '\n') return .{ .start = p, .end = p };
    const word = isWordByte(text[probe]);
    var s = probe;
    while (s > 0 and text[s - 1] != '\n' and isWordByte(text[s - 1]) == word) : (s -= 1) {}
    var e = probe;
    while (e < text.len and text[e] != '\n' and isWordByte(text[e]) == word) : (e += 1) {}
    return .{ .start = s, .end = e };
}

/// Strip a pasted clipboard's line endings down to the one the buffer
/// speaks. A CRLF arriving verbatim would put a stray `\r` at the end of
/// every line, which is invisible on screen and would ride the wire into
/// `rill remount` — where it is a parse error nobody can see.
pub fn normaliseNewlines(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(gpa, src.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\r') {
            // Both CRLF and a lone CR become one `\n`.
            if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
            out.appendAssumeCapacity('\n');
        } else {
            out.appendAssumeCapacity(src[i]);
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── Undo ────────────────────────────────────────────────────────────

/// What an edit was, for the purposes of coalescing. A run of `.typing`
/// that carries straight on from the last one is one undo step; anything
/// else starts a new one.
pub const EditKind = enum { typing, deleting, other };

const Snapshot = struct {
    text: []u8,
    cursor: u32,
    anchor: ?u32,
};

/// Snapshots kept. A prompt-sized buffer times this is well under a
/// megabyte, and a stack that forgets is better than one that grows
/// without a ceiling in a panel that stays mounted for a session.
const UNDO_MAX: usize = 200;

// ── The component ───────────────────────────────────────────────────

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("textarea", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    target: []u8, // stripped of leading `#` and of `state.`? no — kept whole
    action: []u8,
    placeholder: []u8,

    /// `Length.percent` is a FRACTION — 100% is 1.0, not 100. Writing the
    /// human number here made the box a hundred times the width it was
    /// offered, which shows up on screen as "wrap is broken" rather than
    /// as a width bug: the text simply never reaches a right-hand edge.
    width: box_helpers.Length = .{ .percent = 1.0 },
    rows: u16 = DEFAULT_ROWS,
    /// An explicit `height=` in pixels, which wins over `rows`.
    height_px: ?f32 = null,

    wrap: Wrap = .word,
    submit: Submit = .none,
    mono: bool = false,
    live: bool = false,
    clear_on_submit: bool = false,

    color: [4]f32 = input.FIELD_BG,
    border: [4]f32 = input.FIELD_BORDER,
    text_color: [4]f32 = input.TEXT_COLOR,
    active_border: [4]f32 = input.FIELD_BORDER_FOCUSED,

    /// Raw UTF-8. `\n` is the only line separator that ever gets in — see
    /// `normaliseNewlines`.
    buffer: std.ArrayListUnmanaged(u8) = .{},
    /// Byte offset, always on a codepoint boundary.
    cursor: usize = 0,
    /// The other end of the selection, or null when there is none.
    anchor: ?usize = null,
    /// See the header: which side of a soft break the caret is drawn on.
    affinity_before: bool = false,

    focused: bool = false,
    /// A selection drag is live. Also keeps a synced `initial=` out.
    dragging: bool = false,
    /// For double- and triple-click. Wall clock because there is no frame
    /// counter down here and the gesture is measured in human time anyway.
    last_click_ms: i64 = 0,
    click_x: f32 = 0,
    click_y: f32 = 0,
    /// 1 = caret, 2 = word, 3 = line. GLFW reports no double-click, so
    /// the run is counted here.
    click_run: u8 = 0,
    /// When the last edit landed, so the caret can stay SOLID through a
    /// burst of typing instead of blinking out the character just made.
    last_edit_ms: i64 = 0,

    /// The x a vertical arrow is aiming for, held across short lines.
    ///
    /// **The bug this exists for is the classic one.** Without it, Down
    /// through a short line moves the caret to that line's end and the
    /// next Down carries on from there — so passing a short line silently
    /// drags the column left and never gives it back.
    goal_x: ?f32 = null,

    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Set by anything that moves the caret; consumed by the next layout,
    /// which is the only place that knows where the caret actually is.
    scroll_to_caret: bool = false,

    // The line model, rebuilt every layout and READ by `on_input`.
    // It has to live here rather than in the layout's arena: an arrow key
    // arrives between frames, with no font in reach, and "which line am I
    // on" is a question only the last layout can answer.
    lines: std.ArrayListUnmanaged(VisLine) = .{},
    xs: std.ArrayListUnmanaged(f32) = .{},
    /// Where the text was drawn last frame, so a click can be turned into
    /// a byte offset. Zero until the first layout.
    content_x: f32 = 0,
    content_y: f32 = 0,
    content_w: f32 = 0,
    content_h: f32 = 0,
    line_h: f32 = 16,

    undo_stack: std.ArrayListUnmanaged(Snapshot) = .{},
    redo_stack: std.ArrayListUnmanaged(Snapshot) = .{},
    last_edit_kind: EditKind = .other,
    last_edit_end: usize = 0,

    /// The last seed text seen, so a change can be told from a repeat.
    last_seed: []u8,

    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    spark: ?*spark_mod.Spark = null,

    /// In the user's hands right now. A synced seed must not land while it
    /// is — `:::input`'s rule, and here it also defangs the `live` write:
    /// a box publishing to the path it reads re-enters `ingest` on every
    /// keystroke, and this is what makes that re-entry a no-op.
    fn editing(self: *const Component) bool {
        return self.focused or self.dragging;
    }

    fn selection(self: *const Component) ?struct { start: usize, end: usize } {
        const a = self.anchor orelse return null;
        if (a == self.cursor) return null;
        return .{ .start = @min(a, self.cursor), .end = @max(a, self.cursor) };
    }

    /// The visual line the CARET is drawn on, honouring affinity.
    fn caretLine(self: *const Component) usize {
        const ls = self.lines.items;
        if (ls.len == 0) return 0;
        const li = lineOf(ls, self.cursor);
        if (self.affinity_before and li > 0 and ls[li - 1].end == self.cursor and !ls[li - 1].hard) {
            return li - 1;
        }
        return li;
    }

    fn caretX(self: *const Component) f32 {
        const ls = self.lines.items;
        if (ls.len == 0 or self.xs.items.len == 0) return 0;
        const li = self.caretLine();
        if (self.cursor == ls[li].end) return ls[li].width;
        return self.xs.items[@min(self.cursor, self.xs.items.len - 1)];
    }

    fn maxScrollY(self: *const Component) f32 {
        const n: f32 = @floatFromInt(self.lines.items.len);
        return @max(0, n * self.line_h - self.content_h);
    }

    fn maxScrollX(self: *const Component) f32 {
        if (self.wrap == .word) return 0;
        var widest: f32 = 0;
        for (self.lines.items) |ln| widest = @max(widest, ln.width);
        // The caret needs somewhere to stand past the last glyph, or the
        // end of the longest line can never be scrolled fully into view.
        return @max(0, widest + input.CARET_W - self.content_w);
    }

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var target_raw: []const u8 = "";
        var action_raw: []const u8 = "";
        var placeholder_raw: []const u8 = "";
        var initial_raw: ?[]const u8 = null;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "action")) {
                action_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "placeholder")) {
                placeholder_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "initial")) {
                initial_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "wrap")) {
                if (parseWrap(attr.value)) |w| self.wrap = w;
            } else if (std.mem.eql(u8, attr.key, "submit")) {
                if (parseSubmit(attr.value)) |s| self.submit = s;
            } else if (std.mem.eql(u8, attr.key, "mono")) {
                self.mono = isFlag(attr.value);
            } else if (std.mem.eql(u8, attr.key, "live")) {
                self.live = isFlag(attr.value);
            } else if (std.mem.eql(u8, attr.key, "clear_on_submit")) {
                self.clear_on_submit = isFlag(attr.value);
            } else if (std.mem.eql(u8, attr.key, "rows")) {
                if (std.fmt.parseInt(u16, std.mem.trim(u8, attr.value, " \t"), 10)) |r| {
                    if (r > 0) self.rows = r;
                } else |_| {}
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| switch (l) {
                    .pixels => |p| self.height_px = p,
                    else => {},
                };
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, attr.key, "color")) {
                if (box_helpers.parseColor(attr.value)) |v| self.color = v;
            } else if (std.mem.eql(u8, attr.key, "border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.border = v;
            } else if (std.mem.eql(u8, attr.key, "text")) {
                if (box_helpers.parseColor(attr.value)) |v| self.text_color = v;
            } else if (std.mem.eql(u8, attr.key, "active_border")) {
                if (box_helpers.parseColor(attr.value)) |v| self.active_border = v;
            }
        }

        const target = if (target_raw.len > 0 and target_raw[0] == '#') target_raw[1..] else target_raw;
        const is_state_target = std.mem.startsWith(u8, target, "state.");
        // Exactly `:::input`'s rule: a component target's `handle_update`
        // switches on the verb, so an absent one is a missing argument; a
        // state target has a single primitive verb, so it is an argument
        // with no meaning here. The two controls have to agree about this
        // or the vocabulary has an exception in it.
        if (target.len > 0 and !is_state_target and action_raw.len == 0) {
            return Error.TextareaMissingAction;
        }

        // The body seeds the buffer, verbatim — that is what a multi-line
        // control has a body FOR. `initial=` wins when both are given,
        // because it is the one that can carry a `${state.x}`.
        const seed: ?[]const u8 = initial_raw orelse
            (if (spec.body.len > 0) spec.body else null);

        if (seed) |seed_text| {
            const first = self.buffer.items.len == 0 and self.cursor == 0 and seed_text.len > 0;
            // Seed AND sync, but only when the attribute MOVED and never
            // mid-edit. `:::input` learned both halves the hard way: a
            // static `initial=` re-applied on every re-parse wipes what
            // was typed, and a live one landing mid-edit yanks the text
            // out from under the caret.
            const moved = !std.mem.eql(u8, seed_text, self.last_seed);
            if (first or (moved and !self.editing())) {
                self.buffer.clearRetainingCapacity();
                try self.buffer.appendSlice(a, seed_text);
                self.cursor = self.buffer.items.len;
                self.anchor = null;
                self.clearHistory();
            }
            try component_mod.adoptString(a, &self.last_seed, seed_text);
        }

        // `adoptString` rather than free-and-dupe: a box with
        // `target=state.x live` subscribes to the path it writes and
        // `State.set` notifies synchronously, so this function re-enters
        // while a caller upstack still holds a slice of `self.target`.
        try component_mod.adoptString(a, &self.target, target);
        try component_mod.adoptString(a, &self.action, action_raw);
        try component_mod.adoptString(a, &self.placeholder, placeholder_raw);
    }

    fn clearHistory(self: *Component) void {
        for (self.undo_stack.items) |s| self.allocator.free(s.text);
        for (self.redo_stack.items) |s| self.allocator.free(s.text);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
        self.last_edit_kind = .other;
    }
};

/// A bare flag, `:::frosted_glass {backdrop}`-style. An explicit `=0`
/// turns it off so a templated `mono=${state.x}` can decide either way.
fn isFlag(v: []const u8) bool {
    return v.len == 0 or !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
}

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .spark = spark,
        .target = try allocator.dupe(u8, ""),
        .action = try allocator.dupe(u8, ""),
        .placeholder = try allocator.dupe(u8, ""),
        .last_seed = try allocator.dupe(u8, ""),
    };
    errdefer {
        allocator.free(c.target);
        allocator.free(c.action);
        allocator.free(c.placeholder);
        allocator.free(c.last_seed);
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
    c.clearHistory();
    c.undo_stack.deinit(allocator);
    c.redo_stack.deinit(allocator);
    c.lines.deinit(allocator);
    c.xs.deinit(allocator);
    c.buffer.deinit(allocator);
    allocator.free(c.target);
    allocator.free(c.action);
    allocator.free(c.placeholder);
    allocator.free(c.last_seed);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .on_scroll = onScroll,
    .focusable = true,
    // The caret blinks on a wall clock and the box re-walks on every
    // keystroke. Same trade `:::input` makes: cheap to walk, and a
    // version counter would have to be bumped per frame anyway for the
    // blink. `:::clip`'s reason applies on top — this component pushes a
    // clip, and a cached subtree's clip index points into the clip table
    // of the frame that recorded it.
    .disable_cache = true,
};

// ── Visual constants ────────────────────────────────────────────────
//
// The palette, the padding and the caret all come from `:::input` — a
// textarea is the same material cut larger, and a second set of numbers
// would drift the way the button's and the field's already did once.

/// Six lines: tall enough to be visibly a multi-line surface, short
/// enough to sit in a panel beside other controls.
const DEFAULT_ROWS: u16 = 6;

/// The inset used for LAYOUT, fixed at the focused border's thickness so
/// that focusing a box does not move its text by half a pixel. The border
/// is still DRAWN at its own thickness; only the content rect is frozen.
const INSET: f32 = input.BORDER_PX_FOCUSED;
const PAD_Y: f32 = 5;

/// A selection wash in the shell's one lit colour. Amber is what "this is
/// live" means everywhere else here — the grip, the dial's home mark, a
/// pressed key, a focused border — and a selection that picked its own
/// colour would be the exception that makes the rule decoration.
const SELECTION_COLOR: [4]f32 = .{ 1.0, 0.68, 0.0, 0.22 };

/// How far a selection runs past the end of a line whose newline is
/// inside it. Without this a run of empty lines in the middle of a
/// selection is invisible, and you cannot tell whether they are included.
const SELECTED_NEWLINE_PX: f32 = 5;

/// What Tab inserts. Spaces rather than a tab byte, because the width of
/// a `\t` is whatever the font happens to say and a program indented in
/// them would line up differently in a proportional face than a mono one.
/// Two, because rill is mostly flat and a console is narrow.
const TAB_SPACES = "  ";

// GLFW key codes and modifier bits, re-declared for the reason
// `:::input` re-declares its eight: a component does not depend on GLFW.
// Stable across GLFW 3.x.
const KEY_ENTER: i32 = 257;
const KEY_TAB: i32 = 258;
const KEY_BACKSPACE: i32 = 259;
const KEY_DELETE: i32 = 261;
const KEY_RIGHT: i32 = 262;
const KEY_LEFT: i32 = 263;
const KEY_DOWN: i32 = 264;
const KEY_UP: i32 = 265;
const KEY_PAGE_UP: i32 = 266;
const KEY_PAGE_DOWN: i32 = 267;
const KEY_HOME: i32 = 268;
const KEY_END: i32 = 269;
const KEY_KP_ENTER: i32 = 335;
const KEY_A: i32 = 65;
const KEY_C: i32 = 67;
const KEY_V: i32 = 86;
const KEY_X: i32 = 88;
const KEY_Y: i32 = 89;
const KEY_Z: i32 = 90;

const MOD_SHIFT: u32 = 0x0001;
const MOD_CONTROL: u32 = 0x0002;

fn hasMod(mods: u32, bit: u32) bool {
    return (mods & bit) != 0;
}

// ── Layout + render ─────────────────────────────────────────────────

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const style = if (c.mono) lc.theme.applyCodeInline(lc.theme.body) else lc.theme.body;

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const hb = lc.fonts.hbFont(style.font_id);
    const fscale = lc.fonts.scale(style.font_id);
    const m = lc.fonts.metrics(style.font_id);

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 480;
    const w: f32 = c.width.resolve(max_w, fallback_w);
    const line_h = m.line_height;
    const h: f32 = c.height_px orelse
        (line_h * @as(f32, @floatFromInt(c.rows)) + 2 * (INSET + PAD_Y));

    c.line_h = line_h;
    c.content_x = origin[0] + INSET + input.PAD_X;
    c.content_y = origin[1] + INSET + PAD_Y;
    c.content_w = @max(0, w - 2 * (INSET + input.PAD_X));
    c.content_h = @max(0, h - 2 * (INSET + PAD_Y));

    // ── The frame, drawn before the clip so it is not cut by it ──────
    const border_px = if (c.focused) input.BORDER_PX_FOCUSED else input.BORDER_PX;
    const border_rgba = if (c.focused) c.active_border else c.border;
    const bg_rgba = if (c.focused) input.FIELD_BG_FOCUSED else c.color;

    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = border_rgba,
        .radius = input.RADIUS,
    });
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + border_px, origin[1] + border_px },
        .dst_size = .{ w - 2 * border_px, h - 2 * border_px },
        .color = bg_rgba,
        .radius = @max(0, input.RADIUS - border_px),
    });
    // The catch-light along the inside of the bottom edge: a field is a
    // hole, so its light lands at the bottom. `:::input`'s reasoning.
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + border_px, origin[1] + h - border_px - 1 },
        .dst_size = .{ w - 2 * border_px, 1 },
        .color = input.FIELD_BOTTOM_LIGHT,
        .radius = 0,
    });

    // ── The line model ──────────────────────────────────────────────
    const text = c.buffer.items;
    const xs_hard = try aa.alloc(f32, text.len + 1);
    try measureHardLines(aa, hb, fscale, text, xs_hard);
    try layoutLines(c.allocator, text, xs_hard, c.wrap, c.content_w, &c.lines, &c.xs);

    // ── Scroll ──────────────────────────────────────────────────────
    if (c.scroll_to_caret and c.focused) {
        c.scroll_to_caret = false;
        const li = c.caretLine();
        const top = @as(f32, @floatFromInt(li)) * line_h;
        if (top < c.scroll_y) c.scroll_y = top;
        if (top + line_h > c.scroll_y + c.content_h) c.scroll_y = top + line_h - c.content_h;
        const cx = c.caretX();
        if (cx - input.CARET_W < c.scroll_x) c.scroll_x = @max(0, cx - input.CARET_W);
        if (cx + input.CARET_W > c.scroll_x + c.content_w) c.scroll_x = cx + input.CARET_W - c.content_w;
    }
    c.scroll_y = std.math.clamp(c.scroll_y, 0, c.maxScrollY());
    c.scroll_x = std.math.clamp(c.scroll_x, 0, c.maxScrollX());

    // ── Everything from here is inside the window ───────────────────
    // Seal what came before (the frame included) with the clip already in
    // force, so this box's clip cannot reach backwards over its siblings.
    try out.sealClips(lc.current_clip);
    const outer = lc.current_clip;
    const clip = try out.pushClip(outer, .{
        .x = c.content_x,
        .y = c.content_y,
        .w = c.content_w,
        .h = c.content_h,
    });
    lc.current_clip = clip;
    // Restore on ANY exit, or the rest of the document draws clipped to
    // this box — `:::clip` pays for this with an explicit errdefer; a
    // defer is the same promise and covers the early returns too.
    defer {
        out.sealClips(clip) catch {};
        lc.current_clip = outer;
    }

    const sel = c.selection();
    const show_placeholder = text.len == 0 and c.placeholder.len > 0;

    var li: usize = 0;
    while (li < c.lines.items.len) : (li += 1) {
        const ln = c.lines.items[li];
        const line_top = c.content_y + @as(f32, @floatFromInt(li)) * line_h - c.scroll_y;
        // Cull only lines ENTIRELY outside. A line that overlaps the edge
        // must still be drawn and let the scissor cut through it: half an
        // ascender showing is what tells a reader there is more above.
        if (line_top + line_h < c.content_y) continue;
        if (line_top > c.content_y + c.content_h) break;

        const pen_x = c.content_x - c.scroll_x;

        // Selection wash, behind the glyphs (quads are a whole layer
        // under the glyph layer, so this cannot land on top of the text).
        if (sel) |s| {
            if (s.end > ln.start and s.start <= ln.end) {
                const from = @max(s.start, ln.start);
                const to = @min(s.end, ln.end);
                const x0 = if (from == ln.end) ln.width else c.xs.items[from];
                const x1 = if (to == ln.end) ln.width else c.xs.items[to];
                // The newline itself is selected when the selection runs
                // past this line's end — show it, or a selected blank line
                // is a gap you cannot tell is included.
                const tail: f32 = if (s.end > ln.end) SELECTED_NEWLINE_PX else 0;
                try out.appendQuad(lc, .{
                    .dst_pos = .{ pen_x + x0, line_top },
                    .dst_size = .{ @max(1, x1 - x0) + tail, line_h },
                    .color = SELECTION_COLOR,
                    .radius = 0,
                });
            }
        }

        if (ln.end > ln.start) {
            const run = try shape.shapeUtf8(aa, hb, text[ln.start..ln.end]);
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
                pen_x,
                line_top + m.ascender,
                c.text_color,
                style.hot_color,
                style.attention,
                lc.zoom,
            );
        }
    }

    if (show_placeholder) {
        const run = try shape.shapeUtf8(aa, hb, c.placeholder);
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
            c.content_x,
            c.content_y + m.ascender,
            input.PLACEHOLDER_COLOR,
            style.hot_color,
            style.attention,
            lc.zoom,
        );
    }

    // ── The caret ───────────────────────────────────────────────────
    if (c.focused) {
        const ms = std.time.milliTimestamp();
        const phase = @mod(ms, input.BLINK_PERIOD_MS);
        // A caret that blinks while you are typing hides the character you
        // just made. Every editor solves it the same way: the blink clock
        // restarts on an edit, so the caret is solid through a burst of
        // typing and only starts winking once the hands stop.
        const solid = (ms - c.last_edit_ms) < input.BLINK_PERIOD_MS;
        if (solid or phase < @divTrunc(input.BLINK_PERIOD_MS, 2)) {
            const cl = c.caretLine();
            const cx = c.content_x + c.caretX() - c.scroll_x;
            const cy = c.content_y + @as(f32, @floatFromInt(cl)) * line_h - c.scroll_y;
            try out.appendQuad(lc, .{
                .dst_pos = .{ cx, cy + 1 },
                .dst_size = .{ input.CARET_W, line_h - 2 },
                .color = input.CARET_COLOR,
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
        .baseline = c.content_y + m.ascender,
    };
    c.last_box = box;
    return box;
}

/// Fill `xs_hard[i]` with the x of byte `i` measured from the start of its
/// HARD line. One shaping call per hard line, which is what makes ligatures
/// and kerning right within a line and is why this cannot be done per
/// visual line — the wrapper needs the measurements before it knows where
/// the visual lines are.
///
/// **Positions inside a cluster are interpolated** rather than collapsed
/// onto the cluster's start. A ligature spanning two bytes otherwise puts
/// two caret positions in the same pixel; the interpolation keeps them
/// ordered, which is all the caret arithmetic needs of them.
fn measureHardLines(
    aa: std.mem.Allocator,
    hb: shape.Font,
    fscale: f32,
    text: []const u8,
    xs_hard: []f32,
) !void {
    @memset(xs_hard, 0);
    var start: usize = 0;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (end > start) {
            const run = try shape.shapeUtf8(aa, hb, text[start..end]);
            const len = end - start;
            var pen: f32 = 0;
            var g: usize = 0;
            while (g < run.glyphs.len) {
                const cl: usize = @min(run.glyphs[g].cluster, len);
                var j = g;
                var adv: f32 = 0;
                while (j < run.glyphs.len and run.glyphs[j].cluster == run.glyphs[g].cluster) : (j += 1) {
                    adv += run.glyphs[j].x_advance * fscale;
                }
                const next_cl: usize = if (j < run.glyphs.len)
                    @min(run.glyphs[j].cluster, len)
                else
                    len;
                const span = if (next_cl > cl) next_cl - cl else 1;
                var b: usize = cl;
                while (b < next_cl) : (b += 1) {
                    const frac: f32 = @as(f32, @floatFromInt(b - cl)) / @as(f32, @floatFromInt(span));
                    xs_hard[start + b] = pen + adv * frac;
                }
                pen += adv;
                g = j;
            }
            xs_hard[end] = pen;
        } else {
            xs_hard[start] = 0;
        }
        if (end >= text.len) break;
        // The `\n` byte itself is not shaped; the next line's first byte
        // starts a new origin at zero, which `@memset` already left there.
        start = end + 1;
    }
}

// ── Input ───────────────────────────────────────────────────────────

/// A wheel notch over the box.
///
/// Consumed only when it can actually move that way — at the bottom of the
/// text a further downward notch bubbles out to whatever contains this box,
/// and if nothing does, the host scrolls the page. `:::clip`'s rule, and
/// answering "yes, I am a scroller" regardless is what makes a nested
/// scrolling region feel like a trap.
fn onScroll(ctx: *anyopaque, ev: element.ScrollEvent, _: *anyopaque) anyerror!bool {
    const c: *Component = @ptrCast(@alignCast(ctx));
    var took = false;
    const max_y = c.maxScrollY();
    if (ev.dy != 0 and max_y > 0) {
        const next = std.math.clamp(c.scroll_y + ev.dy, 0, max_y);
        if (next != c.scroll_y) {
            c.scroll_y = next;
            took = true;
        }
    }
    const max_x = c.maxScrollX();
    if (ev.dx != 0 and max_x > 0) {
        const next = std.math.clamp(c.scroll_x + ev.dx, 0, max_x);
        if (next != c.scroll_x) {
            c.scroll_x = next;
            took = true;
        }
    }
    if (took) {
        if (c.spark) |sp| sp.host_state.dirty = true;
    }
    return took;
}

/// How long a gap still counts as part of the same click run. GLFW does
/// not report double-clicks, so the widget has to; 400ms is the interval
/// every toolkit's default lands within.
const MULTI_CLICK_MS: i64 = 400;
/// How far the pointer may move between clicks of a run. A double-click
/// that drifted three pixels is still a double-click.
const MULTI_CLICK_SLOP: f32 = 4;

fn onInput(ctx: *anyopaque, event: element.InputEvent, state_ptr: *anyopaque) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .focus_gained => {
            c.focused = true;
            c.scroll_to_caret = true;
            dirty(c);
        },
        .focus_lost => {
            c.focused = false;
            c.dragging = false;
            dirty(c);
        },
        .char_input => |cp| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return;
            try insertText(c, buf[0..n], .typing);
            try afterEdit(c, state_ptr);
        },
        .key_down => |k| try handleKey(c, k, state_ptr),
        .mouse_down => |mev| {
            if (mev.button != 0) return;
            const off = offsetAt(c, mev.local);
            const now = std.time.milliTimestamp();
            // Same place, soon enough: the run continues. Measured in
            // PIXELS rather than in byte offsets, because a person aiming
            // a second click aims at the same spot on screen and the byte
            // under it may well have changed.
            const near = (now - c.last_click_ms) < MULTI_CLICK_MS and
                @abs(c.click_x - mev.local[0]) < MULTI_CLICK_SLOP and
                @abs(c.click_y - mev.local[1]) < MULTI_CLICK_SLOP;
            c.click_run = if (near and c.click_run < 3) c.click_run + 1 else if (near) 3 else 1;
            c.last_click_ms = now;
            c.click_x = mev.local[0];
            c.click_y = mev.local[1];

            switch (c.click_run) {
                1 => {
                    c.cursor = off;
                    c.anchor = off;
                    c.dragging = true;
                    setAffinityFromClick(c, mev.local, off);
                },
                2 => {
                    const wd = wordAround(c.buffer.items, off);
                    c.anchor = wd.start;
                    c.cursor = wd.end;
                    c.dragging = false;
                },
                else => {
                    // Triple and beyond: the whole HARD line, not the
                    // visual one. A wrapped paragraph is one thing to a
                    // person even when it is four rows on screen.
                    const ls = hardLineBounds(c.buffer.items, off);
                    c.anchor = ls.start;
                    c.cursor = ls.end;
                    c.dragging = false;
                    c.click_run = 3;
                },
            }
            c.goal_x = null;
            c.scroll_to_caret = true;
            dirty(c);
        },
        .mouse_move => |mev| {
            if (!c.dragging or !mev.button_down) return;
            const off = offsetAt(c, mev.local);
            if (off == c.cursor) return;
            c.cursor = off;
            c.affinity_before = false;
            c.goal_x = null;
            c.scroll_to_caret = true;
            dirty(c);
        },
        .mouse_up => |mev| {
            if (mev.button == 0) c.dragging = false;
        },
    }
}

/// The byte offset under a point in the box's local coordinates.
fn offsetAt(c: *Component, local: [2]f32) usize {
    const ls = c.lines.items;
    if (ls.len == 0) return 0;
    const y = local[1] - (c.content_y - c.last_box.y) + c.scroll_y;
    const row_f = @floor(y / c.line_h);
    const row: usize = if (row_f < 0)
        0
    else if (row_f >= @as(f32, @floatFromInt(ls.len)))
        ls.len - 1
    else
        @intFromFloat(row_f);
    const x = local[0] - (c.content_x - c.last_box.x) + c.scroll_x;
    return offsetAtX(c.buffer.items, ls, c.xs.items, row, x);
}

/// A click past the right-hand end of a SOFT-wrapped line means "the end
/// of this line", not "the start of the next one" — see the header's note
/// on affinity.
fn setAffinityFromClick(c: *Component, local: [2]f32, off: usize) void {
    c.affinity_before = false;
    const ls = c.lines.items;
    if (ls.len == 0) return;
    const li = lineOf(ls, off);
    if (li == 0) return;
    const above = ls[li - 1];
    if (above.end != off or above.hard) return;
    const x = local[0] - (c.content_x - c.last_box.x) + c.scroll_x;
    if (x >= above.width) c.affinity_before = true;
}

/// The whole hard line containing `off`, newline excluded.
fn hardLineBounds(text: []const u8, off: usize) struct { start: usize, end: usize } {
    const p = @min(off, text.len);
    var s = p;
    while (s > 0 and text[s - 1] != '\n') : (s -= 1) {}
    var e = p;
    while (e < text.len and text[e] != '\n') : (e += 1) {}
    return .{ .start = s, .end = e };
}

fn dirty(c: *Component) void {
    if (c.spark) |sp| sp.host_state.dirty = true;
}

/// Run after every edit. **Nothing may touch `c` after this returns** —
/// the `live` publish goes through `State.set`, which notifies its
/// subscribers synchronously and re-enters `ingest`.
fn afterEdit(c: *Component, state_ptr: *anyopaque) !void {
    c.scroll_to_caret = true;
    c.last_edit_ms = std.time.milliTimestamp();
    dirty(c);
    if (!c.live) return;
    if (!std.mem.startsWith(u8, c.target, "state.")) return;
    publishState(c, state_ptr, c.buffer.items);
}

fn handleKey(c: *Component, k: element.KeyEvent, state_ptr: *anyopaque) !void {
    const shift = hasMod(k.mods, MOD_SHIFT);
    const ctrl = hasMod(k.mods, MOD_CONTROL);

    if (ctrl) {
        switch (k.key) {
            KEY_A => {
                c.anchor = 0;
                c.cursor = c.buffer.items.len;
                c.affinity_before = false;
                c.goal_x = null;
                c.scroll_to_caret = true;
                dirty(c);
                return;
            },
            KEY_C => {
                copySelection(c);
                return;
            },
            KEY_X => {
                copySelection(c);
                if (c.selection() != null) {
                    try pushUndo(c, .other);
                    _ = try deleteSelection(c);
                    try afterEdit(c, state_ptr);
                }
                return;
            },
            KEY_V => {
                try paste(c);
                try afterEdit(c, state_ptr);
                return;
            },
            KEY_Z => {
                // Ctrl+Shift+Z is redo everywhere that also has Ctrl+Y.
                if (shift) try restore(c, &c.redo_stack, &c.undo_stack) else try restore(c, &c.undo_stack, &c.redo_stack);
                try afterEdit(c, state_ptr);
                return;
            },
            KEY_Y => {
                try restore(c, &c.redo_stack, &c.undo_stack);
                try afterEdit(c, state_ptr);
                return;
            },
            else => {},
        }
    }

    switch (k.key) {
        KEY_ENTER, KEY_KP_ENTER => {
            const dispatches = switch (c.submit) {
                .none => false,
                .enter => !shift,
                .ctrl_enter => ctrl,
            };
            if (dispatches) {
                submitBuffer(c, state_ptr);
                return; // nothing may touch `c` — see `submitBuffer`
            }
            try insertText(c, "\n", .other);
            try afterEdit(c, state_ptr);
        },
        KEY_TAB => {
            try insertText(c, TAB_SPACES, .other);
            try afterEdit(c, state_ptr);
        },
        KEY_BACKSPACE => {
            try pushUndo(c, .deleting);
            if (!try deleteSelection(c)) {
                if (c.cursor == 0) return;
                const start = if (ctrl)
                    wordStartBefore(c.buffer.items, c.cursor)
                else
                    input.prevCodepointStart(c.buffer.items, c.cursor);
                removeRange(c, start, c.cursor);
                c.cursor = start;
            }
            c.anchor = null;
            c.affinity_before = false;
            c.goal_x = null;
            noteEdit(c, .deleting);
            try afterEdit(c, state_ptr);
        },
        KEY_DELETE => {
            try pushUndo(c, .deleting);
            if (!try deleteSelection(c)) {
                if (c.cursor >= c.buffer.items.len) return;
                const end = if (ctrl)
                    wordEndAfter(c.buffer.items, c.cursor)
                else
                    input.nextCodepointEnd(c.buffer.items, c.cursor);
                removeRange(c, c.cursor, end);
            }
            c.anchor = null;
            c.affinity_before = false;
            c.goal_x = null;
            noteEdit(c, .deleting);
            try afterEdit(c, state_ptr);
        },
        KEY_LEFT => {
            const to = if (ctrl)
                wordStartBefore(c.buffer.items, c.cursor)
            else if (c.selection()) |s| (if (shift) input.prevCodepointStart(c.buffer.items, c.cursor) else s.start)
            else
                input.prevCodepointStart(c.buffer.items, c.cursor);
            moveTo(c, to, shift);
        },
        KEY_RIGHT => {
            const to = if (ctrl)
                wordEndAfter(c.buffer.items, c.cursor)
            else if (c.selection()) |s| (if (shift) input.nextCodepointEnd(c.buffer.items, c.cursor) else s.end)
            else
                input.nextCodepointEnd(c.buffer.items, c.cursor);
            moveTo(c, to, shift);
        },
        KEY_UP => verticalMove(c, -1, shift),
        KEY_DOWN => verticalMove(c, 1, shift),
        KEY_PAGE_UP => verticalMove(c, -pageRows(c), shift),
        KEY_PAGE_DOWN => verticalMove(c, pageRows(c), shift),
        KEY_HOME => {
            if (ctrl) {
                moveTo(c, 0, shift);
                return;
            }
            const ls = c.lines.items;
            if (ls.len == 0) return;
            moveTo(c, ls[c.caretLine()].start, shift);
        },
        KEY_END => {
            if (ctrl) {
                moveTo(c, c.buffer.items.len, shift);
                return;
            }
            const ls = c.lines.items;
            if (ls.len == 0) return;
            const li = c.caretLine();
            moveTo(c, ls[li].end, shift);
            // End on a wrapped row means the end of THIS row, so the caret
            // has to stay above the break rather than reappearing at the
            // start of the row below. The affinity bit exists for exactly
            // this keystroke and for a click at the same place.
            if (!ls[li].hard) c.affinity_before = true;
        },
        else => {},
    }
}

/// How many rows a Page key moves. One row of overlap, so the line you
/// were reading at the edge is still on screen after the jump — the
/// convention every pager has followed since `less`.
fn pageRows(c: *Component) i64 {
    const rows: i64 = @intFromFloat(@floor(c.content_h / @max(1, c.line_h)));
    return @max(1, rows - 1);
}

/// Move the caret, extending the selection when `extend`, dropping it
/// otherwise. Every horizontal and absolute motion goes through here so
/// the selection rules cannot differ between two keys.
fn moveTo(c: *Component, to: usize, extend: bool) void {
    if (extend) {
        if (c.anchor == null) c.anchor = c.cursor;
    } else {
        c.anchor = null;
    }
    c.cursor = @min(to, c.buffer.items.len);
    c.affinity_before = false;
    c.goal_x = null;
    c.scroll_to_caret = true;
    dirty(c);
}

/// Up/down by `delta` rows, holding the goal column — see `Component.goal_x`.
fn verticalMove(c: *Component, delta: i64, extend: bool) void {
    const ls = c.lines.items;
    if (ls.len == 0) return;
    const goal = c.goal_x orelse c.caretX();
    const from: i64 = @intCast(c.caretLine());
    const want = from + delta;

    if (want < 0) {
        // Up from the first row goes to the very start, and down from the
        // last to the very end. Doing nothing instead is the behaviour
        // that makes a box feel stuck.
        moveTo(c, 0, extend);
        return;
    }
    if (want >= @as(i64, @intCast(ls.len))) {
        moveTo(c, c.buffer.items.len, extend);
        return;
    }
    const target: usize = @intCast(want);
    if (extend) {
        if (c.anchor == null) c.anchor = c.cursor;
    } else {
        c.anchor = null;
    }
    c.cursor = offsetAtX(c.buffer.items, ls, c.xs.items, target, goal);
    // Landing exactly on a soft break means the row below; the caret was
    // aimed at THIS row, so say so.
    c.affinity_before = !ls[target].hard and c.cursor == ls[target].end;
    c.goal_x = goal;
    c.scroll_to_caret = true;
    dirty(c);
}

// ── Editing ─────────────────────────────────────────────────────────

fn removeRange(c: *Component, start: usize, end: usize) void {
    std.mem.copyForwards(u8, c.buffer.items[start..], c.buffer.items[end..]);
    c.buffer.items.len -= (end - start);
}

fn deleteSelection(c: *Component) !bool {
    const s = c.selection() orelse return false;
    removeRange(c, s.start, s.end);
    c.cursor = s.start;
    c.anchor = null;
    return true;
}

fn insertText(c: *Component, text: []const u8, kind: EditKind) !void {
    try pushUndo(c, kind);
    _ = try deleteSelection(c);
    try c.buffer.ensureUnusedCapacity(c.allocator, text.len);
    const old_len = c.buffer.items.len;
    c.buffer.items.len = old_len + text.len;
    if (c.cursor < old_len) {
        std.mem.copyBackwards(
            u8,
            c.buffer.items[c.cursor + text.len .. old_len + text.len],
            c.buffer.items[c.cursor..old_len],
        );
    }
    @memcpy(c.buffer.items[c.cursor .. c.cursor + text.len], text);
    c.cursor += text.len;
    c.anchor = null;
    c.affinity_before = false;
    c.goal_x = null;
    noteEdit(c, kind);
}

fn noteEdit(c: *Component, kind: EditKind) void {
    c.last_edit_kind = kind;
    c.last_edit_end = c.cursor;
}

// ── Undo ────────────────────────────────────────────────────────────

/// Snapshot the buffer before an edit, unless this edit simply continues
/// the last one.
///
/// **Coalescing is what makes undo usable rather than merely present.**
/// One step per keystroke means holding Ctrl+Z to get back a sentence; one
/// step per *run* of typing that carried straight on from the last is what
/// a person means by "undo that". A newline, a paste and a cut are always
/// `.other`, so a program undoes a line at a time.
fn pushUndo(c: *Component, kind: EditKind) !void {
    if (kind != .other and kind == c.last_edit_kind and c.cursor == c.last_edit_end and
        c.undo_stack.items.len > 0 and c.selection() == null)
    {
        return;
    }
    const snap = Snapshot{
        .text = try c.allocator.dupe(u8, c.buffer.items),
        .cursor = @intCast(c.cursor),
        .anchor = if (c.anchor) |a| @intCast(a) else null,
    };
    errdefer c.allocator.free(snap.text);
    try c.undo_stack.append(c.allocator, snap);
    if (c.undo_stack.items.len > UNDO_MAX) {
        const dropped = c.undo_stack.orderedRemove(0);
        c.allocator.free(dropped.text);
    }
    // A new edit forks history: whatever was redoable is now unreachable.
    for (c.redo_stack.items) |s| c.allocator.free(s.text);
    c.redo_stack.clearRetainingCapacity();
}

/// Pop `from`, pushing the CURRENT state onto `to`. Undo and redo are the
/// same operation with the stacks swapped, so they are one function — two
/// implementations of it is two places for the cursor to be restored
/// wrong.
fn restore(
    c: *Component,
    from: *std.ArrayListUnmanaged(Snapshot),
    to: *std.ArrayListUnmanaged(Snapshot),
) !void {
    if (from.items.len == 0) return;
    const mirror = Snapshot{
        .text = try c.allocator.dupe(u8, c.buffer.items),
        .cursor = @intCast(c.cursor),
        .anchor = if (c.anchor) |a| @intCast(a) else null,
    };
    errdefer c.allocator.free(mirror.text);
    try to.append(c.allocator, mirror);

    const snap = from.pop().?;
    defer c.allocator.free(snap.text);
    c.buffer.clearRetainingCapacity();
    try c.buffer.appendSlice(c.allocator, snap.text);
    c.cursor = @min(snap.cursor, c.buffer.items.len);
    c.anchor = if (snap.anchor) |a| @min(@as(usize, a), c.buffer.items.len) else null;
    c.affinity_before = false;
    c.goal_x = null;
    // The restored state is not a continuation of anything, so the next
    // keystroke starts a fresh undo step rather than coalescing into the
    // one we just came back from.
    c.last_edit_kind = .other;
}

// ── Clipboard ───────────────────────────────────────────────────────

fn copySelection(c: *Component) void {
    const s = c.selection() orelse return;
    const sp = c.spark orelse return;
    sp.setClipboardText(c.buffer.items[s.start..s.end]);
}

fn paste(c: *Component) !void {
    const sp = c.spark orelse return;
    const raw = sp.clipboardText() orelse return;
    if (raw.len == 0) return;
    // Copy before inserting: the host's buffer is borrowed only until the
    // next clipboard call, and `normaliseNewlines` allocates anyway.
    const text = try normaliseNewlines(c.allocator, raw);
    defer c.allocator.free(text);
    try insertText(c, text, .other);
}

// ── Dispatch ────────────────────────────────────────────────────────

/// Send the buffer wherever the box points, and clear it if asked to.
///
/// **Nothing may touch `c` after this returns.** `State.set` notifies
/// synchronously, so a box bound to the path it writes re-enters its own
/// `ingest` from inside here.
fn submitBuffer(c: *Component, state_ptr: *anyopaque) void {
    if (c.target.len == 0) return;
    const gpa = c.allocator;

    if (!c.clear_on_submit) {
        deliver(c, state_ptr, c.buffer.items);
        return;
    }
    // Clearing has to happen BEFORE the dispatch — see above, `c` is not
    // ours any more once the callee has the line — so the text is duped
    // and the box emptied first. `gpa` is captured rather than read back
    // off `c` for the same reason.
    const sent = gpa.dupe(u8, c.buffer.items) catch return;
    defer gpa.free(sent);
    c.buffer.clearRetainingCapacity();
    c.cursor = 0;
    c.anchor = null;
    c.scroll_x = 0;
    c.scroll_y = 0;
    c.clearHistory();
    deliver(c, state_ptr, sent);
}

fn deliver(c: *Component, state_ptr: *anyopaque, text: []const u8) void {
    if (std.mem.startsWith(u8, c.target, "state.")) {
        publishState(c, state_ptr, text);
        return;
    }
    if (c.action.len == 0) return;
    const sp = c.spark orelse return;
    sp.registry.handleUpdate(c.target, c.action, text) catch |e| {
        std.log.warn(":::textarea: dispatch failed: target=#{s} action={s} err={s}", .{
            c.target, c.action, @errorName(e),
        });
    };
}

/// Write `text` into the scope-local state at the box's `state.` target.
/// The newlines ride along verbatim, which is the rill console's whole
/// premise: `rill remount <cell> <source>` has carried a multi-statement
/// program on one line since 2026-08-24.
fn publishState(c: *Component, state_ptr: *anyopaque, text: []const u8) void {
    const key = c.target["state.".len..];
    if (key.len == 0) return;
    const st: *state_mod.State = @ptrCast(@alignCast(state_ptr));
    st.set(key, text) catch |e| {
        std.log.warn(":::textarea: state.set failed: err={s}", .{@errorName(e)});
    };
}

// ── Tests ───────────────────────────────────────────────────────────
//
// Everything here runs with no window, no font and no GPU: the line
// model is fed a made-up monospace ruler instead of HarfBuzz, which is
// the whole reason `layoutLines` takes measurements rather than making
// them. A gate that needed a device would be a gate nobody runs.

const testing = std.testing;

var _test_state = state_mod.State.init(testing.allocator);
var _test_spark = blk: {
    var s = spark_mod.Spark.testStub(testing.allocator);
    s.host_state = &_test_state;
    break :blk s;
};

/// A ruler where every byte is `char_w` wide and each hard line restarts
/// at zero. ASCII only, which every test below is.
fn monoXs(text: []const u8, char_w: f32, out: []f32) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i > 0 and text[i - 1] == '\n') start = i;
        out[i] = @as(f32, @floatFromInt(i - start)) * char_w;
    }
}

/// Stand in for `layoutAndRender`'s measuring half: rebuild the line
/// model from the buffer with the fake ruler. Tests call this wherever a
/// real frame would have happened.
fn relayout(c: *Component, char_w: f32, content_w: f32) !void {
    const gpa = testing.allocator;
    const xs_hard = try gpa.alloc(f32, c.buffer.items.len + 1);
    defer gpa.free(xs_hard);
    monoXs(c.buffer.items, char_w, xs_hard);
    c.content_w = content_w;
    c.line_h = 10;
    c.content_h = 40;
    try layoutLines(gpa, c.buffer.items, xs_hard, c.wrap, content_w, &c.lines, &c.xs);
}

/// Put the shared State back the way it was found.
///
/// The leak checker runs PER TEST, and a dispatch leaves a duped key and
/// value in the map — so a test that sends anywhere has to hand the map
/// back empty or it is reported against itself. `:::input`'s tests never
/// hit this because none of them dispatch to a `state.` target.
fn resetState() void {
    _test_state.deinit();
    _test_state = state_mod.State.init(testing.allocator);
}

fn makeBox(attrs: []const components.Attr, body: []const u8) !component_mod.Instance {
    const spec: components.Spec = .{ .name = "textarea", .attrs = attrs, .body = body };
    return create(&_test_spark, testing.allocator, &spec);
}

fn press(inst: component_mod.Instance, k: i32, mods: u32) !void {
    try onInput(inst.ctx, .{ .key_down = .{ .key = k, .mods = mods } }, @ptrCast(&_test_state));
}

fn typeStr(inst: component_mod.Instance, s: []const u8) !void {
    for (s) |ch| try onInput(inst.ctx, .{ .char_input = ch }, @ptrCast(&_test_state));
}

// ── The wrapper ─────────────────────────────────────────────────────

test "textarea: a line breaks at the space, not through the word" {
    // The bug this is paid for: breaking at the overflow position gives
    // "hello wo / rld", which is the difference between a text box and a
    // teletype.
    const text = "hello world";
    var xs: [12]f32 = undefined;
    monoXs(text, 10, &xs);
    // 80px of room: "hello wo" fits, "hello wor" does not.
    try testing.expectEqual(@as(usize, 6), nextBreak(text, &xs, 0, text.len, 80));
}

test "textarea: a word longer than the box breaks anyway, and makes progress" {
    // Two gates in one. Refusing to break would draw outside the box; a
    // break at or before `start` would make `layoutLines` spin forever,
    // which is the failure that takes the whole app with it.
    const text = "supercalifragilistic";
    var xs: [21]f32 = undefined;
    monoXs(text, 10, &xs);
    const brk = nextBreak(text, &xs, 0, text.len, 55);
    try testing.expect(brk > 0);
    try testing.expect(brk < text.len);
}

test "textarea: a trailing space hangs rather than wrapping a word early" {
    // "abc " in 30px of room: the space pushes the measured width to 40,
    // and wrapping on it would move "abc" to the next line for the sake of
    // a character with nothing in it.
    const text = "abc def";
    var xs: [8]f32 = undefined;
    monoXs(text, 10, &xs);
    try testing.expectEqual(@as(usize, 4), nextBreak(text, &xs, 0, text.len, 30));
}

test "textarea: wrap=none never breaks, however long the line" {
    const gpa = testing.allocator;
    const text = "a very long line indeed that is far wider than the box";
    const xs_hard = try gpa.alloc(f32, text.len + 1);
    defer gpa.free(xs_hard);
    monoXs(text, 10, xs_hard);
    var lines: std.ArrayListUnmanaged(VisLine) = .{};
    defer lines.deinit(gpa);
    var xs: std.ArrayListUnmanaged(f32) = .{};
    defer xs.deinit(gpa);
    try layoutLines(gpa, text, xs_hard, .none, 50, &lines, &xs);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqual(@as(u32, @intCast(text.len)), lines.items[0].end);
}

// ── The line model ──────────────────────────────────────────────────

test "textarea: a hard newline separates two offsets; a soft break shares one" {
    const gpa = testing.allocator;
    const text = "ab\ncd ef";
    const xs_hard = try gpa.alloc(f32, text.len + 1);
    defer gpa.free(xs_hard);
    monoXs(text, 10, xs_hard);
    var lines: std.ArrayListUnmanaged(VisLine) = .{};
    defer lines.deinit(gpa);
    var xs: std.ArrayListUnmanaged(f32) = .{};
    defer xs.deinit(gpa);
    // 30px: "cd " fits, "cd e" does not.
    try layoutLines(gpa, text, xs_hard, .word, 30, &lines, &xs);

    try testing.expectEqual(@as(usize, 3), lines.items.len);
    // Hard break: line 0 ends at the `\n` (offset 2), line 1 starts AFTER
    // it (offset 3). Two distinct positions with the newline between them.
    try testing.expectEqual(@as(u32, 2), lines.items[0].end);
    try testing.expectEqual(@as(u32, 3), lines.items[1].start);
    // Soft break: one offset, both roles.
    try testing.expectEqual(lines.items[1].end, lines.items[2].start);
    try testing.expect(lines.items[0].hard);
    try testing.expect(!lines.items[1].hard);
}

test "textarea: xs is rebased onto the VISUAL line, not the hard one" {
    // The bug: a wrapped line drawn from x=0 while its caret arithmetic
    // still measured from the start of the paragraph puts the caret
    // hundreds of pixels right of the glyph it belongs to.
    const gpa = testing.allocator;
    const text = "aaa bbb";
    const xs_hard = try gpa.alloc(f32, text.len + 1);
    defer gpa.free(xs_hard);
    monoXs(text, 10, xs_hard);
    var lines: std.ArrayListUnmanaged(VisLine) = .{};
    defer lines.deinit(gpa);
    var xs: std.ArrayListUnmanaged(f32) = .{};
    defer xs.deinit(gpa);
    try layoutLines(gpa, text, xs_hard, .word, 35, &lines, &xs);
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    // "bbb" starts at byte 4 and is drawn at the left edge of its row.
    try testing.expectEqual(@as(f32, 0), xs.items[4]);
    try testing.expectEqual(@as(f32, 10), xs.items[5]);
}

test "textarea: lineOf resolves a soft break to the LOWER line" {
    const lines = [_]VisLine{
        .{ .start = 0, .end = 4, .width = 40, .hard = false },
        .{ .start = 4, .end = 7, .width = 30, .hard = true },
    };
    try testing.expectEqual(@as(usize, 0), lineOf(&lines, 3));
    try testing.expectEqual(@as(usize, 1), lineOf(&lines, 4));
    try testing.expectEqual(@as(usize, 1), lineOf(&lines, 7));
}

test "textarea: offsetAtX reads a soft line's right edge from its width" {
    // The bug: `xs` at a soft break holds the LOWER line's zero, so a
    // click at the right-hand end of a wrapped row measured a distance of
    // zero and snapped the caret back to the start of the row.
    const gpa = testing.allocator;
    const text = "aaa bbb";
    const xs_hard = try gpa.alloc(f32, text.len + 1);
    defer gpa.free(xs_hard);
    monoXs(text, 10, xs_hard);
    var lines: std.ArrayListUnmanaged(VisLine) = .{};
    defer lines.deinit(gpa);
    var xs: std.ArrayListUnmanaged(f32) = .{};
    defer xs.deinit(gpa);
    try layoutLines(gpa, text, xs_hard, .word, 35, &lines, &xs);
    // A click far to the right of row 0 lands at its end (offset 4), not
    // at its start.
    try testing.expectEqual(@as(usize, 4), offsetAtX(text, lines.items, xs.items, 0, 500));
    try testing.expectEqual(@as(usize, 0), offsetAtX(text, lines.items, xs.items, 0, -50));
}

// ── Word walking ────────────────────────────────────────────────────

test "textarea: a word walk stops at a newline instead of hopping the line" {
    const text = "one two\nthree";
    // From inside "three", back to its start.
    try testing.expectEqual(@as(usize, 8), wordStartBefore(text, 12));
    // From the START of "three", exactly one step: onto the end of "two".
    try testing.expectEqual(@as(usize, 7), wordStartBefore(text, 8));
    // And the mirror going forward.
    try testing.expectEqual(@as(usize, 7), wordEndAfter(text, 4));
    try testing.expectEqual(@as(usize, 8), wordEndAfter(text, 7));

    // The case the guard is actually FOR, and the one the first version
    // of this gate missed: separators leading up to the newline. Walking
    // back from the end of a run of trailing spaces, a walk with no guard
    // sails through the `\n` (not a word byte either) and swallows the
    // whole line above.
    try testing.expectEqual(@as(usize, 4), wordStartBefore("abc\n   ", 7));
    try testing.expectEqual(@as(usize, 6), wordEndAfter("abc   \ndef", 3));
}

test "textarea: a Page key moves a screenful less one row" {
    // One row of overlap, so the line you were reading at the edge is
    // still on screen after the jump — every pager since `less`. And it
    // must CLAMP: a PageDown off the end goes to the end, not nowhere.
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try relayout(c, 10, 200); // line_h 10, content_h 40 → four rows
    try testing.expectEqual(@as(i64, 3), pageRows(c));

    c.cursor = 0;
    try press(inst, KEY_PAGE_DOWN, 0);
    try testing.expectEqual(@as(usize, 0), c.caretLine() - 3);
    try press(inst, KEY_PAGE_DOWN, 0);
    try testing.expectEqual(@as(usize, 6), c.caretLine());
    try press(inst, KEY_PAGE_DOWN, 0);
    try testing.expectEqual(@as(usize, 23), c.cursor); // the very end
    try press(inst, KEY_PAGE_UP, 0);
    try testing.expectEqual(@as(usize, 4), c.caretLine());
}

test "textarea: a double-click in the gap selects the gap, not a neighbour" {
    // Picking the word to one side would be a coin toss, and the two
    // sides disagree about which way it landed.
    const text = "aa   bb";
    const gap = wordAround(text, 3);
    try testing.expectEqual(@as(usize, 2), gap.start);
    try testing.expectEqual(@as(usize, 5), gap.end);
    const word = wordAround(text, 6);
    try testing.expectEqual(@as(usize, 5), word.start);
    try testing.expectEqual(@as(usize, 7), word.end);
}

test "textarea: a double-click past the last character still picks the word" {
    const text = "hello";
    const w = wordAround(text, 5);
    try testing.expectEqual(@as(usize, 0), w.start);
    try testing.expectEqual(@as(usize, 5), w.end);
}

test "textarea: a multi-byte word stays whole" {
    // "café" — the é is two bytes, both of which must count as word bytes
    // or a double-click cuts the codepoint in half.
    const text = "café x";
    const w = wordAround(text, 1);
    try testing.expectEqual(@as(usize, 0), w.start);
    try testing.expectEqual(@as(usize, 5), w.end);
}

// ── Clipboard normalisation ─────────────────────────────────────────

test "textarea: a pasted CRLF becomes one newline" {
    // The bug this is paid for is invisible on screen and fatal on the
    // wire: a stray `\r` at the end of every line rides `rill remount`
    // into the parser, which has no idea what it is.
    const gpa = testing.allocator;
    const got = try normaliseNewlines(gpa, "a\r\nb\rc\nd");
    defer gpa.free(got);
    try testing.expectEqualStrings("a\nb\nc\nd", got);
}

// ── Editing ─────────────────────────────────────────────────────────

test "textarea: Enter makes a newline and does not dispatch by default" {
    defer resetState();
    // The default matters: a multi-line box whose Enter sends can only
    // ever hold one line until you discover Shift.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.prog" },
    };
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));

    try typeStr(inst, "ab");
    try press(inst, KEY_ENTER, 0);
    try typeStr(inst, "cd");
    try testing.expectEqualStrings("ab\ncd", c.buffer.items);
    // Nothing was sent.
    try testing.expect(_test_state.get("prog") == null);
}

test "textarea: submit=enter sends on Enter and newlines on Shift+Enter" {
    defer resetState();
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.chat" },
        .{ .key = "submit", .value = "enter" },
    };
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));

    try typeStr(inst, "one");
    try press(inst, KEY_ENTER, MOD_SHIFT);
    try typeStr(inst, "two");
    try testing.expectEqualStrings("one\ntwo", c.buffer.items);
    try press(inst, KEY_ENTER, 0);
    try testing.expectEqualStrings("one\ntwo", _test_state.get("chat").?);
}

test "textarea: submit=ctrl_enter newlines on Enter and sends on Ctrl+Enter" {
    defer resetState();
    // The console's pairing. Enter must be inert as a dispatcher or a
    // two-statement program can never be typed.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.prog2" },
        .{ .key = "submit", .value = "ctrl_enter" },
    };
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));

    try typeStr(inst, "spin = osc 0.4");
    try press(inst, KEY_ENTER, 0);
    try typeStr(inst, "cube.rot.y = spin");
    try testing.expect(_test_state.get("prog2") == null);

    try press(inst, KEY_ENTER, MOD_CONTROL);
    // The newlines ride the value verbatim — the rill console's whole
    // premise, since `rill remount` carries the source on one line.
    try testing.expectEqualStrings("spin = osc 0.4\ncube.rot.y = spin", _test_state.get("prog2").?);
    try testing.expectEqualStrings("spin = osc 0.4\ncube.rot.y = spin", c.buffer.items);
}

test "textarea: clear_on_submit delivers the text it just threw away" {
    defer resetState();
    // The trap: clearing has to happen before the dispatch (`State.set`
    // re-enters `ingest`), so the line handed over is a copy. Clearing
    // first and sending `buffer.items` would send nothing at all.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.sent" },
        .{ .key = "submit", .value = "enter" },
        .{ .key = "clear_on_submit", .value = "" },
    };
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try typeStr(inst, "hello there");
    try press(inst, KEY_ENTER, 0);
    try testing.expectEqualStrings("hello there", _test_state.get("sent").?);
    try testing.expectEqualStrings("", c.buffer.items);
    try testing.expectEqual(@as(usize, 0), c.cursor);
}

test "textarea: the body seeds the buffer verbatim, newlines and all" {
    // This is what a multi-line control has a body FOR; `initial=` cannot
    // carry a newline through an attribute.
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "line one\nline two");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("line one\nline two", c.buffer.items);
    try testing.expectEqual(@as(usize, 17), c.cursor);
}

test "textarea: a component target still demands an action" {
    // `:::input`'s rule, and it has to be exactly that rule or the two
    // controls disagree about their own grammar.
    const attrs = [_]components.Attr{.{ .key = "target", .value = "#chat" }};
    const spec: components.Spec = .{ .name = "textarea", .attrs = &attrs };
    try testing.expectError(Error.TextareaMissingAction, create(&_test_spark, testing.allocator, &spec));
}

test "textarea: backspace at a line start joins the two lines" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "ab\ncd");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    c.cursor = 3; // start of "cd"
    try press(inst, KEY_BACKSPACE, 0);
    try testing.expectEqualStrings("abcd", c.buffer.items);
    try testing.expectEqual(@as(usize, 2), c.cursor);
}

test "textarea: Ctrl+Backspace eats a word, not a letter" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "alpha beta");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try press(inst, KEY_BACKSPACE, MOD_CONTROL);
    try testing.expectEqualStrings("alpha ", c.buffer.items);
}

test "textarea: typing over a selection replaces it" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "hello world");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    c.anchor = 0;
    c.cursor = 5;
    try typeStr(inst, "bye");
    try testing.expectEqualStrings("bye world", c.buffer.items);
    try testing.expect(c.anchor == null);
}

test "textarea: Ctrl+A then typing replaces the whole buffer" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "a\nb\nc");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try press(inst, KEY_A, MOD_CONTROL);
    try typeStr(inst, "x");
    try testing.expectEqualStrings("x", c.buffer.items);
}

test "textarea: Shift+arrow extends a selection; a bare arrow collapses it" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "abcdef");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    c.cursor = 2;
    c.anchor = null;
    try press(inst, KEY_RIGHT, MOD_SHIFT);
    try press(inst, KEY_RIGHT, MOD_SHIFT);
    try testing.expectEqual(@as(usize, 2), c.anchor.?);
    try testing.expectEqual(@as(usize, 4), c.cursor);
    // A bare Left collapses to the selection's LEFT edge rather than
    // stepping one back from the cursor — the behaviour every text field
    // has, and the one that surprises when it is missing.
    try press(inst, KEY_LEFT, 0);
    try testing.expectEqual(@as(usize, 2), c.cursor);
    try testing.expect(c.anchor == null);
}

test "textarea: arrows step whole codepoints" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "aé🎉");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    c.cursor = 0;
    try press(inst, KEY_RIGHT, 0);
    try testing.expectEqual(@as(usize, 1), c.cursor);
    try press(inst, KEY_RIGHT, 0);
    try testing.expectEqual(@as(usize, 3), c.cursor);
    try press(inst, KEY_RIGHT, 0);
    try testing.expectEqual(@as(usize, 7), c.cursor);
}

// ── The pointer ─────────────────────────────────────────────────────
//
// `offsetAt` turns a click into a byte offset using the geometry the last
// layout recorded, so a test can stand in for that layout by setting the
// same six numbers. This is the half that cannot be seen in a screenshot
// and is exactly the half that silently maps clicks to the wrong place.

/// Put the box where a layout would have left it: origin at (0,0), the
/// content inset by the frame, and the monospace ruler in force.
fn placeBox(c: *Component, char_w: f32, content_w: f32) !void {
    c.last_box = .{ .x = 0, .y = 0, .w = content_w + 2 * (INSET + input.PAD_X), .h = 60 };
    c.content_x = INSET + input.PAD_X;
    c.content_y = INSET + PAD_Y;
    try relayout(c, char_w, content_w);
}

fn clickAt(inst: component_mod.Instance, x: f32, y: f32) !void {
    try onInput(inst.ctx, .{ .mouse_down = .{
        .local = .{ x, y },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));
}

test "textarea: a click lands on the character it was aimed at" {
    // The scroll offset and the content inset both go into this, and
    // dropping either puts every caret a fixed distance from where the
    // pointer was — which looks like a rendering bug and is not one.
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "abcdef\nghijkl");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try placeBox(c, 10, 200);

    // Row 0, between the 3rd and 4th character.
    try clickAt(inst, c.content_x + 31, c.content_y + 2);
    try testing.expectEqual(@as(usize, 3), c.cursor);
    // Row 1 (line_h is 10 in the stub), same column: offset 7 + 3.
    try clickAt(inst, c.content_x + 31, c.content_y + 12);
    try testing.expectEqual(@as(usize, 10), c.cursor);
    // Above the top and left of the left edge still lands somewhere real.
    try clickAt(inst, -50, -50);
    try testing.expectEqual(@as(usize, 0), c.cursor);
    // Below the last row lands on the last row, not past the buffer.
    try clickAt(inst, c.content_x + 1000, c.content_y + 500);
    try testing.expectEqual(@as(usize, 13), c.cursor);
}

test "textarea: a click accounts for the scroll offset" {
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "r0\nr1\nr2\nr3\nr4");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try placeBox(c, 10, 200);

    c.scroll_y = 20; // two rows up
    // The top row of the WINDOW is now row 2, which starts at byte 6.
    try clickAt(inst, c.content_x + 1, c.content_y + 2);
    try testing.expectEqual(@as(usize, 6), c.cursor);
}

test "textarea: a double-click takes the word, a triple the whole hard line" {
    // And the triple takes the HARD line rather than the visual one: a
    // wrapped paragraph is one thing to a person even when it is four rows.
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "alpha beta gamma");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    // 60px of room wraps this into three rows.
    try placeBox(c, 10, 60);
    try testing.expect(c.lines.items.len > 1);

    const x = c.content_x + 25; // inside "alpha" on row 0
    const y = c.content_y + 2;
    try clickAt(inst, x, y);
    try testing.expect(c.selection() == null);
    try clickAt(inst, x, y);
    const word = c.selection().?;
    try testing.expectEqual(@as(usize, 0), word.start);
    try testing.expectEqual(@as(usize, 5), word.end);
    try clickAt(inst, x, y);
    const line = c.selection().?;
    try testing.expectEqual(@as(usize, 0), line.start);
    try testing.expectEqual(@as(usize, 16), line.end);
}

test "textarea: a click far away starts a new run rather than continuing one" {
    // Proximity is measured in PIXELS, not in byte offsets: a second click
    // somewhere else is a new caret, however soon it came.
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "alpha beta");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try placeBox(c, 10, 200);

    try clickAt(inst, c.content_x + 25, c.content_y + 2);
    try clickAt(inst, c.content_x + 85, c.content_y + 2);
    try testing.expect(c.selection() == null);
    try testing.expectEqual(@as(u8, 1), c.click_run);
}

test "textarea: dragging extends the selection from where the press landed" {
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "abcdefgh");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try placeBox(c, 10, 200);

    try clickAt(inst, c.content_x + 21, c.content_y + 2); // offset 2
    try onInput(inst.ctx, .{ .mouse_move = .{
        .local = .{ c.content_x + 61, c.content_y + 2 },
        .button = 0,
        .button_down = true,
    } }, @ptrCast(&_test_state));
    const sel = c.selection().?;
    try testing.expectEqual(@as(usize, 2), sel.start);
    try testing.expectEqual(@as(usize, 6), sel.end);

    // A move with the button UP is not a drag, even while the latch is
    // still set. Pointer capture normally guarantees the release comes
    // back here, but "normally" is doing real work in that sentence — a
    // window manager stealing the button leaves the latch on, and without
    // this the selection then follows the pointer around the screen.
    try onInput(inst.ctx, .{ .mouse_move = .{
        .local = .{ c.content_x + 1, c.content_y + 2 },
        .button = 0,
        .button_down = false,
    } }, @ptrCast(&_test_state));
    try testing.expectEqual(@as(usize, 6), c.cursor);
    try testing.expect(c.dragging);

    // …and the release does clear the latch.
    try onInput(inst.ctx, .{ .mouse_up = .{ .local = .{ 0, 0 }, .button = 0, .button_down = false } }, @ptrCast(&_test_state));
    try testing.expect(!c.dragging);
}

test "textarea: a click past the end of a wrapped row stays on that row" {
    // Without affinity the caret appears one row LOWER than the click,
    // because the offset it landed on is the next row's first byte.
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "aaa bbb");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try placeBox(c, 10, 35);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);

    try clickAt(inst, c.content_x + 300, c.content_y + 2);
    try testing.expectEqual(@as(usize, 4), c.cursor);
    try testing.expect(c.affinity_before);
    try testing.expectEqual(@as(usize, 0), c.caretLine());

    // …and a click on the row BELOW at the same offset does not.
    try clickAt(inst, c.content_x + 1, c.content_y + 12);
    try testing.expectEqual(@as(usize, 4), c.cursor);
    try testing.expect(!c.affinity_before);
    try testing.expectEqual(@as(usize, 1), c.caretLine());
}

test "textarea: the wheel is consumed only while the box can still move" {
    // `:::clip`'s rule. A region that claims every notch stops the page
    // dead whenever the pointer strays over it.
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "r0\nr1\nr2\nr3\nr4\nr5\nr6\nr7");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try placeBox(c, 10, 200); // content_h 40, eight rows of 10 → 40 to give

    try testing.expect(try onScroll(inst.ctx, .{ .local = .{ 0, 0 }, .dy = 20 }, @ptrCast(&_test_state)));
    try testing.expect(try onScroll(inst.ctx, .{ .local = .{ 0, 0 }, .dy = 20 }, @ptrCast(&_test_state)));
    // At the bottom now: the next downward notch belongs to the page.
    try testing.expect(!try onScroll(inst.ctx, .{ .local = .{ 0, 0 }, .dy = 20 }, @ptrCast(&_test_state)));
    // Upward still moves, so the box is not simply dead.
    try testing.expect(try onScroll(inst.ctx, .{ .local = .{ 0, 0 }, .dy = -20 }, @ptrCast(&_test_state)));
}

// ── Vertical motion ─────────────────────────────────────────────────

test "textarea: the goal column survives a short line" {
    // THE classic editor bug. Down through a short line moves the caret to
    // that line's end, and without a remembered goal the next Down carries
    // on from there — so passing a short line drags the column left and
    // never gives it back.
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "abcdefgh\nxy\nabcdefgh");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try relayout(c, 10, 200);

    c.cursor = 6; // column 6 of line 0
    c.goal_x = null;
    try press(inst, KEY_DOWN, 0);
    try relayout(c, 10, 200);
    // Line 1 is only two characters, so the caret lands at its end.
    try testing.expectEqual(@as(usize, 11), c.cursor);
    try press(inst, KEY_DOWN, 0);
    try relayout(c, 10, 200);
    // …and column 6 comes back on line 2, which starts at byte 12.
    try testing.expectEqual(@as(usize, 18), c.cursor);
}

test "textarea: Down off the last line goes to the end rather than nowhere" {
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "ab\ncd");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try relayout(c, 10, 200);
    c.cursor = 4;
    try press(inst, KEY_DOWN, 0);
    try testing.expectEqual(@as(usize, 5), c.cursor);
    c.cursor = 1;
    try press(inst, KEY_UP, 0);
    try testing.expectEqual(@as(usize, 0), c.cursor);
}

test "textarea: End on a wrapped row keeps the caret on that row" {
    // Without affinity the caret jumps to the start of the row BELOW,
    // because the offset it landed on is that row's first byte.
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "aaa bbb");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try relayout(c, 10, 35);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);

    c.cursor = 1;
    c.affinity_before = false;
    try press(inst, KEY_END, 0);
    try testing.expectEqual(@as(usize, 4), c.cursor);
    try testing.expect(c.affinity_before);
    try testing.expectEqual(@as(usize, 0), c.caretLine());
    // And Home comes back to the start of the SAME row.
    try press(inst, KEY_HOME, 0);
    try testing.expectEqual(@as(usize, 0), c.cursor);
}

test "textarea: Ctrl+Home and Ctrl+End reach the buffer's ends" {
    const attrs = [_]components.Attr{.{ .key = "wrap", .value = "none" }};
    const inst = try makeBox(&attrs, "ab\ncd\nef");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try relayout(c, 10, 200);
    c.cursor = 4;
    try press(inst, KEY_END, MOD_CONTROL);
    try testing.expectEqual(@as(usize, 8), c.cursor);
    try press(inst, KEY_HOME, MOD_CONTROL);
    try testing.expectEqual(@as(usize, 0), c.cursor);
}

// ── Undo ────────────────────────────────────────────────────────────

test "textarea: a run of typing undoes as one step, and a newline breaks it" {
    // One step per keystroke means holding Ctrl+Z to get a sentence back,
    // which is undo that is present rather than usable.
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));

    try typeStr(inst, "hello");
    try press(inst, KEY_ENTER, 0);
    try typeStr(inst, "world");
    try testing.expectEqualStrings("hello\nworld", c.buffer.items);

    try press(inst, KEY_Z, MOD_CONTROL);
    try testing.expectEqualStrings("hello\n", c.buffer.items);
    try press(inst, KEY_Z, MOD_CONTROL);
    try testing.expectEqualStrings("hello", c.buffer.items);
    try press(inst, KEY_Z, MOD_CONTROL);
    try testing.expectEqualStrings("", c.buffer.items);
    // An empty stack is a no-op, not a crash.
    try press(inst, KEY_Z, MOD_CONTROL);
    try testing.expectEqualStrings("", c.buffer.items);
}

test "textarea: redo replays, and a fresh edit forks the history away" {
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));

    try typeStr(inst, "abc");
    try press(inst, KEY_Z, MOD_CONTROL);
    try testing.expectEqualStrings("", c.buffer.items);
    try press(inst, KEY_Y, MOD_CONTROL);
    try testing.expectEqualStrings("abc", c.buffer.items);
    // Ctrl+Shift+Z is the other spelling of the same verb.
    try press(inst, KEY_Z, MOD_CONTROL);
    try press(inst, KEY_Z, MOD_CONTROL | MOD_SHIFT);
    try testing.expectEqualStrings("abc", c.buffer.items);

    // Undo, then type: the redo branch is gone rather than resurrectable.
    try press(inst, KEY_Z, MOD_CONTROL);
    try typeStr(inst, "z");
    try press(inst, KEY_Y, MOD_CONTROL);
    try testing.expectEqualStrings("z", c.buffer.items);
}

// ── Clipboard ───────────────────────────────────────────────────────

var _clip_buf: [256]u8 = undefined;
var _clip_len: usize = 0;

fn tClipGet(_: *anyopaque) ?[]const u8 {
    return if (_clip_len == 0) null else _clip_buf[0.._clip_len];
}
fn tClipSet(_: *anyopaque, text: []const u8) void {
    _clip_len = @min(text.len, _clip_buf.len);
    @memcpy(_clip_buf[0.._clip_len], text[0.._clip_len]);
}

test "textarea: copy, cut and paste round-trip through the host's clipboard" {
    var dummy: u8 = 0;
    _test_spark.setClipboard(@ptrCast(&dummy), tClipGet, tClipSet);
    defer {
        _test_spark.clipboard_get_fn = null;
        _test_spark.clipboard_set_fn = null;
        _clip_len = 0;
    }

    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "alpha beta");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));

    c.anchor = 0;
    c.cursor = 5;
    try press(inst, KEY_C, MOD_CONTROL);
    try testing.expectEqualStrings("alpha", _clip_buf[0.._clip_len]);

    c.anchor = 6;
    c.cursor = 10;
    try press(inst, KEY_X, MOD_CONTROL);
    try testing.expectEqualStrings("alpha ", c.buffer.items);
    try testing.expectEqualStrings("beta", _clip_buf[0.._clip_len]);

    try press(inst, KEY_V, MOD_CONTROL);
    try testing.expectEqualStrings("alpha beta", c.buffer.items);
}

test "textarea: a paste with no host clipboard installed is inert, not a crash" {
    // The doctrine `cmd=` buttons set: a document carried to a host that
    // installed nothing gets a keystroke that visibly does nothing.
    _test_spark.clipboard_get_fn = null;
    _test_spark.clipboard_set_fn = null;
    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "abc");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try press(inst, KEY_V, MOD_CONTROL);
    try press(inst, KEY_C, MOD_CONTROL);
    try testing.expectEqualStrings("abc", c.buffer.items);
}

test "textarea: a pasted CRLF arrives as one newline in the buffer" {
    var dummy: u8 = 0;
    _test_spark.setClipboard(@ptrCast(&dummy), tClipGet, tClipSet);
    defer {
        _test_spark.clipboard_get_fn = null;
        _test_spark.clipboard_set_fn = null;
        _clip_len = 0;
    }
    tClipSet(@ptrCast(&dummy), "one\r\ntwo");

    const attrs = [_]components.Attr{};
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try press(inst, KEY_V, MOD_CONTROL);
    try testing.expectEqualStrings("one\ntwo", c.buffer.items);
}

// ── live ────────────────────────────────────────────────────────────

test "textarea: live publishes on every keystroke, not only on submit" {
    defer resetState();
    // What makes a separate Run button possible at all: a `:::button` can
    // only fire a literal `body=`, so the text has to already be somewhere
    // the button's target can read.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.live_prog" },
        .{ .key = "live", .value = "" },
    };
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try typeStr(inst, "ab");
    try testing.expectEqualStrings("ab", _test_state.get("live_prog").?);
    try press(inst, KEY_BACKSPACE, 0);
    try testing.expectEqualStrings("a", _test_state.get("live_prog").?);
}

test "textarea: a synced seed does not land while the box is being typed in" {
    // `:::input` paid for this one: a value arriving mid-edit yanks the
    // text out from under the caret. With `live` it is worse than a
    // nuisance — the box is its own subscriber, so every keystroke would
    // re-seed the buffer from what it had just written.
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "state.x" },
        .{ .key = "initial", .value = "seed" },
    };
    const inst = try makeBox(&attrs, "");
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("seed", c.buffer.items);

    try onInput(inst.ctx, .focus_gained, @ptrCast(&_test_state));
    try typeStr(inst, "!");
    const moved = [_]components.Attr{
        .{ .key = "target", .value = "state.x" },
        .{ .key = "initial", .value = "something else" },
    };
    const spec2: components.Spec = .{ .name = "textarea", .attrs = &moved };
    try update(inst.ctx, &spec2);
    try testing.expectEqualStrings("seed!", c.buffer.items);

    // And it is DROPPED, not queued: leaving the box does not then replay
    // a value that went stale while you were typing. Same as `:::input`,
    // and the alternative is worse — the text you were looking at is
    // replaced a moment after you looked away.
    try onInput(inst.ctx, .focus_lost, @ptrCast(&_test_state));
    const spec3: components.Spec = .{ .name = "textarea", .attrs = &moved };
    try update(inst.ctx, &spec3);
    try testing.expectEqualStrings("seed!", c.buffer.items);

    // The sync itself still works — this is the half `:::slider` had and
    // `:::input` was missing, which is what left a field showing a number
    // that had stopped being true.
    const later = [_]components.Attr{
        .{ .key = "target", .value = "state.x" },
        .{ .key = "initial", .value = "third value" },
    };
    const spec4: components.Spec = .{ .name = "textarea", .attrs = &later };
    try update(inst.ctx, &spec4);
    try testing.expectEqualStrings("third value", c.buffer.items);
}
