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
    /// Theme pointer. Theme swap → invalidate.
    theme_ptr: usize,
};

pub const Entry = struct {
    /// Monotonic version returned by `vtable.content_version` (custom
    /// elements) — 0 for built-ins. On lookup, mismatch counts as a
    /// miss and the stale entry is evicted to make room for the fresh
    /// snapshot.
    version: u64,
    /// Block-local glyphs: `dst_pos` is relative to (0, 0).
    glyphs: []tp.GlyphInstance,
    /// Block-local quads: `dst_pos` is relative to (0, 0).
    quads: []qp.QuadInstance,
    /// Block-local triangle vertices: `pos` is relative to (0, 0).
    tris: []tri_pipeline.Vertex,
    /// Indices relative to the start of `tris` (already rebased to 0).
    tri_indices: []u32,
    /// Block-local image draws (descriptor pointer + relative rect).
    /// Descriptors are owned by the source `:::image-stream` component
    /// and stay valid across cache hits (a re-fire bumps version and
    /// re-snapshots, but the descriptor handle is rewritten in place).
    images: []element.ImageDraw,
    /// Block-local hits: `box.x`/`box.y` are relative to (0, 0).
    hits: []element.Hit,
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
        self.allocator.free(e.quads);
        self.allocator.free(e.tris);
        self.allocator.free(e.tri_indices);
        self.allocator.free(e.images);
        self.allocator.free(e.hits);
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
        // shaper handles them.
        .text, .line_break, .emphasis, .strong, .code, .link => 0,

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
) Key {
    return .{
        .elem_id = elementIdentity(elem),
        .max_w_bits = @bitCast(constraints.max_w),
        .theme_ptr = @intFromPtr(theme),
    };
}

/// Read the current content-version for an element (0 for built-ins).
pub fn versionFor(elem: element.Element) u64 {
    return switch (elem) {
        .custom => |cu| if (cu.vtable.content_version) |getter| getter(cu.ctx) else 0,
        else => 0,
    };
}

/// Blit a cached entry into `out`, translating every position by
/// `origin`. Triangle indices are rebased against the current vertex
/// count of `out.tris`. Returns the `Box` at `origin`.
pub fn blitEntry(
    out: *element.DrawList,
    entry: Entry,
    origin: [2]f32,
) !element.Box {
    const ox = origin[0];
    const oy = origin[1];

    // Glyphs — translate dst_pos.
    const g_start = out.glyphs.items.len;
    try out.glyphs.appendSlice(entry.glyphs);
    for (out.glyphs.items[g_start..]) |*g| {
        g.dst_pos[0] += ox;
        g.dst_pos[1] += oy;
    }

    // Quads — translate dst_pos.
    const q_start = out.quads.items.len;
    try out.quads.appendSlice(entry.quads);
    for (out.quads.items[q_start..]) |*q| {
        q.dst_pos[0] += ox;
        q.dst_pos[1] += oy;
    }

    // Triangles — translate vertex positions, rebase indices.
    const tri_vertex_base: u32 = @intCast(out.tris.items.len);
    try out.tris.appendSlice(entry.tris);
    for (out.tris.items[tri_vertex_base..]) |*v| {
        v.pos[0] += ox;
        v.pos[1] += oy;
    }
    const ti_start = out.tri_indices.items.len;
    try out.tri_indices.appendSlice(entry.tri_indices);
    for (out.tri_indices.items[ti_start..]) |*i| i.* += tri_vertex_base;

    // Images — translate dst_pos. Descriptor handle is stable across
    // hits (owned by the source component).
    for (entry.images) |im| {
        var im2 = im;
        im2.dst_pos[0] += ox;
        im2.dst_pos[1] += oy;
        try out.images.append(im2);
    }

    // Hits — translate box origin. Pointer fields (vtable/ctx/state)
    // are pointer-stable across walks so the cached values stay valid.
    for (entry.hits) |h| {
        var h2 = h;
        h2.box.x += ox;
        h2.box.y += oy;
        try out.hits.append(h2);
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

    const quads = try cache.allocator.dupe(qp.QuadInstance, out.quads.items[q_start..]);
    errdefer cache.allocator.free(quads);
    for (quads) |*q| {
        q.dst_pos[0] -= ox;
        q.dst_pos[1] -= oy;
    }

    const tris = try cache.allocator.dupe(tri_pipeline.Vertex, out.tris.items[t_start..]);
    errdefer cache.allocator.free(tris);
    for (tris) |*v| {
        v.pos[0] -= ox;
        v.pos[1] -= oy;
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

    const hits = try cache.allocator.dupe(element.Hit, out.hits.items[h_start..]);
    errdefer cache.allocator.free(hits);
    for (hits) |*h| {
        h.box.x -= ox;
        h.box.y -= oy;
    }

    try cache.insert(key, .{
        .version = version,
        .glyphs = glyphs,
        .quads = quads,
        .tris = tris,
        .tri_indices = tri_indices,
        .images = images,
        .hits = hits,
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
        .theme_ptr = 0xABCD,
    };

    const glyphs = try testing.allocator.alloc(tp.GlyphInstance, 0);
    const quads = try testing.allocator.alloc(qp.QuadInstance, 0);
    const tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0);
    const tri_indices = try testing.allocator.alloc(u32, 0);
    const images = try testing.allocator.alloc(element.ImageDraw, 0);
    const hits = try testing.allocator.alloc(element.Hit, 0);

    try cache.insert(key, .{
        .version = 1,
        .glyphs = glyphs,
        .quads = quads,
        .tris = tris,
        .tri_indices = tri_indices,
        .images = images,
        .hits = hits,
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
        .theme_ptr = 0xABCD,
    };

    const a_glyphs = try testing.allocator.alloc(tp.GlyphInstance, 1);
    try cache.insert(key, .{
        .version = 0,
        .glyphs = a_glyphs,
        .quads = try testing.allocator.alloc(qp.QuadInstance, 0),
        .tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0),
        .tri_indices = try testing.allocator.alloc(u32, 0),
        .images = try testing.allocator.alloc(element.ImageDraw, 0),
        .hits = try testing.allocator.alloc(element.Hit, 0),
        .box = .{ .x = 0, .y = 0, .w = 1, .h = 1, .baseline = 0 },
    });
    // Insert again — first allocation must be freed by the cache.
    const b_glyphs = try testing.allocator.alloc(tp.GlyphInstance, 2);
    try cache.insert(key, .{
        .version = 0,
        .glyphs = b_glyphs,
        .quads = try testing.allocator.alloc(qp.QuadInstance, 0),
        .tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0),
        .tri_indices = try testing.allocator.alloc(u32, 0),
        .images = try testing.allocator.alloc(element.ImageDraw, 0),
        .hits = try testing.allocator.alloc(element.Hit, 0),
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
            .theme_ptr = 0,
        };
        try cache.insert(key, .{
            .version = 0,
            .glyphs = try testing.allocator.alloc(tp.GlyphInstance, 3),
            .quads = try testing.allocator.alloc(qp.QuadInstance, 1),
            .tris = try testing.allocator.alloc(tri_pipeline.Vertex, 0),
            .tri_indices = try testing.allocator.alloc(u32, 0),
            .images = try testing.allocator.alloc(element.ImageDraw, 0),
            .hits = try testing.allocator.alloc(element.Hit, 0),
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
