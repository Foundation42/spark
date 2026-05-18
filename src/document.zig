//! `Document` — a parsed markdown source + the runtime state that
//! drives its reactive components. Phase 3 of `docs/library-spec.md`.
//!
//! A Document is a handle the host holds across many frames. It
//! owns:
//!
//!   * **Arena**: every `Element` node + every owned string in the
//!     parsed tree lives in this arena. Freed wholesale at
//!     `Document.deinit`.
//!   * **Root Element**: the parser's output — what
//!     `Spark.layoutAndRender` walks.
//!   * **State** (optional): when `state` is non-null, this doc has
//!     its own root State (frontmatter populated it at parse time;
//!     embedded children link `.parent = doc.state`). When null,
//!     `Spark.layoutAndRender` falls back to `spark.host_state`.
//!     Per spec decision #8, each `loadDocument` gets its own State
//!     by default; sharing is opt-in via `LoadOpts.shared_state`.
//!   * **Theme override** (optional): when non-null, layout uses
//!     `doc.theme` instead of `spark.theme`. Null = inherit.
//!
//! Multiple Documents per Spark is the design intent — HUD overlays,
//! debug panels, AI scratch panels can each be a separate Document
//! that the host composes with manual origins in a single frame.

const std = @import("std");
const element = @import("element.zig");
const state_mod = @import("state.zig");
const markdown = @import("markdown.zig");
const component_mod = @import("component.zig");

pub const Error = error{
    DocumentSourceTooLarge,
};

/// Construction options for `Spark.loadDocument`. Defaults give
/// the per-Document State semantics; share state via
/// `.shared_state = &other_doc.state.?` to opt into co-mutation.
pub const LoadOpts = struct {
    /// When non-null, the new Document borrows this State instead
    /// of creating its own. Lifetime is the host's responsibility —
    /// the borrowed State must outlive the Document.
    shared_state: ?*state_mod.State = null,
    /// When non-null, layout uses this Theme instead of
    /// `spark.theme`. Null = inherit the Spark default.
    theme: ?*const element.Theme = null,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    root: element.Element,
    /// Per-document root State. When the host opts into shared state
    /// via `LoadOpts.shared_state`, this stays `null` and
    /// `Spark.layoutAndRender` falls back to the shared State
    /// (whose lifetime the host owns).
    state: ?*state_mod.State = null,
    /// Per-document Theme override. Null = inherit `spark.theme`.
    theme: ?*const element.Theme = null,
    /// Whether this Document allocated `state` itself (owns it).
    /// True for the default per-doc State path; false for
    /// `shared_state`.
    owns_state: bool = false,

    pub fn deinit(self: *Document) void {
        if (self.owns_state) {
            if (self.state) |s| {
                s.deinit();
                self.allocator.destroy(s);
            }
        }
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

/// Wrap a pre-built Element root (e.g. produced by `ansi.parseAnsi`)
/// as a Document so the host can run it through
/// `Spark.layoutAndRender`. Document takes ownership of `arena` —
/// `deinit` will call `arena.deinit()` and free the arena pointer.
///
/// Use this for non-markdown trees the host parses with a different
/// producer; markdown sources should go through `Spark.loadDocument`
/// which wires frontmatter + state + registry parses end-to-end.
pub fn wrapElement(
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    root: element.Element,
    shared_state: ?*state_mod.State,
    theme_override: ?*const element.Theme,
) Document {
    return .{
        .allocator = allocator,
        .arena = arena,
        .root = root,
        .state = shared_state,
        .theme = theme_override,
        .owns_state = false,
    };
}

/// Internal helper invoked by `Spark.loadDocument`. Parses `source`
/// into a Document, applies frontmatter to the doc's State, links
/// the registry so factories see `c.spark`. Caller (Spark) provides
/// the theme + registry + spark via field access on its `self`.
pub fn buildDocument(
    allocator: std.mem.Allocator,
    source: []const u8,
    theme: *const element.Theme,
    registry: *component_mod.Registry,
    opts: LoadOpts,
) !Document {
    if (source.len > 32 * 1024 * 1024) return error.DocumentSourceTooLarge;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // State: either freshly allocated (and frontmatter-seeded) or
    // borrowed from the host's request.
    var doc_state: ?*state_mod.State = null;
    var owns_state = false;
    errdefer if (doc_state) |s| if (owns_state) {
        s.deinit();
        allocator.destroy(s);
    };

    if (opts.shared_state) |shared| {
        doc_state = shared;
        owns_state = false;
    } else {
        const s = try allocator.create(state_mod.State);
        errdefer allocator.destroy(s);
        s.* = state_mod.State.init(allocator);
        errdefer s.deinit();
        // Seed from frontmatter (best-effort; missing/malformed = empty).
        if (state_mod.extractFrontmatter(source)) |fm| {
            var tmp = try state_mod.parseFrontmatter(allocator, fm.body);
            defer tmp.deinit();
            var it = tmp.map.iterator();
            while (it.next()) |entry| {
                try s.set(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        doc_state = s;
        owns_state = true;
    }

    // Strip frontmatter for the markdown parse — the parser sees
    // body bytes only, frontmatter is state-only.
    const body: []const u8 = if (state_mod.extractFrontmatter(source)) |fm| fm.rest else source;

    const root = try markdown.parseWithStateAndScope(
        arena.allocator(),
        body,
        theme,
        registry,
        doc_state.?,
        null, // no scope at the root — embedded docs prefix theirs
    );

    return .{
        .allocator = allocator,
        .arena = arena,
        .root = root,
        .state = doc_state,
        .theme = opts.theme,
        .owns_state = owns_state,
    };
}
