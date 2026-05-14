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

/// Per-run text styling. The same `Style` an inline `text` element
/// carries; future emphasis/strong/link inline kinds derive a child
/// style from the parent's.
///
/// Lives here (not in `text/layout.zig` any more) because it's part
/// of the public element vocabulary — every `text` element has one.
pub const Style = struct {
    font_id: registry_mod.FontId,
    color: [4]f32,
    /// Target colour at `attention == 1.0`. Mono + SDF shader
    /// branches lerp `color → hot_color` by attention; colour-atlas
    /// glyphs (emoji) ignore it. Default warm yellow reads as the
    /// conventional "this is hot / important" cue.
    hot_color: [4]f32 = .{ 1.0, 0.85, 0.40, 1.0 },
    /// LM-driven [0..1] (shader clamps). Default 0 = no visible
    /// effect even with `hot_color` set; opt in by setting non-zero
    /// or by animating the SSBO per-frame for live signals.
    attention: f32 = 0.0,
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

    /// Ordered or unordered list. Items are typically `list_item`
    /// elements; the walker renders a marker (• for unordered, "N."
    /// for ordered) at a fixed indent and recurses item content at a
    /// deeper indent. `start` selects the first number for ordered
    /// lists (defaults to 1).
    list: struct {
        ordered: bool,
        items: []const Element,
        marker_style: Style,
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
};

/// GPU draw work accumulated during the walk. Stage 1 only fills
/// `glyphs`. When widgets land we add `quads` (rounded-rect chrome,
/// solid backgrounds), `lines` (borders, separators), `images`
/// (icons, textured panels). Element implementations don't need to
/// change to opt in — they just start filling more fields.
pub const DrawList = struct {
    glyphs: std.ArrayList(tp.GlyphInstance),
    // future:
    // quads:  std.ArrayList(QuadInstance),
    // lines:  std.ArrayList(LineInstance),
    // images: std.ArrayList(ImageInstance),

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{
            .glyphs = std.ArrayList(tp.GlyphInstance).init(allocator),
        };
    }

    pub fn deinit(self: *DrawList) void {
        self.glyphs.deinit();
        self.* = undefined;
    }

    /// Drop all accumulated draw work without freeing capacity —
    /// the common case at frame start.
    pub fn clearRetainingCapacity(self: *DrawList) void {
        self.glyphs.clearRetainingCapacity();
    }
};

const glyph_cache_mod = @import("text/glyph_cache.zig");
const atlas_mod = @import("gpu/atlas.zig");
