//! ANSI escape-code → Element tree.
//!
//! Stage 5a: static / batch-mode parser. Walks a UTF-8 + ANSI byte
//! stream once, emits a `container.stack_v` of paragraphs — one per
//! source line — with `text` leaves whose Style reflects the current
//! SGR state (foreground colour + bold + italic). Same shape as
//! `markdown.parse`, plugs into the engine through the existing
//! Element contract.
//!
//! ### Provenance
//!
//! The state machine + 256-color palette + SGR dispatch all crib
//! from Christian's `~/dev/ac/src/terminal_parser.zig` (a 448-line
//! ANSI parser written for the terminal app he built in session 1's
//! prior art). What changed:
//!
//!   * `Terminal` callbacks (cell-grid writes, cursor moves, screen
//!     erases) replaced by `Builder` callbacks that accumulate text
//!     runs and flush them as Elements on style boundaries.
//!   * Raylib `Color` replaced by `[4]f32` RGBA matching our Style.
//!   * Cascade for bold / italic routes through `theme.applyStrong`
//!     / `theme.applyEmphasis` — same cascade helpers markdown's
//!     parser uses, so a bold-coloured ANSI run renders with the
//!     theme's bold font in the right colour.
//!
//! ### Out of scope (stage 5a)
//!
//!   * Cursor movement (`A` / `B` / `C` / `D` / `H` / `f`), erase
//!     commands (`J` / `K`), insert / delete / scroll region — all
//!     irrelevant for batch-rendering static terminal output. The
//!     parser still passes through these CSI finals silently.
//!   * Alt-screen toggle / save+restore cursor / scroll region.
//!   * Underline / strikethrough / reverse / hidden — visual support
//!     needs theme + chrome work we haven't done. Bytes parse, flags
//!     update on the state, but the produced Style ignores them for
//!     now.
//!   * Background colours — render path needs per-character quad
//!     emission; defer to stage 5c+.
//!   * OSC sequences — accept + discard.
//!
//! ### Stage 5b will add
//!
//!   * `markdown.zig` dispatch of ``` ```ansi ``` ``` fences to this
//!     parser, returning the tree via `CodeContent.sub_block` so
//!     `layoutCodeBlock` recurses into it. Closes the
//!     markdown↔ANSI composability loop the contract was designed
//!     for.

const std = @import("std");
const element = @import("element.zig");

pub const Error = error{} || std.mem.Allocator.Error;

// ── 256-colour palette ──────────────────────────────────────────────
// Comptime-built so all colour lookups are zero-cost. RGB only;
// alpha resolves to 1.0 at run-time when we build the [4]f32 Style
// colour. Identical to the xterm-256 palette in
// `~/dev/ac/src/terminal_parser.zig` — kept byte-identical so any
// future palette tuning can land in both engines in lock-step.

const Rgb = struct { r: u8, g: u8, b: u8 };

const palette_256: [256]Rgb = blk: {
    var pal: [256]Rgb = undefined;

    // 0-7: standard
    pal[0] = .{ .r = 0, .g = 0, .b = 0 };
    pal[1] = .{ .r = 170, .g = 0, .b = 0 };
    pal[2] = .{ .r = 0, .g = 170, .b = 0 };
    pal[3] = .{ .r = 170, .g = 85, .b = 0 };
    pal[4] = .{ .r = 0, .g = 0, .b = 170 };
    pal[5] = .{ .r = 170, .g = 0, .b = 170 };
    pal[6] = .{ .r = 0, .g = 170, .b = 170 };
    pal[7] = .{ .r = 170, .g = 170, .b = 170 };

    // 8-15: bright
    pal[8] = .{ .r = 85, .g = 85, .b = 85 };
    pal[9] = .{ .r = 255, .g = 85, .b = 85 };
    pal[10] = .{ .r = 85, .g = 255, .b = 85 };
    pal[11] = .{ .r = 255, .g = 255, .b = 85 };
    pal[12] = .{ .r = 85, .g = 85, .b = 255 };
    pal[13] = .{ .r = 255, .g = 85, .b = 255 };
    pal[14] = .{ .r = 85, .g = 255, .b = 255 };
    pal[15] = .{ .r = 255, .g = 255, .b = 255 };

    // 16-231: 6x6x6 colour cube
    var i: usize = 0;
    while (i < 216) : (i += 1) {
        const idx = i + 16;
        const b_val: u8 = @intCast(i % 6);
        const g_val: u8 = @intCast((i / 6) % 6);
        const r_val: u8 = @intCast(i / 36);
        pal[idx] = .{
            .r = if (r_val == 0) 0 else @as(u8, 55) + r_val * 40,
            .g = if (g_val == 0) 0 else @as(u8, 55) + g_val * 40,
            .b = if (b_val == 0) 0 else @as(u8, 55) + b_val * 40,
        };
    }

    // 232-255: grayscale ramp
    i = 0;
    while (i < 24) : (i += 1) {
        const idx = i + 232;
        const v: u8 = @intCast(8 + i * 10);
        pal[idx] = .{ .r = v, .g = v, .b = v };
    }

    break :blk pal;
};

fn paletteColor(code: u8) [4]f32 {
    const rgb = palette_256[code];
    return .{
        @as(f32, @floatFromInt(rgb.r)) / 255.0,
        @as(f32, @floatFromInt(rgb.g)) / 255.0,
        @as(f32, @floatFromInt(rgb.b)) / 255.0,
        1.0,
    };
}

fn truecolor(r: u8, g: u8, b: u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        1.0,
    };
}

// ── SGR state ───────────────────────────────────────────────────────
// What we track per SGR sequence. `fg` null means "use theme.body's
// colour" — the same default the Builder starts at. `bold` and
// `italic` flow through Theme.apply* the same way markdown's cascade
// does so font selection composes correctly (bold-italic picks the
// `bold_italic_font_id`).

const SgrState = struct {
    fg: ?[4]f32 = null,
    bold: bool = false,
    italic: bool = false,

    /// Resolve the current state into a concrete Style by walking
    /// the same cascade helpers markdown's parser uses. Keeps font
    /// selection consistent between the two producers.
    fn toStyle(self: SgrState, theme: *const element.Theme) element.Style {
        var s = theme.body;
        if (self.bold) s = theme.applyStrong(s);
        if (self.italic) s = theme.applyEmphasis(s);
        if (self.fg) |fg| s.color = fg;
        return s;
    }
};

// ── Builder ─────────────────────────────────────────────────────────
// Accumulates byte runs into a text leaf, flushes on style change or
// newline. Owns the arena allocator; produced Elements + their
// strings all live there.

const Builder = struct {
    arena: std.mem.Allocator,
    theme: *const element.Theme,

    /// Children of the paragraph currently being built. Reset on
    /// each newline flush.
    current_para: std.ArrayList(element.Element),
    /// Bytes accumulated since the last style change or newline.
    current_text: std.ArrayList(u8),
    /// Resolved Style for the current accumulating run.
    current_style: element.Style,

    /// Top-level paragraphs collected so far. Flushed into a
    /// `container.stack_v` at the end.
    paragraphs: std.ArrayList(element.Element),

    sgr: SgrState = .{},

    fn init(arena: std.mem.Allocator, theme: *const element.Theme) Builder {
        return .{
            .arena = arena,
            .theme = theme,
            .current_para = std.ArrayList(element.Element).init(arena),
            .current_text = std.ArrayList(u8).init(arena),
            .current_style = theme.body,
            .paragraphs = std.ArrayList(element.Element).init(arena),
        };
    }

    /// Append one byte to the current text run. UTF-8 multi-byte
    /// sequences accumulate transparently — the byte stream stays
    /// valid UTF-8 since SGR sequences fall between codepoint
    /// boundaries in well-formed input.
    fn putByte(self: *Builder, byte: u8) !void {
        try self.current_text.append(byte);
    }

    /// Close the current text run (if any) into a `text` Element
    /// and append to the current paragraph's children.
    fn flushText(self: *Builder) !void {
        if (self.current_text.items.len == 0) return;
        const owned = try self.arena.dupe(u8, self.current_text.items);
        try self.current_para.append(.{ .text = .{ .content = owned, .style = self.current_style } });
        self.current_text.clearRetainingCapacity();
    }

    /// Close the current paragraph (after flushing any pending
    /// text), append to the top-level list, start a fresh one.
    fn flushParagraph(self: *Builder) !void {
        try self.flushText();
        const children = try self.current_para.toOwnedSlice();
        try self.paragraphs.append(.{ .paragraph = children });
        self.current_para = std.ArrayList(element.Element).init(self.arena);
    }

    /// Re-resolve the current Style from `sgr`. Flushes the pending
    /// text run first so it picks up the OLD style; the new run
    /// starts under the new style.
    fn applyStyleChange(self: *Builder) !void {
        try self.flushText();
        self.current_style = self.sgr.toStyle(self.theme);
    }
};

// ── Parser ──────────────────────────────────────────────────────────
// State machine. Same shape as `~/dev/ac/src/terminal_parser.zig`
// but pared back to the states stage 5a actually needs:
//
//   * `ground`      — accumulating printable bytes / handling
//                     control chars
//   * `escape`      — saw 0x1B, expecting `[` for CSI (everything
//                     else returns to ground)
//   * `csi_entry`   — first byte after `[`, sets up param parsing
//   * `csi_param`   — accumulating params, waiting for final byte
//   * `osc_string`  — discard bytes until ST (ESC \) or BEL

const ParserState = enum {
    ground,
    escape,
    csi_entry,
    csi_param,
    csi_intermediate,
    osc_string,
    osc_escape,
};

const MAX_PARAMS: usize = 16;

pub const Parser = struct {
    state: ParserState = .ground,
    params: [MAX_PARAMS]u16 = .{0} ** MAX_PARAMS,
    param_count: u8 = 0,
    private_marker: u8 = 0,

    fn reset(self: *Parser) void {
        self.params = .{0} ** MAX_PARAMS;
        self.param_count = 0;
        self.private_marker = 0;
    }

    fn feed(self: *Parser, b: *Builder, byte: u8) !void {
        switch (self.state) {
            .ground => try self.handleGround(b, byte),
            .escape => self.handleEscape(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => try self.handleCsiParam(b, byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .osc_string => self.handleOsc(byte),
            .osc_escape => self.state = .ground,
        }
    }

    fn handleGround(self: *Parser, b: *Builder, byte: u8) !void {
        switch (byte) {
            0x1B => {
                self.reset();
                self.state = .escape;
            },
            '\n' => try b.flushParagraph(),
            '\r' => {}, // ignore lone CRs; \n alone advances the line
            // Other C0 controls (BEL, BS, HT, etc.) — silently drop.
            // A streaming terminal would handle BS for cursor and HT
            // for tab stops, but a batch renderer treats them as
            // noise. Tabs in real ANSI output land between SGRs so
            // they don't usually matter for colour rendering.
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1A, 0x1C...0x1F => {},
            else => try b.putByte(byte),
        }
    }

    fn handleEscape(self: *Parser, byte: u8) void {
        switch (byte) {
            '[' => self.state = .csi_entry,
            ']' => self.state = .osc_string,
            else => self.state = .ground, // unrecognized escape — drop
        }
    }

    fn handleCsiEntry(self: *Parser, byte: u8) void {
        switch (byte) {
            '?' => {
                self.private_marker = '?';
                self.state = .csi_param;
            },
            '>' => {
                self.private_marker = '>';
                self.state = .csi_param;
            },
            '0'...'9' => {
                self.params[0] = byte - '0';
                self.param_count = 1;
                self.state = .csi_param;
            },
            ';' => {
                self.param_count = 2; // implicit 0 in slot 0
                self.state = .csi_param;
            },
            0x20...0x2F => self.state = .csi_intermediate,
            0x40...0x7E => {
                // CSI with no params — for our subset, only `m`
                // (SGR reset) matters; the rest are cursor / erase
                // ops we ignore.
                self.param_count = 0;
                self.state = .ground;
            },
            else => self.state = .ground,
        }
    }

    fn handleCsiParam(self: *Parser, b: *Builder, byte: u8) !void {
        switch (byte) {
            '0'...'9' => {
                if (self.param_count == 0) self.param_count = 1;
                const idx = self.param_count - 1;
                if (idx < MAX_PARAMS) {
                    self.params[idx] = self.params[idx] *% 10 +% (byte - '0');
                }
            },
            ';' => {
                if (self.param_count < MAX_PARAMS) self.param_count += 1;
            },
            0x20...0x2F => self.state = .csi_intermediate,
            0x40...0x7E => {
                try self.dispatchCsi(b, byte);
                self.state = .ground;
            },
            else => self.state = .ground,
        }
    }

    fn handleCsiIntermediate(self: *Parser, byte: u8) void {
        switch (byte) {
            0x20...0x2F => {},
            0x40...0x7E => self.state = .ground, // dispatch ignored
            else => self.state = .ground,
        }
    }

    fn handleOsc(self: *Parser, byte: u8) void {
        switch (byte) {
            0x1B => self.state = .osc_escape,
            0x07 => self.state = .ground, // BEL terminates OSC
            else => {}, // discard
        }
    }

    /// Dispatch a CSI sequence whose final byte we've just consumed.
    /// Only SGR ('m') updates the visual state for stage 5a;
    /// everything else (cursor, erase, scroll) is silently dropped.
    fn dispatchCsi(self: *Parser, b: *Builder, final: u8) !void {
        // Private-mode sequences (with `?` / `>` prefix) are cursor /
        // mode toggles — none relevant for static rendering.
        if (self.private_marker != 0) return;

        switch (final) {
            'm' => try self.handleSGR(b),
            else => {}, // ignored — cursor moves, erases, etc.
        }
    }

    /// SGR (`ESC [ ... m`) — update the Builder's colour + style
    /// flags. Same set of codes as `~/dev/ac/src/terminal_parser.zig`
    /// minus the ones whose visual support we haven't built yet
    /// (underline / strikethrough / reverse / hidden / background).
    /// Those parse cleanly but don't update the produced Style.
    fn handleSGR(self: *Parser, b: *Builder) !void {
        if (self.param_count == 0) {
            b.sgr = .{};
            try b.applyStyleChange();
            return;
        }

        var i: u8 = 0;
        while (i < self.param_count) : (i += 1) {
            const code = self.params[i];
            switch (code) {
                0 => b.sgr = .{}, // reset
                1 => b.sgr.bold = true,
                3 => b.sgr.italic = true,
                21, 22 => b.sgr.bold = false,
                23 => b.sgr.italic = false,
                // Underline / strikethrough / blink / reverse /
                // hidden — accepted to keep stream sync but no
                // visual effect yet.
                4, 5, 7, 8, 9, 24, 25, 27, 28, 29 => {},

                // Standard foreground colours.
                30...37 => b.sgr.fg = paletteColor(@intCast(code - 30)),
                // Default foreground — null means "fall back to theme.body's colour".
                39 => b.sgr.fg = null,
                // Bright foregrounds (90..97 → palette 8..15).
                90...97 => b.sgr.fg = paletteColor(@intCast(code - 90 + 8)),

                // Background colours — parse + discard for now.
                40...47, 49, 100...107 => {},

                // Extended colour: 38;5;N or 38;2;R;G;B.
                38 => {
                    i += 1;
                    if (i >= self.param_count) break;
                    if (self.params[i] == 5 and i + 1 < self.param_count) {
                        i += 1;
                        b.sgr.fg = paletteColor(@intCast(@min(self.params[i], 255)));
                    } else if (self.params[i] == 2 and i + 3 < self.param_count) {
                        i += 1;
                        const r: u8 = @truncate(self.params[i]);
                        i += 1;
                        const g: u8 = @truncate(self.params[i]);
                        i += 1;
                        const bb: u8 = @truncate(self.params[i]);
                        b.sgr.fg = truecolor(r, g, bb);
                    }
                },
                // 48 (extended background) — consume args but ignore.
                48 => {
                    i += 1;
                    if (i >= self.param_count) break;
                    if (self.params[i] == 5 and i + 1 < self.param_count) {
                        i += 1;
                    } else if (self.params[i] == 2 and i + 3 < self.param_count) {
                        i += 3;
                    }
                },
                else => {},
            }
        }
        try b.applyStyleChange();
    }
};

// ── Public entry ────────────────────────────────────────────────────

/// Parse `source` (UTF-8 + ANSI escape sequences) into an Element
/// tree owned by `arena`. Returns a `container.stack_v` of
/// paragraphs — one per source line.
pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
) !element.Element {
    var b = Builder.init(arena, theme);
    var p = Parser{};

    for (source) |byte| {
        try p.feed(&b, byte);
    }

    // Flush trailing paragraph (the input typically doesn't end with
    // a newline). If the final line had no content it still produces
    // an empty paragraph — matches markdown's behaviour where a
    // blank trailing line takes one line of vertical space.
    try b.flushParagraph();

    return .{ .container = .{
        .layout = .stack_v,
        .children = try b.paragraphs.toOwnedSlice(),
        .gap = 0,
    } };
}
