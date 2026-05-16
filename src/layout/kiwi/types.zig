//! Opaque ID types for the Cassowary solver.
//!
//! `VariableId` and `ConstraintId` are `u32` indices into
//! solver-owned pools — the `enum(u32) { _ }` newtype gives
//! compile-time distinction, so a `VariableId` can't be passed
//! where a `ConstraintId` is expected. IDs stay stable across
//! re-parses for callers that maintain them (matches the
//! project's existing `FontId` / `Registry` pattern in
//! `font/registry.zig` and `component.zig`).
//!
//! This replaces kiwi C++'s `SharedData` / `SharedDataPtr<T>`
//! ref-counted pointer identity. The solver owns the slot; the
//! caller holds a u32 handle. No `Rc`, no `Arc`, no atomic
//! counters.

/// Opaque handle into the solver's variable pool.
pub const VariableId = enum(u32) { _ };

/// Opaque handle into the solver's constraint pool. Returned by
/// `Solver.addConstraint`, consumed by `removeConstraint` and
/// `hasConstraint`.
pub const ConstraintId = enum(u32) { _ };

/// Relational operator carried in a Constraint. Internal name
/// matches kiwi's `OP_LE` / `OP_EQ` / `OP_GE` set, spelled out
/// in Zig idiom.
pub const RelationalOperator = enum { lt_eq, eq, gt_eq };
