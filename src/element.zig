//! Element — the universal contract layout engines hand to text_engine.
//!
//! Markdown blocks are the first concrete implementers; future ANSI
//! cells, syntax-highlighter spans, and (long-term) ImGui-style
//! widgets all plug in through the same shape. Stage 1 ships the
//! minimum kinds needed to re-render session 1's demo content
//! (text, line_break, paragraph, heading, container.stack_v) plus
//! the `custom` escape hatch so future widget kinds can land without
//! breaking the union.
//!
//! Two-pass-friendly shape:
//!   * `Constraints` flows down (parent → child: "you have at most this
//!     much room"),
//!   * `Box` flows up (child → parent: "I took this much, baseline is
//!     here").
//! Stage 1 walker is single-pass — it lays out and writes glyphs to
//! the `DrawList` in one walk. That's fine for immediate-mode UI
//! (the long-term destination); a separate measure pass for retained
//! cases can come later without breaking the contract.
//!
//! What's *not* in here yet but the design holds room for:
//!   * `list`, `quote`, `code_block`, `thematic_break` — stage B
//!     (markdown's full block vocabulary).
//!   * Non-glyph primitives in `DrawList` (quads / lines / images) —
//!     when we add element backgrounds + borders for ImGui-shaped
//!     widget chrome.
//!   * Input handling — every element will expose its laid-out `Box`
//!     so hit-testing can land on it later; the box is not buried.
//!
//! The library is currently named `text_engine`. The destination is
//! broader (Markdown + terminals + Dear ImGui + game UI). Rename
//! conversation happens once the contract is concrete enough to
//! name what the library actually does — not yet.

const std = @import("std");
const registry_mod = @import("font/registry.zig");
const tp = @import("gpu/text_pipeline.zig");

/// Per-run text styling. Every `text` leaf carries one; inline
/// structural kinds (`emphasis` / `strong` / `code` / `link`) are
/// render-time transparent — the parser/builder bakes the cascade
/// into each text leaf's `Style` ahead of time via `Theme.apply*`.
///
/// The semantic flags (`emphasis`, `strong`, `code_inline`, `link`)
/// are markers, not visual switches. They let the cascade helpers
/// resolve correctly (emphasis-inside-strong → bold-italic font) and
/// future fx_kind effects (link hover, code-span background)
/// distinguish the runs. Rendering reads `font_id` + `color` +
/// `hot_color` + `attention` — the flags don't directly drive shape
/// math.
pub const Style = struct {
    font_id: registry_mod.FontId,
    color: [4]f32,
    /// Target colour at `attention == 1.0`. Mono + SDF shader
    /// branches lerp `color → hot_color` by attention; colour-atlas
    /// glyphs (emoji) ignore it.
    hot_color: [4]f32 = .{ 1.0, 0.85, 0.40, 1.0 },
    /// LM-driven [0..1] (shader clamps). Default 0 = no visible
    /// effect even with `hot_color` set.
    attention: f32 = 0.0,

    /// Set when this run sits inside an `emphasis` inline container.
    /// `Theme.applyEmphasis` writes it; the cascade helpers consult
    /// it to pick bold-italic when `strong` is also true.
    emphasis: bool = false,
    /// Set when this run sits inside a `strong` inline container.
    strong: bool = false,
    /// Set when this run sits inside an inline `code` span. Drives
    /// font swap to mono + colour override at apply time; future
    /// stage will draw a code-span background quad.
    code_inline: bool = false,
    /// Set when this run sits inside a `link`. Drives colour
    /// override at apply time; future stage adds underline via
    /// fx_kind and hover state.
    link: bool = false,
};

/// How a `container` element arranges its children. Stage 1 ships
/// `stack_v` only — vertical stacking is the spine of markdown block
/// flow and of most ImGui-style layout (windows, panels). `stack_h`
/// (horizontal stacking), `flex`, `grid` etc. land when widgets ask
/// for them; closed enum with a thoughtful default beats a fully-
/// general "layout descriptor" struct we'd over-engineer now.
pub const ContainerLayout = enum {
    /// Children stack top-to-bottom. Each child's `Box.h` advances
    /// the cursor; `gap` (on the container) separates siblings.
    stack_v,
};

/// Content of a `code_block`. Either raw preformatted text (renders
/// in a single monospace style, newlines split into physical lines —
/// no wrap), or the result of running another layout engine over the
/// inner source (the composability hook — markdown's ` ```ansi `
/// fence dispatches to the ANSI engine and stuffs the resulting tree
/// in here). Stage 2a handles `.raw`; `.sub_block` lands when the
/// ANSI engine arrives.
pub const CodeContent = union(enum) {
    raw: struct { text: []const u8, style: Style },
    sub_block: *const Element,
};

/// The element tree. Closed set of named kinds (fast dispatch, clear
/// pattern-matching) plus `custom` as the open escape hatch for
/// future widgets / engines that haven't earned a named slot.
///
/// Inline content lives in the same union as block content. A
/// paragraph's `children: []const Element` may contain `text` and
/// `line_break` leaves; a heading's `content` is the same shape.
/// When emphasis / strong / inline-code arrive, they'll be nestable
/// inline containers (each carrying a child element list).
pub const Element = union(enum) {
    // ── inline leaves ───────────────────────────────────────────────
    /// A run of text in a single style. Inside a paragraph or
    /// heading flows left-to-right; outside one is a layout error
    /// (caught by the walker — see `error.TextNotInInlineContext`).
    text: struct { content: []const u8, style: Style },

    /// Forced break within a paragraph. Equivalent to markdown's
    /// hard break (two-trailing-spaces or backslash). The current
    /// line flushes, the pen returns to `origin.x`, baseline advances
    /// by the line's `max(line_height)`.
    line_break,

    // ── inline structural containers ────────────────────────────────
    // Render-time transparent: the walker recurses into their content
    // without changing anything. The cascade — picking italic /
    // bold / mono / link-colour fonts — is the parser/builder's job,
    // baked into the descendant `text` leaves via `Theme.apply*`.
    // These exist so semantic structure survives in the tree for
    // future hit-testing, semantic queries, and effects (link hover,
    // code-span backgrounds).

    /// Italic / "emphasis" span. Container of inline content.
    emphasis: []const Element,

    /// Bold / "strong" span. Container of inline content.
    strong: []const Element,

    /// Inline monospace code span (e.g. `` `foo` `` in markdown).
    /// Container of inline content; in practice almost always a
    /// single `text` leaf, but kept as a slice for symmetry.
    code: []const Element,

    /// Hyperlink. `target` is the URI; `content` is the visible
    /// inline content. Underline rendering and click handling land
    /// later — for stage 2c this just colours the descendant runs.
    link: struct { target: []const u8, content: []const Element },

    // ── block containers ────────────────────────────────────────────
    /// Block of inline content laid out into one or more lines.
    /// Children must be inline (`text` / `line_break` for stage 1;
    /// `emphasis` / `strong` / `code` / `link` will join later).
    paragraph: []const Element,

    /// Semantic heading. Stage 1 lays it out identically to
    /// `paragraph` — the caller picks the font_id + colour on each
    /// child text element. `level` is preserved for parsers + ToC
    /// generation + future theming.
    heading: struct { level: u8, content: []const Element },

    /// Structural container that arranges its children according to
    /// `layout`. Stage 1: `stack_v` only. `gap` is applied between
    /// siblings (not before the first or after the last). The
    /// document root is typically `container { stack_v, children }`.
    container: struct {
        layout: ContainerLayout,
        children: []const Element,
        gap: f32 = 0,
    },

    /// Explicit vertical space. Cleaner than `paragraph { children:
    /// &.{} }` for inserting gaps between blocks where per-block
    /// margins aren't quite right.
    spacer: struct { height: f32 },

    /// Horizontal rule — markdown's `---` / `***` / `___`. Rendered
    /// as a thin filled quad spanning the available width, centred
    /// vertically within `theme.thematic_break_height`.
    thematic_break,

    /// Ordered or unordered list. Items are typically `list_item`
    /// elements; the walker renders a marker (• for unordered, "N."
    /// for ordered) at the theme's `list_marker_indent` and recurses
    /// item content at `list_content_indent`. Marker style comes
    /// from `theme.list_marker`. `start` selects the first number
    /// for ordered lists.
    list: struct {
        ordered: bool,
        items: []const Element,
        start: u32 = 1,
    },

    /// One list entry — a vertical stack of its own block content.
    /// Multiple paragraphs / nested lists per item are normal in
    /// CommonMark; the walker treats children as a stack_v.
    list_item: struct {
        children: []const Element,
    },

    /// Block quote. Children are blocks (typically paragraphs); the
    /// walker indents them. The left bar visual is deferred until the
    /// quad/line pipeline lands (stage 4+) — for now, indent alone
    /// distinguishes the quote.
    quote: struct {
        children: []const Element,
    },

    /// Preformatted text block. Single style throughout (no inline
    /// styling within). Newlines in `content.raw.text` split into
    /// physical lines — no wrapping, no whitespace collapsing.
    /// `.sub_block` (cooperative content from another layout engine,
    /// e.g. ANSI) is reserved but not yet rendered.
    code_block: struct {
        content: CodeContent,
    },

    // ── open escape hatch ───────────────────────────────────────────
    /// Anything not yet named — future ImGui widgets, custom game UI
    /// elements, third-party engines. The implementer fills in
    /// `vtable.layout` (returns a `Box`) and `vtable.render` (writes
    /// to the `DrawList`). When a custom kind earns its keep it
    /// graduates to a named variant of this union.
    custom: struct {
        vtable: *const ElementVTable,
        ctx: *anyopaque,
    },
};

/// vtable for `custom` elements. Two-method contract that mirrors
/// the shape of the named variants' walker dispatch — measure, then
/// render. The walker hands both ctx + the resolved origin; the
/// custom element returns its `Box`.
///
/// Reserved for stage 3+: `input` for hit-testing / event dispatch.
/// Layout boxes are already queryable from the returned `Box`, so
/// input plumbing slots in without changing the layout/render
/// contract.
pub const ElementVTable = struct {
    layout_and_render: *const fn (
        ctx: *anyopaque,
        origin: [2]f32,
        constraints: Constraints,
        lc: *LayoutCtx,
        out: *DrawList,
    ) anyerror!Box,
};

/// Parent-imposed bounds. Stage 1 walker mostly ignores these — text
/// flows unconstrained, the way session 1's demo does — but they're
/// already on the contract so wrap policies, fixed-size widgets, and
/// flex containers slot in without changing every signature.
pub const Constraints = struct {
    min_w: f32 = 0,
    max_w: f32 = std.math.inf(f32),
    min_h: f32 = 0,
    max_h: f32 = std.math.inf(f32),
};

/// Layout result for one element. Pixel coords (display space, not
/// NDC). `baseline` is in the same coordinate system as `y`; it's
/// the y of the text baseline for text-bearing boxes, or 0 for
/// non-text elements (containers, widgets, images).
pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    baseline: f32 = 0,
};

/// Visual + layout policy. Two distinct roles:
///   * **Walker reads:** layout constants (indents, gaps), block
///     defaults (`list_marker`, `code_block`, `heading_styles`) it
///     might consult directly.
///   * **Parser / builder reads:** baseline styles + cascade helpers
///     (`applyEmphasis`, `applyStrong`, etc.) when constructing the
///     tree. Cascade is *not* performed at render time — descendant
///     `text` leaves carry their pre-resolved Style.
///
/// Built once after the font registry is populated; the host hands
/// it explicit font IDs for italic / bold / bold-italic / mono /
/// heading variants. Slots that don't have a distinct font (e.g.
/// loading only `regular`) point back at `body.font_id` and the
/// cascade becomes a semantic no-op — emphasis renders identical to
/// body, the `emphasis: true` flag still rides along for future
/// effects.
///
/// Stage 2c caveat: cascade is body-context-relative. Applying
/// emphasis to a heading style swaps to the body italic font rather
/// than a heading italic. A future per-block "font family" abstraction
/// fixes this — but most real docs don't nest emphasis inside
/// headings, and the parser can pick its battles in stage 3.
pub const Theme = struct {
    // ── Baseline styles ─────────────────────────────────────────────
    /// Default body text — the starting point for the inline cascade.
    body: Style,
    /// Heading by level. Index 0 = h1, 5 = h6.
    heading: [6]Style,
    /// Default code-block style (full-block preformatted).
    code_block: Style,
    /// Style the walker uses for list markers (• / "N.").
    list_marker: Style,

    // ── Cascade variant font IDs ────────────────────────────────────
    /// Italic variant of the body font.
    emphasis_font_id: registry_mod.FontId,
    /// Bold variant of the body font.
    strong_font_id: registry_mod.FontId,
    /// Bold-italic variant. Selected when both `emphasis` and
    /// `strong` are active.
    bold_italic_font_id: registry_mod.FontId,
    /// Mono variant at body display size, for inline code spans.
    code_inline_font_id: registry_mod.FontId,

    // ── Cascade colour overrides ────────────────────────────────────
    code_inline_color: [4]f32 = .{ 0.72, 0.88, 1.0, 1.0 },
    link_color: [4]f32 = .{ 0.45, 0.72, 1.0, 1.0 },

    // ── Block chrome (quad primitives) ──────────────────────────────
    // All colours straight-RGBA — the quad fragment premultiplies at
    // output. Alpha < 1 produces a subtle panel; the demo's defaults
    // sit at ~15% opacity so backgrounds read as a tint without
    // muddying foreground text contrast.
    code_block_bg: [4]f32 = .{ 0.45, 0.55, 0.75, 0.15 },
    code_block_radius: f32 = 6,
    code_block_pad_x: f32 = 10,
    code_block_pad_y: f32 = 8,

    quote_bar_color: [4]f32 = .{ 0.45, 0.55, 0.75, 0.6 },
    quote_bar_width: f32 = 3,

    thematic_break_color: [4]f32 = .{ 0.45, 0.50, 0.62, 0.7 },
    thematic_break_height: f32 = 12,
    thematic_break_thickness: f32 = 2,

    // ── Layout constants the walker reads ───────────────────────────
    list_marker_indent: f32 = 8,
    list_content_indent: f32 = 32,
    list_item_gap: f32 = 2,
    quote_indent: f32 = 20,
    block_child_gap: f32 = 4,

    // ── Cascade helpers (parser / hand-builder uses these) ──────────

    /// Apply emphasis (italic) modifier. Sets the flag and recomputes
    /// the font ID so emphasis-inside-strong correctly picks the
    /// bold-italic variant.
    pub fn applyEmphasis(self: Theme, s: Style) Style {
        var out = s;
        out.emphasis = true;
        out.font_id = self.resolveInlineFontId(out);
        return out;
    }

    /// Apply strong (bold) modifier. Same flag-and-recompute pattern.
    pub fn applyStrong(self: Theme, s: Style) Style {
        var out = s;
        out.strong = true;
        out.font_id = self.resolveInlineFontId(out);
        return out;
    }

    /// Apply inline-code modifier — swaps font to mono and overrides
    /// colour. `code_inline` is mutually exclusive with emphasis /
    /// strong at the renderer level (CommonMark doesn't allow nesting
    /// emphasis inside an inline-code span anyway).
    pub fn applyCodeInline(self: Theme, s: Style) Style {
        var out = s;
        out.code_inline = true;
        out.font_id = self.code_inline_font_id;
        out.color = self.code_inline_color;
        return out;
    }

    /// Apply link styling. Currently colour-only; underline lands
    /// with fx_kind in a later stage.
    pub fn applyLink(self: Theme, s: Style) Style {
        var out = s;
        out.link = true;
        out.color = self.link_color;
        return out;
    }

    /// Resolve the right cascade font for the active inline flags.
    /// `code_inline` wins exclusively; otherwise `strong` × `emphasis`
    /// pick from regular / italic / bold / bold-italic. Body-relative —
    /// the heading caveat at the top of `Theme` applies.
    fn resolveInlineFontId(self: Theme, s: Style) registry_mod.FontId {
        if (s.code_inline) return self.code_inline_font_id;
        if (s.strong and s.emphasis) return self.bold_italic_font_id;
        if (s.strong) return self.strong_font_id;
        if (s.emphasis) return self.emphasis_font_id;
        return self.body.font_id;
    }
};

/// Read-only handle elements use to ask text_engine for shaping +
/// atlas placement. Walker fills it once at the top of a frame and
/// passes by pointer through the tree. Owns nothing — every field
/// is a borrow from the host.
pub const LayoutCtx = struct {
    allocator: std.mem.Allocator,
    fonts: *registry_mod.FontRegistry,
    cache: *glyph_cache_mod.GlyphCache,
    mono_atlas: *atlas_mod.Atlas,
    color_atlas: *atlas_mod.Atlas,
    theme: *const Theme,
};

/// GPU draw work accumulated during the walk. Quads land first
/// (backgrounds, bars, rules) then glyphs on top — the host's frame
/// loop records them in that order inside one render pass.
///
/// Future fields slot in unchanged: `lines` (borders, separators),
/// `images` (markdown images, widget icons). Element handlers grow
/// into the new fields without breaking the contract.
pub const DrawList = struct {
    glyphs: std.ArrayList(tp.GlyphInstance),
    quads: std.ArrayList(qp.QuadInstance),
    // future:
    // lines:  std.ArrayList(LineInstance),
    // images: std.ArrayList(ImageInstance),

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{
            .glyphs = std.ArrayList(tp.GlyphInstance).init(allocator),
            .quads = std.ArrayList(qp.QuadInstance).init(allocator),
        };
    }

    pub fn deinit(self: *DrawList) void {
        self.glyphs.deinit();
        self.quads.deinit();
        self.* = undefined;
    }

    /// Drop all accumulated draw work without freeing capacity —
    /// the common case at frame start.
    pub fn clearRetainingCapacity(self: *DrawList) void {
        self.glyphs.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
    }
};

const glyph_cache_mod = @import("text/glyph_cache.zig");
const atlas_mod = @import("gpu/atlas.zig");
const qp = @import("gpu/quad_pipeline.zig");
