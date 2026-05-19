//! Transient render-target pool — recycles offscreen targets across
//! a frame for single-source / chain effects. Keyed by `(w, h,
//! format)` per Decision #4 so multiple effects with the same
//! footprint share one physical allocation.
//!
//! Effects-spec Phase A.3 typed-null stub. The struct, types, and
//! signatures land so downstream code (Spark plumbing, Phase B's
//! single-source pass-graph emit) compiles against a stable surface.
//! `init` returns empty, `deinit` is a no-op, and `acquire` /
//! `release` `@panic` with a Phase B tag — Phase A pattern-passes
//! never allocate offscreen targets, so the panic arms can't fire
//! during A.5/A.6. Phase B is where the real allocator, ref-counted
//! mid-frame release per Decision #4, and frame-end sanity sweep
//! land.

const std = @import("std");
const vk = @import("../gpu/vk.zig");

/// Identifies a target slot in the pool. Decision #4: targets are
/// shared across effects with matching footprint; this tuple is the
/// equivalence class. Format is included because (e.g.) HDR Phase C
/// passes will request RGBA16F vs the LDR sRGB norm — different
/// formats can't share.
pub const TargetKey = struct {
    width: u32,
    height: u32,
    format: vk.c.VkFormat,
};

/// Opaque handle for an acquired target. Phase B fills with the
/// real Vulkan image + view + descriptor set the effect shader
/// samples from. Empty struct in A.3 so the acquire/release
/// signatures are locked.
pub const TargetHandle = struct {
    _: u0 = 0,
};

pub const TargetPool = struct {
    allocator: std.mem.Allocator,
    // Phase B fields: free-list keyed by TargetKey, ref counts,
    // last-consumer dispatch-complete bookkeeping (Decision #4).
    // A.3 carries the allocator only so init/deinit match the
    // post-Phase-B shape — downstream Spark plumbing doesn't churn.

    pub fn init(allocator: std.mem.Allocator) TargetPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TargetPool) void {
        _ = self;
    }

    /// Acquire a target matching `key`. Phase B implements the
    /// real free-list-or-allocate path with ref-counted mid-frame
    /// release on last-consumer dispatch-complete (Decision #4).
    /// Panics in A.3 — Phase A pattern-passes never allocate
    /// offscreen targets, so this branch is unreachable until Phase
    /// B lands.
    pub fn acquire(self: *TargetPool, key: TargetKey) !TargetHandle {
        _ = self;
        _ = key;
        @panic("Phase B: TargetPool.acquire not implemented (Phase A pattern-passes have no offscreen targets)");
    }

    /// Release a previously-acquired target. See `acquire` for the
    /// Phase B implementation note.
    pub fn release(self: *TargetPool, handle: TargetHandle) void {
        _ = self;
        _ = handle;
        @panic("Phase B: TargetPool.release not implemented (Phase A pattern-passes have no offscreen targets)");
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "TargetPool: init + deinit" {
    var pool = TargetPool.init(testing.allocator);
    defer pool.deinit();
    // Lifecycle — proves the allocator-carrying shape works under
    // the testing allocator's leak checks (currently a no-op, but
    // pinned for when Phase B starts allocating).
}

// Note: acquire / release panic arms are not tested. Zig has no
// in-process panic catch; @panic terminates the test runner. The
// arms are documentation, not behavior — `grep "Phase B:"` finds
// every implementation site at once.
