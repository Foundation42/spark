//! `src/pass/` — pass-graph compiler module (effects-spec Phase A.3+).
//! Re-exports the public surface so downstream callers (spark.zig,
//! Phase A.5+ factories) import a single entry point.
//!
//! Internal submodules:
//!   - `graph.zig`           — pass-graph compiler shell + exhaustive
//!                             `PassShape` dispatch switch
//!   - `shader_resolver.zig` — `ShaderId` → `ShaderDispatchHandle`
//!                             lookup; cache populated by A.4
//!   - `target_pool.zig`     — transient render-target pool, keyed
//!                             by `(w, h, format)` per Decision #4;
//!                             implemented in Phase B
//!
//! Convention follows `src/layout/kiwi/root.zig` — a directory module
//! with a `root.zig` re-exporter for the clean library boundary.

const graph = @import("graph.zig");
const shader_resolver = @import("shader_resolver.zig");
const target_pool = @import("target_pool.zig");
const pattern_pipeline = @import("pattern_pipeline.zig");

pub const Graph = graph.Graph;
pub const ShaderResolver = shader_resolver.ShaderResolver;
pub const ShaderDispatchHandle = shader_resolver.ShaderDispatchHandle;
pub const ShaderResolverError = shader_resolver.Error;
pub const shaderIdFromName = shader_resolver.shaderIdFromName;
pub const TargetPool = target_pool.TargetPool;
pub const TargetKey = target_pool.TargetKey;
pub const TargetHandle = target_pool.TargetHandle;
pub const PatternPipelineCache = pattern_pipeline.PatternPipelineCache;
