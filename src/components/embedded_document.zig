//! `:::embedded-document` — recursive document composition (stage 9).
//! The factory the network-effect substrate from `vision.md` is
//! built on. Author writes:
//!
//!     :::embedded-document {#sub src="src/widgets/orbit_panel.md" target_orbit=420}
//!     :::
//!
//! and the host:
//!   1. Reads `src` from disk relative to the process CWD.
//!   2. Allocates a per-instance ArenaAllocator + child `State`
//!      (with `parent = parent_state` so dirty bubbles up).
//!   3. Parses the file via `markdown.parseWithStateAndScope`,
//!      handing in `child_state` + a scope prefix == `#id`. Every
//!      `:::` block inside the child is then cached in the shared
//!      registry under `"{scope}/{id_or_auto:N}"` keys — no
//!      collision with parent-level `#bx` or `#telemetry`.
//!   4. Applies non-reserved parent attrs as overrides onto child
//!      state (so `target_orbit=420` ends up in `child_state` after
//!      the file's own frontmatter has been parsed). Parent always
//!      wins on conflict.
//!   5. Renders by delegating `layoutAndRender` to the parsed child
//!      `Element` root — embedded docs participate in the parent's
//!      layout flow as regular blocks.
//!
//! ### Lifecycle
//!
//! `Factory.deinit` calls `registry.deinitScope(scope)` *before*
//! freeing the child state. That tears down every cached child
//! component (and its Binding) in the shared registry while
//! `child_state` is still alive, so no stale binding callback ever
//! fires against freed memory. Then child state, child arena, and
//! the Component itself follow in order.
//!
//! ### The module-globals smell
//!
//! `Factory.create`'s signature is `(allocator, spec)`. It doesn't
//! see the host's theme / registry / parent state — but the
//! embedded-doc factory *needs* all three to call
//! `parseWithStateAndScope`. The v0 workaround is module-level
//! pointers captured by `install()`. The long-term fix is either a
//! per-factory config pointer baked into `Factory` (small contract
//! change), or a `*Host` context threaded through `Factory.create`.
//! Both are deferred because the smell is isolated to this one
//! file. Captured in journey-session-5.md.
//!
//! ### Source schemes
//!
//! `src=` may be:
//!
//!   * A filesystem path (`"src/widgets/foo.md"`, or absolute) — read
//!     via `std.fs.cwd().readFileAlloc`, no caching (filesystem is
//!     fast enough that re-reads aren't worth tracking). Synchronous.
//!   * A `file://` URL — equivalent to the filesystem path of the
//!     URL's path component. Convenience for authors who want to
//!     write all `src=`s in URL form for consistency.
//!   * An HTTP(S) URL (`"http://127.0.0.1:8080/foo.md"`,
//!     `"https://gist.githubusercontent.com/..."`) — handled by the
//!     opt-in extras module `src/extras/embedded_document_http.zig`.
//!     When `spark.embedded_http != null`, core delegates the URL
//!     branch to it: per-Spark URL→bytes cache, async `IoChannel`
//!     fetch on cache miss, `.loading` / `.failed` placeholder
//!     rendering. Without the extras module installed, URL src=
//!     hits return `error.HttpEmbeddedDocumentRequiresExtras` at
//!     create-time — loud failure rather than silent truncation.
//!
//! `PendingFetch`, `Component`, `OverlayKV`, `fulfillFromBytes*`,
//! and `applyParentOverlays` are exposed `pub` because the extras
//! `EmbeddedDocumentHttp.submit` / `handleCompletion` drive the
//! same shape as the sync path. Data type definitions stay in core
//! so the `pending: ?*PendingFetch` back-reference on `Component`
//! doesn't need an opaque-pointer detour.
//!
//! ### Interactive components inside embedded docs (not supported)
//!
//! The walker dispatches input events with the host's State
//! pointer; an embedded `:::slider` would mutate parent state
//! instead of child state. Fix requires plumbing a state pointer
//! through `Hit` (or `LayoutCtx`) so dispatch knows which state to
//! deliver to. Deferred — the v0 demo uses non-interactive child
//! components (`:::box` + `:::chart`).
//!
//! ### Reactivity inside embedded docs (works)
//!
//! Templated `${state.x}` attrs in a child `:::` block resolve
//! against `child_state` because `parseWithStateAndScope` passes
//! it down. The registry builds Bindings subscribed to
//! `child_state.subscribe(path, ...)`. Child-state mutations fire
//! child Binding refires; the dirty bubble wakes the host's
//! renderer.

const std = @import("std");
const element = @import("../element.zig");
const element_layout = @import("../element_layout.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const markdown = @import("../markdown.zig");
const state_mod = @import("../state.zig");
const io = @import("../io_channel.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");

pub const Error = error{
    EmbeddedDocumentMissingId,
    EmbeddedDocumentMissingSrc,
    EmbeddedDocumentNotInstalled,
    EmbeddedDocumentReadFailed,
    /// URL src= without the `embedded_document_http` extras module
    /// installed on this Spark. Install with
    /// `spark.extras.embedded_document_http.install(&spark)` before
    /// loading documents that reference http:// or https:// sources.
    HttpEmbeddedDocumentRequiresExtras,
};

/// One-time install. Call after registering all the other factories
/// — keeps the dependency on the rest of the registry explicit.
pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("embedded-document", factory);
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

pub const Phase = enum {
    /// `root` is a parsed Element tree; layoutAndRender delegates to it.
    ready,
    /// Awaiting an in-flight async fetch; layoutAndRender renders a
    /// "loading…" placeholder.
    loading,
    /// Fetch errored or post-fetch parse failed; layoutAndRender
    /// renders a red "fetch failed" placeholder.
    failed,
};

pub const OverlayKV = struct {
    key: []u8,
    value: []u8,
};

/// Heap-allocated request-side context for the async URL branch.
/// The Component holds a pointer to it (for cancellation). The
/// extras `EmbeddedDocumentHttp.handleCompletion` owns its lifetime
/// — frees it after applying or discarding the result. The type is
/// `pub` because extras allocates + populates it from outside core,
/// but no HTTP-specific operations live here. `header.handle_completion`
/// is set by the extras submit path to point at its completion
/// dispatcher — core never sets this default.
pub const PendingFetch = struct {
    /// Polymorphic completion header. Host's drain loop dispatches via
    /// `header.handle_completion`. Must be the first field; `user_data`
    /// is `@intFromPtr(&pending)` and the host reads the first usize.
    header: io.PendingHeader,
    allocator: std.mem.Allocator,
    /// Set to null by `deinit_` if the Component is destroyed while
    /// the fetch is in flight.
    component: ?*Component,
    /// Retained for diagnostics; not used for routing.
    handle: io.Handle,
    /// Owned by Pending. Duped at submit time so we can cache the
    /// body keyed by URL when it lands.
    url: []u8,
    /// Snapshot of non-`src` spec attrs at submit time. Re-applied
    /// onto child_state at completion (so parent values land AFTER
    /// frontmatter, preserving the parent-wins rule).
    overlays: []OverlayKV,
    /// Snapshot of the spark pointer so the completion handler can
    /// release the io-channel-owned body, bump host_state.dirty, and
    /// reach the EmbeddedDocumentHttp's url_cache even after the
    /// Component itself has been destroyed.
    spark: *spark_mod.Spark,
};

pub const Component = struct {
    allocator: std.mem.Allocator,
    /// Owns the child Element tree's arena.
    arena: *std.heap.ArenaAllocator,
    /// Captured at create time. Replaces the old `_ref` module
    /// globals — every cross-cutting concern (registry, theme,
    /// parent state, io_channel) is one hop through here.
    spark: *spark_mod.Spark,
    /// Child state. Set up with `parent = spark.host_state` so
    /// child-side mutations wake the root renderer.
    child_state: *state_mod.State,
    /// Parsed root of the embedded document. Only valid when
    /// `phase == .ready`.
    root: element.Element,
    /// Cache-key scope; owned by the Component for deinit's
    /// `registry.deinitScope` call.
    scope: []u8,
    /// Lifecycle phase. .ready for synchronous paths (file://, cache
    /// hits) from the moment `create` returns. .loading for the
    /// cache-miss URL path until the completion handler swaps in
    /// the parsed root. .failed on terminal errors.
    phase: Phase = .ready,
    /// Held when `phase == .loading` so `deinit_` can null its
    /// `.component` field and signal cancel.
    pending: ?*PendingFetch = null,
    /// Stage 10 — headless documents. When true, `layoutAndRender`
    /// returns a zero-size box and emits no draw data, but the doc
    /// is still parsed, frontmatter populates child_state, and any
    /// child components (LLM/SVG/image streams with `auto_start`,
    /// `:::chart` ingest, etc.) run normally. Use for config docs,
    /// cache-warming widgets, or "model" docs whose state other
    /// (visible) docs observe via the parent pointer.
    headless: bool = false,
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const id_raw = spec.id orelse return error.EmbeddedDocumentMissingId;
    const src_path = findAttr(spec.attrs, "src") orelse return error.EmbeddedDocumentMissingSrc;
    const headless = parseBoolAttr(spec.attrs, "headless", false);

    // Per-instance allocations common to every phase. Construction
    // order matters for errdefer cleanup — child_state.deinit relies
    // on its allocator being initialised, etc.
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const child_state = try allocator.create(state_mod.State);
    errdefer allocator.destroy(child_state);
    child_state.* = state_mod.State.init(allocator);
    errdefer child_state.deinit();
    // The PARENT is the document this embed sits in, not the Spark's
    // root — an embed inside a panel inherits that panel's state, which
    // is the whole point of the parent chain. See `component.specState`.
    child_state.parent = component_mod.specState(spec, spark.host_state);

    const scope = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(scope);

    c.* = .{
        .allocator = allocator,
        .spark = spark,
        .arena = arena,
        .child_state = child_state,
        .root = element.Element{ .paragraph = &[_]element.Element{} }, // overwritten on ready paths; never reached in .loading/.failed
        .scope = scope,
        .phase = .loading, // optimistic; switch to .ready on every sync path below
        .pending = null,
        .headless = headless,
    };

    // ── Scheme dispatch ─────────────────────────────────────────────
    // file:// + bare paths are core (synchronous). http:// + https://
    // require the `embedded_document_http` extras module — when
    // installed, `spark.embedded_http != null` and we delegate the
    // entire URL lifecycle (cache hit OR async fetch) to it.
    const is_url = std.mem.startsWith(u8, src_path, "http://") or std.mem.startsWith(u8, src_path, "https://");

    if (is_url) {
        const ext = spark.embedded_http orelse return error.HttpEmbeddedDocumentRequiresExtras;
        try ext.submit(c, src_path, spec);
        return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
    }

    // Filesystem path (raw or file://): synchronous — local reads are
    // fast and the loading-state machinery isn't worth the complexity.
    const source = readLocal(allocator, src_path) catch
        return error.EmbeddedDocumentReadFailed;
    defer allocator.free(source);
    try fulfillFromBytes(c, source, spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

/// Shared finalisation: takes a Component shell and a source
/// buffer, applies frontmatter + overlays, parses, swaps the root
/// in, marks `.ready`. `pub` so the extras URL-fetch path can
/// call it for cache hits.
pub fn fulfillFromBytes(c: *Component, source: []const u8, spec: *const components.Spec) !void {
    var body: []const u8 = source;
    if (state_mod.extractFrontmatter(source)) |fm| {
        body = fm.rest;
        var tmp = try state_mod.parseFrontmatter(c.allocator, fm.body);
        defer tmp.deinit();
        var it = tmp.map.iterator();
        while (it.next()) |entry| {
            try c.child_state.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try applyParentOverlays(c.child_state, spec);

    const root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        body,
        c.spark.theme,
        c.spark.registry,
        c.child_state,
        c.scope,
    );
    c.root = root;
    c.phase = .ready;
}

/// Variant of `fulfillFromBytes` for the extras completion handler,
/// which doesn't have a live `Spec` anymore — applies the snapshotted
/// overlay KVs from the PendingFetch instead. `pub` so the extras
/// URL-fetch path can call it.
pub fn fulfillFromBytesWithOverlays(c: *Component, source: []const u8, overlays: []const OverlayKV) !void {
    var body: []const u8 = source;
    if (state_mod.extractFrontmatter(source)) |fm| {
        body = fm.rest;
        var tmp = try state_mod.parseFrontmatter(c.allocator, fm.body);
        defer tmp.deinit();
        var it = tmp.map.iterator();
        while (it.next()) |entry| {
            try c.child_state.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    for (overlays) |kv| {
        try c.child_state.set(kv.key, kv.value);
    }

    const root = try markdown.parseWithStateAndScope(
        c.arena.allocator(),
        body,
        c.spark.theme,
        c.spark.registry,
        c.child_state,
        c.scope,
    );
    c.root = root;
    c.phase = .ready;
}

/// Read a local (non-URL) source. Same path the synchronous flow
/// used pre-stage-12; broken out so the URL path can stay clean.
fn readLocal(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    const path: []const u8 = if (std.mem.startsWith(u8, src, "file://"))
        src["file://".len..]
    else
        src;
    return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Parent attrs may have changed (e.g. the parent's binding
    // refired because a referenced parent-state path mutated). Push
    // those new values into child_state — child bindings + chart
    // appends already in flight aren't disturbed.
    try applyParentOverlays(c.child_state, spec);

    // Stage 10 — reactive headless toggle. Re-reading the attr on
    // every update means `headless=${state.x}` composes with the
    // existing Binding subsystem: when the referenced state path
    // mutates, the registry re-resolves attrs and calls us with the
    // new value. The next layout pass picks up the flipped state.
    const new_headless = parseBoolAttr(spec.attrs, "headless", false);
    if (new_headless != c.headless) {
        c.headless = new_headless;
        c.spark.host_state.dirty = true;
    }

    // src= changes are not honored on update — would invalidate the
    // child Element tree mid-stream. Author changes `#id` to force a
    // destroy + create cycle through the registry's auto-recreation
    // path.
    //
    // If a fetch is still in flight, refresh the snapshotted overlays
    // on the PendingFetch too — so when the completion lands, the
    // *latest* parent values are applied after the frontmatter.
    if (c.pending) |p| {
        try refreshPendingOverlays(p, spec);
    }
}

/// Imperative `:::update` arms for visibility toggling. The reactive
/// path (`update()` reading `headless=${state.x}` each re-resolve) is
/// the more substrate-coherent way to drive this from data — these
/// actions are for direct mutation, e.g. a `:::button` or an LLM-
/// authored update fragment that wants to reveal / hide a previously
/// configured doc without bouncing through state.
///
/// Actions:
///   - `set-headless` with body `"true"` / `"false"` (or `"0"` / `"no"`).
///   - `toggle-headless` with empty body — flips the current value.
fn handleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    var new_headless: ?bool = null;

    if (std.mem.eql(u8, action, "set-headless")) {
        new_headless = if (std.mem.eql(u8, body, "false") or std.mem.eql(u8, body, "0") or std.mem.eql(u8, body, "no"))
            false
        else
            true;
    } else if (std.mem.eql(u8, action, "toggle-headless")) {
        new_headless = !c.headless;
    } else {
        return; // unknown action — silent no-op
    }

    if (new_headless) |nh| {
        if (nh != c.headless) {
            c.headless = nh;
            c.spark.host_state.dirty = true;
        }
    }
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // If a fetch is in flight, signal cancel by nulling the back
    // pointer. The completion handler will see this, free the body
    // (if it lands) plus the PendingFetch itself, and skip the
    // parse + dirty-bubble work.
    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }
    // Sweep child instances FIRST: their bindings unsubscribe from
    // child_state cleanly while child_state still exists. Without
    // this ordering, child Binding.destroy would call
    // child_state.unsubscribe AFTER we'd freed child_state.
    c.spark.registry.deinitScope(c.scope);
    c.child_state.deinit();
    allocator.destroy(c.child_state);
    c.arena.deinit();
    allocator.destroy(c.arena);
    allocator.free(c.scope);
    allocator.destroy(c);
}

/// Replace the snapshotted overlays on a Pending so the completion
/// handler applies the most recent parent values. Allocates a fresh
/// list; frees the previous one on success.
fn refreshPendingOverlays(p: *PendingFetch, spec: *const components.Spec) !void {
    const a = p.allocator;
    var new_list: std.ArrayListUnmanaged(OverlayKV) = .{};
    errdefer {
        for (new_list.items) |kv| {
            a.free(kv.key);
            a.free(kv.value);
        }
        new_list.deinit(a);
    }
    for (spec.attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "src")) continue;
        const k = try a.dupe(u8, attr.key);
        errdefer a.free(k);
        const v = try a.dupe(u8, attr.value);
        errdefer a.free(v);
        try new_list.append(a, .{ .key = k, .value = v });
    }
    const new_slice = try new_list.toOwnedSlice(a);
    // Replace + free old.
    for (p.overlays) |kv| {
        a.free(kv.key);
        a.free(kv.value);
    }
    a.free(p.overlays);
    p.overlays = new_slice;
}

pub fn applyParentOverlays(child_state: *state_mod.State, spec: *const components.Spec) !void {
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "src")) continue;
        try child_state.set(a.key, a.value);
    }
}

fn findAttr(attrs: []const components.Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

/// Parse a boolean attribute. Presence-with-no-equals (`headless`)
/// isn't expressible in the current attr grammar, so callers say
/// `headless=true` / `headless=false`. `"false"`, `"0"`, and `"no"`
/// (case-sensitive) read as false; anything else reads as true.
/// Missing key returns `default`.
fn parseBoolAttr(attrs: []const components.Attr, key: []const u8, default: bool) bool {
    const s = findAttr(attrs, key) orelse return default;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "no")) return false;
    return true;
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    // Embedded-doc composes a whole inner tree whose state can mutate
    // without the outer wrapper seeing it (the child State's dirty
    // bubble wakes the renderer but doesn't bump us). Caching the
    // outer block as a unit would freeze the inner snapshot. Disable
    // outer caching; the inner stack_v walk caches its own children,
    // which is where the savings live anyway.
    .disable_cache = true,
};

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *const Component = @ptrCast(@alignCast(ctx));

    // Stage 10 — headless documents have no visual representation.
    // The doc was still parsed at create-time (state populated, child
    // components instantiated, auto_start streams fired); we just
    // skip the layout walk and emit nothing. Zero-size box keeps
    // surrounding stack_v layout collapse-friendly.
    if (c.headless) return .{ .x = origin[0], .y = origin[1], .w = 0, .h = 0 };

    switch (c.phase) {
        .ready => {
            // Input-scope swap: while we walk the embedded subtree,
            // any Hit emitted by an interactive child component
            // should carry our child_state pointer (not the host's).
            const saved = lc.state;
            lc.state = @ptrCast(c.child_state);
            defer lc.state = saved;
            return try element_layout.layoutAndRender(c.root, origin, constraints, lc, out);
        },
        .loading => {
            const url: []const u8 = if (c.pending) |p| p.url else "";
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "loading {s}…", .{url}) catch "loading…";
            return try renderPlaceholder(msg, .loading, origin, constraints, lc, out);
        },
        .failed => {
            return try renderPlaceholder("fetch failed", .failed, origin, constraints, lc, out);
        },
    }
}

const PlaceholderScheme = enum { loading, failed };

const PLACEHOLDER_RADIUS: f32 = 6;
const PLACEHOLDER_BORDER_PX: f32 = 2;
const PLACEHOLDER_PAD_X: f32 = 12;
const PLACEHOLDER_PAD_Y: f32 = 8;
const PLACEHOLDER_MIN_W: f32 = 240;

const LOADING_BORDER: [4]f32 = .{ 0.55, 0.65, 0.80, 0.85 };
const LOADING_BG: [4]f32 = .{ 0.10, 0.13, 0.18, 0.55 };
const FAILED_BORDER: [4]f32 = .{ 0.85, 0.30, 0.30, 0.95 };
const FAILED_BG: [4]f32 = .{ 0.30, 0.08, 0.08, 0.60 };

fn renderPlaceholder(
    msg: []const u8,
    scheme: PlaceholderScheme,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    const border_rgba = switch (scheme) {
        .loading => LOADING_BORDER,
        .failed => FAILED_BORDER,
    };
    const bg_rgba = switch (scheme) {
        .loading => LOADING_BG,
        .failed => FAILED_BG,
    };
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);

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

    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ total_w, total_h },
        .color = border_rgba,
        .radius = PLACEHOLDER_RADIUS,
    });
    try out.appendQuad(lc, .{
        .dst_pos = .{ origin[0] + PLACEHOLDER_BORDER_PX, origin[1] + PLACEHOLDER_BORDER_PX },
        .dst_size = .{ total_w - 2 * PLACEHOLDER_BORDER_PX, total_h - 2 * PLACEHOLDER_BORDER_PX },
        .color = bg_rgba,
        .radius = @max(0, PLACEHOLDER_RADIUS - PLACEHOLDER_BORDER_PX),
    });

    const baseline_y = origin[1] + PLACEHOLDER_PAD_Y + m.ascender;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        &out.glyph_targets,
        lc.current_target_dispatch_index,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        run,
        style.font_id,
        origin[0] + PLACEHOLDER_PAD_X,
        baseline_y,
        style.color,
        style.hot_color,
        style.attention,
        lc.zoom,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = total_w,
        .h = total_h,
        .baseline = baseline_y,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// No-op completion handler used by the `refreshPendingOverlays` test
/// fixture — exercises overlay rewrite without involving IoChannel.
fn noopCompletion(comp: io.Completion) void {
    _ = comp;
}

test "applyParentOverlays: copies non-src attrs to child state" {
    var s = state_mod.State.init(testing.allocator);
    defer s.deinit();
    const attrs = [_]components.Attr{
        .{ .key = "src", .value = "ignored.md" },
        .{ .key = "target_orbit", .value = "420" },
        .{ .key = "label", .value = "satellite" },
    };
    const spec: components.Spec = .{ .name = "embedded-document", .attrs = &attrs };
    try applyParentOverlays(&s, &spec);
    try testing.expect(s.get("src") == null); // reserved, not copied
    try testing.expectEqualStrings("420", s.get("target_orbit").?);
    try testing.expectEqualStrings("satellite", s.get("label").?);
}

test "parent overlay overrides child frontmatter" {
    var s = state_mod.State.init(testing.allocator);
    defer s.deinit();
    try s.set("target_orbit", "100"); // pretend this came from frontmatter

    const attrs = [_]components.Attr{
        .{ .key = "target_orbit", .value = "420" }, // parent overlay
    };
    const spec: components.Spec = .{ .name = "embedded-document", .attrs = &attrs };
    try applyParentOverlays(&s, &spec);
    try testing.expectEqualStrings("420", s.get("target_orbit").?); // parent won
}

test "refreshPendingOverlays: replaces snapshot atomically, no leaks" {
    const a = testing.allocator;

    // Build a PendingFetch with an initial overlay snapshot.
    const k1 = try a.dupe(u8, "panel_color");
    const v1 = try a.dupe(u8, "red");
    var initial = try a.alloc(OverlayKV, 1);
    initial[0] = .{ .key = k1, .value = v1 };

    const url = try a.dupe(u8, "http://x/y");
    var test_spark = spark_mod.Spark.testStub(a);
    var p = PendingFetch{
        .header = .{ .handle_completion = noopCompletion },
        .allocator = a,
        .component = null,
        .handle = 0,
        .url = url,
        .overlays = initial,
        .spark = &test_spark,
    };
    defer {
        for (p.overlays) |kv| {
            a.free(kv.key);
            a.free(kv.value);
        }
        a.free(p.overlays);
        a.free(p.url);
    }

    // Refresh with a spec carrying two attrs (one new key, one
    // updated value, plus the reserved src= which must be filtered).
    const attrs = [_]components.Attr{
        .{ .key = "src", .value = "ignored" },
        .{ .key = "panel_color", .value = "blue" },
        .{ .key = "label", .value = "fresh" },
    };
    const spec: components.Spec = .{ .name = "embedded-document", .attrs = &attrs };
    try refreshPendingOverlays(&p, &spec);

    try testing.expectEqual(@as(usize, 2), p.overlays.len);
    try testing.expectEqualStrings("panel_color", p.overlays[0].key);
    try testing.expectEqualStrings("blue", p.overlays[0].value);
    try testing.expectEqualStrings("label", p.overlays[1].key);
    try testing.expectEqualStrings("fresh", p.overlays[1].value);
}

// `freePending` test lives in `src/extras/embedded_document_http.zig`
// alongside the function itself.

test "parseBoolAttr: defaults + truthy/falsy parsing" {
    const a = [_]components.Attr{
        .{ .key = "on", .value = "true" },
        .{ .key = "off", .value = "false" },
        .{ .key = "zero", .value = "0" },
        .{ .key = "no", .value = "no" },
        .{ .key = "anything", .value = "yes" },
        .{ .key = "presence", .value = "" }, // empty value still truthy
    };
    try testing.expectEqual(true, parseBoolAttr(&a, "on", false));
    try testing.expectEqual(false, parseBoolAttr(&a, "off", true));
    try testing.expectEqual(false, parseBoolAttr(&a, "zero", true));
    try testing.expectEqual(false, parseBoolAttr(&a, "no", true));
    try testing.expectEqual(true, parseBoolAttr(&a, "anything", false));
    try testing.expectEqual(true, parseBoolAttr(&a, "presence", false));
    // Missing key returns default.
    try testing.expectEqual(true, parseBoolAttr(&a, "missing", true));
    try testing.expectEqual(false, parseBoolAttr(&a, "missing", false));
}
