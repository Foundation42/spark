//! Element — the universal contract layout engines hand to spark.
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
//! The library is named `spark`. The destination is broader
//! (Markdown + terminals + Dear ImGui + game UI); the contract here
//! is the universal substrate underneath.

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

    /// ANSI / SGR decoration. Underline draws below baseline using
    /// `theme.link_underline_*_em`; same emit path as `link` runs.
    /// Independent so an ANSI run can be underlined without being a
    /// hyperlink.
    underline: bool = false,
    /// Horizontal line through the middle of the x-height, sized via
    /// `theme.strikethrough_*_em`. Same per-run emit pattern as
    /// underline.
    strikethrough: bool = false,
    /// Inverse video. Triggers a background quad in the run's `color`
    /// and forces text to render in `theme.background` for contrast.
    /// `bg` (below) is the canonical place to express the resulting
    /// background colour; the inline-flow walker emits one bg quad
    /// per contiguous run.
    reverse: bool = false,
    /// Optional run background colour. Drawn as a quad behind the
    /// glyphs in the inline-flow walker. Used by `reverse` and (later)
    /// by ANSI background-colour SGR codes (40-47, 100-107, 48;…).
    /// `null` means no background quad — the default.
    bg: ?[4]f32 = null,
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
        /// Pass-graph dispatch metadata for effect components.
        /// **Raw scalar fields rather than an imported `PassShape`
        /// tag** — dodges the element.zig ↔ component.zig import
        /// cycle that would form if we typed this against
        /// `component.PassShape`. `Registry.resolve` (in
        /// component.zig) translates from `Factory.pass_shape`
        /// into these fields at element-construction time; the
        /// walker (`element_layout.zig`) reads them to emit
        /// `PassDispatch` entries into `LayoutCtx.pass_dispatches`.
        ///
        ///   `pass_kind = 0` → `.content` (default, rasterizer-only)
        ///   `pass_kind = 1` → `.pattern`
        ///   `pass_kind = 2` → `.single_source`  (Phase B)
        ///   `pass_kind = 3` → `.chain`           (Phase C)
        ///   `pass_kind = 4` → `.host_slot`       (Phase B/D)
        ///
        /// `shader_id` is the wire-format 16-byte ShaderId
        /// (`component.ShaderId`) the factory committed to at
        /// comptime via `pass.shaderIdFromName(name)`. Zero when
        /// `pass_kind == 0` — the walker uses this as a redundant
        /// sanity check.
        pass_kind: u8 = 0,
        shader_id: [16]u8 = [_]u8{0} ** 16,
    },

    /// Inline-context component. Flows alongside text in a
    /// paragraph/heading at glyph granularity — the inline-flow walker
    /// reserves space for it, baseline-resolves it against surrounding
    /// runs, and dispatches to its vtable to paint at the resolved
    /// `(pen_x, baseline_y)`. The component is responsible for sizing
    /// itself via `vtable.measure_inline` (called before wrap) and
    /// painting itself via `vtable.layout_and_render` (called from
    /// `emitLine` once its line position is settled).
    ///
    /// `valign` controls vertical placement against the line's
    /// resolved baseline. `.baseline` is the default and the right
    /// choice for any component whose interior has its own text
    /// baseline (badges, inline mini-charts with axis labels).
    /// Non-text components (sparkline glyphs, generated SVG icons)
    /// typically want `.middle` or `.top`.
    inline_object: struct {
        vtable: *const ElementVTable,
        ctx: *anyopaque,
        valign: InlineAlign = .baseline,
    },
};

/// Vertical alignment of an `inline_object` against the line's
/// resolved baseline. Computed once per object during line build.
pub const InlineAlign = enum {
    /// Object's reported `ascender` sits at the line's `max(ascender)`
    /// — visually, the object's interior baseline aligns with the
    /// surrounding text baseline. Default; correct for badges and any
    /// other component with its own text inside.
    baseline,
    /// Object's vertical center aligns with the line's x-height
    /// center. Suits text-less glyphs (sparklines, icons).
    middle,
    /// Object's top edge aligns with the line's top. Suits very tall
    /// objects that should hang from the cap line.
    top,
    /// Object's bottom edge aligns with the line's bottom. Symmetric
    /// to `.top`; rarely the right answer but cheap to support.
    bottom,
};

/// Intrinsic size + baseline an inline component reports to the
/// flow walker before wrap. All three values are in display pixels
/// (same coord system as `Box.w/h` and font metrics). `ascender +
/// descender` is the object's full vertical extent; the walker uses
/// `ascender` to participate in the line's `max(ascender)` resolve
/// and `descender` to extend the line box below the baseline if
/// needed.
pub const IntrinsicMetrics = struct {
    width: f32,
    ascender: f32,
    descender: f32 = 0,
};

/// Intrinsic size + layout hint a block component reports to a
/// constraint-aware parent (currently `:::flex`; future `:::grid`
/// row tracks, future custom layouts). Same coord system as
/// `Box.w/h`. `grow` is the flex-grow weight — 0 means "I claim
/// only my intrinsic width"; nonzero means "I claim a proportional
/// share of any slack my parent has after subtracting fixed-width
/// siblings." Only `:::flex` honours it today; other parents
/// (stack_v, list) ignore it.
pub const BlockMetrics = struct {
    width: f32,
    height: f32,
    grow: u32 = 0,
};

/// How a block participates in its parent stack's flow (stage 15 Phase
/// E text exclusion / shape-outside, v1).
///
/// `.normal` — the default. Stack_v lays the child out at its current
/// cursor and advances vertically by `Box.h`.
///
/// `.float_left` / `.float_right` — the child is positioned at the
/// container's left or right edge at the current cursor, and the
/// cursor does NOT advance. The child registers a rect exclusion via
/// `LayoutContext.registerExclusion` so following inline content wraps
/// around its silhouette. The stack tracks the float's bottom in its
/// reported height so containers don't visually clip.
pub const FlowKind = enum { normal, float_left, float_right };

/// vtable for `custom` elements. Two slots: a required
/// layout-and-render and an optional input handler.
///
/// The input slot was reserved across earlier stages and lands at
/// stage 7f. Components without `on_input` (the common case — most
/// chrome doesn't react to input) leave it null and never enter the
/// hit-test layer.
pub const ElementVTable = struct {
    layout_and_render: *const fn (
        ctx: *anyopaque,
        origin: [2]f32,
        constraints: Constraints,
        lc: *LayoutCtx,
        out: *DrawList,
    ) anyerror!Box,
    /// Optional. Called by the host's event dispatcher when a mouse
    /// event hit-tests inside the component's box. `state` is the
    /// host-owned reactive state — handlers mutate it via `set` to
    /// drive other components reactively.
    on_input: ?*const fn (
        ctx: *anyopaque,
        event: InputEvent,
        state: *anyopaque,
    ) anyerror!void = null,
    /// True if this component wants keyboard focus on click. The
    /// element_layout walker stamps this onto the emitted `Hit` so
    /// the host's input dispatcher can wire focus correctly.
    /// Default false — only text-bearing widgets (`:::input`) opt in.
    focusable: bool = false,
    /// Optional content-version getter for the retained layout cache
    /// (stage 14a). Returns a monotonic counter the component bumps
    /// on every internal mutation (chart append, LLM stream chunk,
    /// SVG mesh swap, input caret edit, etc.). The cache keys
    /// include this — a bump produces a fresh key → cache miss →
    /// re-walk. `null` means "treat as content-version 0", which is
    /// correct for pure-by-pointer-identity components.
    content_version: ?*const fn (ctx: *anyopaque) u64 = null,
    /// Disable caching for this component at the outer Element level.
    /// Set when the component's layout output depends on external
    /// state the cache key can't see — reading `state.*` at layout
    /// time (slider thumb position), per-frame animation (input
    /// caret blink), or recursive composition whose inner mutations
    /// can't be summarised in a single version counter
    /// (embedded-document). Inner stack_v walks still cache their
    /// own children — only the outer block-grain cache is suppressed.
    disable_cache: bool = false,
    /// Optional. Called by the inline-flow walker before wrap to
    /// learn an `inline_object`'s intrinsic size + baseline so the
    /// walker can place it correctly within a line. Required for any
    /// component used as an `inline_object`; ignored when the
    /// component appears as a block `custom` element. `em_px` is the
    /// surrounding text's body display size, supplied so components
    /// that want to scale relative to their context can do so without
    /// reaching into the font registry.
    measure_inline: ?*const fn (
        ctx: *anyopaque,
        em_px: f32,
        lc: *LayoutCtx,
    ) anyerror!IntrinsicMetrics = null,
    /// Optional. Called by constraint-aware parents (`:::flex`,
    /// future `:::grid` row tracks) BEFORE placement to learn the
    /// child's intrinsic size + grow weight. The parent uses this
    /// to compute slack distribution: fixed-width children claim
    /// their intrinsic; grow>0 children share whatever's left.
    /// Components that don't opt in get measured by the dispatcher
    /// falling back to running `layout_and_render` into a throwaway
    /// DrawList — correct but expensive. Components that appear as
    /// flex/grid children should implement this directly.
    measure_block: ?*const fn (
        ctx: *anyopaque,
        lc: *LayoutCtx,
        constraints: Constraints,
    ) anyerror!BlockMetrics = null,
    /// Optional. Called by the cache-aware layout dispatcher
    /// (`layoutAndRenderCached`) after each walk — on cache hit
    /// (after blit) and on cache miss (after the fresh
    /// `layout_and_render` call). Components that participate in
    /// suggestion-channel-driven layout (`:::box` reading drag
    /// suggestions; future widget cousins) implement this to record
    /// their resolved size into `LayoutCtx.layout_context.last_sizes`
    /// so drag handlers can read their dimensions even when they
    /// were cache-hit and therefore didn't re-add themselves to the
    /// solver this frame. The reported `box` is in world coordinates.
    on_layout_complete: ?*const fn (
        ctx: *anyopaque,
        box: Box,
        lc: *LayoutCtx,
    ) void = null,
    /// Pass-graph snapshot hook for effect components. Returns the
    /// number of bytes written into `out`; `out` is sized at the
    /// caller end against `MAX_PASS_UNIFORM_BYTES`. `null` for
    /// content-only components — and MUST be null when the owning
    /// element's `pass_kind == 0` (asserted by the layout walker
    /// at every custom-element dispatch). Effect factories that
    /// declare `pass_shape != .content` MUST implement this and
    /// return their std140-padded uniform bytes.
    snapshot_uniforms: ?*const fn (ctx: *anyopaque, out: []u8) usize = null,
    /// Corner radius for this instance's composite, in pixels.
    ///
    /// The walker stamps the answer onto the emitted `PassDispatch` and
    /// the record path writes it into the fixed head, so a shader gets it
    /// without the effect's own uniform block having to carry it and
    /// without every effect having to agree on where it sits. Null and
    /// zero both mean square corners.
    ///
    /// A per-instance hook rather than a factory constant, because a
    /// document says `radius=` and two `:::gbuffer` panels in one
    /// document may reasonably disagree.
    corner_radius: ?*const fn (ctx: *anyopaque) f32 = null,
    /// Per-instance host-slot callback override (Effects-spec B.7).
    /// When non-null, the layout walker uses the returned `(callback,
    /// user_data)` pair in place of the Factory.pass_shape.host_slot
    /// defaults. Lets Phase D matryoshka register ONE `:::3d-scene`
    /// factory whose instances each carry a different scene id —
    /// `:::3d-scene scene_id=hud` and `:::3d-scene scene_id=settings`
    /// resolve to different `user_data` pointers via this hook.
    /// Mirrors `snapshot_uniforms`'s per-instance-data-onto-PassDispatch
    /// pattern. The stub `:::placeholder_scene` factory leaves this
    /// null and rides on its factory-level callback.
    invoke_host_slot: ?*const fn (ctx: *anyopaque) HostSlotInvocation = null,
    /// Per-instance chain snapshot hook (Effects-spec C.1). Mandatory
    /// for factories with `pass_shape == .chain` — walker errors with
    /// `error.ChainElementMissingSnapshotHook` if null on a
    /// `pass_kind == 3` element. Returns the component-owned slice of
    /// active steps + chain-level metadata; walker captures by slice
    /// (no copy). Component MUST NOT mutate the backing storage until
    /// the next walk — same single-writer-per-frame invariant as
    /// DrawList / pass_dispatches. The component is responsible for
    /// allocating scratch in `create()` (sized to its factory's
    /// `max_steps`), honoring its own scratch limit, and producing
    /// `target_format` from the factory's `hdr_target` it captured at
    /// create-time. Walker enforces the universal `MAX_CHAIN_STEPS` /
    /// `MAX_CHAIN_POOL_TARGETS` ceilings; factory-specific bounds are
    /// the component's internal concern.
    snapshot_chain_steps: ?*const fn (
        ctx: *anyopaque,
        target_size: [2]u32,
    ) ChainHookResult = null,
    /// Optional, chain elements only. Answers `PassSource` BEFORE layout
    /// runs, which is why it cannot ride on `snapshot_chain_steps`: that
    /// hook needs the element's box, so it is called after
    /// `layout_and_render`, and by then the walker has already decided
    /// whether to route the children's drawlist primitives into pool[0].
    /// That decision is the whole difference between a backdrop and a
    /// filter. `null` means `.subtree`.
    pass_source: ?*const fn (ctx: *anyopaque) PassSource = null,
    /// Optional. Which host surface a `.host_named` pass samples — read
    /// beside `pass_source` and for the same reason, so the walker can
    /// put both on the dispatch step in one place. `null` (or an empty
    /// answer) on a `.host_named` element is a document asking for a
    /// surface it never named, and the composite is skipped.
    host_surface: ?*const fn (ctx: *anyopaque) HostSurface = null,
    /// Optional. Reports how this component participates in its
    /// parent stack's flow (stage 15 Phase E text exclusion). `null`
    /// (the default) means `.normal` — the component flows in
    /// document order, advancing the stack cursor by its height.
    /// Returning `.float_left` / `.float_right` opts the component
    /// into the float positioning path: stack_v places the child at
    /// the appropriate edge without advancing y, and the component is
    /// expected to register a rect exclusion via
    /// `LayoutContext.registerExclusion` during its
    /// `on_layout_complete` hook so following text wraps around it.
    flow_kind: ?*const fn (ctx: *anyopaque) FlowKind = null,
    /// Cost hint for the stage-14b parallel cache-miss dispatcher.
    /// `false` (default) means a miss on this component is
    /// "expensive enough to dispatch" — a paragraph's HarfBuzz
    /// shaping, a freshly-uploaded LLM-stream re-parse, etc. `true`
    /// marks the miss as a cheap O(N) memcpy that doesn't justify
    /// the dispatch overhead — `:::chart` re-emitting its column
    /// quads on every 60 Hz append, `:::svg-stream` re-walking its
    /// already-tessellated mesh, etc. Cheap walks still dispatch in
    /// parallel **when** the threshold is met by expensive siblings,
    /// but on chart-only-dirty frames the dispatcher stays serial
    /// (no `Counter.wait` cost for work that finishes in
    /// microseconds anyway).
    parallel_layout_cheap: bool = false,
};

/// One input event delivered to a component's `on_input`. Stage 13c
/// added keyboard + focus channels for the `:::input` field; mouse
/// channels stayed as-is. `local` (on MouseEvent) is the mouse
/// position **relative to the component's laid-out top-left** (so a
/// slider doesn't need to recompute its origin to figure out where
/// the thumb dropped).
pub const InputEvent = union(enum) {
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_move: MouseEvent,
    /// Unicode codepoint typed (post-IME). Fires from GLFW's char
    /// callback — represents a printable character intent. Carries
    /// only the codepoint; non-printable keys (arrows, backspace,
    /// enter) come through `key_down` instead.
    char_input: u32,
    /// Non-printable key press. `key` is a raw GLFW keycode; `mods`
    /// is the GLFW modifier mask (`GLFW_MOD_SHIFT` etc — see
    /// `win.c.GLFW_MOD_*`).
    key_down: KeyEvent,
    /// Component gained keyboard focus. Sent by the dispatcher
    /// **before** any subsequent `key_down` / `char_input`.
    focus_gained: void,
    /// Component lost keyboard focus (click landed elsewhere, Esc,
    /// or destruction). Components should commit pending state on
    /// receipt — they won't see further keys until refocused.
    focus_lost: void,
};

pub const MouseEvent = struct {
    local: [2]f32,
    /// 0 = primary (left), 1 = secondary (right), 2 = middle.
    button: u8,
    /// True while the corresponding button is held. Lets `mouse_move`
    /// double as a "drag" channel without a separate event kind.
    button_down: bool,
};

pub const KeyEvent = struct {
    /// Raw GLFW key code (`GLFW_KEY_*`).
    key: i32,
    /// GLFW modifier bitmask (`GLFW_MOD_SHIFT | GLFW_MOD_CONTROL …`).
    mods: u32,
};

/// One hit-test layer entry — the laid-out box of an interactive
/// element. Appended to `DrawList.hits` during `layoutAndRender` only
/// when the element exposes a non-null `on_input`. The dispatcher
/// walks `hits` in **reverse** so the deepest-laid element wins
/// (analogous to the layout walker's natural depth-first emit
/// order).
pub const Hit = struct {
    box: Box,
    vtable: *const ElementVTable,
    ctx: *anyopaque,
    /// State pointer to deliver to `on_input` (stage-9 follow-up).
    /// Top-level elements get the host's state; elements inside an
    /// `:::embedded-document` get that doc's child state. Walker
    /// copies `LayoutCtx.state` into here when emitting the Hit.
    /// `null` means "use the dispatcher's default" — preserves the
    /// pre-input-scoping behaviour for callers that haven't wired
    /// LayoutCtx.state yet.
    state: ?*anyopaque = null,
    /// True if a click on this hit should grab keyboard focus.
    /// Default false — only components that want char/key events
    /// (`:::input`) opt in. Focus-grab clears any previous focus
    /// holder (which gets a `.focus_lost`); subsequent key + char
    /// events route here until focus moves again.
    focusable: bool = false,
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
    /// Where a block child sits inside the width its parent gave it.
    ///
    /// Inherited: a container passes its constraints down untouched, so
    /// setting this once on a panel's wrapper reaches everything under
    /// it. `.start` is what every document did before this existed, and
    /// the aligning path is skipped entirely at `.start` — so nothing
    /// written before today pays a measure pass for a feature it does
    /// not use.
    block_align: Align = .start,
    /// Where a LINE of text sits inside its line box.
    ///
    /// Separate from `block_align` on purpose, and the reason is visible
    /// in `measureBlock`: a paragraph's intrinsic width IS the width it
    /// was offered, so centring it as a block moves it by zero. Prose
    /// centres by moving its lines, which is a different operation at a
    /// different level, and wanting one without the other is the normal
    /// case — centred controls over left-aligned prose is what most tool
    /// panels want.
    text_align: Align = .start,
};

/// Horizontal placement, for a block inside its container and for a line
/// of text inside its line box.
///
/// One enum for both because the arithmetic is identical — a fraction of
/// the leftover space goes in front — and because an author who has
/// learnt `center` for one should not have to learn a second word for
/// the other.
pub const Align = enum(u8) {
    start,
    center,
    end,

    /// `left`/`right` are accepted as synonyms. They are what somebody
    /// reaches for first, and refusing them to be pure about writing
    /// direction would be pedantry in a document language whose text
    /// engine is left-to-right anyway.
    pub fn parse(word: []const u8) ?Align {
        if (std.mem.eql(u8, word, "left")) return .start;
        if (std.mem.eql(u8, word, "right")) return .end;
        if (std.mem.eql(u8, word, "centre")) return .center;
        return std.meta.stringToEnum(Align, word);
    }

    /// The fraction of the leftover space that goes BEFORE the content.
    pub fn leading(self: Align) f32 {
        return switch (self) {
            .start => 0,
            .center => 0.5,
            .end => 1,
        };
    }

    /// Where content of width `content` starts inside `avail`.
    ///
    /// Clamped at zero: content wider than the space it was given starts
    /// at the left edge and overflows to the right, which is what every
    /// other overflow in this engine does. Centring it would push its
    /// beginning off the left edge, where it cannot be read.
    pub fn offset(self: Align, avail: f32, content: f32) f32 {
        if (self == .start) return 0;
        return @max(0, (avail - content) * self.leading());
    }
};

/// The `align=` / `text_align=` pair, as a container reads them off its
/// own attributes.
///
/// **Null means inherit**, which is what makes these cascade: a
/// container that says nothing passes its parent's answer straight
/// through, so `align=center` on a panel's wrapper reaches every block
/// under it without being repeated. Only a container that names one
/// overrides it, and only for its own subtree.
///
/// Shared rather than reimplemented per factory because five of them
/// take these attributes, and five copies of "which word maps to which
/// enum" is five chances for `:::box {align=center}` and
/// `:::flex {align=center}` to mean different things.
pub const AlignAttrs = struct {
    block: ?Align = null,
    text: ?Align = null,

    /// Consume one attribute. Returns true when it was one of ours, so a
    /// factory's attribute loop can chain this in front of its own arms.
    pub fn ingest(self: *AlignAttrs, key: []const u8, value: []const u8) bool {
        if (std.mem.eql(u8, key, "align")) {
            // An unparseable value leaves the field alone rather than
            // resetting it to `.start`: `align=centre_ish` is a typo,
            // and inheriting is a better answer to a typo than silently
            // overriding a parent that got it right.
            if (Align.parse(value)) |a| self.block = a;
            return true;
        }
        if (std.mem.eql(u8, key, "text_align")) {
            if (Align.parse(value)) |a| self.text = a;
            return true;
        }
        return false;
    }

    /// Read both attributes off a Spec.
    ///
    /// `anytype` so `element.zig` stays free of a `markdown_components`
    /// import — it is the layout contract, and the directive parser sits
    /// above it. Every caller passes a `*const components.Spec`.
    ///
    /// Read FRESH each time rather than layered onto what the instance
    /// already held, so deleting `align=` from a document and saving it
    /// goes back to inheriting. A hot reload that could add an attribute
    /// and not remove one would be a strange thing to live with.
    pub fn readFrom(spec: anytype) AlignAttrs {
        var self = AlignAttrs{};
        for (spec.attrs) |a| _ = self.ingest(a.key, a.value);
        return self;
    }

    /// This container's constraints for its children.
    pub fn apply(self: AlignAttrs, base: Constraints) Constraints {
        var out = base;
        if (self.block) |a| out.block_align = a;
        if (self.text) |a| out.text_align = a;
        return out;
    }
};

/// The inset between a container's edge and its children.
///
/// Every panel in matryoshka's `hud/` is a frosted wrapper around a
/// stack of controls, and until 2026-09-01 the vocabulary had no way to
/// say "not flush against the edge" — so a trailing row of buttons sat
/// on the panel's bottom rim. Chris: "our panels need a way to express
/// padding or something - notice how vertically the buttons at the
/// bottom are super close to the bottom edge."
///
/// Read by the effect wrappers, which are what a panel is made of.
/// `drop_shadow` composes it with its own spread inflation rather than
/// replacing it: the spread is about the shadow, the padding is about
/// the content, and a panel usually wants both.
pub const PadAttrs = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn any(self: PadAttrs) bool {
        return self.top != 0 or self.right != 0 or self.bottom != 0 or self.left != 0;
    }

    /// `padding=12`, `padding="12 20"` (vertical horizontal), or
    /// `padding="4 8 12 16"` (top right bottom left) — the CSS ordering,
    /// because it is the one an author already has in their fingers. A
    /// value with spaces has to be quoted, same as `label=`.
    pub fn parse(value: []const u8) ?PadAttrs {
        var n: [4]f32 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, value, " \t");
        while (it.next()) |tok| {
            if (count == 4) return null; // more than four is a typo, not a shorthand
            n[count] = std.fmt.parseFloat(f32, tok) catch return null;
            if (!std.math.isFinite(n[count]) or n[count] < 0) return null;
            count += 1;
        }
        return switch (count) {
            1 => .{ .top = n[0], .right = n[0], .bottom = n[0], .left = n[0] },
            2 => .{ .top = n[0], .right = n[1], .bottom = n[0], .left = n[1] },
            4 => .{ .top = n[0], .right = n[1], .bottom = n[2], .left = n[3] },
            // Three is CSS's `top / horizontal / bottom`, which nobody
            // remembers correctly. Refusing it is kinder than guessing.
            else => null,
        };
    }

    /// `anytype` for the same reason `AlignAttrs.readFrom` is — see there.
    pub fn readFrom(spec: anytype) PadAttrs {
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "padding")) {
                if (parse(a.value)) |p| return p;
            }
        }
        return .{};
    }

    /// The children's constraints: this much narrower and shorter.
    pub fn shrink(self: PadAttrs, base: Constraints) Constraints {
        var out = base;
        if (std.math.isFinite(out.max_w)) {
            out.max_w = @max(0, out.max_w - self.left - self.right);
        }
        if (std.math.isFinite(out.max_h)) {
            out.max_h = @max(0, out.max_h - self.top - self.bottom);
        }
        return out;
    }

    /// Where the children start.
    pub fn inset(self: PadAttrs, origin: [2]f32) [2]f32 {
        return .{ origin[0] + self.left, origin[1] + self.top };
    }

    /// The container's own box, given what the children laid out to.
    /// `origin` is the CONTAINER's, not the children's.
    pub fn grow(self: PadAttrs, child: Box, origin: [2]f32) Box {
        return .{
            .x = origin[0],
            .y = origin[1],
            .w = child.w + self.left + self.right,
            .h = child.h + self.top + self.bottom,
            // Baselines are absolute y, so the child's still points at
            // the right line after the inset moved it.
            .baseline = child.baseline,
        };
    }
};

// ── Pass-graph types (effects-spec Phase A.0 / A.6) ────────────────
//
// These live in element.zig rather than spark.zig (where the A.0 stub
// originally lived) because they're layout-walker output — conceptual
// siblings to `Hit` and `DrawList`. Moving them here lets `LayoutCtx`
// hold a `*std.ArrayList(PassDispatch)` without creating an
// element.zig ↔ spark.zig import cycle. `spark.zig` still owns the
// per-frame `pass_dispatches` list as a sibling field on Spark; it
// imports the types from here.

/// Wire-format region for a pass dispatch. i32 fields (not f32) so
/// the determinism hash has no float-equality questions — the
/// pass-graph compiler quantises layout regions to physical pixels
/// before recording a dispatch.
pub const PassRegion = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Inline uniform-bytes cap on `PassDispatch`. v1 fits every Phase A
/// canary (gradient 48, pattern 16, noise 16) and every effect since
/// with room to spare — the widest is the drop shadow's Gaussian
/// block at 64, and the budget is this cap less
/// `PASS_UNIFORM_OFFSET`, which the blur blocks assert against in
/// `components/effects/gaussian.zig`.
///
/// **Sizing rationale.** 256 matches Vulkan's common push-constant
/// range on desktop GPUs (the spec's guaranteed minimum is 128, but
/// 256 is universal on Intel UHD / AMD / NVIDIA desktop and on most
/// modern mobile). A.6.b will likely route pattern-pass uniforms
/// through `vkCmdPushConstants` rather than per-frame uniform
/// buffers — fixed cap here lines up with that path.
///
/// **No-ownership invariant.** Inline storage eliminates the
/// lifetime question (no arena, no refcount, no per-frame
/// allocator). If a future factory's uniforms exceed 256 bytes,
/// **bump this constant first** — the no-ownership invariant is
/// load-bearing and worth keeping. Only when bumping the constant
/// would push PassDispatch past Vulkan's maxPushConstantsSize on a
/// real target GPU should heap ownership enter the design.
pub const MAX_PASS_UNIFORM_BYTES: u32 = 256;

/// Where an effect's own push constants start, and therefore where every
/// `*_uniform_bytes` slice in this file is pushed to.
///
/// The head is two blocks, both written by the record path rather than by
/// the component:
///
///   * `[0, 16)` — the display transform's per-frame push
///     (`display_mod.Push`, two floats, padded to a vec4 boundary).
///   * `[16, 32)` — `CornerPush`: the composite region's pixel size and
///     its corner radius.
///
/// Both live at FIXED offsets rather than at the tail of each effect's own
/// block — which is where the four content pipelines put the display —
/// because those pipelines build their whole push at record time, and an
/// effect's does not exist until a component has snapshotted it. One fixed
/// head lets a single record path write both for every effect without
/// knowing the size or shape of what follows.
///
/// Every effect fragment shader declares the head; the Zig `Uniforms` struct
/// each one mirrors describes the bytes from `PASS_UNIFORM_OFFSET` onward,
/// so its `@offsetOf` lock-in tests are unchanged and relative to itself.
pub const PASS_UNIFORM_OFFSET: u32 = 32;

/// The composite's geometry, at a fixed head offset for every effect.
///
/// **Why the radius is here rather than in each effect's own uniforms.**
/// A rounded corner is a property of the COMPOSITE — the shape the
/// finished pass is poured into — and not of what any particular filter
/// computes. Before this, `:::box` could round in pixels,
/// `:::liquid_glass` could round in normalised units under the same
/// attribute name, and `:::frosted_glass` / `:::drop_shadow` /
/// `:::gbuffer` were hard rectangles with no way to ask. One head field
/// and a shared `corner.glsl` makes `radius=` mean one thing everywhere.
///
/// **Why the size travels with it.** Coverage has to be computed in
/// PIXELS. `liquid_glass.frag` computed its SDF in normalised UV against
/// a half-extent of `vec2(0.5)`, which makes the corner an ELLIPSE on any
/// panel that is not square and makes the antialiasing band a different
/// number of pixels on each axis — 1.6px across and 1.05px down on a
/// 320x210 panel. A shader that knows its region in pixels can do what
/// `quad.frag` has always done, and derive the band from the screen-space
/// gradient instead of from a guess.
pub const CornerPush = extern struct {
    /// The composite region in physical pixels.
    size_px: [2]f32 = .{ 0, 0 },
    /// Corner radius in pixels. Zero means square, and the shaders take
    /// an early-out on it, so the common case costs nothing.
    radius_px: f32 = 0,
    _pad: f32 = 0,
};

/// Pattern-pass dispatch step — fragment shader drawn directly into
/// the main color attachment at `layout_region`, no offscreen target,
/// no descriptor sets. Effects-spec Phase A.6.a was the original
/// `PassDispatch` shape; at B.2/B.3 it became one arm of the tagged
/// union below as `SingleSourceStep` joined.
pub const PatternStep = struct {
    /// Opaque 16-byte shader identifier per the A.0 wire format.
    /// Type-locked to `component.ShaderId` at the type-system level;
    /// stored here as a raw byte array to avoid an element.zig →
    /// component.zig import cycle.
    shader_id: [16]u8,
    layout_region: PassRegion,
    uniform_bytes: [MAX_PASS_UNIFORM_BYTES]u8 = [_]u8{0} ** MAX_PASS_UNIFORM_BYTES,
    uniform_len: u32 = 0,
    /// Corner radius in pixels for the composite. See `CornerPush`.
    corner_radius: f32 = 0,
    sequence_index: u32,
};

/// Single-source dispatch step — child subtree renders into an
/// offscreen target sized to the effect's compose region, then a
/// filter shader samples that target and composites the result back
/// into the main color attachment at `compose_region`. Effects-spec
/// Phase B.2/B.3 — the tagged-union extension of `PassDispatch`.
///
/// **Subtree capture via dispatch-range.** Walker captures
/// `pass_dispatches.items.len` immediately before and after the
/// effect's `layout_and_render` call. Any pass dispatches the child
/// subtree emits (e.g., a `:::gradient` inside a `:::drop_shadow`)
/// fall naturally inside this range — the index pair documents the
/// containment without needing recursive data structures.
///
/// **Drawlist routing TBD at B.4.** Subtree drawlist items (glyphs,
/// quads, tris) need to render into the offscreen target rather
/// than the main attachment. The routing mechanism (per-item
/// target tag vs per-target drawlist) lands with the GPU consumer
/// that actually executes multi-render-pass dispatches. B.2/B.3
/// emits the dispatch range; B.4 wires the drawlist side.
pub const SingleSourceStep = struct {
    /// Offscreen target dimensions in physical pixels. Equal to
    /// `compose_region.{w, h}` for v1 (1:1 sampling); Phase C may
    /// introduce target-vs-region scaling for multi-resolution
    /// chain passes.
    target_size: [2]u32,
    /// Filter shader (e.g. drop-shadow blur+offset). Same opaque
    /// 16-byte identifier shape as `PatternStep.shader_id`.
    filter_shader_id: [16]u8,
    filter_uniforms: [MAX_PASS_UNIFORM_BYTES]u8 = [_]u8{0} ** MAX_PASS_UNIFORM_BYTES,
    filter_uniforms_len: u32 = 0,
    /// See `PassSource`. A `.backdrop` single_source fills its offscreen
    /// target by COPYING the attachment region the element covers instead of
    /// rendering the children into it — so `:::liquid_glass` refracts the
    /// scene behind the panel rather than its own content, which is the
    /// "see-through" look its header said needed a second sampler. It does
    /// not: the backdrop IS what the one sampler holds.
    source: PassSource = .subtree,
    /// Which host-owned image a `.host_named` pass samples. Empty for
    /// every other source — the field is inert unless `source` says
    /// otherwise, and hashing it always keeps the fingerprint honest
    /// about a document that changed only the surface name.
    host_surface: HostSurface = .{},
    /// Where the composed filter output lands on the main color
    /// attachment.
    compose_region: PassRegion,
    /// Half-open `[start, end)` range into `pass_dispatches.items`
    /// covering this effect's subtree. Nested single-source
    /// dispatches fall inside; the GPU consumer recurses by
    /// processing the subtree before the compose step.
    subtree_dispatch_range: [2]u32,
    /// Corner radius in pixels for the composite. See `CornerPush`.
    corner_radius: f32 = 0,
    sequence_index: u32,
};

/// One record of work the pass-graph compiler emits per layout walk.
/// Tagged union: `.pattern` for direct fragment-shader-into-region
/// effects (Phase A); `.single_source` for render-child-into-target-
/// then-filter effects (Phase B). Hashed via per-arm dispatch by the
/// A.0 determinism protocol — see the protocol comment in
/// `src/tests/integration_render.zig`'s `hashFrame`.
///
/// **Wire format v2** (Phase B.3): the arm tag byte (0 = pattern,
/// 1 = single_source) is hashed first, then arm-specific fields in
/// canonical order. Adding a new arm (`.chain` in Phase C,
/// `.host_slot` in Phase B with `:::placeholder_scene`) extends the
/// switch — protocol grows additively.
///
/// **Inline uniform storage.** `uniform_bytes` / `filter_uniforms`
/// are fixed-cap inline arrays rather than borrowed slices — no
/// arena coordination, no lifetime ambiguity. Wire format walks
/// only the first `*_len` bytes; trailing zero padding is not
/// hashed.
/// Contract for the host-side callback `HostSlotPass` invokes during
/// Phase 1 (offscreen render). Spark binds the cmd buffer and
/// transitions `target_image` to `COLOR_ATTACHMENT_OPTIMAL` BEFORE
/// the call; the host opens whatever `vkCmdBeginRendering` scope its
/// own renderer needs (one color attachment, MRT, depth — spark
/// doesn't care), draws, closes the scope, and returns with the
/// target still in `COLOR_ATTACHMENT_OPTIMAL`. Spark then transitions
/// to `SHADER_READ_ONLY_OPTIMAL` for the Phase 2 compose sample.
///
/// **Typing.** `cmd` / `target_image` / `target_view` are
/// `*anyopaque` to keep vulkan-zig out of spark's public surface.
/// Matryoshka casts on its side (it imports vulkan-zig regardless).
/// `target_format` is the raw `VkFormat` value as `u32` — same
/// rationale: hosts cast through their own vulkan-zig binding.
///
/// **Forward-compat.** `target_format` is forwarded even though the
/// B.7 stub doesn't inspect it. Phase D's `:::3d-scene` will need
/// it to configure renderer pipeline state (RGBA8 vs RGBA16F vs
/// BGRA8). Adding it later would be an API break; free now.
///
/// **Error model.** Callback returns `void`. A failed host render
/// shouldn't tank spark's frame; hosts handle errors internally
/// (clear to an error color, log, return). Mirrors matryoshka's
/// "render a degraded frame, log, keep going" policy.
///
/// **Type placement.** Lives in `element.zig` (walker/dispatch
/// output sibling to `Hit` / `PassDispatch`) rather than
/// `component.zig` because the function-pointer type
/// `HostSlotInvocation.callback` references it, and element.zig
/// can't import component.zig without re-igniting the element↔component
/// cycle the A.6.a refactor dodged. `component.zig` re-exports
/// the symbol so factory code reads `component.HostSlotCtx` as
/// before.
pub const HostSlotCtx = extern struct {
    cmd: *anyopaque,
    target_image: *anyopaque,
    target_view: *anyopaque,
    width: u32,
    height: u32,
    target_format: u32,
};

/// Resolved (callback, user_data) pair the layout walker records onto
/// a `HostSlotStep`. Either from `ElementVTable.invoke_host_slot`
/// (per-instance — Phase D's path) or from
/// `Factory.pass_shape.host_slot.{callback, user_data}`
/// (per-factory — the B.7 stub's path). Walker contract: emits
/// `error.UnresolvedHostSlot` if neither side provides a callback;
/// `HostSlotStep.invocation.callback` is therefore non-null at
/// dispatch time by construction. Dispatch sites belt-and-suspender
/// with `std.debug.assert(@intFromPtr(invocation.callback) != 0)`.
pub const HostSlotInvocation = struct {
    callback: *const fn (user_data: *anyopaque, ctx: HostSlotCtx) void,
    user_data: *anyopaque,
};

/// Host-slot dispatch step (Effects-spec B.7). Phase 1 acquires an
/// offscreen target sized `target_size`, transitions it to
/// `COLOR_ATTACHMENT_OPTIMAL`, and invokes `invocation.callback` —
/// the host opens its own render-pass scope, draws, closes the
/// scope. Phase 2 samples that target with `composite_shader_id`
/// (combined-image-sampler + fullscreen triangle, same pipeline
/// shape as `SingleSourceStep`) and writes to MAIN at
/// `compose_region`. Mirrors `SingleSourceStep` minus the child
/// subtree (host owns the rendering wholesale, no spark walker
/// recursion below this dispatch).
///
/// **Wire format / hashing.** `target_size`, `composite_shader_id`,
/// `compose_region`, `sequence_index` participate in the
/// determinism fingerprint. `invocation` does NOT — function
/// pointers aren't stable across builds/processes and would defeat
/// hash determinism. Same exclusion category as `PatternStep`'s
/// trailing zero padding (memory-resident but not wire-format).
pub const HostSlotStep = struct {
    target_size: [2]u32,
    composite_shader_id: [16]u8,
    compose_region: PassRegion,
    /// Resolved at walker time. NOT hashed. Non-null callback by
    /// walker contract — see `HostSlotInvocation`.
    invocation: HostSlotInvocation,
    /// Corner radius in pixels for the composite. See `CornerPush`.
    corner_radius: f32 = 0,
    sequence_index: u32,
};

/// Universal ceilings on chain-pass topology (Effects-spec C.1).
/// Walker fail-fasts beyond these — defense-in-depth against a
/// component hook returning a runaway step count or pool size.
///
/// Sizing rationale: 4K dual-filter bloom tops at ~10 mips with 25%
/// headroom landing at 13; rounded to 16 for power-of-two ergonomics
/// and symmetry across both axes. Tone_map is single-step; bloom
/// covers the upper end. If a Phase D+ consumer trips these, bump
/// independently — they're not coupled.
pub const MAX_CHAIN_STEPS: u32 = 16;
pub const MAX_CHAIN_POOL_TARGETS: u32 = 16;

/// What a chain step does to its destination before it draws.
///
/// A chain is two kinds of operation wearing the same shape. A FILTER owns
/// its target — blur, downsample, tone-map — and the previous contents are
/// noise, so it clears. A COMPOSITE lays one pool target over another and
/// the previous contents are the whole point, so it keeps them and lets the
/// pipeline's premultiplied-over blend do the work.
///
/// One enum rather than a `loadOp` plus a blend mode, because the two always
/// move together: nothing wants to clear and then blend over the clear, and
/// nothing wants to keep and then overwrite. `:::drop_shadow` needs exactly
/// one of each — two blur steps that clear, and a third that keeps, laying
/// the child back over the shadow it cast.
/// Where a chain's `pool[0]` — its source image — comes from.
///
/// `.subtree` is the original and the default: the walker renders the
/// element's children into pool[0], and the chain filters what it wraps.
/// That is `:::drop_shadow` and `:::frosted_glass` blurring their own
/// content.
///
/// `.backdrop` fills pool[0] by COPYING the region of the host's
/// attachment that the element covers — what is already on screen behind
/// the panel — and the children are not rendered into it at all. They draw
/// to MAIN afterwards, sharp, on top of the composited result. That is the
/// macOS/iOS frosted panel: the scene behind is blurred, the text over it
/// is not.
///
/// The layering needs no new machinery. Phase 2 records every pass
/// composite BEFORE any MAIN drawlist primitive — which is exactly why
/// `.pattern` is "always-background of the parent region" (Decision #12) —
/// so a chain that stops routing its children into pool[0] gets them drawn
/// over its own output for free.
///
/// **What a backdrop can and cannot see.** Phase 1 runs before the host
/// opens its rendering scope, so the copy captures whatever the host drew
/// before calling spark: the ray-traced scene, in matryoshka's case. It
/// cannot see other spark content from this frame, because none of it has
/// been drawn yet. A backdrop panel blurs the scene; it does not blur
/// another panel.
/// `.host_named` is the same idea reaching one step further out: the
/// source is an image the HOST owns and answers for by name — a
/// G-buffer surface, a depth pyramid, a shadow atlas — and the panel
/// becomes a window onto it, showing the part of that surface its own
/// box covers. Children draw over it exactly as they draw over a
/// backdrop, so a `:::gbuffer` panel gets its buttons for free.
///
/// **It is not a copy, and that is the whole difference.** A backdrop
/// blits, because a swapchain being used as an attachment cannot also
/// be sampled. A host surface has no such problem, so `.host_named`
/// BINDS the host's view as the filter's sampler and never allocates a
/// target at all. That is not merely cheaper — it is what makes the
/// effect possible: a blit converts formats without remapping values,
/// and every one of these surfaces needs remapping to be looked at
/// (a normal is signed, a depth is non-linear, a motion vector has a
/// direction). Remapping is a shader's job, so the pixels have to
/// arrive through a sampler.
///
/// The panel then has to say WHICH part of a full-screen surface it is
/// looking at, since it no longer owns a target cut to its own size.
/// That is `SingleSourceStep.host_surface` plus the window transform
/// spark writes into the filter's uniforms at record time — see
/// `HOST_WINDOW_BYTES`.
pub const PassSource = enum(u8) {
    subtree,
    backdrop,
    host_named,

    /// Does this source make the effect a BACKGROUND to its own
    /// children rather than a filter over them?
    ///
    /// True for everything that does not draw its subtree into its own
    /// target. Those elements' children stay on MAIN and must be drawn
    /// over the composite, which has three consequences Phase 2 reads
    /// off this one answer: the subtree is not marked nested, the
    /// composite runs in the pre-pass (the walker emits post-order, so
    /// composing in the main loop would lay the panel over the very
    /// content it belongs behind), and the children then land on top
    /// with no extra machinery.
    ///
    /// Named rather than written out as `!= .subtree` at each site
    /// because the three sites have to agree: a source that is a
    /// background in one of them and not in another produces a panel
    /// drawn over its own buttons, or one composited twice.
    pub fn isBackground(self: PassSource) bool {
        return switch (self) {
            .subtree => false,
            .backdrop, .host_named => true,
        };
    }
};

/// Which host surface a `.host_named` pass samples.
///
/// A fixed-size buffer rather than a slice, for two reasons that both
/// bite. It is copied into a dispatch step that outlives the walk, so
/// a slice into a component's arena would dangle the moment that
/// component re-parsed; and the frame fingerprint hashes dispatch
/// steps BY VALUE, so a pointer would make two identical frames hash
/// differently and the determinism gates would go off.
///
/// The names themselves are the host's vocabulary, not spark's —
/// spark never interprets one, it only carries it back to the
/// resolver the host installed.
pub const HostSurface = struct {
    pub const MAX = 24;
    buf: [MAX]u8 = [_]u8{0} ** MAX,
    len: u8 = 0,

    pub fn from(name: []const u8) HostSurface {
        var self = HostSurface{};
        // Truncates rather than errors: a name too long to carry is a
        // name the resolver will not match, which surfaces as "this
        // host has no surface called that" — the same message a typo
        // gets, at the same place, instead of a parse-time failure in
        // a different file.
        self.len = @intCast(@min(name.len, MAX));
        @memcpy(self.buf[0..self.len], name[0..self.len]);
        return self;
    }

    pub fn slice(self: *const HostSurface) []const u8 {
        return self.buf[0..self.len];
    }
};

/// How many bytes at the head of a `.host_named` filter's uniform
/// block spark OVERWRITES with the window transform.
///
/// Two `vec2`s — scale then offset — mapping the compose quad's own
/// `[0,1]` UV onto the region of the host surface the panel covers.
/// The effect cannot compute these itself: they need the element's
/// laid-out box and the host surface's dimensions, and neither is
/// known when `apply_attrs` runs.
///
/// So the contract is stated rather than negotiated: **a host_named
/// filter's Uniforms must begin with `vec4 window` (scale.xy,
/// offset.xy), and whatever the component writes there is discarded.**
/// `gbuffer.frag` is the worked example.
pub const HOST_WINDOW_BYTES: usize = 16;

pub const ChainLoad = enum(u8) {
    clear,
    keep,
};

/// One step in a chain — sample `source_pool_local`, write to
/// `dest_pool_local`, both indices resolved against the chain's
/// `pool_base` (captured on Spark.chain_pool_bases at Phase 1 acquire
/// time). Inline `uniform_bytes` matches PatternStep / SingleSourceStep
/// — no per-step indirection, fits Vulkan push-constant range.
///
/// **Wire format / hashing** (Effects-spec C.2, v6). Every field
/// participates — chains are walker-emitted, no per-instance pointer
/// state to exclude. See `integration_render.zig` hashFrame protocol.
pub const ChainPassStep = struct {
    composite_shader_id: [16]u8,
    source_pool_local: u16,
    dest_pool_local: u16,
    /// Effects-spec C.2. Defaults to `.clear` — a step that says nothing
    /// owns its target, which is what a filter wants and what every step
    /// written before compositing existed assumed.
    load: ChainLoad = .clear,
    uniform_bytes: [MAX_PASS_UNIFORM_BYTES]u8 = [_]u8{0} ** MAX_PASS_UNIFORM_BYTES,
    uniform_len: u32 = 0,
};

/// Per-walk return of `snapshot_chain_steps`. The component owns the
/// `steps` backing storage (registry allocator, lifetime = instance);
/// walker captures by slice. `target_format` is the raw VkFormat the
/// component chose based on its factory's `hdr_target` (component
/// captured this at create-time and produces the resolved format
/// here). Walker is purely a consumer of this struct — no factory
/// access needed at emission time.
pub const ChainHookResult = struct {
    /// Slice into component-owned scratch. Walker captures by
    /// reference; component MUST NOT mutate backing storage until
    /// next walk (single-writer-per-frame invariant).
    steps: []const ChainPassStep,
    target_format: u32,
    target_pool_count: u16,
    final_pool_local: u16,
    /// Where pool[0] comes from. Defaults to `.subtree`, so a chain
    /// written before backdrops existed keeps its behaviour.
    source: PassSource = .subtree,
};

// Effects-spec C.2 note on what this struct does NOT carry. C.1 drafted a
// `compose_region` here, and it cannot be right: the hook is handed a
// `target_size` and nothing else, so a component would have to remember its
// own layout origin and hope the walker asked in the same order it laid
// out. The compose region is a LAYOUT fact — the element's own box — so the
// walker fills it from the box, exactly as it does for pattern,
// single_source and host_slot, and `layout_cache`'s blit/snapshot rebase
// has one owner to shift instead of two to reconcile. Same reasoning for
// the final composite's push constants: they arrive through the ordinary
// mandatory `snapshot_uniforms` hook that every non-content element already
// implements, rather than through a second channel of their own.

/// Chain-pass dispatch step (Effects-spec C.1). Phase 1 acquires
/// `target_pool_count` ping-pong targets, runs `steps` sequentially
/// (each sampling its `source_pool_local`, writing to its
/// `dest_pool_local`, with image-layout transitions providing the
/// WAR barrier between steps). Phase 2 reads `pool[final_pool_local]`
/// and composites into MAIN at `compose_region` via the factory's
/// `final_composite_shader_id` (mirrors single_source's Phase 2
/// shape exactly). Pool-local indices [0..target_pool_count-1]
/// resolve against the chain's `pool_base` captured on
/// `Spark.chain_pool_bases` at Phase 1 acquire time — no `pool_base`
/// field on ChainStep keeps the dispatch struct structurally
/// immutable (Phase-1-transient state lives on Spark via sibling
/// parallel array, same shape as `dispatch_target_map`).
pub const ChainStep = struct {
    /// Format + dims for ALL ping-pong targets in this chain.
    /// Uniform across the chain in v1 — format-mixed chains can land
    /// in a follow-up with per-step format on ChainPassStep.
    target_size: [2]u32,
    target_format: u32, // raw VkFormat — promotion to TargetFormat enum tracked for C.2
    target_pool_count: u16,
    /// See `PassSource`. Hashed by the frame fingerprint like every other
    /// dispatch field, so a document that toggles `backdrop` is a different
    /// frame rather than a silently identical one.
    source: PassSource = .subtree,
    /// Slice into component-owned scratch. Length = active step
    /// count. Walker enforces `len <= MAX_CHAIN_STEPS` at emission.
    steps: []const ChainPassStep,
    /// Phase 2 destination rect on MAIN — same semantics as
    /// SingleSourceStep.compose_region. Walker captures from hook;
    /// layout_cache rebase shifts xy on blit / inverse on snapshot.
    compose_region: PassRegion,
    /// Pool-local index Phase 2 reads from. Typically equals the last
    /// step's `dest_pool_local`; explicit so a hook can short-circuit
    /// (e.g., picking an intermediate cascade for debug output)
    /// without scanning steps[].
    final_pool_local: u16,
    /// Half-open `[start, end)` range into `pass_dispatches.items`
    /// covering this chain's child subtree (Effects-spec C.1.5).
    /// `phase1ProcessChain` renders the subtree into pool[0] BEFORE
    /// walking `steps[]` — child content is the chain's source image,
    /// `steps[]` are the per-step filter/blur/composite passes
    /// processing it through the ping-pong pool. Mirrors
    /// `SingleSourceStep.subtree_dispatch_range` exactly — same
    /// walker-capture semantics (dispatch_start before child walk,
    /// seq before self-append), same rebase logic across
    /// `mergePrivatePassDispatches` / `blitEntry` / `snapshotEntry`.
    /// Empty range `.{ N, N }` is legal — a chain with no content
    /// subtree starts from a transparent pool[0].
    subtree_dispatch_range: [2]u32,
    /// Effects-spec C.2 — the shader Phase 2 composites
    /// `pool[final_pool_local]` into MAIN with, and its push constants.
    /// Carried on the dispatch rather than looked up from the factory for
    /// the same reason `SingleSourceStep.filter_shader_id` is: the record
    /// path is then a pure function of the dispatch, with no registry
    /// access inside a command-buffer walk. The walker copies it from the
    /// element's resolved `shader_id`, which `passShapeScalars` already
    /// maps to `ChainPass.final_composite_shader_id`.
    final_composite_shader_id: [16]u8,
    final_composite_uniforms: [MAX_PASS_UNIFORM_BYTES]u8 = [_]u8{0} ** MAX_PASS_UNIFORM_BYTES,
    final_composite_uniforms_len: u32 = 0,
    /// Corner radius in pixels for the composite. See `CornerPush`.
    corner_radius: f32 = 0,
    sequence_index: u32,
};

pub const PassDispatch = union(enum) {
    pattern: PatternStep,
    single_source: SingleSourceStep,
    host_slot: HostSlotStep,
    chain: ChainStep,
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
    /// Fallback font for codepoints the primary font doesn't cover —
    /// typically a colour-emoji face. Null disables fallback; in that
    /// case codepoints outside the primary's cmap render as `.notdef`
    /// boxes (FT's standard placeholder). When non-null, the markdown
    /// parser scans every text leaf and splits it on coverage
    /// boundaries: codepoints the primary has stay in the primary
    /// run; codepoints only the fallback has spin off into a sibling
    /// text leaf with `font_id = fallback_font_id`. The inline-flow
    /// walker handles the resulting mixed-font runs without any
    /// further special-casing — same baseline-resolution math as for
    /// emphasis/strong cascades.
    fallback_font_id: ?registry_mod.FontId = null,
    /// FontRegistry handle the parser uses for coverage queries. Same
    /// registry the host populated `body.font_id` etc. against — the
    /// parser needs it (not the layout pass) to decide where to split
    /// text leaves at parse time. Null disables splitting (same effect
    /// as null `fallback_font_id`).
    font_registry: ?*registry_mod.FontRegistry = null,

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

    /// Link underline thickness as a fraction of em size. The walker
    /// multiplies by the run's dominant `displayPx` so underlines
    /// auto-scale with font size — a heading-link gets a chunkier
    /// underline than a body link, in proportion. Defaults to 6% of
    /// em, the OpenType convention's middle of the road.
    link_underline_thickness_em: f32 = 0.06,
    /// Underline offset below baseline, also as a fraction of em.
    /// 10% sits comfortably in the descender zone without colliding
    /// with descenders on most Latin fonts.
    link_underline_offset_em: f32 = 0.10,

    /// Strikethrough thickness as a fraction of em. Matches the
    /// underline default — both are decoration lines and read better
    /// when they share weight.
    strikethrough_thickness_em: f32 = 0.06,
    /// Strikethrough offset *above* baseline (positive value), as a
    /// fraction of em. ~26% sits through the middle of x-height for
    /// most Latin fonts.
    strikethrough_offset_em: f32 = 0.26,

    /// Page background colour the inline-flow walker uses for
    /// contrast text under `style.reverse`. Defaults match the
    /// renderer's `clear_color` (`gpu/renderer.zig`) so reverse-mode
    /// glyphs disappear cleanly into the page when no SGR fg was set.
    background: [4]f32 = .{ 0.04, 0.04, 0.07, 1.0 },

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

/// Read-only handle elements use to ask spark for shaping +
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
    /// Optional state pointer for input-event scoping. The walker
    /// stamps this onto every Hit it emits, so `:::slider` inside
    /// an `:::embedded-document` mutates the embedded doc's child
    /// state, not the parent's. Top-level layout sets this to
    /// `&host_state`; the embedded-doc factory swaps it to its
    /// child state before delegating into the child element tree.
    /// `null` keeps the dispatcher on its fallback path.
    state: ?*anyopaque = null,
    /// Optional per-block layout cache (stage 14a). When non-null,
    /// the walker consults it for each cacheable child of a stack_v
    /// container — hits blit cached glyph/quad/tri ranges with an
    /// origin offset; misses walk fresh + snapshot back into the
    /// cache. `null` falls through to the unconditional walk path.
    cache_blocks: ?*layout_cache_mod.BlockCache = null,
    /// Optional JobSystem for parallel cache-miss layouts (stage 14b).
    /// When non-null AND `glyph_cache_lock` is also non-null, the
    /// stack_v walker fans out walks for cache-miss children onto
    /// worker threads. Workers walk at origin (0,0) into private
    /// DrawLists; main thread merges in order, blits + snapshots.
    job_system: ?*jobs_mod.JobSystem = null,
    /// Mutex guarding the (FreeType glyph slot + Atlas packing +
    /// GlyphCache hashmap) write surface. Held during
    /// `GlyphCache.getOrRasterize` calls from worker threads.
    /// `null` = serial mode (no locking). Must be non-null whenever
    /// `job_system` is non-null and the walker may dispatch jobs.
    glyph_cache_lock: ?*std.Thread.Mutex = null,
    /// Effective zoom factor for crisp-zoom rasterisation. The host
    /// writes its current `zoom` (Ctrl+scroll output) here before each
    /// layout pass. Layout runs in world coordinates regardless of
    /// zoom — but text shaping rasterises glyphs at
    /// `style.font_id.display_px × zoom` so the post-layout
    /// world→screen multiply samples bitmaps at 1:1. Defaults to 1.0
    /// for code paths that haven't been wired through yet.
    zoom: f32 = 1.0,
    /// Optional kiwi-backed constraint solver (stage 15, Phase B).
    /// When non-null, constraint-aware components (currently
    /// `:::box`) declare their bounds as solver variables and read
    /// resolved positions from the solver after each pass. When null,
    /// the same components fall back to imperative layout — same
    /// visual output, different mechanism. Migration is incremental:
    /// each new constraint-participating provider opts into this
    /// channel as it lands.
    layout_context: ?*layout_context_mod.LayoutContext = null,
    /// Effects-spec Phase A.6. Per-frame pass-graph dispatch list
    /// (owned by Spark; LayoutCtx borrows the pointer). When
    /// non-null, the walker emits a `PassDispatch` per custom
    /// element whose `pass_kind != 0`, using the element's
    /// resolved box as the region and calling `vtable.snapshot_uniforms`
    /// for the uniform bytes. `null` for code paths that pre-date
    /// the pass-graph compiler (test fixtures, cached-layout
    /// snapshot blits where the dispatch list isn't being
    /// regenerated).
    pass_dispatches: ?*std.ArrayList(PassDispatch) = null,
    /// Effects-spec Phase B.4.a — drawlist routing. The walker
    /// updates this on entering / exiting a `.single_source`
    /// element (save → set to the new dispatch's index → restore).
    /// `DrawList.appendGlyph` / `appendQuad` / `appendTri` /
    /// `appendImage` read it to stamp the parallel `*_targets`
    /// arrays in lockstep with each primitive append.
    ///
    /// `MAIN_TARGET` (= `std.math.maxInt(u32)`) is the sentinel
    /// for the main color attachment. Any other value is an index
    /// into `pass_dispatches` identifying the owning single-source
    /// effect's `SingleSourceStep` — or, DURING the walk of that
    /// effect's subtree only, a provisional tag (see
    /// `provisionalTag`). Nothing outside the walker ever sees one.
    current_target_dispatch_index: u32 = MAIN_TARGET,
    /// Counter behind `provisionalTag`. Bumped once per pass element
    /// that routes its children offscreen; never read for anything
    /// but uniqueness, so workers holding their own copy is fine —
    /// each resolves its tags into its own private DrawList.
    pass_tag_seq: u32 = 0,
};

/// A tag to stamp on drawlist primitives while walking a pass
/// element's subtree, before that element's own dispatch index is
/// known.
///
/// The index is not knowable at push time, and using the next best
/// thing is what broke: the walker pushed `dispatch_start` — the
/// length of the dispatch list BEFORE the subtree walk — while Phase 1
/// routes primitives by the dispatch's own final index. Those two
/// agree only when the subtree emits no dispatch of its own, so every
/// shipping document was fine and a `:::drop_shadow` around a
/// `:::frosted_glass {backdrop}` drew an empty shadowed panel: the
/// glyphs were tagged with the backdrop's index, and a backdrop is the
/// one dispatch shape that renders no drawlist primitives at all.
///
/// `dispatch_start` cannot be made to work by moving the consumer
/// either, because it is not unique: an effect and the first effect
/// nested inside it capture the SAME value. So the walk stamps a
/// provisional tag that is unique among the pass elements currently
/// open, and each element rewrites its own span to its real index on
/// the way out — innermost first, by recursion. What is left carrying
/// the outer tag when the outer element resolves is exactly what
/// belongs to it: its own direct children, plus the children of any
/// nested `{backdrop}`, which deliberately does not claim them.
///
/// Counting DOWN from `MAIN_TARGET` keeps the provisional space and
/// the dispatch-index space disjoint while both are live, so a
/// resolved tag is never mistaken for an unresolved one.
pub fn provisionalTag(n: u32) u32 {
    return MAIN_TARGET - 1 - n;
}

/// Sentinel value for `LayoutCtx.current_target_dispatch_index` and
/// `DrawList.*_targets` entries meaning "main color attachment"
/// (not part of a `.single_source` subtree). Effects-spec Phase
/// B.4.a — the drawlist routing tag.
pub const MAIN_TARGET: u32 = std.math.maxInt(u32);

// ── Per-target run iterators (Phase B.4.b.4) ───────────────────────
//
// Phase B.4.b.4 needs to issue per-target subrange draws against the
// rasterizer pipelines. The DrawList's parallel target arrays
// (`glyph_targets`, `quad_targets`, `tri_targets`, `image_targets`)
// encode which dispatch's target each primitive belongs to. For
// offscreen targets the matching primitives form a single contiguous
// run by walker construction (push target on enter, emit primitives
// tagged with that target, pop on exit). For the MAIN target the run
// may break into multiple chunks separated by single_source subtrees
// (text :::drop_shadow{box} text → [MAIN_run][TARGET_run][MAIN_run]).
//
// The iterators below scan the parallel arrays once and yield each
// `(first, count)` run matching a target. Pure CPU; no Vulkan
// dependency; trivially unit-testable. Consumer loop shape:
//
//   var it = element.runs(dl.glyph_targets.items, target);
//   while (it.next()) |run| {
//       text_pipeline.recordDrawRange(cmd, extent, run.first, run.count);
//   }

/// One run of consecutive primitives with the same target. Units
/// are primitive-instances (glyphs, quads, individual images).
pub const Run = struct { first: u32, count: u32 };

/// Iterator over `(first, count)` runs of primitives matching
/// `match` in `targets`. For glyph/quad/image arrays — each entry
/// in `targets` corresponds to one primitive instance, so the
/// iterator's units are instance-units directly. For triangles
/// see `triRuns` (different shape because target lives in vertex
/// space while draws live in index space).
pub const RunIterator = struct {
    targets: []const u32,
    match: u32,
    cursor: usize,

    pub fn next(self: *RunIterator) ?Run {
        // Skip past entries that don't match the target.
        while (self.cursor < self.targets.len and self.targets[self.cursor] != self.match) {
            self.cursor += 1;
        }
        if (self.cursor >= self.targets.len) return null;
        const first = self.cursor;
        // Accumulate the contiguous match run.
        while (self.cursor < self.targets.len and self.targets[self.cursor] == self.match) {
            self.cursor += 1;
        }
        return .{
            .first = @intCast(first),
            .count = @intCast(self.cursor - first),
        };
    }
};

pub fn runs(targets: []const u32, match: u32) RunIterator {
    return .{ .targets = targets, .match = match, .cursor = 0 };
}

/// One run of consecutive triangles with the same target,
/// expressed as a slice of the index buffer ready to feed
/// `vkCmdDrawIndexed`. `first_index = first_triangle * 3`,
/// `index_count = triangle_count * 3`.
pub const TriRun = struct { first_index: u32, index_count: u32 };

/// Iterator over triangle runs matching `match`. Triangles are
/// the natural primitive unit for tris, but the target tag lives
/// in *vertex* space (one `tri_targets` entry per vertex in `tris`,
/// not per index in `tri_indices`). The walker invariant (an SVG
/// mesh emits all its vertices first with one shared target tag,
/// then its indices referencing only those vertices) means every
/// triangle's three vertices share one target — so looking up
/// `targets[indices[T * 3]]` correctly identifies triangle T's
/// target. The iterator yields each contiguous-by-target triangle
/// run as a `(first_index, index_count)` pair the pipeline can
/// pass directly to `vkCmdDrawIndexed`.
pub const TriRunIterator = struct {
    targets: []const u32, // per-vertex (parallels `tris`)
    indices: []const u32, // index buffer (`tri_indices`)
    match: u32,
    tri_cursor: usize, // triangle index (each triangle = 3 indices)

    pub fn next(self: *TriRunIterator) ?TriRun {
        const total_tris = self.indices.len / 3;
        // Skip triangles whose first vertex doesn't match.
        while (self.tri_cursor < total_tris and
            self.targets[self.indices[self.tri_cursor * 3]] != self.match)
        {
            self.tri_cursor += 1;
        }
        if (self.tri_cursor >= total_tris) return null;
        const first_tri = self.tri_cursor;
        // Accumulate the contiguous matching triangle run.
        while (self.tri_cursor < total_tris and
            self.targets[self.indices[self.tri_cursor * 3]] == self.match)
        {
            self.tri_cursor += 1;
        }
        return .{
            .first_index = @intCast(first_tri * 3),
            .index_count = @intCast((self.tri_cursor - first_tri) * 3),
        };
    }
};

pub fn triRuns(targets: []const u32, indices: []const u32, match: u32) TriRunIterator {
    return .{ .targets = targets, .indices = indices, .match = match, .tri_cursor = 0 };
}

/// GPU draw work accumulated during the walk. Quads land first
/// (backgrounds, bars, rules) then glyphs on top — the host's frame
/// loop records them in that order inside one render pass.
///
/// **Per-primitive routing tags (Phase B.4.a).** Each primitive
/// array (`glyphs`, `quads`, `tris`, `images`) has a parallel
/// `*_targets: ArrayList(u32)` of identical length — element `i`
/// of the targets array names the render pass that owns primitive
/// `i`. `MAIN_TARGET` (= `std.math.maxInt(u32)`) means the main
/// color attachment; any other value is the index into
/// `pass_dispatches` of the owning `.single_source` effect's
/// `SingleSourceStep`. The targets arrays are **CPU-only metadata**
/// — never uploaded to GPU. The consumer (`Spark.endFrame`)
/// iterates each primitive array filtering by the parallel target
/// tag when choosing which render pass each primitive lands in.
///
/// **Lockstep invariant.** `*_targets.items.len ==
/// primitive.items.len` after every emit. Maintained by the emit
/// helpers (`appendGlyph` / `appendQuad` / `appendTri` /
/// `appendImage`) which append to both arrays in one call —
/// callers must use these helpers, never the underlying
/// `glyphs.append` etc. directly. The `assertTargetsInSync`
/// debug-build sanity check catches drift.
///
/// **Why parallel arrays rather than extending the primitive
/// `extern struct`s?** The primitive types are GPU upload formats
/// (read by shaders via std430 SSBOs); extending them would force
/// GLSL stride updates and waste GPU bandwidth on routing metadata
/// the GPU never reads. Routing is a CPU-side render-pass dispatch
/// decision — keeping it sideways preserves the GPU/CPU layer split.
///
/// **Why not Hits or tri_indices?** Hits are input-routing, not
/// draw work — they're processed by the input dispatcher regardless
/// of render pass. tri_indices reference `tris` by index; an index
/// inherits its target from the vertex it references, so a separate
/// `tri_index_targets` array would be redundant.
/// Where a pass element's subtree starts in each of the four target
/// arrays, so the element can find its own primitives again once its
/// dispatch index is known. See `provisionalTag`.
pub const DrawListMark = struct {
    glyphs: usize,
    quads: usize,
    tris: usize,
    images: usize,

    pub fn of(dl: *const DrawList) DrawListMark {
        return .{
            .glyphs = dl.glyph_targets.items.len,
            .quads = dl.quad_targets.items.len,
            .tris = dl.tri_targets.items.len,
            .images = dl.image_targets.items.len,
        };
    }

    /// Rewrite every primitive appended since this mark that still
    /// carries `from` so it carries `to` instead.
    ///
    /// "Still" is the whole mechanism. A nested pass element resolves
    /// its own span before this runs — it returns first — so its
    /// primitives already carry a real dispatch index and are passed
    /// over here. What is left is what the nested element declined to
    /// claim, which is exactly what belongs to this one.
    pub fn retag(self: DrawListMark, dl: *DrawList, from: u32, to: u32) void {
        for (dl.glyph_targets.items[self.glyphs..]) |*t| {
            if (t.* == from) t.* = to;
        }
        for (dl.quad_targets.items[self.quads..]) |*t| {
            if (t.* == from) t.* = to;
        }
        for (dl.tri_targets.items[self.tris..]) |*t| {
            if (t.* == from) t.* = to;
        }
        for (dl.image_targets.items[self.images..]) |*t| {
            if (t.* == from) t.* = to;
        }
    }
};

pub const DrawList = struct {
    glyphs: std.ArrayList(tp.GlyphInstance),
    glyph_targets: std.ArrayList(u32),
    quads: std.ArrayList(qp.QuadInstance),
    quad_targets: std.ArrayList(u32),
    /// Triangle mesh layer (stage 13d.1). Populated by `:::svg`
    /// during layoutAndRender; rendered first (under quads + text)
    /// so background fills sit behind chrome. Indices reference
    /// `tris` vertices; the host's TrianglePipeline copies both
    /// arrays into its VBO/IBO and issues one `vkCmdDrawIndexed`.
    tris: std.ArrayList(tri_pipeline.Vertex),
    tri_targets: std.ArrayList(u32),
    tri_indices: std.ArrayList(u32),
    /// Raster image layer (stage 14c). One entry per `:::image-stream`
    /// component that has a decoded texture ready. Each carries the
    /// pre-allocated descriptor set (owned by the component) and a
    /// world-space rect; the host's ImagePipeline records one draw
    /// per entry, binding the descriptor between draws.
    images: std.ArrayList(ImageDraw),
    image_targets: std.ArrayList(u32),
    /// Hit-test layer. Populated alongside glyphs / quads during the
    /// layout walk; only elements with a non-null `vtable.on_input`
    /// register an entry. Walked in reverse on each mouse event so
    /// the deepest-laid interactive element wins.
    hits: std.ArrayList(Hit),

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{
            .glyphs = std.ArrayList(tp.GlyphInstance).init(allocator),
            .glyph_targets = std.ArrayList(u32).init(allocator),
            .quads = std.ArrayList(qp.QuadInstance).init(allocator),
            .quad_targets = std.ArrayList(u32).init(allocator),
            .tris = std.ArrayList(tri_pipeline.Vertex).init(allocator),
            .tri_targets = std.ArrayList(u32).init(allocator),
            .tri_indices = std.ArrayList(u32).init(allocator),
            .images = std.ArrayList(ImageDraw).init(allocator),
            .image_targets = std.ArrayList(u32).init(allocator),
            .hits = std.ArrayList(Hit).init(allocator),
        };
    }

    pub fn deinit(self: *DrawList) void {
        self.glyphs.deinit();
        self.glyph_targets.deinit();
        self.quads.deinit();
        self.quad_targets.deinit();
        self.tris.deinit();
        self.tri_targets.deinit();
        self.tri_indices.deinit();
        self.images.deinit();
        self.image_targets.deinit();
        self.hits.deinit();
        self.* = undefined;
    }

    /// Drop all accumulated draw work without freeing capacity —
    /// the common case at frame start.
    pub fn clearRetainingCapacity(self: *DrawList) void {
        self.glyphs.clearRetainingCapacity();
        self.glyph_targets.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.quad_targets.clearRetainingCapacity();
        self.tris.clearRetainingCapacity();
        self.tri_targets.clearRetainingCapacity();
        self.tri_indices.clearRetainingCapacity();
        self.images.clearRetainingCapacity();
        self.image_targets.clearRetainingCapacity();
        self.hits.clearRetainingCapacity();
    }

    // ── Emit helpers (Phase B.4.a) ─────────────────────────────────
    // Single source of truth for parallel-array lockstep — every
    // primitive append goes through these so the routing tag lands
    // alongside. The `lc` parameter carries the current dispatch
    // index via `lc.current_target_dispatch_index`, which the walker
    // pushes/pops on entering/exiting a `.single_source` element.

    pub fn appendGlyph(self: *DrawList, lc: *const LayoutCtx, item: tp.GlyphInstance) !void {
        try self.glyphs.append(item);
        try self.glyph_targets.append(lc.current_target_dispatch_index);
    }

    pub fn appendQuad(self: *DrawList, lc: *const LayoutCtx, item: qp.QuadInstance) !void {
        try self.quads.append(item);
        try self.quad_targets.append(lc.current_target_dispatch_index);
    }

    pub fn appendTri(self: *DrawList, lc: *const LayoutCtx, vertex: tri_pipeline.Vertex) !void {
        try self.tris.append(vertex);
        try self.tri_targets.append(lc.current_target_dispatch_index);
    }

    pub fn appendImage(self: *DrawList, lc: *const LayoutCtx, item: ImageDraw) !void {
        try self.images.append(item);
        try self.image_targets.append(lc.current_target_dispatch_index);
    }

    /// Bulk-append from a worker's private DrawList during the
    /// parallel stack_v merge (`element_layout.zig`'s
    /// `mergePrivate`). Preserves worker-side target tags — workers
    /// run with their own LayoutCtx so their tagging stays valid as
    /// long as the dispatch indices are coordinated across workers.
    pub fn appendGlyphsPreservingTargets(
        self: *DrawList,
        items: []const tp.GlyphInstance,
        targets: []const u32,
    ) !void {
        std.debug.assert(items.len == targets.len);
        try self.glyphs.appendSlice(items);
        try self.glyph_targets.appendSlice(targets);
    }

    pub fn appendQuadsPreservingTargets(
        self: *DrawList,
        items: []const qp.QuadInstance,
        targets: []const u32,
    ) !void {
        std.debug.assert(items.len == targets.len);
        try self.quads.appendSlice(items);
        try self.quad_targets.appendSlice(targets);
    }

    pub fn appendTrisPreservingTargets(
        self: *DrawList,
        vertices: []const tri_pipeline.Vertex,
        targets: []const u32,
    ) !void {
        std.debug.assert(vertices.len == targets.len);
        try self.tris.appendSlice(vertices);
        try self.tri_targets.appendSlice(targets);
    }

    pub fn appendImagePreservingTarget(
        self: *DrawList,
        item: ImageDraw,
        target: u32,
    ) !void {
        try self.images.append(item);
        try self.image_targets.append(target);
    }

    /// Bulk-append from cache (`layout_cache.zig`'s `blitEntry`).
    /// Phase B.6 — cache snapshots stored the parallel routing tags
    /// alongside primitives, locally-rebased so the snapshot's own
    /// pass-dispatch range starts at 0 (and `MAIN_TARGET` preserved
    /// as the sentinel). Replay-with-offset here resolves each
    /// cached tag against the live context:
    ///
    ///   * `MAIN_TARGET` → `lc.current_target_dispatch_index`. The
    ///     sentinel means "outer context's active target at render
    ///     time," not "literally the framebuffer" — so a cached
    ///     subtree blitted inside an enclosing `.single_source`
    ///     descent correctly inherits the enclosing effect's
    ///     offscreen target.
    ///   * Any other value → `cached + pd_base`. The cached `local_pd_idx`
    ///     was rebased to start-at-0 at snapshot; `pd_base` is the
    ///     live `pass_dispatches.items.len` captured before the
    ///     cache entry's own dispatches get merged in (so primitive
    ///     targets and dispatch `sequence_index` land at matching
    ///     positions in the live list).
    pub fn appendGlyphsReplayingTargets(
        self: *DrawList,
        lc: *const LayoutCtx,
        items: []const tp.GlyphInstance,
        cached_targets: []const u32,
        pd_base: u32,
    ) !void {
        std.debug.assert(items.len == cached_targets.len);
        try self.glyphs.appendSlice(items);
        try self.glyph_targets.ensureUnusedCapacity(items.len);
        for (cached_targets) |t| {
            const resolved: u32 = if (t == MAIN_TARGET)
                lc.current_target_dispatch_index
            else
                t + pd_base;
            self.glyph_targets.appendAssumeCapacity(resolved);
        }
    }

    pub fn appendQuadsReplayingTargets(
        self: *DrawList,
        lc: *const LayoutCtx,
        items: []const qp.QuadInstance,
        cached_targets: []const u32,
        pd_base: u32,
    ) !void {
        std.debug.assert(items.len == cached_targets.len);
        try self.quads.appendSlice(items);
        try self.quad_targets.ensureUnusedCapacity(items.len);
        for (cached_targets) |t| {
            const resolved: u32 = if (t == MAIN_TARGET)
                lc.current_target_dispatch_index
            else
                t + pd_base;
            self.quad_targets.appendAssumeCapacity(resolved);
        }
    }

    pub fn appendTrisReplayingTargets(
        self: *DrawList,
        lc: *const LayoutCtx,
        vertices: []const tri_pipeline.Vertex,
        cached_targets: []const u32,
        pd_base: u32,
    ) !void {
        std.debug.assert(vertices.len == cached_targets.len);
        try self.tris.appendSlice(vertices);
        try self.tri_targets.ensureUnusedCapacity(vertices.len);
        for (cached_targets) |t| {
            const resolved: u32 = if (t == MAIN_TARGET)
                lc.current_target_dispatch_index
            else
                t + pd_base;
            self.tri_targets.appendAssumeCapacity(resolved);
        }
    }

    // ── Hot-path helpers for high-frequency tri emission (svg) ────

    /// Pair-ensure capacity on `tris` + `tri_targets` so a tight
    /// loop can call `appendTriAssumeCapacity` repeatedly without
    /// any per-iteration allocation. Used by `:::svg` and
    /// `:::svg-stream` which emit hundreds of triangles in one
    /// burst.
    pub fn ensureUnusedTriCapacity(self: *DrawList, n: usize) !void {
        try self.tris.ensureUnusedCapacity(n);
        try self.tri_targets.ensureUnusedCapacity(n);
    }

    pub fn appendTriAssumeCapacity(
        self: *DrawList,
        lc: *const LayoutCtx,
        vertex: tri_pipeline.Vertex,
    ) void {
        self.tris.appendAssumeCapacity(vertex);
        self.tri_targets.appendAssumeCapacity(lc.current_target_dispatch_index);
    }

    /// Debug-build sanity check — primitives and their parallel
    /// target arrays must stay equal-length at every quiescent
    /// point. Run at frame boundaries to catch any direct
    /// `glyphs.append` / `quads.append` etc. that slipped past the
    /// emit-helper refactor.
    pub fn assertTargetsInSync(self: *const DrawList) void {
        std.debug.assert(self.glyphs.items.len == self.glyph_targets.items.len);
        std.debug.assert(self.quads.items.len == self.quad_targets.items.len);
        std.debug.assert(self.tris.items.len == self.tri_targets.items.len);
        std.debug.assert(self.images.items.len == self.image_targets.items.len);
    }
};

/// One raster image draw — the component supplies an already-allocated
/// descriptor set referencing its texture, and a world-space rect.
/// The renderer iterates `DrawList.images` in order, issuing one
/// `vkCmdDraw(6,1,0,0)` per entry with the descriptor bound.
pub const ImageDraw = struct {
    descriptor_set: *anyopaque, // VkDescriptorSet (kept *anyopaque so element.zig avoids vk.h)
    dst_pos: [2]f32,
    dst_size: [2]f32,
};

const glyph_cache_mod = @import("text/glyph_cache.zig");
const atlas_mod = @import("gpu/atlas.zig");
const qp = @import("gpu/quad_pipeline.zig");
const tri_pipeline = @import("gpu/tri_pipeline.zig");
const layout_cache_mod = @import("layout_cache.zig");
const jobs_mod = @import("common").jobs;
const layout_context_mod = @import("layout/context.zig");

// ── Tests ──────────────────────────────────────────────────────────
//
// Phase B.4.b.4 — run iterator gates. Pure CPU logic; no Vulkan.

const testing = std.testing;

// ── Alignment ───────────────────────────────────────────────────────

test "Align: the words an author will actually type" {
    try testing.expectEqual(Align.start, Align.parse("start").?);
    try testing.expectEqual(Align.center, Align.parse("center").?);
    try testing.expectEqual(Align.end, Align.parse("end").?);
    // Synonyms. `left`/`right` are what somebody reaches for first, and
    // `centre` is not a typo for half the people who will write it.
    try testing.expectEqual(Align.start, Align.parse("left").?);
    try testing.expectEqual(Align.end, Align.parse("right").?);
    try testing.expectEqual(Align.center, Align.parse("centre").?);
    // Anything else is null, so `AlignAttrs.ingest` can leave the field
    // inheriting rather than silently resetting it to `.start`.
    try testing.expect(Align.parse("middle") == null);
    try testing.expect(Align.parse("") == null);
}

test "Align.offset: the arithmetic, including the case that overflows" {
    // A 240-wide thing in a 360-wide panel — the repro gate's slider,
    // and the number it asserts.
    try testing.expectEqual(@as(f32, 0), Align.start.offset(360, 240));
    try testing.expectEqual(@as(f32, 60), Align.center.offset(360, 240));
    try testing.expectEqual(@as(f32, 120), Align.end.offset(360, 240));

    // Content that exactly fills does not move, at any alignment. This
    // is why centring a paragraph as a BLOCK is a no-op: `measureBlock`
    // reports its width as the width it was offered.
    try testing.expectEqual(@as(f32, 0), Align.center.offset(360, 360));
    try testing.expectEqual(@as(f32, 0), Align.end.offset(360, 360));

    // Content WIDER than its space starts at the left edge and overflows
    // right, like every other overflow here. Centring it would push its
    // beginning off the left edge, where it cannot be read — and a
    // negative offset would put a panel's first glyph outside the panel.
    try testing.expectEqual(@as(f32, 0), Align.center.offset(100, 400));
    try testing.expectEqual(@as(f32, 0), Align.end.offset(100, 400));
}

test "AlignAttrs: null means INHERIT, which is what makes it cascade" {
    const base: Constraints = .{ .max_w = 360, .block_align = .center, .text_align = .end };

    // A container that says nothing passes its parent's answer straight
    // through. Without this, every wrapper between a panel and its text
    // would silently reset the alignment to `.start`.
    const silent = AlignAttrs{};
    const through = silent.apply(base);
    try testing.expectEqual(Align.center, through.block_align);
    try testing.expectEqual(Align.end, through.text_align);
    try testing.expectEqual(@as(f32, 360), through.max_w);

    // Naming ONE overrides only that one.
    const half = AlignAttrs{ .text = .start };
    const mixed = half.apply(base);
    try testing.expectEqual(Align.center, mixed.block_align);
    try testing.expectEqual(Align.start, mixed.text_align);
}

test "AlignAttrs.ingest: reads its two attrs, declines the rest" {
    var a = AlignAttrs{};
    try testing.expect(a.ingest("align", "center"));
    try testing.expect(a.ingest("text_align", "right"));
    try testing.expectEqual(Align.center, a.block.?);
    try testing.expectEqual(Align.end, a.text.?);

    // Not ours — the caller's own attribute arms still get a look.
    try testing.expect(!a.ingest("radius", "12"));
    try testing.expect(!a.ingest("blur", "16"));
    // `valign` is the INLINE property and a different thing entirely.
    // Claiming it here would swallow an attribute meant for a line box.
    try testing.expect(!a.ingest("valign", "middle"));

    // A value we cannot parse leaves the field alone rather than
    // resetting it. `align=middle` is a typo, and inheriting is a better
    // answer to a typo than overriding a parent that got it right.
    var b = AlignAttrs{ .block = .center };
    try testing.expect(b.ingest("align", "middle"));
    try testing.expectEqual(Align.center, b.block.?);
}

test "AlignAttrs.readFrom: fresh each time, so deleting an attr takes effect" {
    const Attr = struct { key: []const u8, value: []const u8 };
    const Spec = struct { attrs: []const Attr };

    const with = Spec{ .attrs = &[_]Attr{
        .{ .key = "blur", .value = "16" },
        .{ .key = "align", .value = "center" },
    } };
    const got = AlignAttrs.readFrom(&with);
    try testing.expectEqual(Align.center, got.block.?);
    try testing.expect(got.text == null); // unmentioned → inherit

    // The re-ingest case, which is what a hot reload is: the attribute
    // was deleted and saved. Reading FRESH means it goes back to
    // inheriting; layering onto what the instance held would leave a
    // centred panel that no document asks for any more.
    const without = Spec{ .attrs = &[_]Attr{.{ .key = "blur", .value = "16" }} };
    const after = AlignAttrs.readFrom(&without);
    try testing.expect(after.block == null);
}

test "runs: empty array yields nothing" {
    const targets: []const u32 = &.{};
    var it = runs(targets, MAIN_TARGET);
    try testing.expect(it.next() == null);
}

test "runs: single contiguous match yields one run" {
    const targets: []const u32 = &.{ 7, 7, 7, 7 };
    var it = runs(targets, 7);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 0), r1.first);
    try testing.expectEqual(@as(u32, 4), r1.count);
    try testing.expect(it.next() == null);
}

test "runs: leading/trailing non-matches are skipped" {
    const targets: []const u32 = &.{ 1, 1, 7, 7, 1, 1 };
    var it = runs(targets, 7);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 2), r1.first);
    try testing.expectEqual(@as(u32, 2), r1.count);
    try testing.expect(it.next() == null);
}

test "runs: interleaved MAIN/target splits into multiple runs" {
    // The B.4.b.4 critical case — MAIN target broken into chunks
    // by a single_source subtree. text :::drop_shadow{...} text
    // produces [MAIN, MAIN][TARGET, TARGET][MAIN] in the parallel
    // target array. The run-finder must yield two MAIN runs and
    // one TARGET run.
    const targets: []const u32 = &.{ MAIN_TARGET, MAIN_TARGET, 0, 0, MAIN_TARGET };
    var it = runs(targets, MAIN_TARGET);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 0), r1.first);
    try testing.expectEqual(@as(u32, 2), r1.count);
    const r2 = it.next().?;
    try testing.expectEqual(@as(u32, 4), r2.first);
    try testing.expectEqual(@as(u32, 1), r2.count);
    try testing.expect(it.next() == null);
}

test "runs: no matches yields nothing" {
    const targets: []const u32 = &.{ 1, 2, 3, 4 };
    var it = runs(targets, 7);
    try testing.expect(it.next() == null);
}

test "triRuns: empty index buffer yields nothing" {
    const targets: []const u32 = &.{};
    const indices: []const u32 = &.{};
    var it = triRuns(targets, indices, MAIN_TARGET);
    try testing.expect(it.next() == null);
}

test "triRuns: single mesh's triangles yield one index-range run" {
    // SVG mesh with 4 vertices, 2 triangles (indices 0,1,2 + 0,2,3).
    // All 4 vertices tagged with target 5 (walker invariant).
    const targets: []const u32 = &.{ 5, 5, 5, 5 };
    const indices: []const u32 = &.{ 0, 1, 2, 0, 2, 3 };
    var it = triRuns(targets, indices, 5);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 0), r1.first_index);
    try testing.expectEqual(@as(u32, 6), r1.index_count);
    try testing.expect(it.next() == null);
}

test "triRuns: two meshes targeting different dispatches split correctly" {
    // Mesh A: vertices 0..3 tagged target 7 → indices 0,1,2 + 0,2,3.
    // Mesh B: vertices 4..7 tagged target 9 → indices 4,5,6 + 4,6,7.
    // The walker appends Mesh A's indices first, then Mesh B's,
    // mirroring the order of appendTri calls.
    const targets: []const u32 = &.{ 7, 7, 7, 7, 9, 9, 9, 9 };
    const indices: []const u32 = &.{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };
    var it = triRuns(targets, indices, 7);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 0), r1.first_index);
    try testing.expectEqual(@as(u32, 6), r1.index_count); // 2 triangles
    try testing.expect(it.next() == null);

    var it2 = triRuns(targets, indices, 9);
    const r2 = it2.next().?;
    try testing.expectEqual(@as(u32, 6), r2.first_index);
    try testing.expectEqual(@as(u32, 6), r2.index_count); // 2 triangles
    try testing.expect(it2.next() == null);
}

test "triRuns: interleaved meshes split into multiple per-target runs" {
    // Three meshes, alternating targets: Main, Effect, Main.
    // Mesh 1 (verts 0-2, target MAIN): indices 0,1,2.
    // Mesh 2 (verts 3-5, target 0):     indices 3,4,5.
    // Mesh 3 (verts 6-8, target MAIN):  indices 6,7,8.
    // Expected for target MAIN: two runs (0..3 and 6..9).
    const targets: []const u32 = &.{
        MAIN_TARGET, MAIN_TARGET, MAIN_TARGET,
        0,           0,           0,
        MAIN_TARGET, MAIN_TARGET, MAIN_TARGET,
    };
    const indices: []const u32 = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    var it = triRuns(targets, indices, MAIN_TARGET);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 0), r1.first_index);
    try testing.expectEqual(@as(u32, 3), r1.index_count);
    const r2 = it.next().?;
    try testing.expectEqual(@as(u32, 6), r2.first_index);
    try testing.expectEqual(@as(u32, 3), r2.index_count);
    try testing.expect(it.next() == null);
}

test "CornerPush: std140 offsets, and the head it has to fit inside" {
    // Lock-in for the fixed push head. Every effect fragment shader
    // declares this block by hand as
    //
    //     vec2 display; vec2 _display_pad;   //  0..16
    //     vec2 corner_size;                  // 16..24
    //     float corner_radius;               // 24..28
    //     float _corner_pad;                 // 28..32
    //
    // and a silent reorder here compiles and renders garbage — a corner
    // radius read out of the size's y, say, which cuts every composite's
    // alpha to nothing.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CornerPush, "size_px"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CornerPush, "radius_px"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CornerPush));

    // And the head adds up. `spark.zig` asserts the same thing at
    // comptime from the record path's side; this is the contract stated
    // where the type lives, because the two halves are edited by
    // different people on different days.
    try std.testing.expectEqual(@as(u32, 32), PASS_UNIFORM_OFFSET);
    try std.testing.expect(@sizeOf(CornerPush) <= PASS_UNIFORM_OFFSET - 16);

    // A default-constructed head is square, which is what makes `radius=`
    // opt-in: every effect that never mentions it keeps hard corners and
    // pays one compare per fragment.
    const d = CornerPush{};
    try std.testing.expectEqual(@as(f32, 0), d.radius_px);
}

test "PadAttrs: one, two and four values, in CSS order" {
    const one = PadAttrs.parse("12").?;
    try std.testing.expectEqual(PadAttrs{ .top = 12, .right = 12, .bottom = 12, .left = 12 }, one);

    const two = PadAttrs.parse("8 20").?;
    try std.testing.expectEqual(PadAttrs{ .top = 8, .right = 20, .bottom = 8, .left = 20 }, two);

    const four = PadAttrs.parse("4 8 12 16").?;
    try std.testing.expectEqual(PadAttrs{ .top = 4, .right = 8, .bottom = 12, .left = 16 }, four);

    // Extra whitespace is an author's formatting, not a fifth value.
    try std.testing.expectEqual(two, PadAttrs.parse("  8   20  ").?);
}

test "PadAttrs: three values are refused rather than guessed" {
    // CSS reads three as top / horizontal / bottom, which nobody
    // remembers correctly. A panel silently padded wrong is worse than
    // one that ignores a typo and stays flush.
    try std.testing.expectEqual(@as(?PadAttrs, null), PadAttrs.parse("4 8 12"));
    try std.testing.expectEqual(@as(?PadAttrs, null), PadAttrs.parse("1 2 3 4 5"));
    try std.testing.expectEqual(@as(?PadAttrs, null), PadAttrs.parse("wide"));
    try std.testing.expectEqual(@as(?PadAttrs, null), PadAttrs.parse("-4"));
    try std.testing.expectEqual(@as(?PadAttrs, null), PadAttrs.parse(""));
}

test "PadAttrs: shrink, inset and grow are each other's inverse" {
    const p = PadAttrs{ .top = 4, .right = 8, .bottom = 12, .left = 16 };
    const base: Constraints = .{ .max_w = 300, .max_h = 200 };

    const inner = p.shrink(base);
    try std.testing.expectApproxEqAbs(@as(f32, 300 - 24), inner.max_w, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 200 - 16), inner.max_h, 1e-6);

    const child_origin = p.inset(.{ 100, 50 });
    try std.testing.expectApproxEqAbs(@as(f32, 116), child_origin[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 54), child_origin[1], 1e-6);

    // A child that filled its shrunk constraints grows back to exactly
    // the container's own box — or a padded panel would change width.
    const child: Box = .{ .x = 116, .y = 54, .w = inner.max_w, .h = inner.max_h };
    const box = p.grow(child, .{ 100, 50 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), box.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 300), box.w, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 200), box.h, 1e-6);
}

test "PadAttrs: an unbounded constraint stays unbounded" {
    const p = PadAttrs{ .top = 10, .right = 10, .bottom = 10, .left = 10 };
    const inner = p.shrink(.{ .max_w = std.math.inf(f32), .max_h = std.math.inf(f32) });
    try std.testing.expect(std.math.isInf(inner.max_w));
    try std.testing.expect(std.math.isInf(inner.max_h));
    // And a padding wider than the space available clamps at zero rather
    // than handing a child a negative width to lay out into.
    const tight = p.shrink(.{ .max_w = 5, .max_h = 5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), tight.max_w, 1e-6);
}

test "PadAttrs: readFrom takes the attribute, and nothing means nothing" {
    const Attr = struct { key: []const u8, value: []const u8 };
    const with = [_]Attr{ .{ .key = "blur", .value = "16" }, .{ .key = "padding", .value = "6 14" } };
    const got = PadAttrs.readFrom(&.{ .attrs = &with });
    try std.testing.expectEqual(@as(f32, 6), got.top);
    try std.testing.expectEqual(@as(f32, 14), got.left);
    try std.testing.expect(got.any());

    const without = [_]Attr{.{ .key = "blur", .value = "16" }};
    try std.testing.expect(!PadAttrs.readFrom(&.{ .attrs = &without }).any());
}
