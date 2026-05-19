//! Shader resolver — maps `ShaderId` (16-byte opaque identifier
//! from A.2 / the A.0 wire format) to a `ShaderDispatchHandle` the
//! Vulkan layer can bind. Effects-spec Phase A.3 stub: the resolver
//! exists with its public signature locked, the cache is empty,
//! every `resolve()` call returns `error.ShaderNotRegistered`. A.4
//! lights it up by registering glslc-compiled SPIR-V at build time
//! and populating the cache.
//!
//! Future provenance rungs (remote-fetched, WASM-emitted, inference-
//! emitted shaders per Decision #9) plug in by adding internal lookup
//! branches inside `resolve` — the signature does not change.
//! Component code calls `resolve(id)`; the resolver is the only place
//! that knows where the bytes came from.

const std = @import("std");
const component = @import("../component.zig");

const ShaderId = component.ShaderId;

/// Opaque dispatch handle. A.4 fills with the real Vulkan pipeline
/// + descriptor-set-layout pair the pass-graph compiler binds before
/// recording a draw. Reserved as an empty struct in A.3 so the
/// `resolve` return-type is locked.
pub const ShaderDispatchHandle = struct {
    // A.4 fields land here. The empty struct exists today so the
    // resolver signature compiles and downstream callers (A.5
    // factory create() methods) bind against a stable type.
    _: u0 = 0,
};

pub const Error = error{
    /// Returned by `resolve` for any `ShaderId` that hasn't been
    /// registered. A.3 returns this unconditionally — the cache is
    /// empty. A.4 makes this a real "you asked for a shader the
    /// build step didn't produce" diagnostic.
    ShaderNotRegistered,
};

pub const ShaderResolver = struct {
    allocator: std.mem.Allocator,
    // A.4: backing cache (likely AutoHashMap(ShaderId,
    // ShaderDispatchHandle)). A.3 stores nothing — the allocator
    // sits unused so the init/deinit shape matches the post-A.4
    // surface and downstream Spark plumbing doesn't churn.

    pub fn init(allocator: std.mem.Allocator) ShaderResolver {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShaderResolver) void {
        _ = self;
    }

    /// Resolve a `ShaderId` to a dispatch handle. A.3 returns
    /// `error.ShaderNotRegistered` for any id (empty cache); A.4
    /// will populate the cache from the glslc build step and start
    /// returning real handles. Future provenance rungs add branches
    /// inside this function — the signature stays put.
    pub fn resolve(self: *ShaderResolver, id: ShaderId) Error!ShaderDispatchHandle {
        _ = self;
        _ = id;
        return Error.ShaderNotRegistered;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "ShaderResolver: init + deinit" {
    var r = ShaderResolver.init(testing.allocator);
    defer r.deinit();
    // Lifecycle test — no leak on testing.allocator if init/deinit
    // ever grow to allocate.
}

test "ShaderResolver: resolve returns ShaderNotRegistered for any id" {
    var r = ShaderResolver.init(testing.allocator);
    defer r.deinit();
    const id: ShaderId = [_]u8{0} ** 16;
    try testing.expectError(Error.ShaderNotRegistered, r.resolve(id));
    // Same answer for any other id — the cache is empty until A.4.
    const id2: ShaderId = [_]u8{1} ** 16;
    try testing.expectError(Error.ShaderNotRegistered, r.resolve(id2));
}
