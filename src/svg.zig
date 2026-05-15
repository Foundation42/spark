//! Mini SVG reader (stage 13d.1).
//!
//! Scoped sharply to the subset Recraft V4.1 emits — verified
//! against `/home/chrisbe/Downloads/Petunias.svg`:
//!
//!   * Root: `<svg viewBox="x y w h" width=... height=...>`
//!   * Children: `<path d=... fill=... transform="translate(x,y)">`
//!   * Path data: `M / L / C / z`, uppercase absolute. Lowercase
//!     relative is parsed too for robustness against other models,
//!     but Recraft itself never uses it.
//!   * Fill: `rgb(r,g,b)` or `#rrggbb` / `#rgb`. Default black.
//!   * Transform: `translate(x[,y])` only. Default identity.
//!
//! Anything else (`<g>`, `<defs>`, `<linearGradient>`, strokes,
//! opacity, transforms beyond translate, path `Q/A/H/V/S/T`) is
//! silently ignored — the parser drops the element and moves on.
//! Recraft doesn't emit them; lighter parser, fewer bugs.
//!
//! Returns a `ParsedSvg` whose memory lives in a caller-supplied
//! allocator (typically a per-component arena that frees the whole
//! parse at component deinit). Path points are emitted at the
//! authoring resolution; the caller's box→viewBox transform handles
//! the screen mapping.
//!
//! No XML namespace handling, no entity resolution, no `<![CDATA[`
//! support. Tag detection is `'<'` byte scan with quoted-attribute
//! awareness — sufficient for well-formed SVG-as-emitted-by-LLMs.
//! A future hostile-input gate (or load-from-untrusted-doc path)
//! should swap this for a real XML parser, e.g. libexpat.

const std = @import("std");

pub const Error = error{
    SvgMalformed,
    SvgMissingViewBox,
    OutOfMemory,
};

pub const Point = struct { x: f32, y: f32 };

/// One contour within a path — the chunk between an `M` and the
/// next `M` or `z`. A path can have multiple subpaths (Recraft uses
/// this for shapes with holes).
pub const Subpath = struct {
    // commands' slice is const-friendly so tests can construct
    // fixtures with `&.{...}` array literals.
    /// Polyline-as-points BEFORE flattening curves. Each consecutive
    /// pair is either a line segment (kind = line) or the start
    /// anchor of a cubic Bezier (kind = cubic with two control
    /// points + endpoint in the next three slots).
    ///
    /// To keep the data flat, we instead emit a per-command
    /// record: `commands` parallels the subpath's edges, with one
    /// entry per *segment*. Anchor points are inlined.
    commands: []const Command,
    /// True if the subpath was closed via `z` — the renderer should
    /// add a synthetic line from the last anchor back to the start
    /// anchor.
    closed: bool,
    /// First anchor of the subpath — the `M` point. Convenient for
    /// the close-path synthetic line; otherwise `commands[0]`'s
    /// start point.
    start: Point,
};

pub const CommandKind = enum { line, cubic };

/// One edge in a subpath. `endpoint` is the new "current point"
/// after the edge; cubics also carry their two control points.
pub const Command = struct {
    kind: CommandKind,
    endpoint: Point,
    /// Only meaningful for `.cubic`.
    c1: Point = .{ .x = 0, .y = 0 },
    /// Only meaningful for `.cubic`.
    c2: Point = .{ .x = 0, .y = 0 },
};

pub const Path = struct {
    subpaths: []const Subpath,
    /// Straight RGBA in [0,1]. SVG fills are opaque unless
    /// `fill-opacity` is present; we don't read fill-opacity, so
    /// `a` is always 1.0 for now.
    color: [4]f32,
    /// X / Y translation pulled out of the `transform` attr. SVG
    /// "translate(x,y)" only; everything else is ignored.
    translate: Point = .{ .x = 0, .y = 0 },
};

pub const ParsedSvg = struct {
    /// SVG viewBox in author coordinates — the box the renderer
    /// maps onto the component's pixel rect.
    view_x: f32,
    view_y: f32,
    view_w: f32,
    view_h: f32,
    paths: []const Path,
};

/// Parse an SVG document. The returned slices live in `allocator`;
/// the caller owns them (typically an arena that frees the whole
/// parse in one shot).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!ParsedSvg {
    var p: Parser = .{ .src = source, .pos = 0, .allocator = allocator };
    return p.parseDocument();
}

// ─────────────────────────────────────────────────────────────────
// Parser internals
// ─────────────────────────────────────────────────────────────────

const Parser = struct {
    src: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    fn parseDocument(self: *Parser) Error!ParsedSvg {
        var view_x: f32 = 0;
        var view_y: f32 = 0;
        var view_w: f32 = 0;
        var view_h: f32 = 0;
        var have_viewbox = false;

        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit();

        while (true) {
            const t = self.nextTag() orelse break;
            if (std.mem.eql(u8, t.name, "svg")) {
                if (findAttr(t.attrs, "viewBox")) |vb| {
                    if (parseViewBox(vb)) |b| {
                        view_x = b[0];
                        view_y = b[1];
                        view_w = b[2];
                        view_h = b[3];
                        have_viewbox = true;
                    }
                }
                // No width/height/etc cared about. We trust viewBox
                // and let the renderer's box drive screen extent.
            } else if (std.mem.eql(u8, t.name, "path")) {
                const d = findAttr(t.attrs, "d") orelse continue;
                const fill = findAttr(t.attrs, "fill") orelse "#000";
                const transform = findAttr(t.attrs, "transform");
                const color = parseFill(fill);
                const translate = if (transform) |s| parseTranslate(s) else Point{ .x = 0, .y = 0 };
                const subpaths = self.parsePathData(d) catch continue;
                if (subpaths.len == 0) continue;
                try paths.append(.{
                    .subpaths = subpaths,
                    .color = color,
                    .translate = translate,
                });
            }
            // Other tags ignored.
        }

        if (!have_viewbox) return Error.SvgMissingViewBox;

        return .{
            .view_x = view_x,
            .view_y = view_y,
            .view_w = view_w,
            .view_h = view_h,
            .paths = try paths.toOwnedSlice(),
        };
    }

    // ── Tag scanner ──────────────────────────────────────────────

    const Tag = struct {
        name: []const u8,
        attrs: []const u8, // raw `key="value" key2="value2"` slice
        self_closing: bool,
        is_close: bool, // `</foo>`
    };

    /// Scan to the next `<...>` tag, parse name + raw attrs slice.
    /// Returns null at EOF. Skips `<!-- comments -->`, `<?xml ... ?>`,
    /// and `<!DOCTYPE ...>`. We never need to parse children — every
    /// interesting tag (`<svg>`, `<path>`) carries its data in its
    /// own attrs, and closing tags are ignored.
    fn nextTag(self: *Parser) ?Tag {
        while (self.pos < self.src.len) {
            const open = std.mem.indexOfScalarPos(u8, self.src, self.pos, '<') orelse return null;
            self.pos = open + 1;
            if (self.pos >= self.src.len) return null;

            // Comment / processing instruction / doctype — skip to end.
            if (self.startsWith("!--")) {
                if (std.mem.indexOf(u8, self.src[self.pos..], "-->")) |rel_end| {
                    self.pos += rel_end + 3;
                    continue;
                }
                return null;
            }
            if (self.src[self.pos] == '?' or self.src[self.pos] == '!') {
                if (std.mem.indexOfScalarPos(u8, self.src, self.pos, '>')) |gt| {
                    self.pos = gt + 1;
                    continue;
                }
                return null;
            }

            const is_close = self.src[self.pos] == '/';
            if (is_close) self.pos += 1;

            // Tag name = run of name chars.
            const name_start = self.pos;
            while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
            const name = self.src[name_start..self.pos];

            // Attr region runs until `>` or `/>` — but we have to
            // skip over quoted values so a `>` inside an attr value
            // doesn't terminate prematurely.
            const attrs_start = self.pos;
            var self_closing = false;
            while (self.pos < self.src.len) {
                const ch = self.src[self.pos];
                if (ch == '"' or ch == '\'') {
                    // Skip quoted string.
                    const q = ch;
                    self.pos += 1;
                    while (self.pos < self.src.len and self.src[self.pos] != q) self.pos += 1;
                    if (self.pos < self.src.len) self.pos += 1; // step past closing quote
                    continue;
                }
                if (ch == '>') break;
                if (ch == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                    self_closing = true;
                    break;
                }
                self.pos += 1;
            }
            const attrs_end = self.pos;
            if (self.pos < self.src.len and self.src[self.pos] == '/') self.pos += 1;
            if (self.pos < self.src.len and self.src[self.pos] == '>') self.pos += 1;

            return .{
                .name = name,
                .attrs = self.src[attrs_start..attrs_end],
                .self_closing = self_closing,
                .is_close = is_close,
            };
        }
        return null;
    }

    fn startsWith(self: *Parser, s: []const u8) bool {
        if (self.pos + s.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s);
    }

    // ── Path data parser ─────────────────────────────────────────

    fn parsePathData(self: *Parser, d: []const u8) Error![]Subpath {
        var subpaths = std.ArrayList(Subpath).init(self.allocator);
        errdefer subpaths.deinit();

        var commands = std.ArrayList(Command).init(self.allocator);
        defer commands.deinit();

        var pd: PathReader = .{ .src = d, .pos = 0 };

        var cur: Point = .{ .x = 0, .y = 0 };
        var sub_start: Point = .{ .x = 0, .y = 0 };
        var have_subpath = false;
        // Last command kind (uppercase). SVG path implicit-cmd rule:
        // after an `M` or `m`, additional coordinate pairs are
        // treated as implicit `L` / `l`; after `C` / `c`, additional
        // sextets are implicit cubics.
        var last_cmd: u8 = 'M';

        while (pd.skipWhitespaceAndCommas() and pd.pos < pd.src.len) {
            const ch = pd.src[pd.pos];
            const is_cmd = std.ascii.isAlphabetic(ch);
            const cmd: u8 = if (is_cmd) blk: {
                pd.pos += 1;
                break :blk ch;
            } else last_cmd;
            const upper = std.ascii.toUpper(cmd);
            const relative = std.ascii.isLower(cmd);

            switch (upper) {
                'M' => {
                    const x = pd.readNumber() orelse return Error.SvgMalformed;
                    const y = pd.readNumber() orelse return Error.SvgMalformed;
                    // Flush any prior subpath (open).
                    if (have_subpath and commands.items.len > 0) {
                        try subpaths.append(.{
                            .commands = try commands.toOwnedSlice(),
                            .closed = false,
                            .start = sub_start,
                        });
                        commands = std.ArrayList(Command).init(self.allocator);
                    }
                    const np = if (relative) Point{ .x = cur.x + x, .y = cur.y + y } else Point{ .x = x, .y = y };
                    cur = np;
                    sub_start = np;
                    have_subpath = true;
                    // After M, implicit subsequent pairs are L.
                    last_cmd = if (relative) 'l' else 'L';
                },
                'L' => {
                    const x = pd.readNumber() orelse return Error.SvgMalformed;
                    const y = pd.readNumber() orelse return Error.SvgMalformed;
                    const np = if (relative) Point{ .x = cur.x + x, .y = cur.y + y } else Point{ .x = x, .y = y };
                    try commands.append(.{ .kind = .line, .endpoint = np });
                    cur = np;
                    last_cmd = cmd;
                },
                'C' => {
                    const x1 = pd.readNumber() orelse return Error.SvgMalformed;
                    const y1 = pd.readNumber() orelse return Error.SvgMalformed;
                    const x2 = pd.readNumber() orelse return Error.SvgMalformed;
                    const y2 = pd.readNumber() orelse return Error.SvgMalformed;
                    const x = pd.readNumber() orelse return Error.SvgMalformed;
                    const y = pd.readNumber() orelse return Error.SvgMalformed;
                    const c1 = if (relative) Point{ .x = cur.x + x1, .y = cur.y + y1 } else Point{ .x = x1, .y = y1 };
                    const c2 = if (relative) Point{ .x = cur.x + x2, .y = cur.y + y2 } else Point{ .x = x2, .y = y2 };
                    const np = if (relative) Point{ .x = cur.x + x, .y = cur.y + y } else Point{ .x = x, .y = y };
                    try commands.append(.{ .kind = .cubic, .endpoint = np, .c1 = c1, .c2 = c2 });
                    cur = np;
                    last_cmd = cmd;
                },
                'Z' => {
                    // Close. Synthetic line back to subpath start —
                    // earcut works on closed contours so we don't
                    // emit a literal segment; the `closed=true` flag
                    // signals tessellator to wrap.
                    if (have_subpath) {
                        try subpaths.append(.{
                            .commands = try commands.toOwnedSlice(),
                            .closed = true,
                            .start = sub_start,
                        });
                        commands = std.ArrayList(Command).init(self.allocator);
                        cur = sub_start;
                        have_subpath = false;
                    }
                    last_cmd = cmd;
                },
                else => {
                    // Unknown command — bail out of this path. We
                    // could try to be clever and skip-ahead but
                    // Recraft never emits these and silent partial
                    // paths are worse than dropping the whole one.
                    return Error.SvgMalformed;
                },
            }
        }

        if (have_subpath and commands.items.len > 0) {
            try subpaths.append(.{
                .commands = try commands.toOwnedSlice(),
                .closed = false,
                .start = sub_start,
            });
        }

        return try subpaths.toOwnedSlice();
    }
};

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.';
}

/// Find an attribute value by key in the raw `key="value"` slice
/// produced by the tag scanner. Returns the unquoted value or null.
pub fn findAttr(attrs: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        const ks = i;
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '=') i += 1;
        const k = attrs[ks..i];
        if (i >= attrs.len or attrs[i] != '=') break;
        i += 1;
        if (i >= attrs.len) break;
        const q = attrs[i];
        if (q != '"' and q != '\'') break;
        i += 1;
        const vs = i;
        while (i < attrs.len and attrs[i] != q) i += 1;
        if (i >= attrs.len) break;
        const v = attrs[vs..i];
        i += 1; // closing quote
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

/// Parse `"x y w h"` (or comma-separated). Returns null on failure.
fn parseViewBox(s: []const u8) ?[4]f32 {
    var pr: PathReader = .{ .src = s, .pos = 0 };
    var out: [4]f32 = undefined;
    for (0..4) |i| {
        _ = pr.skipWhitespaceAndCommas();
        out[i] = pr.readNumber() orelse return null;
    }
    return out;
}

/// Parse a `transform="translate(x[,y])"` value. Only translate is
/// supported; anything else (matrix, rotate, scale) returns identity.
fn parseTranslate(s: []const u8) Point {
    const trim = std.mem.trim(u8, s, " \t\r\n");
    if (!std.mem.startsWith(u8, trim, "translate")) return .{ .x = 0, .y = 0 };
    const open = std.mem.indexOfScalar(u8, trim, '(') orelse return .{ .x = 0, .y = 0 };
    const close = std.mem.indexOfScalarPos(u8, trim, open, ')') orelse return .{ .x = 0, .y = 0 };
    const body = trim[open + 1 .. close];
    var pr: PathReader = .{ .src = body, .pos = 0 };
    _ = pr.skipWhitespaceAndCommas();
    const x = pr.readNumber() orelse return .{ .x = 0, .y = 0 };
    _ = pr.skipWhitespaceAndCommas();
    const y = pr.readNumber() orelse 0;
    return .{ .x = x, .y = y };
}

/// Parse an SVG fill string. Recognises:
///   * `rgb(r, g, b)` — channels in [0, 255]
///   * `#rrggbb`, `#rgb`
///   * `none` → fully transparent (alpha 0)
///   * Anything else (named colours etc.) defaults to opaque black.
/// Alpha is always 1.0 unless `none` is matched.
fn parseFill(s: []const u8) [4]f32 {
    const trim = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.eql(u8, trim, "none")) return .{ 0, 0, 0, 0 };
    if (std.mem.startsWith(u8, trim, "rgb(")) {
        const close = std.mem.indexOfScalar(u8, trim, ')') orelse return .{ 0, 0, 0, 1 };
        const body = trim[4..close];
        var pr: PathReader = .{ .src = body, .pos = 0 };
        var ch: [3]f32 = .{ 0, 0, 0 };
        for (0..3) |i| {
            _ = pr.skipWhitespaceAndCommas();
            ch[i] = (pr.readNumber() orelse 0) / 255.0;
        }
        return .{ ch[0], ch[1], ch[2], 1 };
    }
    if (std.mem.startsWith(u8, trim, "#")) {
        const hex = trim[1..];
        if (hex.len == 6) {
            const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return .{ 0, 0, 0, 1 };
            const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return .{ 0, 0, 0, 1 };
            const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return .{ 0, 0, 0, 1 };
            return .{ @as(f32, @floatFromInt(r)) / 255.0, @as(f32, @floatFromInt(g)) / 255.0, @as(f32, @floatFromInt(b)) / 255.0, 1 };
        }
        if (hex.len == 3) {
            const r = std.fmt.parseInt(u8, hex[0..1], 16) catch return .{ 0, 0, 0, 1 };
            const g = std.fmt.parseInt(u8, hex[1..2], 16) catch return .{ 0, 0, 0, 1 };
            const b = std.fmt.parseInt(u8, hex[2..3], 16) catch return .{ 0, 0, 0, 1 };
            return .{
                @as(f32, @floatFromInt(r * 17)) / 255.0,
                @as(f32, @floatFromInt(g * 17)) / 255.0,
                @as(f32, @floatFromInt(b * 17)) / 255.0,
                1,
            };
        }
    }
    return .{ 0, 0, 0, 1 };
}

/// SVG path-data number reader. Handles whitespace + comma
/// separators, leading sign, optional decimal, optional exponent.
const PathReader = struct {
    src: []const u8,
    pos: usize,

    fn skipWhitespaceAndCommas(self: *PathReader) bool {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isWhitespace(c) or c == ',') self.pos += 1 else break;
        }
        return true;
    }

    fn readNumber(self: *PathReader) ?f32 {
        _ = self.skipWhitespaceAndCommas();
        const start = self.pos;
        if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
        var saw_digit = false;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) saw_digit = true;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) saw_digit = true;
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
        }
        if (!saw_digit) {
            self.pos = start;
            return null;
        }
        const slice = self.src[start..self.pos];
        return std.fmt.parseFloat(f32, slice) catch null;
    }
};

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "svg: parses minimal document with a single straight path" {
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
        \\<path d="M 10 10 L 90 10 L 90 90 L 10 90 z" fill="rgb(255,0,0)"></path>
        \\</svg>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    try testing.expectEqual(@as(f32, 100), doc.view_w);
    try testing.expectEqual(@as(f32, 100), doc.view_h);
    try testing.expectEqual(@as(usize, 1), doc.paths.len);
    const p = doc.paths[0];
    try testing.expectEqual(@as(f32, 1.0), p.color[0]);
    try testing.expectEqual(@as(f32, 0.0), p.color[1]);
    try testing.expectEqual(@as(usize, 1), p.subpaths.len);
    try testing.expect(p.subpaths[0].closed);
    try testing.expectEqual(@as(usize, 3), p.subpaths[0].commands.len); // 3 L's; the initial M sets start
}

test "svg: parses cubic Beziers (C command)" {
    const source =
        \\<svg viewBox="0 0 200 200">
        \\<path d="M 100 50 C 150 50 150 150 100 150 C 50 150 50 50 100 50 z" fill="#0080ff"/>
        \\</svg>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 1), doc.paths.len);
    try testing.expectEqual(@as(usize, 1), doc.paths[0].subpaths.len);
    const cmds = doc.paths[0].subpaths[0].commands;
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expectEqual(CommandKind.cubic, cmds[0].kind);
    try testing.expectEqual(@as(f32, 150), cmds[0].c1.x);
    try testing.expectEqual(@as(f32, 50), cmds[0].c1.y);
    try testing.expectEqual(@as(f32, 100), cmds[0].endpoint.x);
    try testing.expectEqual(@as(f32, 150), cmds[0].endpoint.y);
}

test "svg: implicit L after M (multiple coord pairs on one M)" {
    // SVG spec: after M, extra coordinate pairs are implicit L.
    const source =
        \\<svg viewBox="0 0 100 100">
        \\<path d="M 10 10 20 20 30 30 z" fill="rgb(0,0,0)"/>
        \\</svg>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    const cmds = doc.paths[0].subpaths[0].commands;
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expectEqual(CommandKind.line, cmds[0].kind);
    try testing.expectEqual(@as(f32, 20), cmds[0].endpoint.x);
}

test "svg: multiple subpaths via consecutive M" {
    const source =
        \\<svg viewBox="0 0 100 100">
        \\<path d="M 0 0 L 10 0 L 10 10 z M 20 20 L 30 20 L 30 30 z" fill="rgb(0,0,0)"/>
        \\</svg>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 2), doc.paths[0].subpaths.len);
    try testing.expectEqual(@as(f32, 0), doc.paths[0].subpaths[0].start.x);
    try testing.expectEqual(@as(f32, 20), doc.paths[0].subpaths[1].start.x);
}

test "svg: parses transform=\"translate(...)\"" {
    const source =
        \\<svg viewBox="0 0 100 100">
        \\<path d="M 0 0 L 10 10 z" fill="rgb(0,0,0)" transform="translate(5,7)"/>
        \\<path d="M 0 0 L 10 10 z" fill="rgb(0,0,0)" transform="translate(3 4)"/>
        \\<path d="M 0 0 L 10 10 z" fill="rgb(0,0,0)"/>
        \\</svg>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    try testing.expectEqual(@as(f32, 5), doc.paths[0].translate.x);
    try testing.expectEqual(@as(f32, 7), doc.paths[0].translate.y);
    try testing.expectEqual(@as(f32, 3), doc.paths[1].translate.x);
    try testing.expectEqual(@as(f32, 4), doc.paths[1].translate.y);
    try testing.expectEqual(@as(f32, 0), doc.paths[2].translate.x);
}

test "svg: parses rgb + hex fills" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), parseFill("rgb(255,255,255)")[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), parseFill("rgb(128,0,0)")[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), parseFill("#ff00ff")[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), parseFill("#f0f")[2], 0.001);
    try testing.expectEqual(@as(f32, 0), parseFill("none")[3]);
}

test "svg: missing viewBox is an error" {
    const source = "<svg><path d=\"M 0 0\" /></svg>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(Error.SvgMissingViewBox, parse(arena.allocator(), source));
}

test "svg: ignores unknown tags and continues" {
    const source =
        \\<svg viewBox="0 0 10 10">
        \\<defs><linearGradient id="g"/></defs>
        \\<g>
        \\<path d="M 0 0 L 5 0 L 5 5 z" fill="#fff"/>
        \\</g>
        \\</svg>
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 1), doc.paths.len);
}

test "svg: parses Recraft Petunias.svg without error" {
    // Best smoke test we have — point the parser at the real
    // Recraft V4.1 output and confirm it survives. Path data is
    // ~50KB of dense cubics, exercises every branch of the parser.
    const source = @embedFile("test_data/Petunias.svg");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 125), doc.paths.len);
    try testing.expect(doc.view_w > 1000);
    try testing.expect(doc.view_h > 1000);
    // First path is the orange background fill — verify color.
    try testing.expectApproxEqAbs(@as(f32, 250.0 / 255.0), doc.paths[0].color[0], 0.005);
    try testing.expectApproxEqAbs(@as(f32, 107.0 / 255.0), doc.paths[0].color[1], 0.005);
    try testing.expectApproxEqAbs(@as(f32, 32.0 / 255.0), doc.paths[0].color[2], 0.005);
}
