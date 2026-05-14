//! Markdown block-extension parser. Stage 7a of the live-documents
//! staging path (see docs/vision.md).
//!
//! Recognises the `:::name {attrs}\nbody\n:::` syntax that CommonMark
//! doesn't natively support, lifts those blocks out of the source
//! before it reaches cmark, and parks them in a sidecar `Spec` slice.
//! The original byte range gets replaced with a sentinel HTML comment
//! `<!--te:N-->` (N is the spec index) bracketed by blank lines so
//! cmark sees it as a standalone `CMARK_NODE_HTML_BLOCK`. The mapper
//! in markdown.zig intercepts that exact pattern and re-materialises
//! the spec as a `custom` Element backed by the placeholder vtable.
//!
//! Why pre-process instead of post-walking cmark's output: `:::`
//! lines are *our* syntax, not CommonMark's. cmark's paragraph
//! grouping treats them as plain text, sometimes splitting open / body
//! / close across multiple paragraphs depending on blank-line layout
//! — fragile to reconstruct downstream. Owning the lexer ourselves
//! gives unambiguous block boundaries and keeps vendored cmark
//! completely untouched.
//!
//! Stage 7a deliverable: parse runs, sidecar threads through, all
//! `:::` blocks render as `missing component: NAME` fallback panels.
//! Real factory dispatch + persistent component cache land in 7b.

const std = @import("std");
const element = @import("element.zig");
const text_layout = @import("text/layout.zig");
const shape = @import("font/shape.zig");
const state_mod = @import("state.zig");

pub const Error = error{
    UnterminatedComponentBlock,
    InvalidDirective,
    InvalidAttribute,
} || std.mem.Allocator.Error;

/// One key=value pair from a `:::name {key=val key="quoted val"}`
/// header. Bare values capture everything up to whitespace or `}`;
/// quoted values capture everything up to the matching `"` with no
/// escape handling yet (we defer that until real content needs it).
pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

/// Parsed component directive — the data a future component factory
/// (stage 7b) consumes to instantiate a real component. At stage 7a
/// the placeholder vtable only reads `name` for the fallback panel
/// label; `id` / `attrs` / `body` ride along unused but parsed so the
/// pipeline is end-to-end exercised.
pub const Spec = struct {
    name: []const u8,
    id: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    /// Raw body text between the `:::name {...}` open and the `:::`
    /// close, with leading + trailing newlines trimmed. Per-component
    /// interpretation (YAML, CSV, arbitrary) belongs to the component
    /// at stage 7c; we just preserve the bytes.
    body: []const u8 = "",
};

pub const Preprocessed = struct {
    /// Source with `:::` blocks replaced by `<!--te:N-->` sentinels,
    /// ready to feed to cmark.
    source: []const u8,
    /// Specs indexed by the sentinel N. Arena-owned alongside `source`.
    specs: []const Spec,
};

/// Walk `attrs` collecting every distinct `${path}` reference's
/// resolved key (with the optional `state.` prefix stripped, same
/// rules as `substituteState`). Used by the component registry to
/// know which paths to subscribe to. Owns no memory — keys are
/// slices into the caller-supplied attr value strings.
pub fn collectReferencedPaths(
    allocator: std.mem.Allocator,
    attrs: []const Attr,
) Error![][]const u8 {
    var paths = std.ArrayList([]const u8).init(allocator);
    for (attrs) |attr| {
        var i: usize = 0;
        while (i < attr.value.len) {
            if (attr.value[i] == '$' and i + 1 < attr.value.len and attr.value[i + 1] == '{') {
                const close = std.mem.indexOfScalarPos(u8, attr.value, i + 2, '}') orelse {
                    break;
                };
                const raw_path = std.mem.trim(u8, attr.value[i + 2 .. close], " \t");
                const key: []const u8 = if (std.mem.startsWith(u8, raw_path, "state."))
                    raw_path["state.".len..]
                else
                    raw_path;
                // Skip duplicates inside the same attrs sweep — same
                // path used in two attr values still only needs one
                // subscription per Binding.
                var already = false;
                for (paths.items) |existing| {
                    if (std.mem.eql(u8, existing, key)) {
                        already = true;
                        break;
                    }
                }
                if (!already) try paths.append(key);
                i = close + 1;
                continue;
            }
            i += 1;
        }
    }
    return paths.toOwnedSlice();
}

/// Pre-scan `source` for `:::name {attrs}\nbody\n:::` blocks. Returns
/// the rewritten source + the extracted specs, both owned by `arena`.
///
/// Block detection is line-based and naive on purpose: any line whose
/// trimmed content begins with `:::` followed by an identifier opens a
/// block; any line whose trimmed content is exactly `:::` closes it.
/// Fenced code blocks (` ``` ` or `~~~`) are tracked and the scanner
/// passes through them verbatim so embedded `:::` in code samples
/// doesn't get hijacked. Nesting `:::` inside another `:::` is not
/// supported at this stage — first `:::` close ends the block.
///
/// `state` is optional; when non-null, attribute values containing
/// `${path}` are looked up in the state and substituted at parse
/// time (stage 7d static interpolation). Reactive re-substitution
/// on state mutation is stage 7e.
pub fn preprocess(arena: std.mem.Allocator, source: []const u8, state: ?*const state_mod.State) Error!Preprocessed {
    var specs = std.ArrayList(Spec).init(arena);
    var out = std.ArrayList(u8).init(arena);
    try out.ensureUnusedCapacity(source.len);

    var in_block = false;
    var current: Spec = undefined;
    var body_buf = std.ArrayList(u8).init(arena);

    var in_fence = false;
    var fence_marker: []const u8 = "";

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (in_block) {
            if (std.mem.eql(u8, trimmed, ":::")) {
                const body_trimmed = std.mem.trim(u8, body_buf.items, "\n\r");
                current.body = try arena.dupe(u8, body_trimmed);
                const idx = specs.items.len;
                try specs.append(current);
                // Bracket the sentinel with blank lines to guarantee
                // cmark sees it as block-context HTML — without the
                // surrounding blanks, an open line that abuts a
                // preceding paragraph would get inlined into it.
                try out.writer().print("\n\n<!--te:{d}-->\n\n", .{idx});
                in_block = false;
                body_buf.clearRetainingCapacity();
            } else {
                try body_buf.appendSlice(line);
                try body_buf.append('\n');
            }
            continue;
        }

        // Outside a `:::` block: track fenced-code state so we don't
        // intercept `:::` lines inside code samples.
        if (in_fence) {
            try out.appendSlice(line);
            try out.append('\n');
            if (std.mem.startsWith(u8, trimmed, fence_marker)) {
                in_fence = false;
                fence_marker = "";
            }
            continue;
        }
        if (fenceMarkerOf(trimmed)) |marker| {
            in_fence = true;
            fence_marker = marker;
            try out.appendSlice(line);
            try out.append('\n');
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ":::")) {
            const after = std.mem.trimLeft(u8, trimmed[3..], " \t");
            if (after.len > 0 and isNameStart(after[0])) {
                current = try parseDirectiveLine(arena, after, state);
                in_block = true;
                continue;
            }
            // Otherwise fall through and let cmark see the `:::` line
            // verbatim — e.g. `:::` at the end of a sentence in prose.
        }

        try out.appendSlice(line);
        try out.append('\n');
    }

    if (in_block) return error.UnterminatedComponentBlock;

    return .{
        .source = try out.toOwnedSlice(),
        .specs = try specs.toOwnedSlice(),
    };
}

/// Parse the post-`:::` content of a directive open line (i.e. the
/// caller has already stripped `:::` + leading whitespace). Returns a
/// Spec with `name` / `id` / `attrs` populated; `body` is left empty
/// for the preprocessor to fill in once it has scanned the body.
///
/// Grammar (informal):
///   directive  := name (`{` attr-list `}`)?
///   name       := IDENT
///   attr-list  := (attr ws*)*
///   attr       := `#` IDENT                       -- sets id
///                | IDENT `=` (BARE | `"` ... `"`) -- key/value
///                | IDENT                          -- key with ""
///   IDENT      := [A-Za-z][A-Za-z0-9_-]*
///   BARE       := [^ \t}]+
pub fn parseDirectiveLine(arena: std.mem.Allocator, content: []const u8, state: ?*const state_mod.State) Error!Spec {
    var i: usize = 0;

    // Name — allows digit-leading names like "3d-scene". Keys / ids
    // stay letter-leading via isIdentStart below; the looser rule only
    // applies here because directive names are tag-like, not
    // programming identifiers.
    const name_start = i;
    if (i >= content.len or !isNameStart(content[i])) return error.InvalidDirective;
    i += 1;
    while (i < content.len and isIdentChar(content[i])) : (i += 1) {}
    const name = try arena.dupe(u8, content[name_start..i]);

    skipSpaces(content, &i);

    var id: ?[]const u8 = null;
    var attrs = std.ArrayList(Attr).init(arena);

    if (i < content.len and content[i] == '{') {
        i += 1;
        while (true) {
            skipSpaces(content, &i);
            if (i >= content.len) return error.InvalidAttribute;
            if (content[i] == '}') {
                i += 1;
                break;
            }

            if (content[i] == '#') {
                i += 1;
                const id_start = i;
                while (i < content.len and isIdentChar(content[i])) : (i += 1) {}
                if (i == id_start) return error.InvalidAttribute;
                id = try arena.dupe(u8, content[id_start..i]);
                continue;
            }

            const key_start = i;
            if (!isIdentStart(content[i])) return error.InvalidAttribute;
            i += 1;
            while (i < content.len and isIdentChar(content[i])) : (i += 1) {}
            const key = try arena.dupe(u8, content[key_start..i]);

            var value: []const u8 = "";
            if (i < content.len and content[i] == '=') {
                i += 1;
                if (i < content.len and content[i] == '"') {
                    i += 1;
                    const v_start = i;
                    while (i < content.len and content[i] != '"') : (i += 1) {}
                    if (i >= content.len) return error.InvalidAttribute;
                    value = try substituteState(arena, content[v_start..i], state);
                    i += 1; // consume closing quote
                } else {
                    // Bare value scanner — terminates on whitespace
                    // or the closing `}` of the attribute block, but
                    // treats `${...}` as a single opaque unit so
                    // template `}` doesn't truncate the value.
                    const v_start = i;
                    var depth: u32 = 0;
                    while (i < content.len) : (i += 1) {
                        const ch = content[i];
                        if (depth == 0 and isAttrTerminator(ch)) break;
                        if (ch == '$' and i + 1 < content.len and content[i + 1] == '{') {
                            depth += 1;
                            i += 1; // consume the `{` too (loop increments past `$`)
                            continue;
                        }
                        if (depth > 0 and ch == '}') depth -= 1;
                    }
                    value = try substituteState(arena, content[v_start..i], state);
                }
            }
            try attrs.append(.{ .key = key, .value = value });
        }
    }

    // Anything beyond the closing brace should be only whitespace.
    skipSpaces(content, &i);
    if (i < content.len) return error.InvalidDirective;

    return .{
        .name = name,
        .id = id,
        .attrs = try attrs.toOwnedSlice(),
        .body = "",
    };
}

/// Walk `raw` substituting any `${path}` segments with the matching
/// value from `state`. Unresolved paths (state is null, or the path
/// isn't set) leave the `${...}` token in place — louder than silent
/// emptiness, easier for authors / LLMs to notice they typo'd a key.
/// Always returns an arena-allocated string so the caller's
/// lifetime contract is uniform regardless of whether substitution
/// happened.
///
/// Public so the component registry can re-run substitution against
/// a current state when a path mutates (stage 7e reactivity).
pub fn substituteState(arena: std.mem.Allocator, raw: []const u8, state: ?*const state_mod.State) Error![]const u8 {
    // Fast path: no `$` → straight dupe, skip the rebuild.
    if (std.mem.indexOfScalar(u8, raw, '$') == null) {
        return try arena.dupe(u8, raw);
    }

    var out = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, raw, i + 2, '}');
            if (close) |end| {
                const path_raw = raw[i + 2 .. end];
                const path = std.mem.trim(u8, path_raw, " \t");
                // `state.` prefix is optional — both `${state.x}` and
                // `${x}` resolve against the same flat map. Vision
                // examples lean on the prefixed form; tolerating both
                // costs nothing.
                const lookup_key: []const u8 = if (std.mem.startsWith(u8, path, "state."))
                    path["state.".len..]
                else
                    path;
                if (state) |s| {
                    if (s.get(lookup_key)) |val| {
                        try out.appendSlice(val);
                        i = end + 1;
                        continue;
                    }
                }
                // Unresolved — leave the literal `${...}` so the
                // typo is visible downstream.
                try out.appendSlice(raw[i .. end + 1]);
                i = end + 1;
                continue;
            }
            // Unterminated `${` — emit verbatim and bail out.
            try out.appendSlice(raw[i..]);
            break;
        }
        try out.append(raw[i]);
        i += 1;
    }
    return try out.toOwnedSlice();
}

/// Recognise the sentinel HTML comment emitted by `preprocess` inside
/// a `CMARK_NODE_HTML_BLOCK` literal. Returns the spec index on match,
/// null otherwise — the caller then routes to fallback HTML-as-code
/// rendering. We strip whitespace + carriage returns because cmark may
/// re-quote the block's content with a trailing newline.
pub fn extractSentinelIndex(literal: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, literal, " \t\r\n");
    const prefix = "<!--te:";
    const suffix = "-->";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    if (!std.mem.endsWith(u8, trimmed, suffix)) return null;
    const body = trimmed[prefix.len .. trimmed.len - suffix.len];
    return std.fmt.parseInt(usize, body, 10) catch null;
}

// ── Placeholder vtable ─────────────────────────────────────────────
//
// At stage 7a every component renders as a clearly-marked fallback so
// the parser side can be validated without any of the runtime layer
// (registry, cache, real components) being in place. Colours +
// padding live here as private constants rather than on `Theme` — the
// fallback is a failure-mode visual that the author shouldn't see
// once 7b/7c ship, so it doesn't earn theme surface area.

const PLACEHOLDER_BORDER: [4]f32 = .{ 0.85, 0.30, 0.30, 0.95 };
const PLACEHOLDER_BG: [4]f32 = .{ 0.30, 0.08, 0.08, 0.60 };
const PLACEHOLDER_RADIUS: f32 = 6;
const PLACEHOLDER_BORDER_PX: f32 = 2;
const PLACEHOLDER_PAD_X: f32 = 12;
const PLACEHOLDER_PAD_Y: f32 = 8;
const PLACEHOLDER_MIN_W: f32 = 240;

pub const placeholder_vtable: element.ElementVTable = .{
    .layout_and_render = placeholderLayoutAndRender,
};

fn placeholderLayoutAndRender(
    ctx_raw: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const spec: *const Spec = @ptrCast(@alignCast(ctx_raw));
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "missing component: {s}",
        .{spec.name},
    ) catch "missing component";

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, msg);

    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const intrinsic_w = text_w + 2 * PLACEHOLDER_PAD_X;
    const total_w: f32 = if (std.math.isFinite(constraints.max_w))
        constraints.max_w
    else
        @max(intrinsic_w, PLACEHOLDER_MIN_W);
    const total_h: f32 = m.line_height + 2 * PLACEHOLDER_PAD_Y;

    // Border (outer rounded panel) — opaque-ish red. Drawn first so
    // the inner panel layers on top, leaving only a 2px ring visible.
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ total_w, total_h },
        .color = PLACEHOLDER_BORDER,
        .radius = PLACEHOLDER_RADIUS,
    });
    // Inner panel — darker semi-transparent fill, inset by the border
    // thickness with proportionally-smaller corner radius so the inner
    // rounding follows the outer.
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + PLACEHOLDER_BORDER_PX, origin[1] + PLACEHOLDER_BORDER_PX },
        .dst_size = .{ total_w - 2 * PLACEHOLDER_BORDER_PX, total_h - 2 * PLACEHOLDER_BORDER_PX },
        .color = PLACEHOLDER_BG,
        .radius = @max(0, PLACEHOLDER_RADIUS - PLACEHOLDER_BORDER_PX),
    });

    const baseline_y = origin[1] + PLACEHOLDER_PAD_Y + m.ascender;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        run,
        style.font_id,
        origin[0] + PLACEHOLDER_PAD_X,
        baseline_y,
        style.color,
        style.hot_color,
        style.attention,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = total_w,
        .h = total_h,
        .baseline = baseline_y,
    };
}

// ── Lexer helpers ──────────────────────────────────────────────────

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

/// Looser than `isIdentStart` — directive names (`3d-scene`, `chart`)
/// are tag-like and routinely start with digits. Keys / ids keep the
/// stricter letter-first rule.
fn isNameStart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
}

fn isAttrTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '}';
}

fn skipSpaces(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) : (i.* += 1) {}
}

/// Detect a fenced-code-block opener on a trimmed line. Returns the
/// fence run (` ``` ` or `~~~~`) when it matches CommonMark's fence
/// rule (>=3 of the same char), null otherwise.
fn fenceMarkerOf(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len < 3) return null;
    const c = trimmed[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == c) : (n += 1) {}
    if (n < 3) return null;
    return trimmed[0..n];
}

// ── Tests ──────────────────────────────────────────────────────────

test "parseDirectiveLine: name only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try parseDirectiveLine(arena.allocator(), "box", null);
    try std.testing.expectEqualStrings("box", s.name);
    try std.testing.expect(s.id == null);
    try std.testing.expectEqual(@as(usize, 0), s.attrs.len);
}

test "parseDirectiveLine: digit-leading name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try parseDirectiveLine(arena.allocator(), "3d-scene {#orbit}", null);
    try std.testing.expectEqualStrings("3d-scene", s.name);
    try std.testing.expectEqualStrings("orbit", s.id.?);
}

test "parseDirectiveLine: id + attrs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try parseDirectiveLine(arena.allocator(), "3d-scene {#orbit-view width=100% src=\"sat.gltf\"}", null);
    try std.testing.expectEqualStrings("3d-scene", s.name);
    try std.testing.expectEqualStrings("orbit-view", s.id.?);
    try std.testing.expectEqual(@as(usize, 2), s.attrs.len);
    try std.testing.expectEqualStrings("width", s.attrs[0].key);
    try std.testing.expectEqualStrings("100%", s.attrs[0].value);
    try std.testing.expectEqualStrings("src", s.attrs[1].key);
    try std.testing.expectEqualStrings("sat.gltf", s.attrs[1].value);
}

test "preprocess: extracts one block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try preprocess(arena.allocator(),
        \\before
        \\:::box {#bx color=red}
        \\hello
        \\:::
        \\after
        \\
    , null);
    try std.testing.expectEqual(@as(usize, 1), p.specs.len);
    try std.testing.expectEqualStrings("box", p.specs[0].name);
    try std.testing.expectEqualStrings("bx", p.specs[0].id.?);
    try std.testing.expectEqualStrings("hello", p.specs[0].body);
    try std.testing.expect(std.mem.indexOf(u8, p.source, "<!--te:0-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.source, ":::") == null);
}

test "preprocess: leaves fenced code alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try preprocess(arena.allocator(),
        \\```
        \\:::not-a-directive
        \\:::
        \\```
        \\
    , null);
    try std.testing.expectEqual(@as(usize, 0), p.specs.len);
    try std.testing.expect(std.mem.indexOf(u8, p.source, ":::not-a-directive") != null);
}

test "preprocess: unterminated block errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnterminatedComponentBlock, preprocess(arena.allocator(),
        \\:::box
        \\never closed
        \\
    , null));
}

test "extractSentinelIndex" {
    try std.testing.expectEqual(@as(?usize, 0), extractSentinelIndex("<!--te:0-->"));
    try std.testing.expectEqual(@as(?usize, 42), extractSentinelIndex("<!--te:42-->\n"));
    try std.testing.expectEqual(@as(?usize, null), extractSentinelIndex("<!-- something else -->"));
    try std.testing.expectEqual(@as(?usize, null), extractSentinelIndex("<!--te:abc-->"));
}

test "parseDirectiveLine: ${state.x} substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = state_mod.State.init(std.testing.allocator);
    defer state.deinit();
    try state.set("box_color", "blue");
    try state.set("target_id", "SAT-04");

    // `state.` prefix and bare paths both resolve.
    const s = try parseDirectiveLine(arena.allocator(), "box {color=${state.box_color} src=\"models/${target_id}.gltf\"}", &state);
    try std.testing.expectEqualStrings("blue", s.attrs[0].value);
    try std.testing.expectEqualStrings("models/SAT-04.gltf", s.attrs[1].value);
}

test "parseDirectiveLine: unresolved ${} stays literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = state_mod.State.init(std.testing.allocator);
    defer state.deinit();
    const s = try parseDirectiveLine(arena.allocator(), "box {color=${state.missing}}", &state);
    try std.testing.expectEqualStrings("${state.missing}", s.attrs[0].value);
}
