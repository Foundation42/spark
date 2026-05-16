//! Internal: tableau column identifier.
//!
//! Every column in the simplex tableau is identified by a
//! `Symbol`. There are five kinds:
//!
//! - **external** — represents a user-visible Variable. One per
//!   `VariableId`, minted lazily on first reference.
//! - **slack**    — introduced for an inequality constraint to
//!   convert it to equality (the slack carries the surplus).
//! - **err**      — introduced for a soft (non-required)
//!   constraint to track its violation; the objective function
//!   minimises a weighted sum of these.
//! - **dummy**    — placeholder used by required equality
//!   constraints; cannot enter the basis.
//! - **invalid**  — the default-constructed sentinel. Never
//!   appears in a valid Row.
//!
//! Symbol uses `id` to disambiguate symbols of the same kind;
//! ids start at 1 (`m_id_tick` in C++ kiwi) so the
//! default-constructed `id=0, kind=.invalid` symbol is unique.
//!
//! Replaces kiwi's `impl::Symbol` ref-counted `SharedData`
//! handle with a plain value type. The solver owns the id-tick
//! counter; symbols are 8 bytes, copyable, hashable.

const std = @import("std");

pub const SymbolKind = enum(u8) {
    invalid,
    external,
    slack,
    /// Renamed from kiwi's `Error` — `error` is a Zig keyword.
    /// Same role: tracks the violation of a soft constraint.
    err,
    dummy,
};

pub const Symbol = struct {
    id: u32 = 0,
    kind: SymbolKind = .invalid,

    /// The default-constructed sentinel.
    pub const invalid: Symbol = .{};

    pub fn isInvalid(self: Symbol) bool {
        return self.kind == .invalid;
    }

    pub fn eql(a: Symbol, b: Symbol) bool {
        return a.id == b.id and a.kind == b.kind;
    }

    /// Total order over Symbols: sort by kind first (in the
    /// numerical order of the enum), then by id. Used by the
    /// solver where deterministic tie-breaks matter.
    pub fn lessThan(_: void, a: Symbol, b: Symbol) bool {
        if (@intFromEnum(a.kind) != @intFromEnum(b.kind)) {
            return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        }
        return a.id < b.id;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "default-constructed Symbol is the invalid sentinel" {
    const s = Symbol{};
    try testing.expect(s.isInvalid());
    try testing.expectEqual(SymbolKind.invalid, s.kind);
    try testing.expectEqual(@as(u32, 0), s.id);
    try testing.expect(Symbol.eql(s, Symbol.invalid));
}

test "eql compares both fields" {
    const a = Symbol{ .id = 5, .kind = .slack };
    const b = Symbol{ .id = 5, .kind = .slack };
    const c = Symbol{ .id = 5, .kind = .err };
    const d = Symbol{ .id = 6, .kind = .slack };
    try testing.expect(Symbol.eql(a, b));
    try testing.expect(!Symbol.eql(a, c));
    try testing.expect(!Symbol.eql(a, d));
}

test "lessThan orders by kind then by id" {
    const ext_high = Symbol{ .id = 100, .kind = .external };
    const slack_low = Symbol{ .id = 1, .kind = .slack };
    const slack_high = Symbol{ .id = 2, .kind = .slack };
    // external (1) < slack (2): kind ordering dominates id.
    try testing.expect(Symbol.lessThan({}, ext_high, slack_low));
    // Same kind: id ordering.
    try testing.expect(Symbol.lessThan({}, slack_low, slack_high));
    try testing.expect(!Symbol.lessThan({}, slack_high, slack_low));
}

test "Symbol is hashable as an AutoHashMap key" {
    var map = std.AutoHashMap(Symbol, u32).init(testing.allocator);
    defer map.deinit();
    try map.put(Symbol{ .id = 1, .kind = .external }, 100);
    try map.put(Symbol{ .id = 2, .kind = .slack }, 200);
    try testing.expectEqual(@as(?u32, 100), map.get(Symbol{ .id = 1, .kind = .external }));
    try testing.expectEqual(@as(?u32, 200), map.get(Symbol{ .id = 2, .kind = .slack }));
    try testing.expectEqual(@as(?u32, null), map.get(Symbol{ .id = 1, .kind = .slack }));
}
