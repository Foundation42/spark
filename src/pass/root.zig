//! `src/pass/` — pass-graph compiler module (effects-spec Phase A.3+).
//! Re-exports the public surface so downstream callers (spark.zig,
//! Phase A.5+ factories) import a single entry point.
//!
//! Internal submodules:
//!   - `graph.zig`                  — pass-graph compiler shell +
//!                                    exhaustive `PassShape` switch
//!   - `shader_resolver.zig`        — `ShaderId` → `ShaderDispatchHandle`
//!                                    lookup; cache populated by A.4
//!   - `target_pool.zig`            — transient render-target pool,
//!                                    keyed by `(w, h, format)` per
//!                                    Decision #4; B.1 implementation
//!   - `pattern_pipeline.zig`              — pattern-pass `VkPipeline`
//!                                           cache, push-constants
//!                                           only (A.6.b)
//!   - `single_source_pipeline.zig`        — single-source filter
//!                                           pipeline cache,
//!                                           descriptor-set + push-
//!                                           constants (B.4.b.1)
//!   - `single_source_descriptor_pool.zig` — per-frame descriptor-set
//!                                           pool for single-source
//!                                           compose dispatches,
//!                                           grow-on-overflow,
//!                                           keep-on-reset (B.4.b.2)
//!
//! Convention follows `src/layout/kiwi/root.zig` — a directory module
//! with a `root.zig` re-exporter for the clean library boundary.

const graph = @import("graph.zig");
const shader_resolver = @import("shader_resolver.zig");
const target_pool = @import("target_pool.zig");
const pattern_pipeline = @import("pattern_pipeline.zig");
const single_source_pipeline = @import("single_source_pipeline.zig");
const single_source_descriptor_pool = @import("single_source_descriptor_pool.zig");
const single_source_factory = @import("single_source_factory.zig");

pub const Graph = graph.Graph;
pub const ShaderResolver = shader_resolver.ShaderResolver;
pub const ShaderDispatchHandle = shader_resolver.ShaderDispatchHandle;
pub const ShaderResolverError = shader_resolver.Error;
pub const shaderIdFromName = shader_resolver.shaderIdFromName;
pub const TargetPool = target_pool.TargetPool;
pub const TargetKey = target_pool.TargetKey;
pub const TargetHandle = target_pool.TargetHandle;
pub const PatternPipelineCache = pattern_pipeline.PatternPipelineCache;
pub const SingleSourcePipelineCache = single_source_pipeline.SingleSourcePipelineCache;
pub const SingleSourceDescriptorPool = single_source_descriptor_pool.SingleSourceDescriptorPool;
pub const SingleSourceFactory = single_source_factory.SingleSourceFactory;
