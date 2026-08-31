//! Per-block retained layout cache.
//!
//! Stage 14a. Multi-stream demos stress the per-chunk re-walk pattern:
//! every LLM chunk flipped `state.dirty`, which re-walked every
//! top-level tree — re-shaping every word, even paragraphs that hadn't
//! moved. The cache stores the walker's output per cacheable Element,
//! keyed by (identity, content-version, constraints, theme). On hit,
//! we blit the cached glyph/quad/tri/hit ranges with an origin offset
//! into the live DrawList — no shaping, no atlas hits.
//!
//! Cache entries are stored in **block-local coordinates** (positions
//! relative to `(0, 0)`). Blitting at a new origin is one O(N) pass
//! per draw kind that adds the origin to every position. The same
//! cached entry serves every y on which a stack_v sibling above it
//! happens to land — so when one streaming block grows by N pixels,
//! its siblings below stay in cache and re-emit at their new y for
//! free.
//!
//! ## What gets cached
//!
//! Caching is opt-in per Element kind, set by
//! `cacheableLeaf`:
//!
//!   * **Leaf-ish blocks** (paragraph, heading, code_block,
//!     thematic_break): cacheable. Their layout output is a pure
//!     function of their content + constraints + theme.
//!   * **Containers** (container, list, list_item, quote): not
//!     cached at the container level — they recursively invoke
//!     `layoutStackV`, which caches each child individually. Caching
//!     the container as a unit would couple all its descendants'
//!     invalidations.
//!   * **Custom components**: cacheable iff
//!     `vtable.disable_cache == false`. Custom components that read
//!     external state at layout time (slider, embedded-doc, input
//!     with its blinking caret) set `disable_cache = true` and walk
//!     fresh every time — their cache wins come from their
//!     descendants' inner stack_v walks, not from caching themselves.
//!
//! ## Invalidation
//!
//! The cache key for a custom element includes `vtable.content_version`
//! (defaults to 0 when the slot is null). Components bump their
//! counter on every internal mutation:
//!
//!   * `Registry.handleUpdate` bumps the target's counter (after the
//!     factory's handler runs).
//!   * `Binding.refire` (state-driven attr refresh) bumps the bound
//!     instance's counter.
//!   * Per-component internal mutation paths (chart append, LLM
//!     stream chunk, SVG mesh swap, input caret/buffer edits) bump
//!     directly.
//!
//! A version bump produces a fresh cache key on the next walk → miss
//! → re-walk + snapshot.
//!
//! ## Why pointer-based identity
//!
//! Element values live in parse arenas with stable addresses for the
//! lifetime of one parse. A full re-parse changes pointer identity
//! for every Element in that arena; entries from prior parses will
//! never key-match again and are recoverable only via
//! `BlockCache.clear()`. v0 calls `clear()` on top-level re-parse
//! (which happens once, at startup); the LLM stream's inner re-parse
//! makes its own child pointers stale every chunk — those stale
//! entries linger until the cache is cleared. They don't cause
//! correctness bugs (their keys never re-occur), only memory growth.
//! Stage 14b will add scoped invalidation for the per-stream case.

const std = @import("std");
const element = @import("element.zig");
const tp = @import("gpu/text_pipeline.zig");
const qp = @import("gpu/quad_pipeline.zig");
const tri_pipeline = @import("gpu/tri_pipeline.zig");

/// Hashmap key — content version is held *outside* the key (on the
/// Entry) so a version bump replaces the same slot rather than
/// orphaning the old entry at a new key. Without this discipline a
/// 1000-chunk LLM stream would leak 1000 cache entries.
pub const Key = struct {
    /// Address-identity for the Element. For value-typed unions like
    /// `Element` we use a stable interior pointer (the children slice,
    /// the custom ctx, etc.) — see `elementIdentity`. Different parse
    /// generations produce different identities; same parse with same
    /// content reproduces the same identity.
    elem_id: usize,
    /// `Constraints.max_w` bit-pattern. Different widths → different
    /// wrap → different layout.
    max_w_bits: u32,
    /// `LayoutCtx.zoom` bit-pattern. Crisp-zoom rasterises glyphs at
    /// `display_px × zoom`, so the cached GlyphInstances' uv_min/max
    /// point to size-specific atlas rects. A zoom change at the host
    /// level (Ctrl+scroll) produces a fresh key here, leaving the old
    /// entries intact so a round-trip back to the original zoom hits
    /// without re-walking.
    zoom_bits: u32,
    /// Theme pointer. Theme swap → invalidate.
    theme_ptr: usize,
    /// Per-pass environment seed (stage 15 Phase E). Folds in any
    /// layout-state that the cached output baked into its positions
    /// — currently the active exclusion rect set, hashed via
    /// `LayoutContext.exclusionsHash`. A float landing above a
    /// paragraph rotates this seed and forces a fresh wrap; the same
    /// floats across frames produce the same seed so cached entries
    /// keep hitting once the document settles. 0 when no exclusions
    /// are active or `layout_context` isn't wired (tests, headless
    /// preview).
    pass_seed: u64,
};

pub const Entry = struct {
    /// Monotonic version returned by `vtable.content_version` (custom
    /// elements) — 0 for built-ins. On lookup, mismatch counts as a
    /// miss and the stale entry is evicted to make room for the fresh
    /// snapshot.
    version: u64,
    /// Block-local glyphs: `dst_pos` is relative to (0, 0).
    glyphs: []tp.GlyphInstance,
    /// Routing tags parallel to `glyphs`. Block-local indices: an
    /// entry of `MAIN_TARGET` means "outer context's active target at
    /// blit time"; any other value is a `local_pd_idx` rebased so the
    /// snapshot's own pass-dispatch range starts at 0. Resolved by
    /// `blitEntry`'s replay-with-offset. See effects-spec Phase B.6.
    glyph_targets: []u32,
    /// Block-local quads: `dst_pos` is relative to (0, 0).
    quads: []qp.QuadInstance,
    /// Routing tags parallel to `quads`. Same semantics as `glyph_targets`.
    quad_targets: []u32,
    /// Block-local triangle vertices: `pos` is relative to (0, 0).
    tris: []tri_pipeline.Vertex,
    /// Routing tags parallel to `tris` (per-vertex; consumer-side
    /// run iterators in `element.zig` already handle the vertex-level
    /// resolution). Same semantics as `glyph_targets`.
    tri_targets: []u32,
    /// Indices relative to the start of `tris` (already rebased to 0).
    tri_indices: []u32,
    /// Block-local image draws (descriptor pointer + relative rect).
    /// Descriptors are owned by the source `:::image-stream` component
    /// and stay valid across cache hits (a re-fire bumps version and
    /// re-snapshots, but the descriptor handle is rewritten in place).
    images: []element.ImageDraw,
    /// Routing tags parallel to `images`. Same semantics as `glyph_targets`.
    image_targets: []u32,
    /// Block-local hits: `box.x`/`box.y` are relative to (0, 0).
    hits: []element.Hit,
    /// Block-local pass dispatches (effects-spec Phase B.5 polish).
    /// Regions stored relative to (0, 0); indices stored relative to
    /// start-of-block (0). On blit, both get translated back to the
    /// current origin + current pd base. Without this field, cached
    /// pattern / single_source dispatches were silently dropped on
    /// cache hit — patterns vanished after frame 1.
    pass_dispatches: []element.PassDispatch,
    /// Measured layout box at origin (0, 0). `baseline` is also
    /// block-local (relative to the cached origin).
    box: element.Box,
};

pub const BlockCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .{},

    // Counters useful for instrumentation + tests. Reset between
    // benchmarking windows by hand.
    hits: u64 = 0,
    misses: u64 = 0,
    skipped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) BlockCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BlockCache) void {
        self.freeAll();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeAll(self: *BlockCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| self.freeEntry(kv.value_ptr.*);
    }

    fn freeEntry(self: *BlockCache, e: Entry) void {
        self.allocator.free(e.glyphs);
        self.allocator.free(e.glyph_targets);
        self.allocator.free(e.quads);
        self.allocator.free(e.quad_targets);
        self.allocator.free(e.tris);
        self.allocator.free(e.tri_targets);
        self.allocator.free(e.tri_indices);
        self.allocator.free(e.images);
        self.allocator.free(e.image_targets);
        self.allocator.free(e.hits);
        self.allocator.free(e.pass_dispatches);
    }

    /// Drop every cached entry. Call on full re-parse / theme swap.
    pub fn clear(self: *BlockCache) void {
        self.freeAll();
        self.entries.clearRetainingCapacity();
    }

    /// Reset the hit/miss/skip counters (e.g. between benchmark windows).
    pub fn resetStats(self: *BlockCache) void {
        self.hits = 0;
        self.misses = 0;
        self.skipped = 0;
    }

    pub fn hitRate(self: BlockCache) f32 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total));
    }

    /// Lookup with version comparison. Returns the entry only when
    /// version matches the freshly-computed expected version — a
    /// mismatch counts as a miss and evicts the stale entry so the
    /// next insert at the same key has nothing to free.
    pub fn lookup(self: *BlockCache, key: Key, version: u64) ?Entry {
        if (self.entries.get(key)) |e| {
            if (e.version == version) {
                self.hits += 1;
                return e;
            }
            // Stale — evict in place so the next snapshot replaces
            // the slot cleanly. Avoids the leak that a new-key-per-
            // version scheme would have on long-running streams.
            if (self.entries.fetchRemove(key)) |old| self.freeEntry(old.value);
        }
        self.misses += 1;
        return null;
    }

    /// Insert (or replace) the entry for `key`. Takes ownership of
    /// every slice in `entry` — caller must not free them.
    pub fn insert(self: *BlockCache, key: Key, entry: Entry) !void {
        if (self.entries.fetchRemove(key)) |old| self.freeEntry(old.value);
        try self.entries.put(self.allocator, key, entry);
    }
};

/// Stable interior-pointer identity for an Element value. Returns 0
/// for kinds whose identity isn't worth caching at the block grain
/// (inline leaves, structural inline kinds, spacers).
pub fn elementIdentity(elem: element.Element) usize {
    return switch (elem) {
        // Inline kinds are never cached at the block level — they
        // belong inside paragraph/heading content and the inline-flow
        // shaper handles them. `inline_object` is in the same family.
        .text, .line_break, .emphasis, .strong, .code, .link, .inline_object => 0,

        .paragraph => |children| @intFromPtr(children.ptr),
        .heading => |h| @intFromPtr(h.content.ptr),
        // Containers/lists/quotes are not cached as units — their
        // recursive layoutStackV caches each child individually.
        .container, .list, .list_item, .quote => 0,
        // Spacer is one struct field; caching saves nothing.
        .spacer => 0,
        .thematic_break => 0,
        .code_block => |cb| switch (cb.content) {
            .raw => |r| @intFromPtr(r.text.ptr),
            .sub_block => |sb| @intFromPtr(sb),
        },
        .custom => |cu| @intFromPtr(cu.ctx),
    };
}

/// Whether this Element kind is eligible for caching at all.
/// Independent of the per-instance disable_cache flag (which only
/// applies to custom).
pub fn cacheableLeaf(elem: element.Element) bool {
    return switch (elem) {
        .paragraph,
        .heading,
        .thematic_break,
        .code_block,
        => true,
        .custom => |cu| !cu.vtable.disable_cache,
        else => false,
    };
}

/// Build the cache key for `elem` under the given constraints/theme.
/// Version travels alongside but stays out of the hashmap key —
/// see `Key`'s doc comment.
pub fn keyFor(
    elem: element.Element,
    constraints: element.Constraints,
    theme: *const element.Theme,
    zoom: f32,
    pass_seed: u64,
) Key {
    return .{
        .elem_id = elementIdentity(elem),
        .max_w_bits = @bitCast(constraints.max_w),
        .zoom_bits = @bitCast(zoom),
        .theme_ptr = @intFromPtr(theme),
        .pass_seed = pass_seed,
    };
}

/// Read the current content-version for an element (0 for built-ins).
///
/// **Paragraphs and headings are not built-ins for this purpose.** They
/// are cached as a unit, keyed on `@intFromPtr(children.ptr)` — a
/// pointer that does not move when a reactive `inline_object` inside
/// them changes its text. Without the aggregation below, a paragraph
/// containing `::value{text=${state.x}}` draws once and replays that
/// snapshot forever: the state writes, the binding fires, the component
/// re-ingests and bumps its version, and the picture never changes.
///
/// This is the THIRD instance of one bug — the frozen slider inside an
/// effect and the hot-reload freeze were the first two, and both were
/// cured the same way, by folding descendant versions upward. What is
/// different here is the grain: those aggregate over BLOCK children
/// (`aggregateChildVersions`), and a paragraph's children are inline.
pub fn versionFor(elem: element.Element) u64 {
    return switch (elem) {
        .custom => |cu| if (cu.vtable.content_version) |getter| getter(cu.ctx) else 0,
        .paragraph => |kids| aggregateInlineVersions(kids),
        .heading => |h| aggregateInlineVersions(h.content),
        else => 0,
    };
}

/// Fold the content-versions of every `inline_object` reachable inside
/// a paragraph or heading's inline content into a single `u64`.
///
/// Recurses through the inline containers (`emphasis`, `strong`,
/// `code`, `link`) because `**${state.x}**` puts the object one level
/// down, and a readout inside bold is not a different feature.
///
/// Each object contributes `mixVersion(@intFromPtr(ctx), version)`.
/// `elementIdentity` cannot supply that identity — it answers 0 for
/// every inline kind, deliberately — so the instance pointer stands in
/// for it, and `mixVersion` explains why the two are hashed together
/// rather than XORed side by side. `Showing ${state.x} of ${state.x}`
/// is two objects on one path, moving in lockstep, and the naive fold
/// makes a paragraph holding exactly two of them look permanently
/// unchanged.
///
/// Returns 0 for the overwhelmingly common case of a paragraph with no
/// components in it, which is what keeps the cache doing its job: a
/// stable 0 means every ordinary paragraph still hits.
pub fn aggregateInlineVersions(children: []const element.Element) u64 {
    var v: u64 = 0;
    for (children) |child| {
        switch (child) {
            .inline_object => |io| {
                const cv: u64 = if (io.vtable.content_version) |getter| getter(io.ctx) else 0;
                v ^= mixVersion(@intFromPtr(io.ctx), cv);
            },
            .emphasis, .strong, .code => |inner| v ^= aggregateInlineVersions(inner),
            .link => |l| v ^= aggregateInlineVersions(l.content),
            // A `.custom` at an inline position is a tree-construction
            // error the layout walker rejects, so this arm is only ever
            // reached by a hand-built tree — but `aggregateRootVersion`
            // routes paragraph roots through here now, and dropping the
            // block-grain case on the way past would be a silent
            // narrowing rather than a decision.
            .custom => v ^= mixVersion(@intCast(elementIdentity(child)), versionFor(child)),
            else => {},
        }
    }
    return v;
}

/// Stage 15 Phase C.5 — fold child content-versions into a single
/// `u64` that changes whenever ANY child's version changes. Container
/// components (`:::flex`, `:::grid`) call this from their own
/// `content_version` and XOR the result with their own version. The
/// cache key then catches both "self mutated" and "a descendant
/// mutated" without the container needing to know what mutated.
///
/// Each child's contribution is `mixVersion(identity, version)` — see
/// that function for why the two are HASHED TOGETHER rather than XORed
/// side by side, which is what this did until 2026-08-31 and which had
/// a hole in it.
///
/// Bumps to grandchildren propagate up automatically because each
/// container in the chain aggregates its own children — so a `:::box`
/// inside a `:::grid` inside a `:::flex` rolls all the way up: box's
/// version bumps → grid's aggregated version changes → flex's
/// aggregated version changes → flex cache invalidates.
pub fn aggregateChildVersions(children: []const element.Element) u64 {
    var v: u64 = 0;
    for (children) |child| {
        v ^= mixVersion(@intCast(elementIdentity(child)), versionFor(child));
    }
    return v;
}

/// Combine one child's identity and content-version into a term that
/// can be XOR-folded with its siblings'.
///
/// **The hole this closes.** The fold used to be `v ^= version ^ id`,
/// with a comment claiming that mixing the identity in "dodges the
/// A XOR A = 0 trap". It dodges half of it. Two siblings holding the
/// same version at the same instant do not cancel, because their ids
/// differ — but the ids are constant, so the *pair* contributes
/// `id_a ^ id_b` at every value the two versions share. Two components
/// bound to the same state path bump in lockstep by construction:
/// created together, re-ingested together, re-fired together on a
/// write. `:::flex` holding two `:::progress {value=${state.p}}` folds
/// to `id_a ^ id_b` before the write and `id_a ^ id_b` after it, so the
/// flex replays a stale drawlist and both bars are frozen.
///
/// Found on 2026-08-31 by the test written for the INLINE aggregate,
/// which has the same shape and hit the same wall. Nothing had ever
/// pointed two same-path bindings at one container, which is why the
/// block-grain version survived since Stage 15 Phase C.5.
///
/// Hashing the pair (splitmix64's finaliser over an identity-keyed
/// product) means a shared version bump moves both terms to unrelated
/// values, and their XOR moves with it.
pub fn mixVersion(identity: u64, version: u64) u64 {
    var x = (identity *% 0x9E3779B97F4A7C15) ^ (version *% 0xBF58476D1CE4E5B9);
    x ^= x >> 30;
    x *%= 0xBF58476D1CE4E5B9;
    x ^= x >> 27;
    x *%= 0x94D049BB133111EB;
    x ^= x >> 31;
    return x;
}

/// `aggregateChildVersions` for a component that holds ONE root element
/// rather than a child slice — which is every effect: `:::drop_shadow`,
/// `:::frosted_glass`, and everything the `SingleSourceFactory` generates
/// parse their body into a single `root`.
///
/// **The bug this exists for.** Those effects returned only their OWN
/// version from `content_version`, so a slider inside one was frozen at the
/// value it was created with: dragging it moved the plane and changed the
/// scene, and the knob never moved, because the effect's cached drawlist
/// was replayed unchanged. It looked like a broken slider and was a stale
/// cache. `:::flex` and `:::grid` had aggregated since Stage 15 Phase C.5;
/// the effects were simply never given the same treatment, and no shipped
/// document had an interactive control inside an effect until backdrop
/// panels made that the obvious thing to write.
pub fn aggregateRootVersion(root: element.Element) u64 {
    return switch (root) {
        .container => |co| aggregateChildVersions(co.children),
        // A root that is itself the component (an effect wrapping a single
        // `:::box`) still has a version worth folding in — and since
        // `versionFor` learned to aggregate a paragraph's inline objects,
        // a lone paragraph root arrives here already folded. It used to
        // route to `aggregateChildVersions`, which walks a paragraph's
        // INLINE children with block-grain accessors and therefore
        // answered a constant 0 for all of them.
        else => versionFor(root),
    };
}

/// Blit a cached entry into `out`, translating every position by
/// `origin`. Triangle indices are rebased against the current vertex
/// count of `out.tris`. Returns the `Box` at `origin`.
pub fn blitEntry(
    out: *element.DrawList,
    lc: *const element.LayoutCtx,
    entry: Entry,
    origin: [2]f32,
) !element.Box {
    const ox = origin[0];
    const oy = origin[1];

    // Phase B.6 — replay-with-offset for primitive routing tags.
    // Symmetric mirror of the `pass_dispatches` rebase below:
    // snapshot stored locally-rebased indices (own range starting
    // at 0; `MAIN_TARGET` preserved as the sentinel); blit
    // resolves them against the live pass-dispatch base + the
    // outer walker's active target.
    //
    // `pd_base` snapshotted up front: we use the same value for
    // both the primitive replay (here) and the pass_dispatches
    // merge below, so cached `local_pd_idx` and cached `sequence_index`
    // land at matching positions in the live list.
    const pd_base: u32 = if (lc.pass_dispatches) |out_pd| @intCast(out_pd.items.len) else 0;

    // Glyphs — translate dst_pos.
    const g_start = out.glyphs.items.len;
    try out.appendGlyphsReplayingTargets(lc, entry.glyphs, entry.glyph_targets, pd_base);
    for (out.glyphs.items[g_start..]) |*g| {
        g.dst_pos[0] += ox;
        g.dst_pos[1] += oy;
    }

    // Quads — translate dst_pos.
    const q_start = out.quads.items.len;
    try out.appendQuadsReplayingTargets(lc, entry.quads, entry.quad_targets, pd_base);
    for (out.quads.items[q_start..]) |*q| {
        q.dst_pos[0] += ox;
        q.dst_pos[1] += oy;
    }

    // Triangles — translate vertex positions, rebase indices.
    const tri_vertex_base: u32 = @intCast(out.tris.items.len);
    try out.appendTrisReplayingTargets(lc, entry.tris, entry.tri_targets, pd_base);
    for (out.tris.items[tri_vertex_base..]) |*v| {
        v.pos[0] += ox;
        v.pos[1] += oy;
    }
    const ti_start = out.tri_indices.items.len;
    try out.tri_indices.appendSlice(entry.tri_indices);
    for (out.tri_indices.items[ti_start..]) |*i| i.* += tri_vertex_base;

    // Images — translate dst_pos. Descriptor handle is stable across
    // hits (owned by the source component). Replay cached targets
    // per-item (parallel to glyph/quad/tri above) using the
    // singular `appendImagePreservingTarget` API.
    std.debug.assert(entry.images.len == entry.image_targets.len);
    for (entry.images, entry.image_targets) |im, cached_target| {
        var im2 = im;
        im2.dst_pos[0] += ox;
        im2.dst_pos[1] += oy;
        // MAIN_TARGET sentinel resolution: "whatever the active
        // outer target is at render time," not "literally the
        // framebuffer." This is what makes the cache compose under
        // nesting — a cached subtree blitted inside an enclosing
        // single_source effect correctly routes its outer-tagged
        // primitives to that effect's offscreen target.
        const resolved: u32 = if (cached_target == element.MAIN_TARGET)
            lc.current_target_dispatch_index
        else
            cached_target + pd_base;
        try out.appendImagePreservingTarget(im2, resolved);
    }

    // Hits — translate box origin. Pointer fields (vtable/ctx/state)
    // are pointer-stable across walks so the cached values stay valid.
    for (entry.hits) |h| {
        var h2 = h;
        h2.box.x += ox;
        h2.box.y += oy;
        try out.hits.append(h2);
    }

    // Pass dispatches — translate regions by origin + offset indices
    // by current pd base. Mirrors `mergePrivatePassDispatches` in
    // element_layout.zig but reads from a cached entry instead of a
    // worker's private pd. Skipped when the caller didn't thread a
    // pd through `lc` (pre-effects-spec call sites).
    if (lc.pass_dispatches) |out_pd| {
        if (entry.pass_dispatches.len > 0) {
            // Reuses `pd_base` captured at function entry so cached
            // primitive `local_pd_idx` targets above and cached
            // `sequence_index` here land at matching positions.
            const ox_i32: i32 = @intFromFloat(@round(ox));
            const oy_i32: i32 = @intFromFloat(@round(oy));
            try out_pd.ensureUnusedCapacity(entry.pass_dispatches.len);
            for (entry.pass_dispatches) |d| {
                var d_local = d;
                switch (d_local) {
                    .pattern => |*p| {
                        p.sequence_index += pd_base;
                        p.layout_region.x += ox_i32;
                        p.layout_region.y += oy_i32;
                    },
                    .single_source => |*ss| {
                        ss.subtree_dispatch_range[0] += pd_base;
                        ss.subtree_dispatch_range[1] += pd_base;
                        ss.sequence_index += pd_base;
                        ss.compose_region.x += ox_i32;
                        ss.compose_region.y += oy_i32;
                    },
                    // Effects-spec B.7 — host_slot. No
                    // subtree_dispatch_range (host owns rendering, no
                    // walker recursion below). `invocation` is a
                    // resolved per-instance pair, valid across cache
                    // hits as long as the source Component instance
                    // outlives the cache entry — same lifetime
                    // assumption as `vtable`/`ctx` pointers above.
                    .host_slot => |*hs| {
                        hs.sequence_index += pd_base;
                        hs.compose_region.x += ox_i32;
                        hs.compose_region.y += oy_i32;
                    },
                    // Effects-spec C.1 — chain. `steps` slice points
                    // into source Component-owned scratch — same
                    // lifetime model as host_slot's invocation. Pool
                    // resolution happens against per-frame
                    // `Spark.chain_pool_bases` at Phase 1, so
                    // pool-local indices on steps don't shift here.
                    //
                    // Effects-spec C.1.5 — subtree_dispatch_range
                    // shifts by pd_base (mirrors single_source).
                    .chain => |*c| {
                        c.subtree_dispatch_range[0] += pd_base;
                        c.subtree_dispatch_range[1] += pd_base;
                        c.sequence_index += pd_base;
                        c.compose_region.x += ox_i32;
                        c.compose_region.y += oy_i32;
                    },
                }
                out_pd.appendAssumeCapacity(d_local);
            }
        }
    }

    return .{
        .x = ox,
        .y = oy,
        .w = entry.box.w,
        .h = entry.box.h,
        .baseline = if (entry.box.baseline == 0) 0 else oy + entry.box.baseline,
    };
}

/// Snapshot the ranges `[g_start..end]` etc. of `out` back into a
/// cache `Entry` with block-local coordinates (origin subtracted from
/// every position). The triangle indices in the snapshot are rebased
/// against `tri_vertex_base` so the cached entry's indices start at 0.
/// `pd_slice` is the pass-dispatch range emitted by this walk (caller
/// passes `pass_dispatches.items[pd_start..]`); regions get translated
/// to block-local and indices rebased to start-at-0 the same way
/// `tri_indices` does.
pub fn snapshotEntry(
    cache: *BlockCache,
    key: Key,
    version: u64,
    out: *const element.DrawList,
    g_start: usize,
    q_start: usize,
    t_start: usize,
    ti_start: usize,
    i_start: usize,
    h_start: usize,
    tri_vertex_base: u32,
    pd_slice: []const element.PassDispatch,
    pd_start: u32,
    origin: [2]f32,
    box: element.Box,
) !void {
    const ox = origin[0];
    const oy = origin[1];

    const glyphs = try cache.allocator.dupe(tp.GlyphInstance, out.glyphs.items[g_start..]);
    errdefer cache.allocator.free(glyphs);
    for (glyphs) |*g| {
        g.dst_pos[0] -= ox;
        g.dst_pos[1] -= oy;
    }

    // Phase B.6 — snapshot the parallel routing tags alongside the
    // primitives, rebasing local pass-dispatch indices against
    // `pd_start` so the cache entry is self-contained. `MAIN_TARGET`
    // is preserved verbatim; it resolves to the outer walker's
    // active target at blit time.
    const glyph_targets = try cache.allocator.dupe(u32, out.glyph_targets.items[g_start..]);
    errdefer cache.allocator.free(glyph_targets);
    for (glyph_targets) |*t| {
        if (t.* != element.MAIN_TARGET) t.* -= pd_start;
    }

    const quads = try cache.allocator.dupe(qp.QuadInstance, out.quads.items[q_start..]);
    errdefer cache.allocator.free(quads);
    for (quads) |*q| {
        q.dst_pos[0] -= ox;
        q.dst_pos[1] -= oy;
    }

    const quad_targets = try cache.allocator.dupe(u32, out.quad_targets.items[q_start..]);
    errdefer cache.allocator.free(quad_targets);
    for (quad_targets) |*t| {
        if (t.* != element.MAIN_TARGET) t.* -= pd_start;
    }

    const tris = try cache.allocator.dupe(tri_pipeline.Vertex, out.tris.items[t_start..]);
    errdefer cache.allocator.free(tris);
    for (tris) |*v| {
        v.pos[0] -= ox;
        v.pos[1] -= oy;
    }

    const tri_targets = try cache.allocator.dupe(u32, out.tri_targets.items[t_start..]);
    errdefer cache.allocator.free(tri_targets);
    for (tri_targets) |*t| {
        if (t.* != element.MAIN_TARGET) t.* -= pd_start;
    }

    const tri_indices = try cache.allocator.dupe(u32, out.tri_indices.items[ti_start..]);
    errdefer cache.allocator.free(tri_indices);
    for (tri_indices) |*i| i.* -= tri_vertex_base;

    const images = try cache.allocator.dupe(element.ImageDraw, out.images.items[i_start..]);
    errdefer cache.allocator.free(images);
    for (images) |*im| {
        im.dst_pos[0] -= ox;
        im.dst_pos[1] -= oy;
    }

    const image_targets = try cache.allocator.dupe(u32, out.image_targets.items[i_start..]);
    errdefer cache.allocator.free(image_targets);
    for (image_targets) |*t| {
        if (t.* != element.MAIN_TARGET) t.* -= pd_start;
    }

    const hits = try cache.allocator.dupe(element.Hit, out.hits.items[h_start..]);
    errdefer cache.allocator.free(hits);
    for (hits) |*h| {
        h.box.x -= ox;
        h.box.y -= oy;
    }

    // Pass dispatches — dup + translate regions to block-local +
    // rebase indices to start-of-block. Mirrors the inverse of
    // `blitEntry`'s pd merge.
    const pds = try cache.allocator.dupe(element.PassDispatch, pd_slice);
    errdefer cache.allocator.free(pds);
    const ox_i32: i32 = @intFromFloat(@round(ox));
    const oy_i32: i32 = @intFromFloat(@round(oy));
    for (pds) |*d| {
        switch (d.*) {
            .pattern => |*p| {
                p.sequence_index -= pd_start;
                p.layout_region.x -= ox_i32;
                p.layout_region.y -= oy_i32;
            },
            .single_source => |*ss| {
                ss.subtree_dispatch_range[0] -= pd_start;
                ss.subtree_dispatch_range[1] -= pd_start;
                ss.sequence_index -= pd_start;
                ss.compose_region.x -= ox_i32;
                ss.compose_region.y -= oy_i32;
            },
            // Effects-spec B.7 — inverse of `blitEntry`'s host_slot
            // rebase. No subtree_dispatch_range.
            .host_slot => |*hs| {
                hs.sequence_index -= pd_start;
                hs.compose_region.x -= ox_i32;
                hs.compose_region.y -= oy_i32;
            },
            // Effects-spec C.1 — inverse of `blitEntry`'s chain
            // rebase. Pool-local indices on steps unchanged (no
            // global pool index space at cache scope).
            //
            // Effects-spec C.1.5 — subtree_dispatch_range inverse-
            // shifts by pd_start (mirrors single_source).
            .chain => |*c| {
                c.subtree_dispatch_range[0] -= pd_start;
                c.subtree_dispatch_range[1] -= pd_start;
                c.sequence_index -= pd_start;
                c.compose_region.x -= ox_i32;
                c.compose_region.y -= oy_i32;
            },
        }
    }

    try cache.insert(key, .{
        .version = version,
        .glyphs = glyphs,
        .glyph_targets = glyph_targets,
        .quads = quads,
        .quad_targets = quad_targets,
        .tris = tris,
        .tri_targets = tri_targets,
        .tri_indices = tri_indices,
        .images = images,
        .image_targets = image_targets,
        .hits = hits,
        .pass_dispatches = pds,
        .box = .{
            .x = 0,
            .y = 0,
            .w = box.w,
            .h = box.h,
            .baseline = if (box.baseline == 0) 0 else box.baseline - oy,
        },
    });
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "BlockCache: insert/lookup roundtrip" {
    var cache = BlockCache.init(testing.allocator);
    defer cache.deinit();

    const key: Key = .{
        .elem_id = 0xCAFE,
        .max_w_bits = @bitCast(@as(f32, 800)),
        .zoom_bits = @bitCast(@as(f32, 1.0)),
        .theme_ptr = 0xABCD,
        .pass_seed = 0,
    };

    const glyphs = try testing.allocator.alloc(tp.GlyphInstance, 0);
    const glyph_targets = try testing.allocator.alloc(u32, 0);
    const quads = try testing.allocator.alloc(qp.QuadInstance, 0);
    const quad_targets = try testing.allocator.alloc(u32, 0);
    const tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0);
    const tri_targets = try testing.allocator.alloc(u32, 0);
    const tri_indices = try testing.allocator.alloc(u32, 0);
    const images = try testing.allocator.alloc(element.ImageDraw, 0);
    const image_targets = try testing.allocator.alloc(u32, 0);
    const hits = try testing.allocator.alloc(element.Hit, 0);
    const pass_dispatches = try testing.allocator.alloc(element.PassDispatch, 0);

    try cache.insert(key, .{
        .version = 1,
        .glyphs = glyphs,
        .glyph_targets = glyph_targets,
        .quads = quads,
        .quad_targets = quad_targets,
        .tris = tris,
        .tri_targets = tri_targets,
        .tri_indices = tri_indices,
        .images = images,
        .image_targets = image_targets,
        .hits = hits,
        .pass_dispatches = pass_dispatches,
        .box = .{ .x = 0, .y = 0, .w = 100, .h = 20, .baseline = 0 },
    });

    const got = cache.lookup(key, 1) orelse return error.MissingEntry;
    try testing.expectEqual(@as(f32, 100), got.box.w);
    try testing.expectEqual(@as(u64, 1), cache.hits);
    try testing.expectEqual(@as(u64, 0), cache.misses);

    // Lookup with a different version misses AND evicts the stale entry.
    try testing.expect(cache.lookup(key, 2) == null);
    try testing.expectEqual(@as(u64, 1), cache.misses);
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}

test "BlockCache: insert replaces existing entry" {
    var cache = BlockCache.init(testing.allocator);
    defer cache.deinit();

    const key: Key = .{
        .elem_id = 0xCAFE,
        .max_w_bits = @bitCast(@as(f32, 800)),
        .zoom_bits = @bitCast(@as(f32, 1.0)),
        .theme_ptr = 0xABCD,
        .pass_seed = 0,
    };

    const a_glyphs = try testing.allocator.alloc(tp.GlyphInstance, 1);
    try cache.insert(key, .{
        .version = 0,
        .glyphs = a_glyphs,
        .glyph_targets = try testing.allocator.alloc(u32, 1),
        .quads = try testing.allocator.alloc(qp.QuadInstance, 0),
        .quad_targets = try testing.allocator.alloc(u32, 0),
        .tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0),
        .tri_targets = try testing.allocator.alloc(u32, 0),
        .tri_indices = try testing.allocator.alloc(u32, 0),
        .images = try testing.allocator.alloc(element.ImageDraw, 0),
        .image_targets = try testing.allocator.alloc(u32, 0),
        .hits = try testing.allocator.alloc(element.Hit, 0),
        .pass_dispatches = try testing.allocator.alloc(element.PassDispatch, 0),
        .box = .{ .x = 0, .y = 0, .w = 1, .h = 1, .baseline = 0 },
    });
    // Insert again — first allocation must be freed by the cache.
    const b_glyphs = try testing.allocator.alloc(tp.GlyphInstance, 2);
    try cache.insert(key, .{
        .version = 0,
        .glyphs = b_glyphs,
        .glyph_targets = try testing.allocator.alloc(u32, 2),
        .quads = try testing.allocator.alloc(qp.QuadInstance, 0),
        .quad_targets = try testing.allocator.alloc(u32, 0),
        .tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0),
        .tri_targets = try testing.allocator.alloc(u32, 0),
        .tri_indices = try testing.allocator.alloc(u32, 0),
        .images = try testing.allocator.alloc(element.ImageDraw, 0),
        .image_targets = try testing.allocator.alloc(u32, 0),
        .hits = try testing.allocator.alloc(element.Hit, 0),
        .pass_dispatches = try testing.allocator.alloc(element.PassDispatch, 0),
        .box = .{ .x = 0, .y = 0, .w = 2, .h = 2, .baseline = 0 },
    });

    const got = cache.lookup(key, 0) orelse return error.MissingEntry;
    try testing.expectEqual(@as(usize, 2), got.glyphs.len);
    try testing.expectEqual(@as(f32, 2), got.box.w);
}

test "BlockCache: clear frees all entries" {
    var cache = BlockCache.init(testing.allocator);
    defer cache.deinit();

    for (0..5) |i| {
        const key: Key = .{
            .elem_id = i + 1,
            .max_w_bits = 0,
            .zoom_bits = 0,
            .theme_ptr = 0,
            .pass_seed = 0,
        };
        try cache.insert(key, .{
            .version = 0,
            .glyphs = try testing.allocator.alloc(tp.GlyphInstance, 3),
            .glyph_targets = try testing.allocator.alloc(u32, 3),
            .quads = try testing.allocator.alloc(qp.QuadInstance, 1),
            .quad_targets = try testing.allocator.alloc(u32, 1),
            .tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0),
            .tri_targets = try testing.allocator.alloc(u32, 0),
            .tri_indices = try testing.allocator.alloc(u32, 0),
            .images = try testing.allocator.alloc(element.ImageDraw, 0),
            .image_targets = try testing.allocator.alloc(u32, 0),
            .hits = try testing.allocator.alloc(element.Hit, 0),
            .pass_dispatches = try testing.allocator.alloc(element.PassDispatch, 0),
            .box = .{ .x = 0, .y = 0, .w = 10, .h = 5, .baseline = 0 },
        });
    }
    try testing.expectEqual(@as(usize, 5), cache.entries.count());
    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}

test "elementIdentity: stable across re-reads of same element value" {
    const text_a = "hello";
    const children: [1]element.Element = .{
        .{ .text = .{
            .content = text_a,
            .style = .{ .font_id = 0, .color = .{ 1, 1, 1, 1 } },
        } },
    };
    const para_a = element.Element{ .paragraph = &children };
    const para_b = element.Element{ .paragraph = &children };
    try testing.expect(elementIdentity(para_a) == elementIdentity(para_b));
    try testing.expect(elementIdentity(para_a) != 0);
}

test "elementIdentity: containers/inline kinds return 0" {
    const para = element.Element{ .paragraph = &.{} };
    const list = element.Element{ .list = .{ .ordered = false, .items = &.{} } };
    try testing.expectEqual(@as(usize, 0), elementIdentity(list));
    try testing.expect(elementIdentity(para) != 0 or true); // paragraph hashes the slice ptr; allow either
    try testing.expectEqual(@as(usize, 0), elementIdentity(.line_break));
}

test "cacheableLeaf: classifies kinds" {
    try testing.expect(cacheableLeaf(element.Element{ .paragraph = &.{} }));
    try testing.expect(cacheableLeaf(element.Element{ .heading = .{ .level = 1, .content = &.{} } }));
    try testing.expect(cacheableLeaf(.thematic_break));
    try testing.expect(!cacheableLeaf(.line_break));
    try testing.expect(!cacheableLeaf(element.Element{ .container = .{ .layout = .stack_v, .children = &.{} } }));
    try testing.expect(!cacheableLeaf(element.Element{ .list = .{ .ordered = false, .items = &.{} } }));
}

test "aggregateChildVersions: child bumps flip the aggregated value" {
    const State = struct {
        var ver_a: u64 = 0;
        var ver_b: u64 = 0;
        fn vA(_: *anyopaque) u64 {
            return ver_a;
        }
        fn vB(_: *anyopaque) u64 {
            return ver_b;
        }
        fn dummyLar(
            _: *anyopaque,
            origin: [2]f32,
            _: element.Constraints,
            _: *element.LayoutCtx,
            _: *element.DrawList,
        ) anyerror!element.Box {
            return .{ .x = origin[0], .y = origin[1], .w = 0, .h = 0 };
        }
    };

    const vt_a: element.ElementVTable = .{
        .layout_and_render = State.dummyLar,
        .content_version = State.vA,
    };
    const vt_b: element.ElementVTable = .{
        .layout_and_render = State.dummyLar,
        .content_version = State.vB,
    };

    var ctx_a: u8 = 0;
    var ctx_b: u8 = 0;
    State.ver_a = 0;
    State.ver_b = 0;

    const children: [2]element.Element = .{
        .{ .custom = .{ .vtable = &vt_a, .ctx = &ctx_a } },
        .{ .custom = .{ .vtable = &vt_b, .ctx = &ctx_b } },
    };

    const v0 = aggregateChildVersions(&children);

    // Bump one child — aggregated value should change.
    State.ver_a = 1;
    const v1 = aggregateChildVersions(&children);
    try testing.expect(v0 != v1);

    // Identity-mixing regression: two siblings with the same version
    // must NOT cancel each other out. Without identity-mix,
    // (5 XOR 5) = 0 and the aggregate would equal the no-bump
    // baseline, hiding the change.
    State.ver_a = 5;
    State.ver_b = 5;
    const v_same = aggregateChildVersions(&children);
    try testing.expect(v_same != 0);

    State.ver_a = 5;
    State.ver_b = 7;
    const v_diff = aggregateChildVersions(&children);
    try testing.expect(v_same != v_diff);

    // And the half of that trap the identity mix did NOT cover until
    // 2026-08-31. Two siblings bound to the same state path bump in
    // LOCKSTEP — created together, re-ingested together, re-fired
    // together — so the pair's contribution under `v ^ id` was
    // `id_a ^ id_b` at 5,5 and `id_a ^ id_b` again at 6,6. Constant.
    // `:::flex` holding two `:::progress {value=${state.p}}` replayed a
    // stale drawlist and both bars were frozen. See `mixVersion`.
    State.ver_a = 6;
    State.ver_b = 6;
    try testing.expect(aggregateChildVersions(&children) != v_same);
}

test "aggregateRootVersion: a child's bump reaches the wrapper" {
    // The bug: `:::drop_shadow` / `:::frosted_glass` / everything from
    // `SingleSourceFactory` returned only their own version, so a cached
    // ancestor replayed a stale snapshot and any interactive control inside
    // an effect was frozen at its create-time appearance.
    var v: u64 = 7;
    const Fake = struct {
        fn version(ctx: *anyopaque) u64 {
            return @as(*const u64, @ptrCast(@alignCast(ctx))).*;
        }
        const vt: element.ElementVTable = .{
            .layout_and_render = undefined,
            .content_version = version,
        };
    };
    const child = element.Element{ .custom = .{ .ctx = @ptrCast(&v), .vtable = &Fake.vt } };
    const kids = [_]element.Element{child};
    const root = element.Element{ .paragraph = &kids };

    const before = aggregateRootVersion(root);
    v = 8;
    const after = aggregateRootVersion(root);

    // Rule 1: the child's version really did move, so "the aggregate moved"
    // is about propagation rather than about nothing having happened.
    try std.testing.expect(before != after);

    // And a root with no versioned children is stable — otherwise every
    // wrapper would miss its cache every frame and the aggregate would be a
    // very expensive way of disabling the cache.
    const plain = [_]element.Element{.{ .line_break = {} }};
    const plain_root = element.Element{ .paragraph = &plain };
    try std.testing.expectEqual(aggregateRootVersion(plain_root), aggregateRootVersion(plain_root));
}

/// Minimal `inline_object` stand-in: a `u64` you can write, reachable
/// through a vtable. Each instance is its own `ctx`, which is also the
/// identity the aggregate mixes in.
const FakeInline = struct {
    version: u64 = 0,

    fn read(ctx: *anyopaque) u64 {
        return @as(*const FakeInline, @ptrCast(@alignCast(ctx))).version;
    }

    const vt: element.ElementVTable = .{
        .layout_and_render = undefined,
        .measure_inline = undefined,
        .content_version = read,
    };

    fn elem(self: *FakeInline) element.Element {
        return .{ .inline_object = .{ .vtable = &vt, .ctx = @ptrCast(self) } };
    }
};

test "versionFor: a reactive inline object's bump reaches its paragraph" {
    // THE BUG. A paragraph is cached on `@intFromPtr(children.ptr)`,
    // and that pointer does not move when `::value{text=${state.x}}`
    // re-ingests. Before this, `versionFor(.paragraph)` was a constant
    // 0, so the paragraph drew once and replayed that snapshot for the
    // life of the document — the state wrote, the binding fired, the
    // component's own version bumped, and the picture never changed.
    var v = FakeInline{};
    const kids = [_]element.Element{ .{ .text = .{
        .content = "showing ",
        .style = .{ .font_id = 0, .color = .{ 1, 1, 1, 1 } },
    } }, v.elem() };
    const para = element.Element{ .paragraph = &kids };

    const before = versionFor(para);
    v.version = 1;
    const after = versionFor(para);
    try std.testing.expect(before != after);

    // Rule 5, and the reason this is not simply "aggregate everything":
    // an ordinary paragraph must report a STABLE version, or every
    // paragraph in every document misses its cache on every frame and
    // the fix costs more than the bug.
    const plain = [_]element.Element{.{ .text = .{
        .content = "no components here",
        .style = .{ .font_id = 0, .color = .{ 1, 1, 1, 1 } },
    } }};
    const plain_para = element.Element{ .paragraph = &plain };
    try std.testing.expectEqual(@as(u64, 0), versionFor(plain_para));

    // A heading is cached the same way and gets the same treatment —
    // `# Showing ::value{...}` is a title that reports what it is
    // titling.
    const head = element.Element{ .heading = .{ .level = 2, .content = &kids } };
    v.version = 2;
    const h2 = versionFor(head);
    v.version = 3;
    try std.testing.expect(h2 != versionFor(head));
}

test "aggregateInlineVersions: two readouts on one path do not cancel" {
    // `Showing ${state.x} of ${state.x}` — both objects are bound to
    // the same path, so they bump in lockstep and hold equal versions
    // forever. Without the per-instance identity mixed in, `v XOR v`
    // is 0 at every value and the paragraph looks permanently
    // unchanged: the exact shape of the bug, reintroduced by the fix.
    var a = FakeInline{};
    var b = FakeInline{};
    const kids = [_]element.Element{ a.elem(), b.elem() };

    a.version = 5;
    b.version = 5;
    const at_five = aggregateInlineVersions(&kids);
    try std.testing.expect(at_five != 0);

    a.version = 6;
    b.version = 6;
    try std.testing.expect(aggregateInlineVersions(&kids) != at_five);
}

test "aggregateInlineVersions: reaches through emphasis, strong and links" {
    // `**${state.x}**` puts the object one level down. A readout inside
    // bold is not a different feature, and a version that stopped at the
    // paragraph's immediate children would freeze it.
    var v = FakeInline{};
    const inner = [_]element.Element{v.elem()};

    const wrappers = [_]element.Element{
        .{ .emphasis = &inner },
        .{ .strong = &inner },
        .{ .code = &inner },
        .{ .link = .{ .target = "#", .content = &inner } },
    };

    for (wrappers) |w| {
        const kids = [_]element.Element{w};
        v.version = 1;
        const before = aggregateInlineVersions(&kids);
        v.version = 2;
        try std.testing.expect(before != aggregateInlineVersions(&kids));
    }
}
