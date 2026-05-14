//! CommonMark → Element tree.
//!
//! Wraps the vendored cmark parser (vendor/cmark/, 0.31.2) and walks
//! its AST to produce an `element.Element` tree owned by the
//! caller-supplied arena. The cmark root is freed before parse()
//! returns — the Element tree references only arena-allocated
//! strings and slices, so it survives the cmark lifetime cleanly.
//!
//! ### Cascade
//!
//! Style resolution happens here, threaded through recursion. The
//! mapper holds the "current Style" and:
//!
//!   * starts at `theme.body` for normal content,
//!   * swaps to `theme.heading[level - 1]` when entering a heading,
//!   * applies `theme.applyEmphasis / applyStrong / applyCodeInline
//!     / applyLink` when descending into the matching inline kind,
//!   * writes the resolved Style onto every TEXT leaf as it emits.
//!
//! The walker downstream consequently treats the structural inline
//! kinds (emphasis/strong/code/link) as render-time transparent —
//! all the visual distinction lives in the resolved text-leaf styles.
//!
//! ### Soft vs hard line breaks
//!
//! `CMARK_NODE_SOFTBREAK` (a literal newline in the source between
//! two non-empty lines) is emitted as a one-space text node, matching
//! the CommonMark "newlines collapse to spaces in paragraphs" rule.
//! `CMARK_NODE_LINEBREAK` (markdown's hard break — two trailing
//! spaces or a backslash) becomes a real `line_break` element.
//!
//! ### Deferred / approximated
//!
//!   * **Thematic break** (`---`) renders as a 12px spacer until the
//!     quad/line pipeline lands.
//!   * **HTML blocks / inline HTML** render as preformatted code
//!     (raw source visible) — better than dropping silently, less
//!     work than HTML rendering we don't want anyway.
//!   * **Images** render as their alt text only.
//!   * **Link `title=` attribute** ignored; only `href` is captured.

const std = @import("std");
const element = @import("element.zig");

pub const cmark = @cImport({
    @cInclude("cmark.h");
});

pub const Error = error{
    CmarkParseFailed,
    UnsupportedNodeKind,
} || std.mem.Allocator.Error;

/// Parse `source` (UTF-8 CommonMark) into an Element tree owned by
/// `arena`. The returned root is a `container.stack_v` containing
/// every top-level block — the same shape as `cmark`'s
/// `CMARK_NODE_DOCUMENT`. Free the entire tree by deinit'ing the
/// arena the caller passed in.
pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
) Error!element.Element {
    const root = cmark.cmark_parse_document(
        source.ptr,
        source.len,
        cmark.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkParseFailed;
    defer cmark.cmark_node_free(root);

    return try mapBlock(arena, root, theme.body, theme);
}

// ── Block mapping ──────────────────────────────────────────────────

/// Map one cmark BLOCK node to an Element. `cascade` is the current
/// resolved style — relevant only for the inline content nested
/// inside this block; block kinds themselves don't carry a style.
fn mapBlock(
    arena: std.mem.Allocator,
    node: *cmark.cmark_node,
    cascade: element.Style,
    theme: *const element.Theme,
) Error!element.Element {
    const t = cmark.cmark_node_get_type(node);

    switch (t) {
        cmark.CMARK_NODE_DOCUMENT => {
            const children = try mapBlockChildren(arena, node, cascade, theme);
            return .{ .container = .{
                .layout = .stack_v,
                .children = children,
                .gap = 8,
            } };
        },

        cmark.CMARK_NODE_PARAGRAPH => {
            const inline_content = try mapInlineChildren(arena, node, cascade, theme);
            return .{ .paragraph = inline_content };
        },

        cmark.CMARK_NODE_HEADING => {
            const raw_level = cmark.cmark_node_get_heading_level(node);
            const level: u8 = @intCast(std.math.clamp(raw_level, 1, 6));
            // Headings restart the inline cascade from their own
            // baseline style — emphasis inside an h2 cascades off the
            // h2 base, NOT off body. (Limited by the body-relative
            // cascade caveat in element.Theme — fix when nested
            // emphasis inside headings becomes a visual concern.)
            const heading_base = theme.heading[level - 1];
            const inline_content = try mapInlineChildren(arena, node, heading_base, theme);
            return .{ .heading = .{ .level = level, .content = inline_content } };
        },

        cmark.CMARK_NODE_BLOCK_QUOTE => {
            const children = try mapBlockChildren(arena, node, cascade, theme);
            return .{ .quote = .{ .children = children } };
        },

        cmark.CMARK_NODE_LIST => {
            const ordered = cmark.cmark_node_get_list_type(node) == cmark.CMARK_ORDERED_LIST;
            const raw_start = cmark.cmark_node_get_list_start(node);
            const start: u32 = if (ordered) @intCast(@max(@as(c_int, 1), raw_start)) else 1;
            const items = try mapBlockChildren(arena, node, cascade, theme);
            return .{ .list = .{ .ordered = ordered, .items = items, .start = start } };
        },

        cmark.CMARK_NODE_ITEM => {
            const children = try mapBlockChildren(arena, node, cascade, theme);
            return .{ .list_item = .{ .children = children } };
        },

        cmark.CMARK_NODE_CODE_BLOCK, cmark.CMARK_NODE_HTML_BLOCK => {
            // Both render as preformatted code for now. CMARK provides
            // the fenced language via `cmark_node_get_fence_info` —
            // when the ANSI engine lands we'll dispatch on that to
            // `CodeContent.sub_block`.
            const literal_ptr = cmark.cmark_node_get_literal(node);
            const raw: []const u8 = if (literal_ptr != null)
                std.mem.span(literal_ptr)
            else
                "";
            const trimmed = std.mem.trimRight(u8, raw, "\n");
            const owned = try arena.dupe(u8, trimmed);
            return .{ .code_block = .{ .content = .{ .raw = .{
                .text = owned,
                .style = theme.code_block,
            } } } };
        },

        cmark.CMARK_NODE_THEMATIC_BREAK => {
            // Visual line deferred until the quad/line pipeline ships.
            return .{ .spacer = .{ .height = 12 } };
        },

        else => return error.UnsupportedNodeKind,
    }
}

/// Iterate `parent`'s direct children, mapping each as a block. The
/// returned slice is arena-owned. Used by DOCUMENT, BLOCK_QUOTE,
/// LIST, ITEM — every container kind whose children are blocks.
fn mapBlockChildren(
    arena: std.mem.Allocator,
    parent: *cmark.cmark_node,
    cascade: element.Style,
    theme: *const element.Theme,
) Error![]const element.Element {
    var list = std.ArrayList(element.Element).init(arena);
    var child: ?*cmark.cmark_node = cmark.cmark_node_first_child(parent);
    while (child) |c| : (child = cmark.cmark_node_next(c)) {
        try list.append(try mapBlock(arena, c, cascade, theme));
    }
    return try list.toOwnedSlice();
}

// ── Inline mapping ─────────────────────────────────────────────────

/// Iterate `parent`'s direct children, mapping each as inline content.
/// Used by PARAGRAPH and HEADING (containers whose children are
/// inline), and recursively by emphasis/strong/code/link container
/// kinds.
fn mapInlineChildren(
    arena: std.mem.Allocator,
    parent: *cmark.cmark_node,
    cascade: element.Style,
    theme: *const element.Theme,
) Error![]const element.Element {
    var list = std.ArrayList(element.Element).init(arena);
    var child: ?*cmark.cmark_node = cmark.cmark_node_first_child(parent);
    while (child) |c| : (child = cmark.cmark_node_next(c)) {
        try appendInline(arena, c, cascade, theme, &list);
    }
    return try list.toOwnedSlice();
}

/// Map one inline cmark node and append the result(s) to `out`. Most
/// inline kinds produce exactly one Element; IMAGE produces zero or
/// more (its alt-text inline children, inlined).
fn appendInline(
    arena: std.mem.Allocator,
    node: *cmark.cmark_node,
    cascade: element.Style,
    theme: *const element.Theme,
    out: *std.ArrayList(element.Element),
) Error!void {
    const t = cmark.cmark_node_get_type(node);

    switch (t) {
        cmark.CMARK_NODE_TEXT => {
            const literal_ptr = cmark.cmark_node_get_literal(node);
            const literal: []const u8 = if (literal_ptr != null)
                std.mem.span(literal_ptr)
            else
                "";
            const owned = try arena.dupe(u8, literal);
            try out.append(.{ .text = .{ .content = owned, .style = cascade } });
        },

        cmark.CMARK_NODE_SOFTBREAK => {
            // Soft break = newline in source between two non-empty
            // lines of the same paragraph. CommonMark says render as
            // a space.
            try out.append(.{ .text = .{ .content = " ", .style = cascade } });
        },

        cmark.CMARK_NODE_LINEBREAK => {
            try out.append(.line_break);
        },

        cmark.CMARK_NODE_EMPH => {
            const inner_cascade = theme.applyEmphasis(cascade);
            const inner = try mapInlineChildren(arena, node, inner_cascade, theme);
            try out.append(.{ .emphasis = inner });
        },

        cmark.CMARK_NODE_STRONG => {
            const inner_cascade = theme.applyStrong(cascade);
            const inner = try mapInlineChildren(arena, node, inner_cascade, theme);
            try out.append(.{ .strong = inner });
        },

        cmark.CMARK_NODE_CODE => {
            // Inline code is a literal — no recursion into children,
            // just one text leaf inside the structural `code`
            // container. Code-inline cascade overrides font + colour.
            const literal_ptr = cmark.cmark_node_get_literal(node);
            const literal: []const u8 = if (literal_ptr != null)
                std.mem.span(literal_ptr)
            else
                "";
            const owned = try arena.dupe(u8, literal);
            const inner = try arena.alloc(element.Element, 1);
            inner[0] = .{ .text = .{ .content = owned, .style = theme.applyCodeInline(cascade) } };
            try out.append(.{ .code = inner });
        },

        cmark.CMARK_NODE_LINK => {
            const url_ptr = cmark.cmark_node_get_url(node);
            const target: []const u8 = if (url_ptr != null)
                try arena.dupe(u8, std.mem.span(url_ptr))
            else
                "";
            const inner_cascade = theme.applyLink(cascade);
            const inner = try mapInlineChildren(arena, node, inner_cascade, theme);
            try out.append(.{ .link = .{ .target = target, .content = inner } });
        },

        cmark.CMARK_NODE_IMAGE => {
            // Render alt-text only — image rendering needs the
            // texture pipeline (later). The alt content sits in the
            // image node's inline children; flatten them into the
            // outer flow as if the image weren't there.
            const alt = try mapInlineChildren(arena, node, cascade, theme);
            try out.appendSlice(alt);
        },

        cmark.CMARK_NODE_HTML_INLINE => {
            // Show the raw HTML as inline code so the source is
            // visible rather than silently dropped.
            const literal_ptr = cmark.cmark_node_get_literal(node);
            const literal: []const u8 = if (literal_ptr != null)
                std.mem.span(literal_ptr)
            else
                "";
            const owned = try arena.dupe(u8, literal);
            const inner = try arena.alloc(element.Element, 1);
            inner[0] = .{ .text = .{ .content = owned, .style = theme.applyCodeInline(cascade) } };
            try out.append(.{ .code = inner });
        },

        else => return error.UnsupportedNodeKind,
    }
}
