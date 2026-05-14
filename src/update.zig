//! `:::update` micro-stream dispatch path. Stage 8a of the
//! live-documents staging path — the LLM-streamed-delta-into-live-
//! component hot path the reactive substrate (stages 7d/e/f) was
//! built to enable.
//!
//! Two roles:
//!
//! 1. **Wire format** — parses `:::update {...}\nbody\n:::` blocks
//!    out of a raw byte stream. No cmark, no Element walker, no
//!    layout machinery is on this path; only the directive lexer
//!    from `markdown_components.zig` is reused (because the syntax
//!    is the same `:::name {attrs}` shape live-components use).
//!
//! 2. **Dispatch** — routes each parsed Spec to one of two backends:
//!
//!      a. *Component-targeted* — `:::update {#id action=NAME}`
//!         body BODY :::` → `registry.handleUpdate(id, action, body)`,
//!         which calls the cached instance's `Factory.handle_update`.
//!         This is the path for opaque streaming payloads (chart
//!         points, log lines, raw bytes) that don't fit a flat
//!         state map.
//!
//!      b. *State-targeted* — `:::update {target=state.path}\nVALUE\n:::`
//!         → `state.set(path, body)`. The reactive substrate from
//!         stage 7e handles propagation: subscribers fire, bound
//!         components re-update, `state.dirty` triggers re-layout.
//!         This is the canonical path for declarative-state mutations.
//!
//! Either path flips `state.dirty` so the renderer's existing
//! re-layout trigger fires. (The state-target case does that
//! transitively through `state.set`; component-target does it
//! explicitly after the handler returns, so a component that mutates
//! purely internal state still triggers a redraw.)
//!
//! ### Allocation policy
//!
//! Callers supply an arena. Per-update overhead is one attr-list
//! slice + one body dupe, both arena-allocated. A 100-update burst
//! allocates tens of KB, then the caller resets the arena in one
//! shot. Steady-state cost is dominated by `parseDirectiveLine`'s
//! attribute parse, which is hundreds of bytes of string work for a
//! typical handful of attrs.
//!
//! ### Why share the `:::name {}` lexer
//!
//! `:::update` could have used a custom one-line syntax (e.g.
//! `@update#id action=NAME body...`), but reusing the existing
//! directive grammar means:
//!
//!   * The substitution + attribute parsing rules are already proven.
//!   * An author can hand-write a test update directive and read it
//!     with the same eye they read `:::box` blocks.
//!   * The streaming path's parser is ~80 lines: a wrapper around
//!     `parseDirectiveLine` plus a body scanner.

const std = @import("std");
const components = @import("markdown_components.zig");
const component_mod = @import("component.zig");
const state_mod = @import("state.zig");

pub const Error = error{
    /// Source byte stream doesn't open with a valid `:::update`
    /// directive line — either no `:::` prefix, no directive name,
    /// or a name other than `update`.
    InvalidUpdate,
    /// Opening `:::update` line was found but no closing `:::` line
    /// followed before end-of-source.
    UnterminatedUpdate,
    /// Dispatched directive had neither `#id` (for component target)
    /// nor `target=` (for state target). One must be present.
    InvalidUpdateDirective,
    /// `#id` was present but `action=` was missing — required for
    /// component-target dispatch.
    MissingAction,
} || components.Error || component_mod.Error;

/// One parsed `:::update` block plus the byte offset immediately
/// after its close. Callers advance `source` by `consumed` for the
/// next iteration; `applyAll` does this loop for you.
pub const ParsedUpdate = struct {
    spec: components.Spec,
    consumed: usize,
};

/// Parse one `:::update {...}\nbody\n:::` block from the front of
/// `source`. Skips leading whitespace + blank lines. Returns null
/// when `source` is whitespace-only (end of stream); errors when the
/// first non-blank line isn't a recognisable `:::update` open.
///
/// Body strings have leading + trailing whitespace stripped to match
/// the rule `preprocess` applies to live-component bodies, so callers
/// don't have to worry about a stray trailing newline ending up in
/// e.g. a color value.
pub fn parseUpdate(arena: std.mem.Allocator, source: []const u8) Error!?ParsedUpdate {
    // Skip leading whitespace / blank lines.
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    if (i >= source.len) return null;

    // Open line: must trim down to `:::name {...}` shape.
    const open_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
    const open_line = std.mem.trim(u8, source[i..open_end], " \t\r");
    if (!std.mem.startsWith(u8, open_line, ":::")) return error.InvalidUpdate;
    const after = std.mem.trim(u8, open_line[3..], " \t");
    if (after.len == 0) return error.InvalidUpdate;

    // Parse the directive. Updates never carry `${}` references in
    // their attrs (the LLM resolves before emitting), so we pass null
    // for state — substitution would be a no-op anyway.
    var spec = components.parseDirectiveLine(arena, after, null) catch return error.InvalidUpdate;
    if (!std.mem.eql(u8, spec.name, "update")) return error.InvalidUpdate;

    // Body scan: every line until the next standalone `:::` close.
    const body_start: usize = if (open_end < source.len) open_end + 1 else open_end;
    var j = body_start;
    while (j < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, j, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[j..line_end], " \t\r");
        if (std.mem.eql(u8, line, ":::")) {
            const body_raw = source[body_start..j];
            const body_trim = std.mem.trim(u8, body_raw, " \t\r\n");
            spec.body = try arena.dupe(u8, body_trim);
            const consumed = if (line_end < source.len) line_end + 1 else line_end;
            return .{ .spec = spec, .consumed = consumed };
        }
        if (line_end >= source.len) break;
        j = line_end + 1;
    }
    return error.UnterminatedUpdate;
}

/// Dispatch one already-parsed update Spec. Decision tree:
///
///   * `spec.id != null` → component-targeted. `action=` attr is
///     required; the registry looks up `id` and calls
///     `Factory.handle_update(ctx, action, body)`.
///   * `target=state.path` attr → state-targeted. Calls
///     `state.set(path, body)`; the reactive layer handles the rest.
///   * Neither present → `InvalidUpdateDirective`.
///
/// `state.dirty` is bumped on success regardless of dispatch path so
/// the renderer relays out next frame.
pub fn applyUpdate(
    state: *state_mod.State,
    registry: *component_mod.Registry,
    spec: components.Spec,
) anyerror!void {
    if (spec.id) |id| {
        const action = findAttr(spec.attrs, "action") orelse return error.MissingAction;
        try registry.handleUpdate(id, action, spec.body);
        // Component handler may have mutated only its own opaque
        // state — flip dirty explicitly so the renderer wakes up.
        state.dirty = true;
        return;
    }
    if (findAttr(spec.attrs, "target")) |target| {
        const key: []const u8 = if (std.mem.startsWith(u8, target, "state."))
            target["state.".len..]
        else
            target;
        try state.set(key, spec.body);
        return;
    }
    return error.InvalidUpdateDirective;
}

/// Parse + dispatch every `:::update` block in `source`. Returns the
/// number of updates applied. Stops at end-of-source. Errors on the
/// first malformed update — the caller's arena reset cleans up.
pub fn applyAll(
    arena: std.mem.Allocator,
    state: *state_mod.State,
    registry: *component_mod.Registry,
    source: []const u8,
) anyerror!usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < source.len) {
        const parsed_opt = try parseUpdate(arena, source[i..]);
        const parsed = parsed_opt orelse break;
        try applyUpdate(state, registry, parsed.spec);
        count += 1;
        i += parsed.consumed;
    }
    return count;
}

fn findAttr(attrs: []const components.Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseUpdate: state-target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = (try parseUpdate(arena.allocator(),
        \\:::update {target=state.box_color}
        \\red
        \\:::
        \\
    )).?;
    try testing.expectEqualStrings("update", p.spec.name);
    try testing.expect(p.spec.id == null);
    try testing.expectEqualStrings("red", p.spec.body);
    const target = findAttr(p.spec.attrs, "target").?;
    try testing.expectEqualStrings("state.box_color", target);
}

test "parseUpdate: component-target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = (try parseUpdate(arena.allocator(),
        \\:::update {#bx action=set-color}
        \\orange
        \\:::
    )).?;
    try testing.expectEqualStrings("bx", p.spec.id.?);
    try testing.expectEqualStrings("orange", p.spec.body);
    try testing.expectEqualStrings("set-color", findAttr(p.spec.attrs, "action").?);
}

test "parseUpdate: multi-line body preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = (try parseUpdate(arena.allocator(),
        \\:::update {#chart action=append}
        \\00:01, 7400, 24.5
        \\00:02, 7450, 24.8
        \\:::
    )).?;
    try testing.expect(std.mem.indexOf(u8, p.spec.body, "00:01") != null);
    try testing.expect(std.mem.indexOf(u8, p.spec.body, "00:02") != null);
}

test "parseUpdate: leading whitespace skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = (try parseUpdate(arena.allocator(),
        \\
        \\
        \\:::update {target=x}
        \\v
        \\:::
    )).?;
    try testing.expectEqualStrings("v", p.spec.body);
}

test "parseUpdate: returns null on whitespace-only input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try parseUpdate(arena.allocator(), "\n\n   \n")) == null);
    try testing.expect((try parseUpdate(arena.allocator(), "")) == null);
}

test "parseUpdate: errors on non-update directive name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidUpdate, parseUpdate(arena.allocator(),
        \\:::box {color=red}
        \\:::
    ));
}

test "parseUpdate: errors on missing close" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnterminatedUpdate, parseUpdate(arena.allocator(),
        \\:::update {target=x}
        \\value
    ));
}

test "applyUpdate: state-target hits state.set" {
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var registry = component_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const attrs = [_]components.Attr{.{ .key = "target", .value = "state.box_color" }};
    const spec: components.Spec = .{ .name = "update", .attrs = &attrs, .body = "red" };
    try applyUpdate(&st, &registry, spec);

    try testing.expectEqualStrings("red", st.get("box_color").?);
    try testing.expect(st.dirty);
}

test "applyUpdate: target without state. prefix also works" {
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var registry = component_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const attrs = [_]components.Attr{.{ .key = "target", .value = "raw_key" }};
    const spec: components.Spec = .{ .name = "update", .attrs = &attrs, .body = "v" };
    try applyUpdate(&st, &registry, spec);
    try testing.expectEqualStrings("v", st.get("raw_key").?);
}

test "applyUpdate: no #id and no target errors" {
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var registry = component_mod.Registry.init(testing.allocator);
    defer registry.deinit();
    const spec: components.Spec = .{ .name = "update", .body = "x" };
    try testing.expectError(error.InvalidUpdateDirective, applyUpdate(&st, &registry, spec));
}

test "applyAll: parses + dispatches multiple state updates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var registry = component_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const count = try applyAll(arena.allocator(), &st, &registry,
        \\:::update {target=state.a}
        \\1
        \\:::
        \\
        \\:::update {target=state.b}
        \\2
        \\:::
        \\
        \\:::update {target=state.a}
        \\3
        \\:::
    );
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("3", st.get("a").?);
    try testing.expectEqualStrings("2", st.get("b").?);
}

test "applyAll: empty / whitespace-only source returns 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st = state_mod.State.init(testing.allocator);
    defer st.deinit();
    var registry = component_mod.Registry.init(testing.allocator);
    defer registry.deinit();
    try testing.expectEqual(@as(usize, 0), try applyAll(arena.allocator(), &st, &registry, "\n\n"));
}

// Component-target end-to-end test lives in component.zig (where the
// test factory + handler counters already exist). Replicating that
// scaffolding here would just duplicate state.
