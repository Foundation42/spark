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
const components = @import("markdown_components.zig");
const component_mod = @import("component.zig");
const state_mod = @import("state.zig");

pub const cmark = @cImport({
    @cInclude("cmark.h");
});

pub const Error = error{
    CmarkParseFailed,
    UnsupportedNodeKind,
} || std.mem.Allocator.Error || components.Error;

// Once a registry is involved, host-supplied factory closures can
// throw anything — collapse our return type to `anyerror!Element`.
// Public error set above stays for callers that don't pass a
// registry and want a narrow signature later.

/// Threaded through the block-mapping recursion. Replaces the old
/// `arena + theme` pair (one struct ptr is cheaper to pass than two
/// scalars, and we needed somewhere to hang `specs` anyway). Inline
/// mapping doesn't see `specs` because inline content is never a
/// component — keeps the inline recursion signature unchanged.
const MapCtx = struct {
    arena: std.mem.Allocator,
    theme: *const element.Theme,
    /// Specs for `:::` component blocks, indexed by sentinel N.
    /// Populated by `components.preprocess` ahead of the cmark parse.
    specs: []const components.Spec,
    /// Host-supplied component registry. When null, every `:::` block
    /// renders as the missing-component placeholder (stage-7a
    /// behaviour). When non-null, `mapBlock` tries `registry.resolve`
    /// first and falls back to the placeholder only for unregistered
    /// directive names.
    registry: ?*component_mod.Registry,
};

/// Parse `source` (UTF-8 CommonMark) into an Element tree owned by
/// `arena`. The returned root is a `container.stack_v` containing
/// every top-level block — the same shape as `cmark`'s
/// `CMARK_NODE_DOCUMENT`. Free the entire tree by deinit'ing the
/// arena the caller passed in.
///
/// `:::name {attrs}\nbody\n:::` block extensions are extracted before
/// cmark sees the source (see `markdown_components.preprocess`); the
/// extracted specs ride along through the mapper as a sidecar slice
/// and get re-materialised as `custom` Elements when the mapper hits
/// the matching sentinel HTML comment.
///
/// `registry` is the optional component registry. Passing null gets
/// the 7a placeholder behaviour for every directive. Passing one
/// instructs the mapper to consult it for each `:::` block: hits
/// produce real component instances (vtable + ctx from the
/// host-registered factory); misses still fall through to the
/// placeholder. The registry's `beginParse` is invoked before the
/// mapper runs; the host is responsible for calling `gc()` once it
/// has swapped the new Element tree into place.
pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
    registry: ?*component_mod.Registry,
) anyerror!element.Element {
    return parseWithState(arena, source, theme, registry, null);
}

/// Same as `parse` but with an explicit `?*const State` to use for
/// `${path}` interpolation in component attribute values. When
/// `state` is null and the source begins with a `---` YAML
/// frontmatter block, the frontmatter is parsed into a temporary
/// State and used for substitution — the simplest path for static
/// docs that declare their state inline. When `state` is non-null,
/// any frontmatter in the source is still stripped (so cmark never
/// sees it as a `---` thematic break) but the host's state takes
/// precedence — the right shape for stage 7e when the host owns the
/// state across re-parses.
///
/// The temporary state built from inline frontmatter lives in
/// `arena` and is freed when the arena is.
pub fn parseWithState(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
    registry: ?*component_mod.Registry,
    state: ?*const state_mod.State,
) anyerror!element.Element {
    var body: []const u8 = source;
    var local_state: ?state_mod.State = null;
    defer if (local_state) |*s| s.deinit();

    if (state_mod.extractFrontmatter(source)) |fm| {
        body = fm.rest;
        if (state == null) {
            local_state = try state_mod.parseFrontmatter(arena, fm.body);
        }
    }
    const effective_state: ?*const state_mod.State = if (state) |s|
        s
    else if (local_state) |*s| s else null;

    const pre = try components.preprocess(arena, body, effective_state);

    const root = cmark.cmark_parse_document(
        pre.source.ptr,
        pre.source.len,
        cmark.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkParseFailed;
    defer cmark.cmark_node_free(root);

    if (registry) |r| r.beginParse();

    const mc: MapCtx = .{
        .arena = arena,
        .theme = theme,
        .specs = pre.specs,
        .registry = registry,
    };
    return try mapBlock(&mc, root, theme.body);
}

// ── Block mapping ──────────────────────────────────────────────────

/// Map one cmark BLOCK node to an Element. `cascade` is the current
/// resolved style — relevant only for the inline content nested
/// inside this block; block kinds themselves don't carry a style.
fn mapBlock(
    mc: *const MapCtx,
    node: *cmark.cmark_node,
    cascade: element.Style,
) anyerror!element.Element {
    const t = cmark.cmark_node_get_type(node);

    switch (t) {
        cmark.CMARK_NODE_DOCUMENT => {
            const children = try mapBlockChildren(mc, node, cascade);
            return .{ .container = .{
                .layout = .stack_v,
                .children = children,
                .gap = 8,
            } };
        },

        cmark.CMARK_NODE_PARAGRAPH => {
            const inline_content = try mapInlineChildren(mc.arena, node, cascade, mc.theme);
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
            const heading_base = mc.theme.heading[level - 1];
            const inline_content = try mapInlineChildren(mc.arena, node, heading_base, mc.theme);
            return .{ .heading = .{ .level = level, .content = inline_content } };
        },

        cmark.CMARK_NODE_BLOCK_QUOTE => {
            const children = try mapBlockChildren(mc, node, cascade);
            return .{ .quote = .{ .children = children } };
        },

        cmark.CMARK_NODE_LIST => {
            const ordered = cmark.cmark_node_get_list_type(node) == cmark.CMARK_ORDERED_LIST;
            const raw_start = cmark.cmark_node_get_list_start(node);
            const start: u32 = if (ordered) @intCast(@max(@as(c_int, 1), raw_start)) else 1;
            const items = try mapBlockChildren(mc, node, cascade);
            return .{ .list = .{ .ordered = ordered, .items = items, .start = start } };
        },

        cmark.CMARK_NODE_ITEM => {
            const children = try mapBlockChildren(mc, node, cascade);
            return .{ .list_item = .{ .children = children } };
        },

        cmark.CMARK_NODE_CODE_BLOCK => {
            // CMARK provides the fenced language via
            // `cmark_node_get_fence_info` — when the ANSI engine
            // lands (stage 5b) we'll dispatch on that to
            // `CodeContent.sub_block`.
            return try makePreformattedBlock(mc, node);
        },

        cmark.CMARK_NODE_HTML_BLOCK => {
            // `:::` blocks survive the preprocess as HTML comment
            // sentinels — `<!--te:N-->` — which cmark emits as
            // `CMARK_NODE_HTML_BLOCK` literals. Match and materialise
            // a `custom` element backed by the spec; otherwise fall
            // back to rendering the raw HTML block as preformatted
            // text (better than dropping silently).
            const literal_ptr = cmark.cmark_node_get_literal(node);
            const literal: []const u8 = if (literal_ptr != null)
                std.mem.span(literal_ptr)
            else
                "";
            if (components.extractSentinelIndex(literal)) |idx| {
                if (idx < mc.specs.len) {
                    const spec_ptr = &mc.specs[idx];
                    // Try the registered factory first. Cache hit
                    // reuses a persistent instance; miss invokes the
                    // factory's create. Either way the Element holds
                    // the factory-supplied vtable + ctx — the cached
                    // instance state lives in the registry's
                    // allocator, stable across many parses.
                    if (mc.registry) |reg| {
                        if (try reg.resolve(spec_ptr, idx)) |inst| {
                            return .{ .custom = .{
                                .vtable = inst.vtable,
                                .ctx = inst.ctx,
                            } };
                        }
                    }
                    // No registry, or no factory for this directive
                    // name — fall back to the missing-component
                    // placeholder. Spec lives in arena memory; its
                    // address is stable for the Element tree's
                    // lifetime.
                    return .{ .custom = .{
                        .vtable = &components.placeholder_vtable,
                        .ctx = @ptrCast(@constCast(spec_ptr)),
                    } };
                }
            }
            return try makePreformattedBlock(mc, node);
        },

        cmark.CMARK_NODE_THEMATIC_BREAK => {
            return .thematic_break;
        },

        else => return error.UnsupportedNodeKind,
    }
}

/// Wrap a CODE_BLOCK or HTML_BLOCK literal in a preformatted
/// code_block Element. Shared between the cmark CODE_BLOCK arm and
/// the HTML_BLOCK fallback path (when the literal isn't one of our
/// `:::` sentinels).
fn makePreformattedBlock(
    mc: *const MapCtx,
    node: *cmark.cmark_node,
) anyerror!element.Element {
    const literal_ptr = cmark.cmark_node_get_literal(node);
    const raw: []const u8 = if (literal_ptr != null)
        std.mem.span(literal_ptr)
    else
        "";
    const trimmed = std.mem.trimRight(u8, raw, "\n");
    const owned = try mc.arena.dupe(u8, trimmed);
    return .{ .code_block = .{ .content = .{ .raw = .{
        .text = owned,
        .style = mc.theme.code_block,
    } } } };
}

/// Iterate `parent`'s direct children, mapping each as a block. The
/// returned slice is arena-owned. Used by DOCUMENT, BLOCK_QUOTE,
/// LIST, ITEM — every container kind whose children are blocks.
fn mapBlockChildren(
    mc: *const MapCtx,
    parent: *cmark.cmark_node,
    cascade: element.Style,
) anyerror![]const element.Element {
    var list = std.ArrayList(element.Element).init(mc.arena);
    var child: ?*cmark.cmark_node = cmark.cmark_node_first_child(parent);
    while (child) |c| : (child = cmark.cmark_node_next(c)) {
        try list.append(try mapBlock(mc, c, cascade));
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
