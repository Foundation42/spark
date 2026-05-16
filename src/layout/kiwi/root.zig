//! kiwi — pure-Zig port of the Cassowary linear constraint
//! solver.
//!
//! Algorithm fidelity mirrors kiwi C++ v1.4.2 (nucleic/kiwi,
//! commit `613c5bce`); API ergonomics borrow from cassowary-rs
//! (`90d1df49`) and casuarius (`922a4735`). See
//! `../../../docs/layout.md` for the constraint-substrate design
//! and the reasoning behind the deviations from upstream
//! (explicit `removeVariable`, `beginEdit` / `commitEdit`
//! batching, `fetchChanges()` change-set).
//!
//! Public surface lives here; internal types (Symbol, Row, Tag,
//! EditInfo, solver internals) stay private to their modules
//! and are not re-exported.

const types = @import("types.zig");
pub const VariableId = types.VariableId;
pub const ConstraintId = types.ConstraintId;
pub const RelationalOperator = types.RelationalOperator;

const errors = @import("errors.zig");
pub const AddVariableError = errors.AddVariableError;
pub const AddConstraintError = errors.AddConstraintError;
pub const RemoveConstraintError = errors.RemoveConstraintError;
pub const AddEditVariableError = errors.AddEditVariableError;
pub const RemoveEditVariableError = errors.RemoveEditVariableError;
pub const SuggestValueError = errors.SuggestValueError;

pub const strength = @import("strength.zig");
pub const Strength = strength.Strength;

pub const Term = @import("term.zig").Term;
pub const Expression = @import("expression.zig").Expression;
pub const Constraint = @import("constraint.zig").Constraint;
