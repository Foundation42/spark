//! Component registry + persistent instance cache. Stage 7b of the
//! live-documents staging path.
//!
//! Stage 7a parsed `:::name {attrs}\nbody\n:::` blocks into Specs and
//! emitted a `custom` Element backed by a fallback "missing component"
//! placeholder. This module supplies the runtime layer that
//! transforms those Specs into real per-instance state:
//!
//!   * **Factory** — host-supplied. One per directive name. Knows how
//!     to `create` a new instance from a Spec, optionally `update` an
//!     existing instance when its Spec attrs change between parses,
//!     and optionally `deinit` it when the registry GCs it.
//!
//!   * **Instance** — internal. A registry-owned bag holding the
//!     factory-provided vtable + ctx the Element points at, plus
//!     `parses_unused` bookkeeping for the sweep+GC pass.
//!
//!   * **Registry** — owns the factories map + the instance cache
//!     (keyed by `Spec.id`, or `"auto:N"` derived from the spec's
//!     appearance index when the author didn't supply an `#id`).
//!     Methods correspond to the parse lifecycle: `beginParse` bumps
//!     "unused" counters; `resolve` is called per `:::` block during
//!     parse and resets the counter on the matching instance;
//!     `gc` (called by the host when it's safe — typically right
//!     after the new Element tree has replaced the previous one)
//!     destroys instances that have been untouched for more than
//!     `sweep_threshold` parses.
//!
//! Stage-7b deliverable: this module exists, tests cover
//! create/update/cache-hit/cache-miss/gc, and `markdown.parse` will
//! consult the registry first before falling through to the
//! placeholder. Until a host registers a factory, the demo's visual
//! output is unchanged from 7a — the infrastructure is dormant,
//! ready for stage 7c (first concrete component).
//!
//! ### Auto-ID policy
//!
//! Order-based: a Spec without explicit `#id` is cached under
//! `"auto:N"` where N is its appearance index in the source
//! (i.e. the sentinel number `<!--te:N-->`). Stable across edits
//! that don't reorder existing `:::` blocks; **not** stable when a
//! new `:::` block is inserted before existing ones — every
//! subsequent block's auto-id shifts and its cached instance gets
//! GC'd at the next sweep. Position-in-tree IDs (parent + sibling
//! index) survive that edit pattern; we'll add them when LLM-driven
//! structural rewrites prove the simple scheme isn't enough.
//!
//! ### Lifecycle ordering
//!
//! The host must NOT call `gc()` while any Element tree referencing
//! cached instance ctx pointers is still alive. The intended flow:
//!
//!     registry.beginParse();
//!     const tree = try markdown.parse(arena, src, theme, &registry);
//!     // ... swap tree pointer, free previous tree's arena ...
//!     registry.gc();   // safe now — no live Element points at any
//!                      // instance the registry is about to free.
//!
//! `markdown.parse` itself calls `beginParse`. The host calls `gc`
//! when its parse-tree swap is complete.

const std = @import("std");
const element = @import("element.zig");
const components = @import("markdown_components.zig");
const state_mod = @import("state.zig");
const spark_mod = @import("spark.zig");

pub const Error = error{
    DuplicateFactory,
    UnknownComponentId,
    NoUpdateHandler,
    /// Resolve was called before `Registry.attachSpark` — the
    /// `*Spark` pointer that factories receive isn't available.
    /// Library hosts must call `registry.attachSpark(&spark)` after
    /// constructing both, before any parse runs.
    SparkNotAttached,
} || std.mem.Allocator.Error;

// ── Pass-shape types (effects-spec Phase A.2) ──────────────────────
//
// Factory's `pass_shape` field declares what kind of GPU work this
// component contributes. `.content` (the default) is the historical
// behavior — the component layouts itself into the shared DrawList
// like every pre-effects factory does. The other arms describe shader
// dispatches the pass-graph compiler (Phase A.3+) consumes. Per-arm
// config lives on the union arm, not on Factory — `.content`-only
// factories carry no dead config slots they never read.
//
// A.3 may relocate these types into `src/pass/`. The split here is
// "types Factory needs" (this file) vs "runtime dispatch records"
// (spark.zig's PassDispatch). Both halves serialize via the same
// A.0-locked wire-format protocol; ShaderId is the shared currency.

/// 4-sided pixel inflation applied to a single-source pass's child
/// layout region — the breathing room a `:::drop_shadow` or
/// `:::frosted_glass` needs around the rasterized child for the
/// effect's spatial spread (blur radius + offset) to render without
/// clipping at the child's natural bounds.
pub const Edges = extern struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,
};

/// How a `SingleSourcePass` factory declares its layout-inflation
/// requirement. Resolved **once at create() from Spec** per Decision
/// #8 — the resulting `Edges` value is stored on the instance and
/// never re-evaluated. `.fixed` is the simple case (a built-in
/// drop_shadow with a hardcoded blur margin); `.from_params` lets
/// the factory peek at attrs to size the inflation against the
/// declared blur radius / offset. Dynamic shader-uniform changes
/// (animating the blur in real time) animate within the reserved
/// edge — they never re-trigger inflation.
pub const LayoutInflationSpec = union(enum) {
    fixed: Edges,
    from_params: *const fn (*const components.Spec) Edges,
};

/// Opaque 16-byte identifier for a shader resource. v1 is built-in
/// embedded SPIR-V — the build step (A.4) derives a stable 16-byte
/// id (e.g. content hash of the `.spv` blob, or a build-time stable
/// slot id) and that's what the pass-graph compiler records into
/// `PassDispatch.shader_id`. Hashed verbatim by the A.0 determinism
/// hasher (16 bytes, raw — see protocol comment on `spark.PassDispatch`).
///
/// Future-flex (Decision #9 — provenance ladder): remote-fetched,
/// WASM-emitted, or inference-emitted shaders may carry longer
/// underlying identifiers. If that lands, `ShaderId` can become an
/// opaque type with a `serialize() [16]u8` method (likely a content
/// hash of the longer id) — call sites that read raw bytes today
/// shift to calling `.serialize()`, the A.0 wire format stays 16
/// bytes, the protocol stays untouched. The door is open; v1 takes
/// the simple shape.
pub const ShaderId = [16]u8;

/// `.pattern` arm payload — a fragment shader with no input texture
/// drawn into the laid-out region. v1 canaries: `:::gradient`,
/// `:::pattern`, `:::noise`. Always-background of the parent region
/// per Decision #12.
pub const PatternPass = struct {
    shader_id: ShaderId,
    /// Decision #7 — v1 asserts `false`. Reserved for Phase C HDR
    /// chains. Compiler enforces this until the chain arm lights up.
    hdr_target: bool = false,
};

/// `.single_source` arm payload — child renders to an offscreen
/// target, shader filters that target, result composites back at the
/// child's region + inflation. Phase B canaries: `:::drop_shadow`,
/// `:::frosted_glass`, `:::blur`.
pub const SingleSourcePass = struct {
    shader_id: ShaderId,
    /// Decision #7 — v1 asserts `false`.
    hdr_target: bool = false,
    /// Decision #8 — resolved once at create() from Spec. `null`
    /// means no inflation (rare; pure pass-through filters). The
    /// pass-graph compiler reads this once per instance creation
    /// and caches the resulting `Edges` on the instance side.
    layout_inflation: ?LayoutInflationSpec = null,
};

/// `.chain` arm payload — reserved for Phase C. Multi-pass sequences
/// with intermediate downsampled targets, HDR format negotiation.
/// Empty in v1; the pass-graph compiler panics on this arm until
/// Phase C lights it up.
pub const ChainPass = struct {};

/// `.host_slot` arm payload — reserved in A.2, implemented in Phase
/// B alongside the `:::placeholder_scene` stub factory. The stub
/// proves `HostSlotPass.callback` end-to-end with a clear-to-color
/// callback so the arm doesn't bitrot before Phase D lights up the
/// real matryoshka adoption path (a `:::3d-scene` factory invoking
/// the host's renderer). Empty in A.2; Phase B adds the `callback`
/// field.
pub const HostSlotPass = struct {};

/// Tagged union — what kind of GPU work a factory contributes.
/// Default `.content` keeps the entire pre-effects codebase
/// compiling unchanged; new factories opt into a shader-shape by
/// setting this field.
///
/// Implementation state of each arm:
///
///   - `.content` ........... shipped (every pre-effects factory)
///   - `.pattern` ........... v1 — implements in A.5/A.6
///   - `.single_source` ..... v1 — implements in Phase B
///   - `.chain` ............. reserved, Phase C
///   - `.host_slot` ......... reserved in A.2; implements in Phase B
///                            alongside `:::placeholder_scene` stub
///
/// The pass-graph compiler (A.3+) switches exhaustively on this
/// union. Reserved arms panic with "Phase X variant not implemented
/// in v1" until their phase ships — honest failure beats silent
/// no-op, and the exhaustive switch is the documentation of which
/// arms are live.
pub const PassShape = union(enum) {
    content,
    pattern: PatternPass,
    single_source: SingleSourcePass,
    chain: ChainPass,
    host_slot: HostSlotPass,
};

/// Component factory — host-supplied per directive name. `create` is
/// called on cache miss; `update` (if non-null) is called on cache
/// hit so the instance can react to attr changes between parses;
/// `deinit` (if non-null) runs when the registry GCs the instance.
///
/// `handle_update` (stage 8a) is the micro-stream hot path: the host
/// receives a `:::update {#id action=NAME}\nBODY\n:::` directive
/// from outside (LLM stream, network, keyboard), looks up the cached
/// instance by `#id`, and calls this handler — bypassing cmark, the
/// Element walker, and any re-parse. Components opt in; the
/// dispatcher errors with `NoUpdateHandler` when called on a
/// component that didn't supply one.
///
/// `create`'s allocator is the registry's allocator (NOT the parse
/// arena) — instance state lives across many parses, so it must
/// outlive any single parse arena. `deinit` receives the same
/// allocator for symmetry.
///
/// `create` takes `*Spark` as its first arg (Phase 1 of library-spec).
/// The component captures the pointer in its instance ctx so
/// `update`/`deinit`/`handle_update` can reach engine resources
/// (registry, state, io_channel, dotenv, asset_cache, …) without
/// needing the registry to pass it again.
pub const Factory = struct {
    create: *const fn (
        spark: *spark_mod.Spark,
        allocator: std.mem.Allocator,
        spec: *const components.Spec,
    ) anyerror!Instance,
    update: ?*const fn (
        ctx: *anyopaque,
        spec: *const components.Spec,
    ) anyerror!void = null,
    deinit: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) void = null,
    handle_update: ?*const fn (
        ctx: *anyopaque,
        action: []const u8,
        body: []const u8,
    ) anyerror!void = null,

    /// What kind of GPU work this factory contributes. Default
    /// `.content` matches every pre-effects factory's behavior
    /// (rasterize into the shared DrawList); shader-shaped factories
    /// opt into `.pattern`, `.single_source`, etc. Per-arm config
    /// (shader_id, hdr_target, layout_inflation) lives on the union
    /// arm — not as parallel fields on Factory.
    pass_shape: PassShape = .content,
};

/// What a factory produces — the (vtable, ctx) pair the Element
/// holds. `ctx` is whatever per-instance state the component
/// allocates in `Factory.create`; the registry remembers it
/// verbatim and hands it back through the `custom` Element.
pub const Instance = struct {
    vtable: *const element.ElementVTable,
    ctx: *anyopaque,
};

/// What `resolve` hands back to the caller — exactly the fields a
/// `custom` Element needs. The Instance itself stays inside the
/// registry; callers only see the pointers.
pub const Resolved = struct {
    vtable: *const element.ElementVTable,
    ctx: *anyopaque,
};

/// Per-cached-instance bookkeeping kept alongside the Instance the
/// factory produced. `parses_unused` is bumped at the start of each
/// parse by `beginParse`; `resolve` resets it to 0 on a cache hit.
/// `factory_name` lets `gc` find the right factory to call `deinit`.
/// `binding` is non-null only when the directive's attrs reference
/// at least one `${path}` — it holds the templated form + the State
/// subscriber pointers we'll unsubscribe at gc time.
const Entry = struct {
    instance: Instance,
    parses_unused: u32,
    factory_name: []const u8,
    binding: ?*Binding = null,
};

/// Reactive-state plumbing for one cached component instance.
/// Allocated separately from the Entry so the Subscriber callback
/// can hold a stable `*Binding` ctx even if the registry's instance
/// map reallocates. Lifetime: created on the first resolve where
/// the templated attrs contain `${}`; destroyed when the parent
/// Entry is GC'd.
const Binding = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.State,
    factory: Factory,
    instance_ctx: *anyopaque,
    /// Templated attrs (with `${...}` literals), arena-duped into
    /// `allocator`. The Subscriber callback re-substitutes against
    /// the current state on every mutation.
    templated_attrs: []components.Attr,
    /// Subscription handles, one per distinct path referenced by
    /// `templated_attrs`. Owned by the State; we hold the pointers
    /// so we can `unsubscribe` at gc.
    subscriptions: []*state_mod.Subscriber,

    fn refire(self: *Binding) anyerror!void {
        // Build a fresh substituted Spec in a scratch arena that
        // dies when this fire returns. The factory only needs the
        // values during its `update` callback — anything it wants
        // to retain it copies into its own state.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const fresh_attrs = try a.alloc(components.Attr, self.templated_attrs.len);
        for (self.templated_attrs, 0..) |t, i| {
            fresh_attrs[i] = .{
                .key = t.key,
                .value = try components.substituteState(a, t.value, self.state),
            };
        }
        const fresh_spec = components.Spec{
            .name = "",
            .id = null,
            .attrs = fresh_attrs,
            .body = "",
        };
        if (self.factory.update) |u| try u(self.instance_ctx, &fresh_spec);
    }

    fn callback(ctx: *anyopaque) anyerror!void {
        const b: *Binding = @ptrCast(@alignCast(ctx));
        return b.refire();
    }

    fn destroy(self: *Binding) void {
        for (self.subscriptions) |sub| self.state.unsubscribe(sub);
        self.allocator.free(self.subscriptions);
        for (self.templated_attrs) |attr| {
            self.allocator.free(attr.key);
            self.allocator.free(attr.value);
        }
        self.allocator.free(self.templated_attrs);
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    factories: std.StringHashMapUnmanaged(Factory) = .{},
    instances: std.StringHashMapUnmanaged(Entry) = .{},
    /// Max consecutive parses an instance can go untouched before
    /// `gc` destroys it. Default 4 — a few parses of slack so that
    /// transient edits (block reorderings, comment toggles) don't
    /// thrash component state.
    sweep_threshold: u32 = 4,

    /// Host attaches a `*Spark` here after both the Spark instance
    /// and the Registry exist (chicken-and-egg avoided because Spark
    /// borrows the Registry, not the other way around). Resolve
    /// asserts it's non-null when called — every code path leading
    /// to `factory.create` must have a real Spark to thread through.
    spark: ?*spark_mod.Spark = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// Attach the Spark pointer. Call once after `Spark.init`.
    pub fn attachSpark(self: *Registry, spark: *spark_mod.Spark) void {
        self.spark = spark;
    }

    /// Drop all factories + destroy all cached instances. Host
    /// calls this at shutdown.
    ///
    /// Iteration discipline: an embedded-document component's
    /// `deinit_` calls `self.deinitScope(c.scope)` which mutates
    /// `self.instances` via `fetchRemove`. Iterating the map and
    /// invoking `deinit_` in the same pass would corrupt the
    /// iterator (Debug catches the mutation panic; ReleaseFast just
    /// loses entries and crashes later). Collect every key up-front,
    /// then walk the collected list and `fetchRemove` each entry
    /// before invoking its `deinit_` — same two-phase pattern
    /// `deinitScope` itself uses.
    pub fn deinit(self: *Registry) void {
        // Phase 1: snapshot every live instance key (duped so the
        // map's storage is safe to free).
        var keys = std.ArrayList([]const u8).init(self.allocator);
        defer keys.deinit();
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            keys.append(entry.key_ptr.*) catch continue;
        }

        // Phase 2: for each key, fetchRemove + destroy. Embedded
        // documents' `deinit_` may call `deinitScope` which removes
        // *more* keys; an already-removed key just returns null
        // here, harmless.
        for (keys.items) |key| {
            const entry = self.instances.fetchRemove(key) orelse continue;
            if (entry.value.binding) |b| b.destroy();
            if (self.factories.get(entry.value.factory_name)) |f| {
                if (f.deinit) |d| d(entry.value.instance.ctx, self.allocator);
            }
            self.allocator.free(entry.key);
        }
        self.instances.deinit(self.allocator);

        var fit = self.factories.iterator();
        while (fit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.factories.deinit(self.allocator);

        self.* = undefined;
    }

    /// Register a factory for a directive name. The registry takes
    /// its own copy of `name` so the caller is free to pass a
    /// literal / borrowed slice. Errors if the name is already
    /// registered (re-registration would orphan instances of the old
    /// factory — explicit unregister later if it's ever needed).
    pub fn register(self: *Registry, name: []const u8, factory: Factory) Error!void {
        const gop = try self.factories.getOrPut(self.allocator, name);
        if (gop.found_existing) return error.DuplicateFactory;
        gop.key_ptr.* = try self.allocator.dupe(u8, name);
        gop.value_ptr.* = factory;
    }

    /// Bump `parses_unused` on every cached instance. `resolve` will
    /// reset it for the ones touched during this parse; `gc` (called
    /// after the parse tree swap) destroys the still-untouched.
    pub fn beginParse(self: *Registry) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| entry.value_ptr.parses_unused += 1;
    }

    /// Resolve a `:::` block to an Instance. Returns null when no
    /// factory matches `spec.name` (caller falls back to the
    /// placeholder visual). `sentinel_idx` is the per-document
    /// position of the block — used to fabricate an `auto:N` cache
    /// key when the author didn't supply `#id`.
    ///
    /// `spec` is expected to carry **templated** attribute values
    /// (with `${path}` still literal). The registry substitutes
    /// them against `state` before invoking factory.create /
    /// factory.update, and — when `${}` references exist — sets up
    /// a Binding so subsequent state mutations refire update
    /// automatically.
    ///
    /// `scope` (stage 9) namespaces the cache key so an embedded
    /// document can hold `:::box {#bx}` without colliding with the
    /// parent doc's `:::box {#bx}`. When non-null the effective key
    /// becomes `"{scope}/{id_or_auto:N}"`. Null preserves the
    /// single-global-namespace behaviour for the top-level doc.
    pub fn resolve(
        self: *Registry,
        spec: *const components.Spec,
        sentinel_idx: usize,
        state: ?*state_mod.State,
        scope: ?[]const u8,
    ) !?Resolved {
        const factory = self.factories.get(spec.name) orelse return null;

        var key_buf: [192]u8 = undefined;
        const id: []const u8 = blk: {
            if (scope) |s| {
                if (spec.id) |sid|
                    break :blk std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ s, sid }) catch unreachable
                else
                    break :blk std.fmt.bufPrint(&key_buf, "{s}/auto:{d}", .{ s, sentinel_idx }) catch unreachable;
            }
            if (spec.id) |sid| break :blk sid;
            break :blk std.fmt.bufPrint(&key_buf, "auto:{d}", .{sentinel_idx}) catch unreachable;
        };

        // Cache-hit path first, by lookup. We can't hold a getOrPut
        // pointer across `buildEntry` / `invokeUpdate` — those can
        // recursively resolve nested `:::` blocks (e.g. inside an
        // `:::embedded-document` factory.create), which insert new
        // map entries and may rehash, invalidating any held pointer.
        // Painful lesson learned during stage 9 — dangling
        // `gop.value_ptr.*` writes after rehash corrupted the
        // newly-resized slot and the next gc tripped on garbage
        // `parses_unused`.
        if (self.instances.getPtr(id)) |entry_ptr| {
            // Factory-name change → destroy + recreate.
            if (!std.mem.eql(u8, entry_ptr.factory_name, spec.name)) {
                if (self.factories.get(entry_ptr.factory_name)) |old_factory| {
                    if (old_factory.deinit) |d|
                        d(entry_ptr.instance.ctx, self.allocator);
                }
                if (entry_ptr.binding) |b| b.destroy();
                // Build the replacement FIRST (may grow the map);
                // then look up again because entry_ptr is now stale.
                const fresh = try self.buildEntry(factory, spec, state);
                const reaq = self.instances.getPtr(id) orelse unreachable;
                reaq.* = fresh;
                return .{
                    .vtable = reaq.instance.vtable,
                    .ctx = reaq.instance.ctx,
                };
            }
            // Same factory — update path. The instance ctx pointer is
            // stable across `invokeUpdate` even if the map rehashes
            // (factories store their own state externally), but the
            // entry_ptr is not — re-acquire it before mutating
            // `parses_unused`.
            const ctx_stable = entry_ptr.instance.ctx;
            const vtable_stable = entry_ptr.instance.vtable;
            try self.invokeUpdate(factory, ctx_stable, spec, state);
            if (self.instances.getPtr(id)) |reaq| reaq.parses_unused = 0;
            return .{ .vtable = vtable_stable, .ctx = ctx_stable };
        }

        // Cache miss. Build the entry FIRST (recursive resolves grow
        // the map safely — we're holding no pointers into it). Then
        // put once via `putNoClobber`.
        const built = try self.buildEntry(factory, spec, state);
        errdefer {
            if (built.binding) |b| b.destroy();
            if (factory.deinit) |d| d(built.instance.ctx, self.allocator);
        }
        const stable_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(stable_id);
        try self.instances.putNoClobber(self.allocator, stable_id, built);
        return .{
            .vtable = built.instance.vtable,
            .ctx = built.instance.ctx,
        };
    }

    /// Substitute `spec.attrs` against `state` into a scratch arena
    /// and call `factory.update`. Used on the cache-hit path so the
    /// cached instance learns about templated attr changes between
    /// parses without being destroyed.
    fn invokeUpdate(
        self: *Registry,
        factory: Factory,
        ctx: *anyopaque,
        spec: *const components.Spec,
        state: ?*state_mod.State,
    ) !void {
        const u = factory.update orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const fresh = try buildSubstitutedSpec(a, spec, state);
        try u(ctx, &fresh);
    }

    /// Build a fresh Entry from scratch: substitute spec.attrs,
    /// call factory.create, and (when the templated attrs reference
    /// any `${path}`) construct a Binding that subscribes the
    /// callback to each path. Caller stores the returned Entry in
    /// the instances map.
    fn buildEntry(
        self: *Registry,
        factory: Factory,
        spec: *const components.Spec,
        state: ?*state_mod.State,
    ) !Entry {
        // First create the instance with substituted attrs in a
        // scratch arena — same shape as invokeUpdate.
        var create_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer create_arena.deinit();
        const ca = create_arena.allocator();
        const fresh = try buildSubstitutedSpec(ca, spec, state);
        const sp = self.spark orelse return error.SparkNotAttached;
        const inst = try factory.create(sp, self.allocator, &fresh);

        var entry: Entry = .{
            .instance = inst,
            .parses_unused = 0,
            .factory_name = self.factories.getKey(spec.name).?,
            .binding = null,
        };

        // If the spec has no `${}` references — or no state to
        // resolve against — we're done. Static directives skip the
        // entire reactive plumbing.
        if (state == null) return entry;

        // Inspect templated attrs for `${path}` references; only
        // build a Binding if there's at least one.
        var path_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer path_arena.deinit();
        const paths = try components.collectReferencedPaths(path_arena.allocator(), spec.attrs);
        if (paths.len == 0) return entry;

        // Dupe templated attrs into long-lived registry storage so
        // the subscriber callback can re-substitute on any future
        // mutation.
        const templated = try self.allocator.alloc(components.Attr, spec.attrs.len);
        errdefer self.allocator.free(templated);
        for (spec.attrs, 0..) |src, i| {
            templated[i] = .{
                .key = try self.allocator.dupe(u8, src.key),
                .value = try self.allocator.dupe(u8, src.value),
            };
        }

        const binding = try self.allocator.create(Binding);
        binding.* = .{
            .allocator = self.allocator,
            .state = state.?,
            .factory = factory,
            .instance_ctx = inst.ctx,
            .templated_attrs = templated,
            .subscriptions = &.{},
        };

        var subs = try self.allocator.alloc(*state_mod.Subscriber, paths.len);
        var i: usize = 0;
        errdefer {
            for (subs[0..i]) |s| state.?.unsubscribe(s);
            self.allocator.free(subs);
        }
        while (i < paths.len) : (i += 1) {
            subs[i] = try state.?.subscribe(paths[i], Binding.callback, @ptrCast(binding));
        }
        binding.subscriptions = subs;

        entry.binding = binding;
        return entry;
    }

    /// Look up a cached instance by explicit id. Returns null when no
    /// `:::name {#id ...}` block with that id has been resolved yet
    /// (or when its instance has been GC'd). Auto-generated `auto:N`
    /// ids are reachable too, but the intended caller is
    /// `:::update {#id ...}` dispatch which always uses author-stable
    /// ids.
    pub fn lookup(self: *Registry, id: []const u8) ?Resolved {
        const entry = self.instances.get(id) orelse return null;
        return .{ .vtable = entry.instance.vtable, .ctx = entry.instance.ctx };
    }

    /// Resolve a sibling reference inside the caller's own scope.
    /// `our_ctx` is the calling component's ctx pointer; the
    /// registry uses it to recover the caller's scope prefix (the
    /// part of its cache key before the final `/`) and then
    /// qualifies `target_id` against that scope. Falls back to a
    /// scope-less lookup when the caller can't be located or when
    /// the qualified key isn't found — covers top-level components
    /// addressing other top-level components.
    ///
    /// Used by the stage-15D `:::handle` to find its target box
    /// when both live inside the same `:::flex {#scope}`; the
    /// author writes `target=#sibling_id` instead of having to
    /// know the implicit `{scope}/sibling_id` registry path.
    ///
    /// O(n) over registry entries on a miss — fine at input
    /// frequency, callers should cache the result if they need
    /// per-frame lookups.
    pub fn lookupSibling(self: *Registry, our_ctx: *anyopaque, target_id: []const u8) ?Resolved {
        var our_scope: ?[]const u8 = null;
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.instance.ctx == our_ctx) {
                const key = entry.key_ptr.*;
                if (std.mem.lastIndexOfScalar(u8, key, '/')) |slash| {
                    our_scope = key[0..slash];
                }
                break;
            }
        }

        if (our_scope) |scope| {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/{s}", .{ scope, target_id })) |full| {
                if (self.instances.get(full)) |entry| {
                    return .{ .vtable = entry.instance.vtable, .ctx = entry.instance.ctx };
                }
            } else |_| {}
        }

        return self.lookup(target_id);
    }

    /// Dispatch one `:::update {#id action=NAME}` directive to the
    /// cached instance's `handle_update` handler. The `body` slice is
    /// passed through verbatim (caller has already trimmed surrounding
    /// whitespace via `parseUpdate`'s body-trim rule). Errors:
    ///
    ///   * `UnknownComponentId` — no live instance under `id`. The
    ///     host's previous parse may have GC'd it; caller drops.
    ///   * `NoUpdateHandler` — the factory didn't opt into updates.
    ///     Caller logs and drops at its policy.
    ///
    /// Doesn't touch `parses_unused`: update lifecycle is
    /// intentionally orthogonal to parse lifecycle. If the doc stops
    /// referencing the instance, the next gc() will sweep it and
    /// subsequent updates fall through with UnknownComponentId, which
    /// is the right behaviour — the document no longer wants this
    /// component.
    pub fn handleUpdate(
        self: *Registry,
        id: []const u8,
        action: []const u8,
        body: []const u8,
    ) anyerror!void {
        const entry = self.instances.get(id) orelse return error.UnknownComponentId;
        const factory = self.factories.get(entry.factory_name) orelse return error.UnknownComponentId;
        const handler = factory.handle_update orelse return error.NoUpdateHandler;
        try handler(entry.instance.ctx, action, body);
    }

    /// Destroy every cached instance whose key starts with
    /// `"{prefix}/"`. Used by embedded-document factories (stage 9)
    /// to tear down all of their child components when the embedded
    /// doc itself is destroyed. Without this, child instances would
    /// only get swept on the next gc pass — risky because the
    /// embedded-doc factory.deinit is about to free the child State
    /// the bindings reference.
    ///
    /// Bindings are unsubscribed (via Binding.destroy) before the
    /// instance is destroyed, so a child instance whose binding
    /// references the about-to-be-freed child State doesn't get
    /// fired during the embedded-doc's teardown.
    pub fn deinitScope(self: *Registry, prefix: []const u8) void {
        var dead = std.ArrayList([]const u8).init(self.allocator);
        defer dead.deinit();

        var sep_buf: [192]u8 = undefined;
        const search_prefix = std.fmt.bufPrint(&sep_buf, "{s}/", .{prefix}) catch return;

        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, search_prefix)) {
                dead.append(entry.key_ptr.*) catch continue;
            }
        }
        for (dead.items) |key| {
            const entry = self.instances.fetchRemove(key) orelse continue;
            if (entry.value.binding) |b| b.destroy();
            if (self.factories.get(entry.value.factory_name)) |f| {
                if (f.deinit) |d| d(entry.value.instance.ctx, self.allocator);
            }
            self.allocator.free(entry.key);
        }
    }

    /// Destroy every cached instance whose `parses_unused` exceeds
    /// `sweep_threshold`. Host calls this after swapping the new
    /// Element tree into place — at which point no live Element
    /// references the about-to-be-freed instance ctxs.
    pub fn gc(self: *Registry) void {
        // Two-pass: collect dead keys, then remove. Can't mutate the
        // map while iterating it.
        var dead = std.ArrayList([]const u8).init(self.allocator);
        defer dead.deinit();

        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.parses_unused > self.sweep_threshold) {
                dead.append(entry.key_ptr.*) catch continue;
            }
        }
        for (dead.items) |key| {
            const entry = self.instances.fetchRemove(key) orelse continue;
            if (entry.value.binding) |b| b.destroy();
            if (self.factories.get(entry.value.factory_name)) |f| {
                if (f.deinit) |d| d(entry.value.instance.ctx, self.allocator);
            }
            self.allocator.free(entry.key);
        }
    }
};

/// Allocate a fresh `Spec` whose attrs are `templated.attrs` with
/// every `${path}` resolved against `state`. The returned Spec
/// borrows the allocator; caller-supplied arenas are the natural
/// choice because the substituted attrs are consumed inside
/// factory.create / factory.update and don't outlive that call.
fn buildSubstitutedSpec(
    allocator: std.mem.Allocator,
    templated: *const components.Spec,
    state: ?*state_mod.State,
) !components.Spec {
    const fresh_attrs = try allocator.alloc(components.Attr, templated.attrs.len);
    for (templated.attrs, 0..) |src, i| {
        fresh_attrs[i] = .{
            .key = src.key,
            .value = try components.substituteState(
                allocator,
                src.value,
                if (state) |s| @as(*const state_mod.State, s) else null,
            ),
        };
    }
    return .{
        .name = templated.name,
        .id = templated.id,
        .attrs = fresh_attrs,
        .body = templated.body,
    };
}

// ── Tests ──────────────────────────────────────────────────────────
//
// Tests build a fake factory with file-scope counters (rather than
// closures over locals — Zig wants the captured pointers to be
// comptime-known) so each test can assert on create/update/deinit
// call counts. Counters are reset at the top of each test.

const testing = std.testing;

var t_creates: u32 = 0;
var t_updates: u32 = 0;
var t_deinits: u32 = 0;
var t_handle_updates: u32 = 0;
var t_last_action_buf: [64]u8 = undefined;
var t_last_action_len: usize = 0;
var t_last_body_buf: [256]u8 = undefined;
var t_last_body_len: usize = 0;

const TestState = struct {
    allocator: std.mem.Allocator,
    last_color: []u8,
};

fn testLayout(_: *anyopaque, _: [2]f32, _: element.Constraints, _: *element.LayoutCtx, _: *element.DrawList) anyerror!element.Box {
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}
const test_vtable: element.ElementVTable = .{ .layout_and_render = testLayout };

fn pickColor(spec: *const components.Spec) ?[]const u8 {
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "color")) return a.value;
    }
    return null;
}

fn testCreate(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!Instance {
    _ = spark; // tests don't dereference spark fields
    t_creates += 1;
    const state = try allocator.create(TestState);
    // Real components own their state — copy the value into our own
    // allocator-owned memory. The Spec's strings live in scratch
    // memory the registry frees after `create` returns.
    state.* = .{
        .allocator = allocator,
        .last_color = try allocator.dupe(u8, pickColor(spec) orelse ""),
    };
    return .{ .vtable = &test_vtable, .ctx = @ptrCast(state) };
}
fn testUpdate(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    t_updates += 1;
    const state: *TestState = @ptrCast(@alignCast(ctx));
    if (pickColor(spec)) |c| {
        state.allocator.free(state.last_color);
        state.last_color = try state.allocator.dupe(u8, c);
    }
}
fn testDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    t_deinits += 1;
    const state: *TestState = @ptrCast(@alignCast(ctx));
    allocator.free(state.last_color);
    allocator.destroy(state);
}
fn testHandleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    t_handle_updates += 1;
    t_last_action_len = @min(action.len, t_last_action_buf.len);
    @memcpy(t_last_action_buf[0..t_last_action_len], action[0..t_last_action_len]);
    t_last_body_len = @min(body.len, t_last_body_buf.len);
    @memcpy(t_last_body_buf[0..t_last_body_len], body[0..t_last_body_len]);
    // Mirror into the component's state so tests can assert end-to-end.
    if (std.mem.eql(u8, action, "set-color")) {
        const state: *TestState = @ptrCast(@alignCast(ctx));
        state.allocator.free(state.last_color);
        state.last_color = try state.allocator.dupe(u8, body);
    }
}
const test_factory: Factory = .{
    .create = testCreate,
    .update = testUpdate,
    .deinit = testDeinit,
    .handle_update = testHandleUpdate,
};

fn resetCounters() void {
    t_creates = 0;
    t_updates = 0;
    t_deinits = 0;
    t_handle_updates = 0;
    t_last_action_len = 0;
    t_last_body_len = 0;
}

test "register + resolve creates instance once" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    const r1 = try registry.resolve(&spec, 0, null, null);
    try testing.expect(r1 != null);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_updates);

    registry.beginParse();
    const r2 = try registry.resolve(&spec, 0, null, null);
    try testing.expect(r2 != null);
    try testing.expectEqual(r1.?.ctx, r2.?.ctx);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 1), t_updates);
}

test "resolve returns null for unregistered name" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    const spec: components.Spec = .{ .name = "nothing", .id = "x" };
    const r = try registry.resolve(&spec, 0, null, null);
    try testing.expect(r == null);
}

test "auto-id is order-based" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const a: components.Spec = .{ .name = "box" }; // no id → auto:5
    const r1 = try registry.resolve(&a, 5, null, null);
    registry.beginParse();
    const r2 = try registry.resolve(&a, 5, null, null);
    try testing.expectEqual(r1.?.ctx, r2.?.ctx);

    // Different sentinel idx with same name → different cache slot.
    const r3 = try registry.resolve(&a, 6, null, null);
    try testing.expect(r1.?.ctx != r3.?.ctx);
    try testing.expectEqual(@as(u32, 2), t_creates);
}

test "gc destroys after sweep_threshold consecutive unused parses" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    registry.sweep_threshold = 2;
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    _ = try registry.resolve(&spec, 0, null, null);
    try testing.expectEqual(@as(u32, 1), t_creates);

    // Threshold=2 → instance dies on the third unused parse.
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 0), t_deinits);
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 0), t_deinits);
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 1), t_deinits);

    _ = try registry.resolve(&spec, 0, null, null);
    try testing.expectEqual(@as(u32, 2), t_creates);
}

test "factory name change destroys old + recreates" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);
    try registry.register("chart", test_factory);

    // Auto-id collision when the spec at sentinel 0 changes name
    // across parses — e.g. an edit turning `:::box` into `:::chart`.
    const as_box: components.Spec = .{ .name = "box" };
    _ = try registry.resolve(&as_box, 0, null, null);
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_deinits);

    registry.beginParse();
    const as_chart: components.Spec = .{ .name = "chart" };
    _ = try registry.resolve(&as_chart, 0, null, null);
    try testing.expectEqual(@as(u32, 2), t_creates);
    try testing.expectEqual(@as(u32, 1), t_deinits);
}

test "update sees latest spec attrs" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const attrs_red = [_]components.Attr{.{ .key = "color", .value = "red" }};
    const spec_red: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs_red };
    const r1 = try registry.resolve(&spec_red, 0, null, null);
    {
        const state: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("red", state.last_color);
    }

    registry.beginParse();
    const attrs_blue = [_]components.Attr{.{ .key = "color", .value = "blue" }};
    const spec_blue: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs_blue };
    _ = try registry.resolve(&spec_blue, 0, null, null);
    {
        const state: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("blue", state.last_color);
    }
}

test "reactive: state.set fires factory.update on bound component" {
    resetCounters();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    try st.set("box_color", "red");

    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const attrs = [_]components.Attr{.{ .key = "color", .value = "${state.box_color}" }};
    const spec: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs };

    // Initial resolve substitutes — factory.create sees "red".
    const r1 = try registry.resolve(&spec, 0, &st, null);
    {
        const tst: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("red", tst.last_color);
    }
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 0), t_updates);

    // State mutation fires the binding's subscriber → factory.update.
    try st.set("box_color", "green");
    try testing.expectEqual(@as(u32, 1), t_creates);
    try testing.expectEqual(@as(u32, 1), t_updates);
    {
        const tst: *TestState = @ptrCast(@alignCast(r1.?.ctx));
        try testing.expectEqualStrings("green", tst.last_color);
    }

    // An unrelated path mutation doesn't fire.
    try st.set("unrelated", "x");
    try testing.expectEqual(@as(u32, 1), t_updates);
}

test "scoped resolve namespaces cache keys" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };

    // Same #id under different scopes -> two distinct instances.
    const r_top = try registry.resolve(&spec, 0, null, null);
    const r_a = try registry.resolve(&spec, 0, null, "embed:a");
    const r_b = try registry.resolve(&spec, 0, null, "embed:b");
    try testing.expectEqual(@as(u32, 3), t_creates);
    try testing.expect(r_top.?.ctx != r_a.?.ctx);
    try testing.expect(r_a.?.ctx != r_b.?.ctx);

    // Cache hit within the same scope reuses.
    registry.beginParse();
    const r_a_again = try registry.resolve(&spec, 0, null, "embed:a");
    try testing.expectEqual(@as(u32, 3), t_creates);
    try testing.expectEqual(r_a.?.ctx, r_a_again.?.ctx);
}

test "scoped resolve: auto:N + scope" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box" }; // no id -> auto:N
    _ = try registry.resolve(&spec, 0, null, "child");
    _ = try registry.resolve(&spec, 0, null, null);
    try testing.expectEqual(@as(u32, 2), t_creates); // scoped vs unscoped are distinct
}

test "deinitScope destroys only matching instances" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const spec_top: components.Spec = .{ .name = "box", .id = "top" };
    const spec_inner: components.Spec = .{ .name = "box", .id = "inner" };
    _ = try registry.resolve(&spec_top, 0, null, null);
    _ = try registry.resolve(&spec_inner, 0, null, "child");
    _ = try registry.resolve(&spec_inner, 1, null, "other");
    try testing.expectEqual(@as(u32, 3), t_creates);
    try testing.expectEqual(@as(u32, 0), t_deinits);

    registry.deinitScope("child");
    try testing.expectEqual(@as(u32, 1), t_deinits);

    // Top-level + "other"'s instance survive.
    try testing.expect(registry.lookup("top") != null);
    try testing.expect(registry.lookup("other/inner") != null);
    try testing.expect(registry.lookup("child/inner") == null);
}

test "lookup returns null for unknown id" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try testing.expect(registry.lookup("nope") == null);
}

test "lookup returns the resolved instance once it exists" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    const r = try registry.resolve(&spec, 0, null, null);
    const looked = registry.lookup("bx").?;
    try testing.expectEqual(r.?.ctx, looked.ctx);
}

test "handleUpdate dispatches to factory handle_update" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    _ = try registry.resolve(&spec, 0, null, null);
    try testing.expectEqual(@as(u32, 1), t_creates);

    try registry.handleUpdate("bx", "set-color", "orange");
    try testing.expectEqual(@as(u32, 1), t_handle_updates);
    try testing.expectEqualStrings("set-color", t_last_action_buf[0..t_last_action_len]);
    try testing.expectEqualStrings("orange", t_last_body_buf[0..t_last_body_len]);
}

test "handleUpdate: unknown id errors" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    try registry.register("box", test_factory);
    try testing.expectError(error.UnknownComponentId, registry.handleUpdate("missing", "set-color", "red"));
}

test "handleUpdate: factory without handler errors" {
    resetCounters();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    const no_handler: Factory = .{
        .create = testCreate,
        .update = testUpdate,
        .deinit = testDeinit,
        // handle_update intentionally null
    };
    try registry.register("box", no_handler);

    const spec: components.Spec = .{ .name = "box", .id = "bx" };
    _ = try registry.resolve(&spec, 0, null, null);
    try testing.expectError(error.NoUpdateHandler, registry.handleUpdate("bx", "set-color", "red"));
}

test "reactive: gc unsubscribes the binding" {
    resetCounters();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    try st.set("c", "red");

    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    var test_spark = spark_mod.Spark.testStub(testing.allocator);
    registry.attachSpark(&test_spark);
    registry.sweep_threshold = 0; // die after one unused parse
    try registry.register("box", test_factory);

    const attrs = [_]components.Attr{.{ .key = "color", .value = "${c}" }};
    const spec: components.Spec = .{ .name = "box", .id = "bx", .attrs = &attrs };
    _ = try registry.resolve(&spec, 0, &st, null);
    try testing.expectEqual(@as(u32, 1), t_creates);

    // Parse without re-resolving → entry hits sweep, gc destroys it
    // including the binding (and its subscription).
    registry.beginParse();
    registry.gc();
    try testing.expectEqual(@as(u32, 1), t_deinits);

    // State mutation no longer fires anything (subscription was
    // soft-deleted at gc).
    try st.set("c", "blue");
    try testing.expectEqual(@as(u32, 0), t_updates);
}

// ── Phase A.2 pass-shape tests ─────────────────────────────────────

test "Factory defaults to .content pass_shape" {
    // Anonymous-literal factory declarations across the codebase
    // (box.zig, grid.zig, …) don't mention pass_shape — A.2's
    // addition is non-breaking only as long as `.content` is the
    // field default. This test pins that contract so a future change
    // that drops the default fails here, not in 20 unrelated files.
    const f: Factory = .{
        .create = stub_create,
    };
    try testing.expectEqual(PassShape.content, f.pass_shape);
}

test "PassShape constructs in every variant" {
    // Compile-time check that each arm is reachable. Effect factories
    // from A.5 onward construct via these constructor sites; if a
    // future edit renames an arm, the test breaks loudly.
    const noop_inflation: LayoutInflationSpec = .{ .fixed = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } };
    const sid: ShaderId = [_]u8{0} ** 16;

    const shapes = [_]PassShape{
        .content,
        .{ .pattern = .{ .shader_id = sid } },
        .{ .single_source = .{ .shader_id = sid, .layout_inflation = noop_inflation } },
        .{ .chain = .{} },
        .{ .host_slot = .{} },
    };
    try testing.expectEqual(@as(usize, 5), shapes.len);
}

test "PassShape switches exhaustively" {
    // The pass-graph compiler (A.3+) will switch on PassShape and
    // dispatch per arm. This test stands in for that switch site at
    // A.2 time — proves the union is exhaustively matchable and
    // locks the arm names. When the compiler lands, the real switch
    // replaces this stub.
    const sid: ShaderId = [_]u8{0} ** 16;
    const cases = [_]PassShape{
        .content,
        .{ .pattern = .{ .shader_id = sid } },
        .{ .single_source = .{ .shader_id = sid } },
        .{ .chain = .{} },
        .{ .host_slot = .{} },
    };
    for (cases) |shape| {
        const tag: []const u8 = switch (shape) {
            .content => "content",
            .pattern => "pattern",
            .single_source => "single_source",
            .chain => "chain",
            .host_slot => "host_slot",
        };
        try testing.expect(tag.len > 0);
    }
}

test "LayoutInflationSpec.from_params resolves at create time" {
    // Decision #8 contract: from_params evaluates once at create()
    // from the Spec. This test exercises that function-pointer arm
    // — the resolver-style API the spec calls out — to prove it
    // compiles and behaves as a normal Zig function pointer.
    const helpers = struct {
        fn computeEdges(spec: *const components.Spec) Edges {
            _ = spec;
            return .{ .left = 4, .right = 4, .top = 8, .bottom = 8 };
        }
    };
    const spec_inflation: LayoutInflationSpec = .{ .from_params = helpers.computeEdges };
    const dummy_spec: components.Spec = .{ .name = "test" };
    const edges = switch (spec_inflation) {
        .fixed => |e| e,
        .from_params => |f| f(&dummy_spec),
    };
    try testing.expectEqual(@as(f32, 4), edges.left);
    try testing.expectEqual(@as(f32, 8), edges.top);
}

fn stub_create(
    spark: *spark_mod.Spark,
    allocator: std.mem.Allocator,
    spec: *const components.Spec,
) anyerror!Instance {
    _ = spark;
    _ = allocator;
    _ = spec;
    return error.UnknownComponentId;
}
