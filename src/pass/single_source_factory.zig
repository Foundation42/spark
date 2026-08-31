//! Comptime generator for single_source Factory boilerplate.
//!
//! `SingleSourceFactory(.{...})` returns a struct exposing `.factory`
//! (a `Component.Factory` ready to register) and `.install(spark)`
//! (a one-liner registration helper). Generated internals: Component
//! struct, create/update/deinit_, snapshot_uniforms, layoutAndRender,
//! vtable.
//!
//! **Scope, as of C.3.** One effect ships against this: `:::liquid_glass`.
//! `:::drop_shadow` and `:::frosted_glass` were both generated here once and
//! both left, because a separable Gaussian is two images and a single_source
//! pass owns one offscreen target. The generator is right for what it covers
//! — one filter over one image — and a chain is a different shape, not a
//! richer version of this one. There is no ChainFactory generator yet and
//! two hand-written chains is not enough evidence for one.
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
//!     child; leave null when it renders within child bounds, which
//!     `:::liquid_glass` does. Both fields are populated with the
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
//!     radius: f32,
//!     refraction: f32,
//!     edge_softness: f32,
//!     rim_brightness: f32,
//!     tint: [4]f32,
//! };
//!
//! fn applyAttrs(spec: *const components.Spec) Uniforms {
//!     return .{
//!         .radius = params.resolve(f32, spec, "radius", 0.15),
//!         .refraction = params.resolve(f32, spec, "refraction", 0.15),
//!         .edge_softness = params.resolve(f32, spec, "edge_softness", 0.005),
//!         .rim_brightness = params.resolve(f32, spec, "rim_brightness", 0.3),
//!         .tint = params.resolve([4]f32, spec, "tint", .{ 1, 1, 1, 0.05 }),
//!     };
//! }
//!
//! pub const Effect = single_source_factory.SingleSourceFactory(.{
//!     .name = "liquid_glass",
//!     .shader = "liquid_glass.frag",
//!     .Uniforms = Uniforms,
//!     .apply_attrs = applyAttrs,
//! });
//! pub const factory = Effect.factory;
//! pub const install = Effect.install;
//!
//! test "Uniforms: std140 layout offsets" {
//!     try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "radius"));
//!     try testing.expectEqual(@as(usize, 16), @offsetOf(Uniforms, "tint"));
//!     try testing.expectEqual(@as(usize, 32), @sizeOf(Uniforms));
//! }
//! ```

const std = @import("std");
const element = @import("../element.zig");
const layout_cache = @import("../layout_cache.zig");
const element_layout = @import("../element_layout.zig");
const component_mod = @import("../component.zig");
const components = @import("../markdown_components.zig");
const spark_mod = @import("../spark.zig");
const markdown = @import("../markdown.zig");
const shader_resolver = @import("shader_resolver.zig");
const params = @import("../params.zig");

pub const Error = error{
    SingleSourceShaderNotRegistered,
};

/// Returns a struct exposing `.factory` and `.install(spark)` for a
/// single_source effect. See module doc for usage.
/// A bare `{backdrop}` means true, `{backdrop=false}` means false, absent
/// means false. `params.resolve` cannot express this — a valueless attribute
/// trims to empty, which it reports as unparseable and answers with the
/// caller's default, so the bare flag read as OFF and the effect silently
/// filtered its own children instead.
/// `surface=<name>` — the host image this effect is a window onto.
///
/// A raw attribute read rather than `params.resolve`, because the
/// value is a NAME and not a number: `resolve` parses toward a type
/// and answers a default when it cannot, which for a string would
/// mean silently substituting one surface for another.
fn surfaceName(spec: *const components.Spec) []const u8 {
    for (spec.attrs) |a| {
        if (!std.mem.eql(u8, a.key, "surface")) continue;
        return std.mem.trim(u8, a.value, " \t");
    }
    return "";
}

/// Whether an `update` takes a new surface name from the spec.
///
/// Split out and public so the rule can be gated without a device: it
/// is one boolean and it is the whole of the difference between "a
/// panel can change which buffer it looks at" and "a panel parses one
/// name and is stuck with it".
///
/// Both halves matter. The arm check is why a `.subtree` or
/// `.backdrop` effect never becomes a host window mid-life — that
/// decision is made before layout and routes the children. The
/// emptiness check is why a re-fire whose spec has no `surface=` at
/// all (a `:::update` touching some other attribute) leaves the name
/// alone instead of blanking it, which would composite nothing and
/// look like the host stopped answering.
pub fn adoptsSurface(source: element.PassSource, new_name: []const u8) bool {
    return source == .host_named and new_name.len > 0;
}

fn readFlag(spec: *const components.Spec, key: []const u8) bool {
    for (spec.attrs) |a| {
        if (!std.mem.eql(u8, a.key, key)) continue;
        const t = std.mem.trim(u8, a.value, " \t");
        if (t.len == 0) return true; // bare — presence is the value
        if (std.ascii.eqlIgnoreCase(t, "true")) return true;
        return false;
    }
    return false;
}

pub fn SingleSourceFactory(comptime config: anytype) type {
    const UniformsT = config.Uniforms;
    const SHADER_ID: component_mod.ShaderId = shader_resolver.shaderIdFromName(config.shader);

    comptime {
        // The budget is the range MINUS the display head every effect
        // block carries — see `element.PASS_UNIFORM_OFFSET`.
        if (@sizeOf(UniformsT) > element.MAX_PASS_UNIFORM_BYTES - element.PASS_UNIFORM_OFFSET) {
            @compileError("SingleSourceFactory: Uniforms exceeds the per-effect push budget");
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
            /// The body text this instance's `root` was parsed from.
            body: component_mod.Body = .{},
            /// Resolve-once: see `passSource`.
            source: element.PassSource = .subtree,
            /// Which host image a `.host_named` effect samples. Empty
            /// otherwise. Resolved once at create, beside `source`, and
            /// for the same reason.
            surface: element.HostSurface = .{},
            /// The effect's own minimum box, when it declares one.
            ///
            /// Resolved ONCE at create from the spec, exactly as
            /// `inflation` is and for the same reason: a size that
            /// changed on update would cascade through layout. Zero
            /// means "take the child's size", which is what every
            /// filter effect wants.
            min_size: [2]f32 = .{ 0, 0 },
            /// This instance's composite corner radius, in pixels.
            ///
            /// Re-read on every ingest rather than resolved once like
            /// `min_size`, because a radius does not cascade through
            /// layout — it only changes what the composite is poured
            /// into — so `radius=${state.r}` is a reasonable thing for a
            /// document to write.
            corner_radius: f32 = 0,
            /// `align=` / `text_align=`, inherited by everything under
            /// this effect. See `element.AlignAttrs`.
            alignment: element.AlignAttrs = .{},
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
                .min_size = if (@hasField(@TypeOf(config), "compute_min_size"))
                    config.compute_min_size(spec)
                else
                    .{ 0, 0 },
                .corner_radius = params.resolve(f32, spec, "radius", 0),
                .alignment = element.AlignAttrs.readFrom(spec),
                .version = 0,
                .body = .{},
                // `surface=` wins over `{backdrop}` when both are
                // written, because it is the more specific request:
                // one names an image, the other says "whatever is
                // behind me". An effect asking for both is a document
                // being edited, and answering the named one keeps the
                // panel showing what its author last typed.
                .source = if (surfaceName(spec).len > 0)
                    .host_named
                else if (readFlag(spec, "backdrop"))
                    .backdrop
                else
                    .subtree,
                .surface = element.HostSurface.from(surfaceName(spec)),
            };
            errdefer c.arena.deinit();

            // The namespace this block's CHILDREN are parsed into: this
            // instance's own registry key, which is unique by construction.
            // `id_raw` alone is not — every unnamed block shares the empty
            // string, in this document and in every other one, so two panels
            // each holding an unnamed effect resolved their children to one
            // set of instances. See `Spec.scope`.
            c.scope = try allocator.dupe(u8, component_mod.specScope(spec, id_raw));
            errdefer allocator.free(c.scope);

            _ = c.body.adopt(spec.body);
            c.root = try markdown.parseWithStateAndScope(
                c.arena.allocator(),
                spec.body,
                spark.theme,
                spark.registry,
                component_mod.specState(spec, spark.host_state),  // the DOCUMENT's state, not the Spark's root — see specState
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
            // A radius changes what the composite is poured into and
            // nothing about layout, so unlike `inflation` and
            // `min_size` it is safe to re-read here.
            c.corner_radius = params.resolve(f32, spec, "radius", 0);
            c.alignment = element.AlignAttrs.readFrom(spec);
            c.version = prev_version +% 1;

            // **The surface NAME can change under a live instance; the
            // ARM cannot.** They look like the same question and are
            // not.
            //
            // `c.source` decides where the children's drawlist
            // primitives go, and `passSource` is asked BEFORE layout —
            // flipping it mid-frame would route the children one way
            // and fill the target the other, so it resolves once at
            // create and stays. The name is read much later, at record
            // time in `recordSingleSourceCompose`, long after the
            // children have been placed. Nothing depends on it holding
            // still.
            //
            // So `surface=${state.surface}` works, and a document can
            // switch which engine buffer a panel is a window onto from
            // a button, without a remount. Before this it parsed its
            // first value, drew it, and never changed again — correct
            // on the first frame, which is the worst way to be wrong.
            //
            // Only when the arm is already `.host_named` and the new
            // spec still names something: an edit from `surface=x` to
            // `{backdrop}` is an arm change and needs a new `#id`, the
            // same rule inflation has.
            if (adoptsSurface(c.source, surfaceName(spec))) {
                c.surface = element.HostSurface.from(surfaceName(spec));
            }

            // The body is authored text too, and it can change under a live
            // instance — a hot-reloaded document hands the same `#id` a new
            // body. Re-parse when it does, and only then: an unchanged body
            // must not throw away this subtree's layout cache on every
            // `:::update`.
            if (c.body.adopt(spec.body)) {
                if (c.spark) |sp| {
                    // The block-layout cache is keyed by element ADDRESS
                    // (`layout_cache.elementIdentity`), which is sound while a
                    // parsed tree lives as long as its document — and false the
                    // instant one is re-parsed into the same arena, because the
                    // recycled allocations land on the same addresses and the new
                    // heading collides with the old one's cached draws. Dropping
                    // the cache is the honest price of a re-parse, and a re-parse
                    // is a human-scale event.
                    sp.layout_cache.clear();
                    // Empty first, so a parse that fails leaves a valid root
                    // rather than one pointing into the arena we just reset.
                    c.root = element.Element{ .paragraph = &[_]element.Element{} };
                    _ = c.arena.reset(.retain_capacity);
                    c.root = try markdown.parseWithStateAndScope(
                        c.arena.allocator(),
                        spec.body,
                        sp.theme,
                        sp.registry,
                        component_mod.specState(spec, sp.host_state),  // the DOCUMENT's state, not the Spark's root — see specState
                        c.scope,
                    );
                }
            }
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

            var child_constraints = c.alignment.apply(constraints);
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

            var w = child_box.w + inf.left + inf.right;
            var h = child_box.h + inf.top + inf.bottom;

            // The MINIMUM this effect declared for itself (zero for a
            // filter, which takes its child's size).
            //
            // Every effect until now wrapped something, so taking the
            // child's size was the only sensible answer. `:::gbuffer` is
            // a WINDOW: its body is usually empty, so the child box is
            // zero and the pass would composite into a rectangle with no
            // area — a panel that runs, allocates nothing, reports no
            // error and shows nothing at all, which is a long afternoon.
            //
            // Clamped up rather than overridden, so a window with content
            // in it still grows to fit.
            w = @max(w, c.min_size[0]);
            h = @max(h, c.min_size[1]);
            // The parent's constraint still wins — a declared size is
            // what the effect WANTS, not a licence to overflow the
            // column it was placed in.
            if (std.math.isFinite(constraints.max_w)) w = @min(w, constraints.max_w);
            if (std.math.isFinite(constraints.max_h)) h = @min(h, constraints.max_h);

            return .{
                .x = origin[0],
                .y = origin[1],
                .w = w,
                .h = h,
                .baseline = 0,
            };
        }

        /// Generated effects had NO `content_version`, which meant
        /// `layout_cache.versionFor` answered a constant 0 for them and the
        /// cached drawlist was replayed forever: neither an attribute change
        /// on the effect nor a state change in a child could invalidate it.
        /// A slider inside `:::liquid_glass` drove the plane and never drew
        /// its own new position — the same freeze the hand-written effects
        /// had, arrived at by a shorter route.
        /// `{backdrop}` — filter what is BEHIND the element instead of what
        /// it wraps, and let the children draw over the result on MAIN. See
        /// `element.PassSource`.
        ///
        /// Answered BEFORE layout, which is why it cannot ride on the
        /// uniforms hook: the walker needs it to decide where the children's
        /// drawlist primitives go. Resolved once at create — flipping it
        /// mid-frame would route the children one way and fill the target the
        /// other.
        fn passSource(ctx: *anyopaque) element.PassSource {
            const c: *const Component = @ptrCast(@alignCast(ctx));
            return c.source;
        }

        /// Which host image a `.host_named` effect samples. Read
        /// beside `passSource` and answered from the same resolve-once
        /// field, so the two can never disagree about what this pass is.
        fn hostSurface(ctx: *anyopaque) element.HostSurface {
            const c: *const Component = @ptrCast(@alignCast(ctx));
            return c.surface;
        }

        fn contentVersion(ctx: *anyopaque) u64 {
            const c: *const Component = @ptrCast(@alignCast(ctx));
            return c.version ^ layout_cache.aggregateRootVersion(c.root);
        }

        fn cornerRadius(ctx: *anyopaque) f32 {
            const c: *const Component = @ptrCast(@alignCast(ctx));
            return c.corner_radius;
        }

        const vtable: element.ElementVTable = .{
            .layout_and_render = layoutAndRender,
            .snapshot_uniforms = snapshotUniforms,
            .content_version = contentVersion,
            .pass_source = passSource,
            .host_surface = hostSurface,
            .corner_radius = cornerRadius,
            // Cacheable as of Phase B.6.a — substrate handles primitive
            // routing tags through cache via replay-with-offset.
        };
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "adoptsSurface: the NAME may change under a live panel, the ARM may not" {
    // The distinction this whole rule exists for. `surface=` is read at
    // record time, after the children have been routed, so it can move.
    // `PassSource` is asked BEFORE layout and decides where those
    // children go, so it cannot — an effect that flipped arm mid-frame
    // would route its children one way and fill its target the other.
    try testing.expect(adoptsSurface(.host_named, "albedo"));

    // Rule 1: assert the inequality. A predicate that answered true for
    // everything would pass the line above and turn every `:::pattern`
    // and every `{backdrop}` into a host window the moment a bound
    // attribute fired.
    try testing.expect(!adoptsSurface(.subtree, "albedo"));
    try testing.expect(!adoptsSurface(.backdrop, "albedo"));
}

test "adoptsSurface: a re-fire with no surface= leaves the name alone" {
    // A `:::update` that touches some other attribute re-fires the whole
    // spec, and a synthetic spec need not carry `surface=` at all.
    // Adopting an empty name there would composite nothing — a blank
    // panel that reads as the host having stopped answering, from a
    // document edit that never mentioned the surface.
    try testing.expect(!adoptsSurface(.host_named, ""));
}

test "surfaceName: an absent attribute is empty, and whitespace is trimmed" {
    // `surface = normal ` from a document mid-edit has to resolve to the
    // same name as `surface=normal`, because the host compares it with
    // `mem.eql` and a trailing space is a surface nobody has.
    var attrs = [_]components.Attr{.{ .key = "surface", .value = "  normal \t" }};
    const spec = components.Spec{ .name = "gbuffer", .id = null, .attrs = &attrs, .body = "" };
    try testing.expectEqualStrings("normal", surfaceName(&spec));

    var other = [_]components.Attr{.{ .key = "mode", .value = "heat" }};
    const none = components.Spec{ .name = "gbuffer", .id = null, .attrs = &other, .body = "" };
    try testing.expectEqualStrings("", surfaceName(&none));
}
