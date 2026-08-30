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
const ansi = @import("ansi.zig");

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
    /// Attribute values are kept in their **templated** form (with
    /// `${path}` literals); the registry substitutes against `state`
    /// at resolve time so the templated form is available for
    /// reactive re-substitution on state mutations (stage 7e).
    specs: []const components.Spec,
    /// Host-supplied component registry. When null, every `:::` block
    /// renders as the missing-component placeholder (stage-7a
    /// behaviour). When non-null, `mapBlock` tries `registry.resolve`
    /// first and falls back to the placeholder only for unregistered
    /// directive names.
    registry: ?*component_mod.Registry,
    /// Reactive state for `${path}` substitution. Hands directly to
    /// `registry.resolve`. The placeholder path doesn't need it
    /// (only reads `spec.name`).
    state: ?*state_mod.State,
    /// Cache-key scope for components resolved during this parse
    /// (stage 9). Null at the top-level doc; embedded-document
    /// factories propagate their `#id` here when calling
    /// parseWithState so child components don't collide with parent
    /// components in the registry's instance map.
    scope: ?[]const u8 = null,
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

/// Whether this parse is the outermost one for its source, or a
/// nested re-entry from a factory that is itself mid-parse.
///
/// It decides exactly one thing: who calls `Registry.beginParse`.
/// The outermost parse bumps every cached instance's unused counter
/// so `gc` can sweep what this parse does not touch; a nested parse
/// must NOT, because it is running *inside* that cycle and would
/// double-age its siblings.
///
/// This used to be inferred from `scope == null`, which held only
/// while a scope implied nesting. A mounted panel is scoped (so its
/// `#id`s do not collide with the next panel's) *and* outermost, so
/// the two questions came apart and are now asked separately.
pub const Nesting = enum { root, nested };

/// Same as `parseWithState` but also takes a `scope` prefix for the
/// registry's instance cache (stage 9). Embedded-document factories
/// call this with their own `#id` as the scope so child components
/// don't collide with the parent's in the same Registry.
///
/// Nested by definition — every caller is a factory reached from an
/// enclosing parse. A top-level document that wants a scope wants
/// `parseRootWithScope`.
pub fn parseWithStateAndScope(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
    registry: ?*component_mod.Registry,
    state: ?*state_mod.State,
    scope: ?[]const u8,
) anyerror!element.Element {
    return parseInternal(arena, source, theme, registry, state, scope, .nested);
}

/// An outermost parse that still namespaces its components.
///
/// The shape a host wants for a second, third, Nth document in one
/// Spark: `Document`s are independent but the Registry behind them
/// is shared, so without a scope two panels holding `:::slider
/// {#exposure}` resolve to ONE instance drawn twice, and every
/// document's first unnamed directive is `auto:0`.
pub fn parseRootWithScope(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
    registry: ?*component_mod.Registry,
    state: ?*state_mod.State,
    scope: ?[]const u8,
) anyerror!element.Element {
    return parseInternal(arena, source, theme, registry, state, scope, .root);
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
    state: ?*state_mod.State,
) anyerror!element.Element {
    return parseInternal(arena, source, theme, registry, state, null, .root);
}

fn parseInternal(
    arena: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
    registry: ?*component_mod.Registry,
    state: ?*state_mod.State,
    scope: ?[]const u8,
    nesting: Nesting,
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
    const effective_state: ?*state_mod.State = if (state) |s|
        s
    else if (local_state) |*s| s else null;

    // Preprocess intentionally does NOT substitute — Spec.attrs stay
    // templated so the component registry can stash the templates
    // and re-substitute on state mutations (stage 7e). The placeholder
    // path doesn't read attrs, so leaving them templated has no
    // visible consequence for unregistered directives.
    const pre = try components.preprocess(arena, body, null);

    const root = cmark.cmark_parse_document(
        pre.source.ptr,
        pre.source.len,
        cmark.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkParseFailed;
    defer cmark.cmark_node_free(root);

    // Only the top-level doc calls beginParse — embedded docs share
    // the registry but don't reset its parses_unused counters, since
    // they're a nested parse INSIDE one. Each parent re-parse will
    // re-invoke the embedded-doc factory which re-enters here; the
    // embedded children get touched via scoped resolve and stay
    // alive through the outer beginParse cycle naturally.
    if (nesting == .root) {
        // Aged within this document's own scope — see `beginParse`.
        if (registry) |r| r.beginParse(scope);
    }

    const mc: MapCtx = .{
        .arena = arena,
        .theme = theme,
        .specs = pre.specs,
        .registry = registry,
        .state = effective_state,
        .scope = scope,
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
            const inline_content = try mapInlineChildren(mc, node, cascade);
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
            const inline_content = try mapInlineChildren(mc, node, heading_base);
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
            // Fence info is the language tag (```ansi ...). When set
            // to `ansi`, hand the body to the ANSI parser and embed
            // the resulting Element tree as `CodeContent.sub_block` —
            // the layout walker recurses into it so live colours
            // render inside the same code-block chrome that wraps
            // raw text. Theme body swapped to `code_block` so SGR
            // text picks up the mono font for terminal-like spacing.
            const fence_info_ptr = cmark.cmark_node_get_fence_info(node);
            const fence_info: []const u8 = if (fence_info_ptr != null)
                std.mem.span(fence_info_ptr)
            else
                "";
            if (std.mem.eql(u8, fence_info, "ansi")) {
                const literal_ptr = cmark.cmark_node_get_literal(node);
                const raw: []const u8 = if (literal_ptr != null)
                    std.mem.span(literal_ptr)
                else
                    "";
                const trimmed = std.mem.trimRight(u8, raw, "\n");
                var ansi_theme = mc.theme.*;
                ansi_theme.body = mc.theme.code_block;
                const tree = try ansi.parse(mc.arena, trimmed, &ansi_theme);
                const owned = try mc.arena.create(element.Element);
                owned.* = tree;
                return .{ .code_block = .{ .content = .{ .sub_block = owned } } };
            }
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
                        if (try reg.resolve(spec_ptr, idx, mc.state, mc.scope)) |inst| {
                            return .{ .custom = .{
                                .vtable = inst.vtable,
                                .ctx = inst.ctx,
                                .pass_kind = inst.pass_kind,
                                .shader_id = inst.shader_id,
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

/// Emit one (or more) `.text` elements for a markdown TEXT node,
/// splitting on font-coverage boundaries when the theme has a fallback
/// font registered. Codepoints the primary font (cascade.font_id) has
/// stay in primary runs; codepoints only the fallback covers spin off
/// into sibling text leaves with `font_id = fallback`. Combining marks
/// (ZWJ + variation selectors) stick with the run they're modifying so
/// emoji ligature sequences (👨‍👩‍👧, ❤️, etc.) stay intact.
///
/// Falls back to the pre-fallback single-leaf path when the theme has
/// no `font_registry` or `fallback_font_id` — keeps the parser usable
/// in test contexts where no real registry exists.
fn appendTextWithFallback(
    arena: std.mem.Allocator,
    out: *std.ArrayList(element.Element),
    text: []const u8,
    cascade: element.Style,
    theme: *const element.Theme,
) Error!void {
    const fonts = theme.font_registry;
    const fallback_id = theme.fallback_font_id;
    if (fonts == null or fallback_id == null) {
        const owned = try arena.dupe(u8, text);
        try out.append(.{ .text = .{ .content = owned, .style = cascade } });
        return;
    }
    const reg = fonts.?;
    const fid = fallback_id.?;
    const primary = cascade.font_id;

    _ = std.unicode.Utf8View.init(text) catch {
        // Malformed UTF-8 — keep the leaf intact. Splitting per-byte
        // would produce garbage; better to render the box-of-shame
        // once than to fragment the text and lose meaning.
        const owned = try arena.dupe(u8, text);
        try out.append(.{ .text = .{ .content = owned, .style = cascade } });
        return;
    };

    var seg_start: usize = 0;
    var pos: usize = 0;
    var seg_uses_fallback = false;
    var first = true;

    while (pos < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch {
            pos += 1;
            continue;
        };
        const end = pos + cp_len;
        if (end > text.len) break;
        const cp = std.unicode.utf8Decode(text[pos..end]) catch {
            pos = end;
            continue;
        };

        // Peek the next codepoint so VS16 (U+FE0F → "render as emoji")
        // and VS15 (U+FE0E → "render as text") can override the
        // coverage check on the base codepoint. Without this, dual-
        // presentation codepoints like U+2764 (heart) — which most
        // text fonts ship as a monochrome glyph — would always route
        // to the primary, losing the colour-emoji rendering the
        // source explicitly requested via VS16.
        var next_cp: ?u32 = null;
        if (end < text.len) {
            if (std.unicode.utf8ByteSequenceLength(text[end])) |nl| {
                if (end + nl <= text.len) {
                    if (std.unicode.utf8Decode(text[end .. end + nl])) |ncp| {
                        next_cp = ncp;
                    } else |_| {}
                }
            } else |_| {}
        }

        const use_fb = pickFontForCodepoint(reg, primary, fid, cp, next_cp, seg_uses_fallback);
        if (first) {
            seg_uses_fallback = use_fb;
            first = false;
        } else if (use_fb != seg_uses_fallback) {
            try emitTextSegment(arena, out, text[seg_start..pos], cascade, fid, seg_uses_fallback);
            seg_start = pos;
            seg_uses_fallback = use_fb;
        }
        pos = end;
    }
    if (pos > seg_start) {
        try emitTextSegment(arena, out, text[seg_start..pos], cascade, fid, seg_uses_fallback);
    }
}

/// Per-codepoint dispatcher. Combining marks (ZWJ, variation selectors,
/// zero-width spaces) inherit from the current segment so emoji
/// ligature sequences stay intact even when the body font happens to
/// claim ZWJ as a non-printing character.
fn pickFontForCodepoint(
    fonts: *registry_mod.FontRegistry,
    primary: registry_mod.FontId,
    fallback: registry_mod.FontId,
    cp: u32,
    next_cp: ?u32,
    current_uses_fallback: bool,
) bool {
    switch (cp) {
        // ZWJ, ZWNJ, variation selectors 15/16, zero-width spaces —
        // inherit from the run they're decorating. (VS16 itself joins
        // the prior base's run; the lookahead below handled the base's
        // routing on the previous iteration.)
        0x200B, 0x200C, 0x200D, 0xFE0E, 0xFE0F => return current_uses_fallback,
        else => {},
    }
    // Explicit presentation overrides via Variation Selector
    // immediately following the base codepoint. Standard Unicode
    // emoji-presentation rule.
    if (next_cp) |nc| {
        if (nc == 0xFE0F and fonts.hasCodepoint(fallback, cp)) return true;
        if (nc == 0xFE0E and fonts.hasCodepoint(primary, cp)) return false;
    }
    if (fonts.hasCodepoint(primary, cp)) return false;
    if (fonts.hasCodepoint(fallback, cp)) return true;
    return false; // neither has it — let primary render `.notdef`
}

/// Append one font-homogeneous slice as a `.text` element. When
/// `use_fallback` is true, override the cascade's `font_id` to the
/// fallback (every other style field — colour, attention, link, etc.
/// — passes through unchanged so cascade behaviour outside font
/// selection is preserved).
fn emitTextSegment(
    arena: std.mem.Allocator,
    out: *std.ArrayList(element.Element),
    slice: []const u8,
    cascade: element.Style,
    fallback: registry_mod.FontId,
    use_fallback: bool,
) Error!void {
    const owned = try arena.dupe(u8, slice);
    var style = cascade;
    if (use_fallback) style.font_id = fallback;
    try out.append(.{ .text = .{ .content = owned, .style = style } });
}

const registry_mod = @import("font/registry.zig");

/// Iterate `parent`'s direct children, mapping each as inline content.
/// Used by PARAGRAPH and HEADING (containers whose children are
/// inline), and recursively by emphasis/strong/code/link container
/// kinds.
fn mapInlineChildren(
    mc: *const MapCtx,
    parent: *cmark.cmark_node,
    cascade: element.Style,
) Error![]const element.Element {
    var list = std.ArrayList(element.Element).init(mc.arena);
    var child: ?*cmark.cmark_node = cmark.cmark_node_first_child(parent);
    while (child) |c| : (child = cmark.cmark_node_next(c)) {
        try appendInline(mc, c, cascade, &list);
    }
    return try list.toOwnedSlice();
}

/// Map one inline cmark node and append the result(s) to `out`. Most
/// inline kinds produce exactly one Element; IMAGE produces zero or
/// more (its alt-text inline children, inlined).
fn appendInline(
    mc: *const MapCtx,
    node: *cmark.cmark_node,
    cascade: element.Style,
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
            try appendTextWithFallback(mc.arena, out, literal, cascade, mc.theme);
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
            const inner_cascade = mc.theme.applyEmphasis(cascade);
            const inner = try mapInlineChildren(mc, node, inner_cascade);
            try out.append(.{ .emphasis = inner });
        },

        cmark.CMARK_NODE_STRONG => {
            const inner_cascade = mc.theme.applyStrong(cascade);
            const inner = try mapInlineChildren(mc, node, inner_cascade);
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
            const owned = try mc.arena.dupe(u8, literal);
            const inner = try mc.arena.alloc(element.Element, 1);
            inner[0] = .{ .text = .{ .content = owned, .style = mc.theme.applyCodeInline(cascade) } };
            try out.append(.{ .code = inner });
        },

        cmark.CMARK_NODE_LINK => {
            const url_ptr = cmark.cmark_node_get_url(node);
            const target: []const u8 = if (url_ptr != null)
                try mc.arena.dupe(u8, std.mem.span(url_ptr))
            else
                "";
            const inner_cascade = mc.theme.applyLink(cascade);
            const inner = try mapInlineChildren(mc, node, inner_cascade);
            try out.append(.{ .link = .{ .target = target, .content = inner } });
        },

        cmark.CMARK_NODE_IMAGE => {
            // Render alt-text only — image rendering needs the
            // texture pipeline (later). The alt content sits in the
            // image node's inline children; flatten them into the
            // outer flow as if the image weren't there.
            const alt = try mapInlineChildren(mc, node, cascade);
            try out.appendSlice(alt);
        },

        cmark.CMARK_NODE_HTML_INLINE => {
            // Stage 15E.2: inline `::name{attrs}` directives survive
            // preprocess as `<!--ti:N-->` sentinels that cmark hands
            // back as HTML_INLINE literals. Detect, resolve through
            // the registry, materialise as Element.inline_object.
            // Anything else falls through to the original raw-HTML-
            // as-code rendering so legitimate inline HTML in source
            // stays visible rather than silently disappearing.
            const literal_ptr = cmark.cmark_node_get_literal(node);
            const literal: []const u8 = if (literal_ptr != null)
                std.mem.span(literal_ptr)
            else
                "";

            if (components.extractInlineSentinelIndex(literal)) |idx| {
                if (idx < mc.specs.len) {
                    const spec_ptr = &mc.specs[idx];
                    if (mc.registry) |reg| {
                        // Factory errors fall through to the inline
                        // fallback below — registry surfaces a broader
                        // error set than this mapper, and a single
                        // bad directive shouldn't blow up the whole
                        // parse.
                        const resolved = reg.resolve(spec_ptr, idx, mc.state, mc.scope) catch null;
                        if (resolved) |inst| {
                            try out.append(.{ .inline_object = .{
                                .vtable = inst.vtable,
                                .ctx = inst.ctx,
                            } });
                            return;
                        }
                    }
                    // Unresolved inline directive — render the original
                    // `::name` fragment as inert code so the author
                    // sees their typo or unregistered name. Cleaner
                    // than the block-level placeholder panel, which
                    // would blow the line height open mid-paragraph.
                    try appendInlineFallback(mc, spec_ptr.name, cascade, out);
                    return;
                }
            }

            // Genuine inline HTML — pre-15E.2 behaviour: render the
            // raw literal as inline code so it stays visible.
            const owned = try mc.arena.dupe(u8, literal);
            const inner = try mc.arena.alloc(element.Element, 1);
            inner[0] = .{ .text = .{ .content = owned, .style = mc.theme.applyCodeInline(cascade) } };
            try out.append(.{ .code = inner });
        },

        else => return error.UnsupportedNodeKind,
    }
}

/// Fallback rendering for an inline directive whose name isn't
/// registered (or whose factory.create errored). Emits the original
/// `::name` fragment as inert code-styled text so the author sees
/// what's wrong without the paragraph layout breaking.
fn appendInlineFallback(
    mc: *const MapCtx,
    name: []const u8,
    cascade: element.Style,
    out: *std.ArrayList(element.Element),
) Error!void {
    const owned = try std.fmt.allocPrint(mc.arena, "::{s}", .{name});
    const inner = try mc.arena.alloc(element.Element, 1);
    inner[0] = .{ .text = .{ .content = owned, .style = mc.theme.applyCodeInline(cascade) } };
    try out.append(.{ .code = inner });
}

// ── Tests ───────────────────────────────────────────────────────────

test "ansi fence dispatches to ansi.parse and embeds as sub_block" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Parse-only test — never reaches the font registry, so stub
    // font_ids of 0 are fine. Theme defaults fill in chrome fields.
    const stub_style: element.Style = .{ .font_id = 0, .color = .{ 1, 1, 1, 1 } };
    const theme: element.Theme = .{
        .body = stub_style,
        .heading = .{ stub_style, stub_style, stub_style, stub_style, stub_style, stub_style },
        .code_block = stub_style,
        .list_marker = stub_style,
        .emphasis_font_id = 0,
        .strong_font_id = 0,
        .bold_italic_font_id = 0,
        .code_inline_font_id = 0,
    };

    const source =
        "Before fence.\n\n" ++
        "```ansi\n" ++
        "plain \x1B[31mred\x1B[0m back\n" ++
        "```\n\n" ++
        "After fence.\n";

    const tree = try parse(arena, source, &theme, null);

    try std.testing.expect(tree == .container);
    const children = tree.container.children;
    try std.testing.expectEqual(@as(usize, 3), children.len);

    // Proof the ansi info-string was honored: middle child is a
    // code_block whose content tag is .sub_block, not .raw.
    try std.testing.expect(children[1] == .code_block);
    try std.testing.expect(children[1].code_block.content == .sub_block);

    // Embedded tree shape: container.stack_v of paragraphs.
    const sub = children[1].code_block.content.sub_block.*;
    try std.testing.expect(sub == .container);
    const paras = sub.container.children;
    try std.testing.expect(paras.len >= 1);
    try std.testing.expect(paras[0] == .paragraph);

    // SGR \x1B[31m sets foreground to palette index 1 — red
    // (170/255, 0, 0). At least one text leaf must carry it.
    var saw_red = false;
    for (paras[0].paragraph) |leaf| {
        if (leaf != .text) continue;
        const c = leaf.text.style.color;
        if (c[0] > 0.5 and c[1] < 0.1 and c[2] < 0.1) saw_red = true;
    }
    try std.testing.expect(saw_red);
}

test "non-ansi code fence stays raw" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const stub_style: element.Style = .{ .font_id = 0, .color = .{ 1, 1, 1, 1 } };
    const theme: element.Theme = .{
        .body = stub_style,
        .heading = .{ stub_style, stub_style, stub_style, stub_style, stub_style, stub_style },
        .code_block = stub_style,
        .list_marker = stub_style,
        .emphasis_font_id = 0,
        .strong_font_id = 0,
        .bold_italic_font_id = 0,
        .code_inline_font_id = 0,
    };

    // Different language must NOT trigger the ANSI path — falls
    // through to the existing preformatted handler.
    const source =
        "```zig\n" ++
        "const x = 1;\n" ++
        "```\n";

    const tree = try parse(arena, source, &theme, null);
    try std.testing.expect(tree == .container);
    const children = tree.container.children;
    try std.testing.expectEqual(@as(usize, 1), children.len);
    try std.testing.expect(children[0] == .code_block);
    try std.testing.expect(children[0].code_block.content == .raw);
}
