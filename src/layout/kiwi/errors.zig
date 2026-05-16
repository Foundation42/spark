//! Error sets for kiwi's public API.
//!
//! Each public `Solver` method has its own narrow error set,
//! mirroring kiwi C++'s exception hierarchy (`errors.h`) with
//! `OutOfMemory` added where allocator failure is possible.
//! `InternalSolverError` is the catch-all for invariant
//! violations during simplex pivoting — it should never occur
//! on legal input but we surface it explicitly rather than
//! panicking. The solver exposes `lastInternalErrorMessage` for
//! diagnostic detail when it does.

pub const AddVariableError = error{
    OutOfMemory,
};

pub const AddConstraintError = error{
    /// The constraint passed in was already added (same handle).
    DuplicateConstraint,
    /// The required-strength set is infeasible after this add.
    UnsatisfiableConstraint,
    OutOfMemory,
    InternalSolverError,
};

pub const RemoveConstraintError = error{
    UnknownConstraint,
    OutOfMemory,
    InternalSolverError,
};

pub const AddEditVariableError = error{
    DuplicateEditVariable,
    /// Edit-variable strength must be strictly less than
    /// `strength.required`. Equality is rejected post-clip via
    /// exact-value compare — see `strength.zig`.
    BadRequiredStrength,
    OutOfMemory,
};

pub const RemoveEditVariableError = error{
    UnknownEditVariable,
    InternalSolverError,
};

pub const SuggestValueError = error{
    UnknownEditVariable,
    InternalSolverError,
};
