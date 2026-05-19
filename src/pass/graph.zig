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

    /// Per-component dispatch hook. Public so any test that wants to
    /// exercise a specific arm can call directly. Reserved arms
    /// `@panic` with a phase-tagged message; search `Phase X:` to
    /// find every implementation site at once.
    ///
    /// **A.6.a status.** `.pattern` lights up: the layout walker
    /// (`element_layout.zig`) handles pattern dispatches inline
    /// when it encounters a custom element with `pass_kind == 1`,
    /// snapshotting uniforms and appending a `PassDispatch` to
    /// `LayoutCtx.pass_dispatches` directly. This function's
    /// `.pattern` arm is therefore a no-op — it exists to keep the
    /// exhaustive switch shape against a hypothetical caller that
    /// hands a single `PassShape` value for ad-hoc dispatch.
    /// `.single_source` / `.chain` / `.host_slot` still panic until
    /// their phases ship.
    pub fn dispatchPass(self: *Graph, shape: PassShape) void {
        _ = self;
        switch (shape) {
            .content => {
                // Delegated to the rasterizer — `layoutAndRender`
                // walks the same element into the shared DrawList.
            },
            .pattern => {
                // v1 `.pattern` arm is a no-op; the layout walker in
                // `element_layout.zig` emits the `PassDispatch`
                // directly (it's already holding the resolved box
                // and the component ctx, so cramming the emission
                // through this hook would be busy-work). The arm is
                // reserved for Phase B+ variant-specific dispatch
                // logic that doesn't fit the CPU layout walker —
                // target acquisition for `.single_source`, barrier
                // emission for `.chain`, host-callback invocation
                // for `.host_slot`. The exhaustive switch shape
                // stays so those phases plug in without restructure.
            },
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
}

test "Graph: dispatchPass(.pattern) returns normally (A.6.a)" {
    // Pattern dispatch is handled inline in element_layout.zig's
    // custom walker; this arm is a no-op for the public hook so it
    // never panics. The reserved arms' panic behavior isn't
    // testable in-process (Zig has no panic catch). The exhaustive
    // switch shape + searchable "Phase X:" tags are the load-bearing
    // artifacts; those live in source, not test assertions.
    var g = Graph.init();
    defer g.deinit();
    const sid: component.ShaderId = [_]u8{0} ** 16;
    g.dispatchPass(.{ .pattern = .{ .shader_id = sid } });
}
