//! Comptime generator for single_source Factory boilerplate.
//!
//! `SingleSourceFactory(.{...})` returns a struct exposing `.factory`
//! (a `Component.Factory` ready to register) and `.install(spark)`
//! (a one-liner registration helper). Generated internals: Component
//! struct, create/update/deinit_, snapshot_uniforms, layoutAndRender,
//! vtable.
//!
//! What stays per-effect (the call site provides):
//!   - **`Uniforms` extern struct** — std140-padded, ABI-mirrors the
//!     GLSL push_constant block. The offset/size lock-in test stays
//!     explicit per [[feedback-std140-offset-lockin]]; auto-padding
//!     would compile cleanly while rendering GPU garbage on silent
//!     reorders, defeating the purpose.
//!   - **`apply_attrs(spec) Uniforms`** — the only real per-effect
//!     logic. Parses spec attrs via `params.resolve` and assembles
//!     the Uniforms value.
//!   - **`layout_inflation` + `compute_inflation`** — optional. Pass
//!     a callback when the effect reserves halo room around the
//!     child (drop_shadow); leave null when it renders within child
//!     bounds (frosted_glass). Both fields are populated with the
//!     same function (Factory's `.from_params` for the spec table;
//!     Component's stored inflation for layoutAndRender's child
//!     constraint clamp + return-box compute).
//!
//! What the generator handles uniformly:
//!   - Component struct (arena + parsed root + scope + spark +
//!     stored inflation + uniforms + version).
//!   - create() — arena init, scope dup, fail-fast shader resolver
//!     check, body parse, instance return.
//!   - update() — re-runs apply_attrs, bumps version. Per Decision
//!     #8 inflation is NOT re-evaluated on update (re-inflation
//!     would cascade through layout).
//!   - deinit_() — scope unregister, arena deinit, scope free,
//!     allocator destroy.
//!   - snapshot_uniforms() — memset 0, memcpy Uniforms bytes.
//!   - layoutAndRender() — walk child at inflated origin with
//!     inflated constraints, return inflated box. With zero
//!     inflation this is a clean passthrough.
//!   - vtable + Factory.pass_shape = .single_source.
//!
//! Caching: factories are cacheable as of B.6.a (cache substrate
//! handles routing tags through replay-with-offset). No
//! disable_cache flag plumbed.
//!
//! Usage:
//!
//! ```zig
//! const Uniforms = extern struct {
//!     blur_radius: f32,
//!     _pad: [3]f32 = .{ 0, 0, 0 },
//!     tint_color: [4]f32,
//! };
//!
//! fn applyAttrs(spec: *const components.Spec) Uniforms {
//!     return .{
//!         .blur_radius = params.resolve(f32, spec, "blur", 12.0),
//!         .tint_color = params.resolve([4]f32, spec, "tint",
//!             .{ 1, 1, 1, 0.0625 }),
//!     };
//! }
//!
//! pub const Effect = single_source_factory.SingleSourceFactory(.{
//!     .name = "frosted_glass",
//!     .shader = "frosted_glass.frag",
//!     .Uniforms = Uniforms,
//!     .apply_attrs = applyAttrs,
//! });
//! pub const factory = Effect.factory;
//! pub const install = Effect.install;
//!
//! test "Uniforms: std140 layout offsets" {
//!     try testing.expectEqual(@as(usize, 0),
//!         @offsetOf(Uniforms, "blur_radius"));
//!     try testing.expectEqual(@as(usize, 16),
//!         @offsetOf(Uniforms, "tint_color"));
//!     try testing.expectEqual(@as(usize, 32), @sizeOf(Uniforms));
//! }
//! ```

const std = @import("std");
const element = @import("../element.zig");
const element_layout = @import("../element_layout.zig");
const component_mod = @import("../component.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const markdown = @import("../markdown.zig");
const shader_resolver = @import("shader_resolver.zig");

pub const Error = error{
    SingleSourceShaderNotRegistered,
};

/// Returns a struct exposing `.factory` and `.install(spark)` for a
/// single_source effect. See module doc for usage.
pub fn SingleSourceFactory(comptime config: anytype) type {
    const UniformsT = config.Uniforms;
    const SHADER_ID: component_mod.ShaderId = shader_resolver.shaderIdFromName(config.shader);

    comptime {
        if (@sizeOf(UniformsT) > element.MAX_PASS_UNIFORM_BYTES) {
            @compileError("SingleSourceFactory: Uniforms exceeds MAX_PASS_UNIFORM_BYTES");
        }
    }

    return struct {
        const Component = struct {
            arena: std.heap.ArenaAllocator,
            root: element.Element,
            scope: []u8,
            spark: ?*spark_mod.Spark = null,
            inflation: component_mod.Edges,
            uniforms: UniformsT,
            version: u64 = 0,
        };

        pub const factory: component_mod.Factory = .{
            .create = create,
            .update = update,
            .deinit = deinit_,
            .pass_shape = .{ .single_source = .{
                .shader_id = SHADER_ID,
                .layout_inflation = if (@hasField(@TypeOf(config), "layout_inflation"))
                    config.layout_inflation
                else
                    null,
            } },
        };

        pub fn install(spark: *spark_mod.Spark) !void {
            try spark.registry.register(config.name, factory);
        }

        fn create(
            spark: *spark_mod.Spark,
            allocator: std.mem.Allocator,
            spec: *const components.Spec,
        ) anyerror!component_mod.Instance {
            _ = spark.shader_resolver.resolve(SHADER_ID) catch return Error.SingleSourceShaderNotRegistered;

            const c = try allocator.create(Component);
            errdefer allocator.destroy(c);

            const id_raw = spec.id orelse config.name;

            const inf: component_mod.Edges = if (@hasField(@TypeOf(config), "compute_inflation"))
                config.compute_inflation(spec)
            else
                .{};

            c.* = .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .root = element.Element{ .paragraph = &[_]element.Element{} },
                .scope = undefined,
                .spark = spark,
                .inflation = inf,
                .uniforms = config.apply_attrs(spec),
                .version = 0,
            };
            errdefer c.arena.deinit();

            c.scope = try allocator.dupe(u8, id_raw);
            errdefer allocator.free(c.scope);

            c.root = try markdown.parseWithStateAndScope(
                c.arena.allocator(),
                spec.body,
                spark.theme,
                spark.registry,
                spark.host_state,
                c.scope,
            );

            return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
        }

        fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
            const c: *Component = @ptrCast(@alignCast(ctx));
            const prev_version = c.version;
            // Decision #8: inflation resolves ONCE at create. update()
            // touches only uniforms — animating within the reserved
            // edge is fine; growing requires recreate via #id change.
            c.uniforms = config.apply_attrs(spec);
            c.version = prev_version +% 1;
        }

        fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const c: *Component = @ptrCast(@alignCast(ctx));
            if (c.spark) |sp| sp.registry.deinitScope(c.scope);
            c.arena.deinit();
            allocator.free(c.scope);
            allocator.destroy(c);
        }

        fn snapshotUniforms(ctx: *anyopaque, out: []u8) usize {
            const c: *const Component = @ptrCast(@alignCast(ctx));
            const bytes = std.mem.asBytes(&c.uniforms);
            @memset(out, 0);
            @memcpy(out[0..bytes.len], bytes);
            return bytes.len;
        }

        /// Walk the child subtree at inflated origin with inflated
        /// constraints, return the inflated box. Walker reads
        /// box.{w,h} as the single_source dispatch's target_size, so
        /// the returned box IS the GPU target size — invariant
        /// preserved across both inflated and zero-inflation cases.
        fn layoutAndRender(
            ctx: *anyopaque,
            origin: [2]f32,
            constraints: element.Constraints,
            lc: *element.LayoutCtx,
            out: *element.DrawList,
        ) anyerror!element.Box {
            const c: *Component = @ptrCast(@alignCast(ctx));
            const inf = c.inflation;

            var child_constraints = constraints;
            if (std.math.isFinite(child_constraints.max_w)) {
                child_constraints.max_w = @max(0, child_constraints.max_w - inf.left - inf.right);
            }
            if (std.math.isFinite(child_constraints.max_h)) {
                child_constraints.max_h = @max(0, child_constraints.max_h - inf.top - inf.bottom);
            }

            const child_box = try element_layout.layoutAndRenderCached(
                c.root,
                .{ origin[0] + inf.left, origin[1] + inf.top },
                child_constraints,
                lc,
                out,
            );

            return .{
                .x = origin[0],
                .y = origin[1],
                .w = child_box.w + inf.left + inf.right,
                .h = child_box.h + inf.top + inf.bottom,
                .baseline = 0,
            };
        }

        const vtable: element.ElementVTable = .{
            .layout_and_render = layoutAndRender,
            .snapshot_uniforms = snapshotUniforms,
            // Cacheable as of Phase B.6.a — substrate handles primitive
            // routing tags through cache via replay-with-offset.
        };
    };
}
