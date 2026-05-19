//! Shader resolver — maps `ShaderId` (16-byte opaque identifier
//! from A.2 / the A.0 wire format) to a `ShaderDispatchHandle` the
//! Vulkan layer can bind. Effects-spec Phase A.4: real registry,
//! seeded from the build-step's `@embedFile`'d SPIR-V at Spark init
//! time. The resolver is the lookup boundary; the embedded source
//! lives in the generated `shaders` module (see `build.zig`).
//!
//! Provenance ladder (Decision #9). Today's only lookup branch is
//! the embedded registry — populated synchronously at Spark init
//! from build-time-compiled SPIR-V. Future rungs plug in by adding
//! branches inside `resolve`:
//!
//!   * Asset cache — `resolve` falls back to a borrowed
//!     `*AssetCache` (see `src/extras/asset_cache.zig`) for shaders
//!     that authors load dynamically (filesystem, HTTP). Same id;
//!     same handle; different source. The hook isn't wired yet —
//!     this comment is the contract for where it lands.
//!   * Remote fetch — pulls SPIR-V from a registered shader index
//!     server. Cached locally via the asset-cache path.
//!   * WASM / inference-emitted — shader bytes synthesized at
//!     runtime; same registration shape, different origin.
//!
//! The `resolve` signature does not change as branches are added.
//! Callers see only the opaque `ShaderDispatchHandle`; the resolver
//! is the only place that knows where the bytes came from.
//!
//! ShaderId derivation. Built-in shaders coin their id from a
//! **stable build-time name** (e.g. `"fullscreen.vert"`) via
//! `shaderIdFromName`. Names — not content hashes of the `.spv`
//! blob — because glslc with `-O` is deterministic for a fixed
//! version but optimizer output can shift across Vulkan SDK
//! versions. Hashing names dodges the "every SDK update breaks the
//! determinism fingerprint" failure mode. Future provenance rungs
//! where content-hashing genuinely matters (remote-fetched bytes,
//! WASM-emitted shaders) carry their own ids by construction.

const std = @import("std");
const component = @import("../component.zig");

const ShaderId = component.ShaderId;

/// Opaque dispatch handle. A.4 holds the SPIR-V bytecode; A.6 will
/// swap the field to a compiled `VkPipeline` + descriptor-set layout
/// once the pass-graph compiler needs real GPU resources. The
/// resolver's `resolve` signature doesn't change with that swap —
/// callers bind against the handle type, not the field.
pub const ShaderDispatchHandle = struct {
    /// SPIR-V bytecode for the shader. Borrowed — typically a slice
    /// into an `@embedFile`'d blob owned by the `shaders` module,
    /// lifetime = process. Asset-cache-loaded shaders (future) will
    /// borrow from cache-owned storage; the resolver is responsible
    /// for keeping the source alive as long as any handle is out.
    spv: []const u8,
};

pub const Error = error{
    /// Returned by `resolve` for any `ShaderId` not in the registry
    /// and (once wired) not findable via the fallback branches.
    /// At Spark init time, builtins are seeded — a `ShaderNotRegistered`
    /// at runtime means the factory asked for an id no shader was
    /// coined under.
    ShaderNotRegistered,
} || std.mem.Allocator.Error;

pub const ShaderResolver = struct {
    allocator: std.mem.Allocator,
    /// Built-in registry — populated at Spark init from the
    /// embedded SPIR-V blobs. Map values are borrowed (lifetime =
    /// the embedded `shaders` module, i.e. process).
    registry: std.AutoHashMap(ShaderId, []const u8),

    pub fn init(allocator: std.mem.Allocator) ShaderResolver {
        return .{
            .allocator = allocator,
            .registry = std.AutoHashMap(ShaderId, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ShaderResolver) void {
        self.registry.deinit();
    }

    /// Register a shader by stable name. Computes the `ShaderId`
    /// from the name via `shaderIdFromName`. Re-registering the
    /// same name overwrites — useful for hot-reload paths later;
    /// harmless for the startup seed.
    ///
    /// **v1 ownership contract.** The `spv` slice is *borrowed,
    /// not owned*. Today every registered slice points into the
    /// embedded `shaders` module's `@embedFile`'d data —
    /// process-lifetime, never freed, no refcounting needed. The
    /// resolver holds the pointer and trusts it to remain valid.
    ///
    /// **Future ownership work** (lands with the asset-cache
    /// fallback rung): non-embedded sources — asset-cache fetches,
    /// remote downloads, WASM-emitted bytes — need real lifetime
    /// semantics (release / refcount / arena ownership). When that
    /// rung lands, this signature gains an ownership tag or the
    /// resolver grows a parallel `registerOwned` path. v1 leaves
    /// the contract simple by enforcing the borrowed-static
    /// invariant at the call site (Spark init only registers from
    /// `@embedFile`'d blobs). Don't relax the invariant without
    /// landing the ownership work first.
    pub fn register(self: *ShaderResolver, name: []const u8, spv: []const u8) Error!void {
        const id = shaderIdFromName(name);
        try self.registry.put(id, spv);
    }

    /// Resolve a `ShaderId` to a dispatch handle. Today: looks up
    /// the built-in registry. Future provenance rungs add fallback
    /// branches inside this function — the signature is fixed.
    pub fn resolve(self: *ShaderResolver, id: ShaderId) Error!ShaderDispatchHandle {
        if (self.registry.get(id)) |spv| {
            return .{ .spv = spv };
        }
        // Future fallback: asset cache lookup lands here. See the
        // provenance-ladder note at the top of this file.
        return Error.ShaderNotRegistered;
    }
};

/// Derive a stable 16-byte `ShaderId` from a shader's build-time
/// name. Two Wyhash passes with different seeds produce a 128-bit
/// spread — collision-free across any realistic shader set,
/// deterministic across runs, machines, and Vulkan SDK versions.
/// The build step coins names (`"fullscreen.vert"`, `"gradient.frag"`,
/// …); A.5+ factories call this at create-time to compute the id
/// they pass to `resolve`.
pub fn shaderIdFromName(name: []const u8) ShaderId {
    var out: ShaderId = undefined;
    const h1 = std.hash.Wyhash.hash(0, name);
    const h2 = std.hash.Wyhash.hash(1, name);
    @memcpy(out[0..8], std.mem.asBytes(&h1));
    @memcpy(out[8..16], std.mem.asBytes(&h2));
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "ShaderResolver: init + deinit" {
    var r = ShaderResolver.init(testing.allocator);
    defer r.deinit();
}

test "ShaderResolver: unregistered id returns ShaderNotRegistered" {
    var r = ShaderResolver.init(testing.allocator);
    defer r.deinit();
    const id: ShaderId = [_]u8{0} ** 16;
    try testing.expectError(Error.ShaderNotRegistered, r.resolve(id));
}

test "ShaderResolver: register + resolve round-trip" {
    var r = ShaderResolver.init(testing.allocator);
    defer r.deinit();
    const fake_spv = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0x00, 0x00, 0x01, 0x00 }; // SPIR-V magic prefix
    try r.register("test.vert", &fake_spv);
    const id = shaderIdFromName("test.vert");
    const handle = try r.resolve(id);
    try testing.expectEqualSlices(u8, &fake_spv, handle.spv);
}

test "ShaderResolver: re-register overwrites" {
    var r = ShaderResolver.init(testing.allocator);
    defer r.deinit();
    const v1 = [_]u8{ 1, 2, 3 };
    const v2 = [_]u8{ 4, 5, 6, 7 };
    try r.register("x.frag", &v1);
    try r.register("x.frag", &v2);
    const handle = try r.resolve(shaderIdFromName("x.frag"));
    try testing.expectEqualSlices(u8, &v2, handle.spv);
}

test "shaderIdFromName: deterministic across calls" {
    const a = shaderIdFromName("fullscreen.vert");
    const b = shaderIdFromName("fullscreen.vert");
    try testing.expectEqual(a, b);
}

test "shaderIdFromName: distinct names produce distinct ids" {
    const a = shaderIdFromName("fullscreen.vert");
    const b = shaderIdFromName("gradient.frag");
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "ShaderResolver: smoke test — embedded fullscreen.vert is non-empty" {
    // Build-infrastructure smoke test. If glslc compilation succeeded
    // and @embedFile landed real bytes, this passes; if either is
    // silently broken (compile-step skipped, .spv truncated to zero),
    // this fails — early signal that A.4's build path is alive,
    // before A.5 starts depending on it.
    const shaders = @import("shaders");
    try testing.expect(shaders.fullscreen_vert.len > 0);
    // SPIR-V magic number is 0x07230203 little-endian — first four
    // bytes of any valid SPIR-V blob. Sanity-checks that what landed
    // is actually SPIR-V, not (say) preprocessor output or an error
    // message redirected into the file.
    try testing.expectEqual(@as(u8, 0x03), shaders.fullscreen_vert[0]);
    try testing.expectEqual(@as(u8, 0x02), shaders.fullscreen_vert[1]);
    try testing.expectEqual(@as(u8, 0x23), shaders.fullscreen_vert[2]);
    try testing.expectEqual(@as(u8, 0x07), shaders.fullscreen_vert[3]);
}
