//! Pass-graph compiler — walks components looking for non-`.content`
//! `pass_shape` factories, emits dispatches into the per-frame
//! `pass_dispatches` list on Spark. Effects-spec Phase A.3 shell:
//! the entry-point function and the exhaustive `PassShape` switch
//! land here so the implementation state is documented in code with
//! searchable phase tags. A.6 wires the document-tree walk into
//! `compile` and the panic arms start firing for real factories.
//!
//! Why a struct (today empty) rather than free functions: A.6+ will
//! grow per-compile state (in-flight dependency edges, ordering
//! buffer, target reservations). Keeping the struct shape from A.3
//! means downstream callers bind against `Graph.compile(...)` and
//! the eventual state additions don't churn the call site.

const std = @import("std");
const component = @import("../component.zig");

const PassShape = component.PassShape;

pub const Graph = struct {
    // A.6+ fields: dependency edges, ordering buffer, in-flight
    // target reservations. A.3 carries no state — the struct exists
    // so the public surface is stable.

    pub fn init() Graph {
        return .{};
    }

    pub fn deinit(self: *Graph) void {
        _ = self;
    }

    /// Walk components, dispatch per `pass_shape`. A.3 stub: no
    /// iteration yet — when A.6 lights up the real walker (over the
    /// document tree's custom-element nodes), this body becomes:
    /// `for each custom element: dispatchPass(factory.pass_shape)`.
    /// Today it's a no-op because no factory declares a non-`.content`
    /// shape, so even a real walker would find nothing to dispatch.
    pub fn compile(self: *Graph) !void {
        _ = self;
        // A.6: iterate document tree → dispatchPass(shape).
    }

    /// Per-component dispatch hook. Public so the A.6 walker (which
    /// lands inside `compile`) and any test that wants to exercise a
    /// specific arm can call directly. Reserved arms `@panic` with a
    /// phase-tagged message; search `Phase X:` to find every
    /// implementation site at once.
    pub fn dispatchPass(self: *Graph, shape: PassShape) void {
        _ = self;
        switch (shape) {
            .content => {
                // Delegated to the rasterizer — `layoutAndRender`
                // walks the same element into the shared DrawList.
            },
            .pattern => @panic("Phase A.6: pattern-pass dispatch not implemented"),
            .single_source => @panic("Phase B: single-source-pass dispatch not implemented"),
            .chain => @panic("Phase C: chain-pass dispatch not implemented"),
            .host_slot => @panic("Phase B/D: host-slot-pass dispatch not implemented (Phase B lights the arm via :::placeholder_scene; Phase D ships :::3d-scene)"),
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Graph: init + deinit" {
    var g = Graph.init();
    defer g.deinit();
}

test "Graph: compile is no-op while no factories declare non-.content" {
    var g = Graph.init();
    defer g.deinit();
    try g.compile();
    // Asserts only that compile doesn't error — A.6 grows real
    // assertions when the walker lands.
}

test "Graph: dispatchPass(.content) returns normally" {
    var g = Graph.init();
    defer g.deinit();
    g.dispatchPass(.content);
    // The reserved arms' panic behavior isn't testable in-process
    // (Zig has no panic catch). The exhaustive switch shape +
    // searchable "Phase X:" tags are the load-bearing artifacts;
    // those live in source above, not as test assertions.
}
