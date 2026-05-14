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
//! ### Remote sources (stage 11)
//!
//! `src=` may be:
//!
//!   * A filesystem path (`"src/widgets/foo.md"`, or absolute) — read
//!     via `std.fs.cwd().readFileAlloc`, no caching (filesystem is
//!     fast enough that re-reads aren't worth tracking).
//!   * An HTTP(S) URL (`"http://127.0.0.1:8080/foo.md"`,
//!     `"https://gist.githubusercontent.com/..."`) — fetched via
//!     `std.http.Client.fetch` and cached in a module-level
//!     `url_cache` keyed by URL string. Cache lifetime is program
//!     lifetime; `deinitGlobals()` frees it at host shutdown.
//!   * A `file://` URL — equivalent to the filesystem path of the
//!     URL's path component. Convenience for authors who want to
//!     write all `src=`s in URL form for consistency.
//!
//! HTTPS uses Zig's std.crypto.tls — the system trust store is
//! loaded on first use. Failures (network, 4xx/5xx, TLS handshake)
//! return `EmbeddedDocumentReadFailed`, which the registry's
//! resolve path turns into the "missing component" placeholder
//! visual. Loud but recoverable.
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
const markdown = @import("../markdown.zig");
const state_mod = @import("../state.zig");

pub const Error = error{
    EmbeddedDocumentMissingId,
    EmbeddedDocumentMissingSrc,
    EmbeddedDocumentNotInstalled,
    EmbeddedDocumentReadFailed,
};

// Module globals set by install(). See "module-globals smell" above.
var registry_ref: ?*component_mod.Registry = null;
var theme_ref: ?*const element.Theme = null;
var parent_state_ref: ?*state_mod.State = null;
/// Allocator used for the URL cache; same as the registry's
/// allocator. Captured at install() time so cache lookups don't
/// need to thread an allocator everywhere.
var cache_allocator: ?std.mem.Allocator = null;
/// URL → fetched bytes cache. Lazily initialised on first remote
/// fetch. Entries persist for the program lifetime; `deinitGlobals()`
/// frees them. Keyed by URL string (also duped into the allocator).
var url_cache: std.StringHashMapUnmanaged([]const u8) = .{};

/// One-time install. Call after registering all the other factories
/// — keeps the dependency on the rest of the registry explicit.
pub fn install(
    registry: *component_mod.Registry,
    theme: *const element.Theme,
    parent_state: *state_mod.State,
) !void {
    registry_ref = registry;
    theme_ref = theme;
    parent_state_ref = parent_state;
    cache_allocator = registry.allocator;
    try registry.register("embedded-document", factory);
}

/// Free the URL cache. Host calls this at shutdown after
/// `registry.deinit()`. Idempotent (safe to call when no remote
/// loads ever happened).
pub fn deinitGlobals() void {
    const a = cache_allocator orelse return;
    var it = url_cache.iterator();
    while (it.next()) |entry| {
        a.free(entry.key_ptr.*);
        a.free(entry.value_ptr.*);
    }
    url_cache.deinit(a);
    url_cache = .{};
    cache_allocator = null;
    registry_ref = null;
    theme_ref = null;
    parent_state_ref = null;
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Owns the child Element tree's arena.
    arena: *std.heap.ArenaAllocator,
    /// Child state. Set up with `parent = parent_state_ref` so
    /// child-side mutations wake the root renderer.
    child_state: *state_mod.State,
    /// Parsed root of the embedded document.
    root: element.Element,
    /// Cache-key scope; owned by the Component for deinit's
    /// `registry.deinitScope` call.
    scope: []u8,
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    if (registry_ref == null or theme_ref == null or parent_state_ref == null) {
        return error.EmbeddedDocumentNotInstalled;
    }
    const id_raw = spec.id orelse return error.EmbeddedDocumentMissingId;
    const src_path = findAttr(spec.attrs, "src") orelse return error.EmbeddedDocumentMissingSrc;

    // Load the source via scheme dispatch — filesystem path or
    // HTTP(S) URL. `source` always ends up owned by `allocator` for
    // the duration of this function; we copy out anything we need
    // into per-instance storage before returning.
    const source = loadSource(allocator, src_path) catch
        return error.EmbeddedDocumentReadFailed;
    defer allocator.free(source);

    // Per-instance allocations. Construction order matters for
    // errdefer cleanup — child_state.deinit relies on its allocator
    // being initialised, etc.
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
    child_state.parent = parent_state_ref;

    const scope = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(scope);

    // Populate child state with frontmatter, then overlay parent
    // attrs (parent always wins). Doing this before the parse so the
    // parse sees the final state during ${path} substitution.
    var body: []const u8 = source;
    if (state_mod.extractFrontmatter(source)) |fm| {
        body = fm.rest;
        var tmp = try state_mod.parseFrontmatter(allocator, fm.body);
        defer tmp.deinit();
        var it = tmp.map.iterator();
        while (it.next()) |entry| {
            try child_state.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try applyParentOverlays(child_state, spec);

    const root = try markdown.parseWithStateAndScope(
        arena.allocator(),
        body,
        theme_ref.?,
        registry_ref.?,
        child_state,
        scope,
    );

    c.* = .{
        .allocator = allocator,
        .arena = arena,
        .child_state = child_state,
        .root = root,
        .scope = scope,
    };
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Parent attrs may have changed (e.g. the parent's binding
    // refired because a referenced parent-state path mutated). Push
    // those new values into child_state — child bindings + chart
    // appends already in flight aren't disturbed.
    try applyParentOverlays(c.child_state, spec);
    // src= changes are not honored on update — would invalidate the
    // child Element tree mid-stream. Author changes `#id` to force a
    // destroy + create cycle through the registry's auto-recreation
    // path.
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    // Sweep child instances FIRST: their bindings unsubscribe from
    // child_state cleanly while child_state still exists. Without
    // this ordering, child Binding.destroy would call
    // child_state.unsubscribe AFTER we'd freed child_state.
    if (registry_ref) |r| r.deinitScope(c.scope);
    c.child_state.deinit();
    allocator.destroy(c.child_state);
    c.arena.deinit();
    allocator.destroy(c.arena);
    allocator.free(c.scope);
    allocator.destroy(c);
}

fn applyParentOverlays(child_state: *state_mod.State, spec: *const components.Spec) !void {
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "src")) continue;
        try child_state.set(a.key, a.value);
    }
}

fn findAttr(attrs: []const components.Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

/// Detect the `src=` scheme and dispatch. Returns bytes owned by
/// `allocator` — caller's responsibility to free. For URL sources,
/// the bytes are duped out of the cache so each Component gets its
/// own copy (lifetime is then bound to the Component's allocator,
/// matching the filesystem path).
fn loadSource(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://")) {
        const cached = try cachedFetch(src);
        return try allocator.dupe(u8, cached);
    }
    const path: []const u8 = if (std.mem.startsWith(u8, src, "file://"))
        src["file://".len..]
    else
        src;
    // 1 MiB cap is plenty for any reasonable doc; bumped when
    // content demand justifies.
    return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

/// Fetch + cache. Returns a slice OWNED by the cache (do not free
/// it directly — caller dupes if it needs an independent copy).
fn cachedFetch(url: []const u8) ![]const u8 {
    const a = cache_allocator orelse return error.EmbeddedDocumentNotInstalled;

    if (url_cache.get(url)) |bytes| return bytes;

    var client = std.http.Client{ .allocator = a };
    defer client.deinit();

    var body = std.ArrayList(u8).init(a);
    errdefer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 8 * 1024 * 1024,
    }) catch return error.EmbeddedDocumentReadFailed;

    if (result.status != .ok) return error.EmbeddedDocumentReadFailed;

    const url_key = try a.dupe(u8, url);
    errdefer a.free(url_key);
    const owned = try body.toOwnedSlice();
    errdefer a.free(owned);

    try url_cache.put(a, url_key, owned);
    return owned;
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
};

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *const Component = @ptrCast(@alignCast(ctx));

    // Input-scope swap: while we walk the embedded subtree, any Hit
    // emitted by an interactive child component should carry our
    // child_state pointer (not the host's). Save+restore so peers
    // after us in the parent's layout get the parent's state back.
    const saved = lc.state;
    lc.state = @ptrCast(c.child_state);
    defer lc.state = saved;

    return try element_layout.layoutAndRender(c.root, origin, constraints, lc, out);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

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
