//! `:::svg-stream` — async vector graphics from an image-class
//! model (stage 13d.3). Sibling of [`:::llm-stream`](llm_stream.zig);
//! shares the IoChannel + JobSystem plumbing, but the wire format
//! is different from chat completions.
//!
//! ### Wire format
//!
//! Recraft V4.1 on OpenRouter is an image-generation model served
//! behind the `POST /chat/completions` endpoint. Despite the chat
//! framing it does **not** stream tokens — it returns a single
//! JSON response after several seconds of upstream work:
//!
//!     {
//!       "choices": [{
//!         "message": {
//!           "content": null,
//!           "images": [{
//!             "type": "image_url",
//!             "image_url": {
//!               "url": "data:image/svg+xml;base64,PHN2ZyB4bWxu…"
//!             }
//!           }]
//!         }
//!       }]
//!     }
//!
//! We send `stream:false`, accumulate the raw response into one
//! buffer, then on `.end`: parse the JSON, base64-decode the data
//! URL, run the bytes through `svg.parse` + parallel tessellate,
//! and swap the mesh in. The "stream" in `:::svg-stream` is about
//! "fetched asynchronously off the render thread" — the renderer
//! never blocks on Recraft's queue — not about token-by-token
//! progressive paint. If a future SVG model actually streams its
//! output, that's a separate code path.
//!
//! Default provider is OpenRouter (`provider=openai`,
//! `model=recraft-ai/recraft-v3-svg` or whatever Recraft handle is
//! current); any OpenAI-compatible endpoint that returns text
//! works. The component sets `max_tokens` higher than llm-stream
//! by default (SVG strings dwarf prose strings).
//!
//! Author writes:
//!
//!     :::svg-stream {#bowl
//!       provider=openai
//!       endpoint=https://openrouter.ai/api/v1/chat/completions
//!       model=recraft-ai/recraft-v3-svg
//!       api_key_env=OPENROUTER_DYNABOOK
//!       prompt="A bowl of petunias, vector art"
//!       width=480
//!       max_tokens=8000
//!       auto_start=false }
//!     :::
//!
//! ### Re-tessellation cadence
//!
//! For v0 we re-tessellate on every chunk. Recraft's chunks tend
//! to be small (per-line of SVG) so this is bounded — and 13d.2's
//! parallel tessellation makes the per-chunk cost negligible. If
//! profiling shows otherwise, debounce to (say) every 50 ms via
//! the existing IoChannel timer plumbing.
//!
//! ### Cancellation invariant
//!
//! Identical to embedded-document + llm-stream: a `PendingSvgStream`
//! is heap-allocated at submit time; Component holds a back-pointer
//! for the cancel signal only; the completion handler owns its
//! lifetime. See [[project-io-channel-cancellation]].

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const state_mod = @import("../state.zig");
const io = @import("../io_channel.zig");
const dotenv = @import("../dotenv.zig");
const svg = @import("../svg.zig");
const tess = @import("../svg_tessellate.zig");
const jobs_mod = @import("../jobs.zig");
const asset_cache_mod = @import("../asset_cache.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    SvgStreamMissingId,
    SvgStreamMissingModel,
    SvgStreamMissingPrompt,
    SvgStreamMissingApiKeyEnv,
    SvgStreamApiKeyNotFound,
    SvgStreamUnknownProvider,
    SvgStreamNotInstalled,
};

// Module globals (same pattern as llm-stream).
var registry_ref: ?*component_mod.Registry = null;
var parent_state_ref: ?*state_mod.State = null;
var io_channel_ref: ?*io.IoChannel = null;
var env_ref: ?*const dotenv.DotEnv = null;
var job_system_ref: ?*jobs_mod.JobSystem = null;
var asset_cache_ref: ?*asset_cache_mod.AssetCache = null;

pub fn install(
    registry: *component_mod.Registry,
    parent_state: *state_mod.State,
    io_channel: *io.IoChannel,
    env: ?*const dotenv.DotEnv,
    job_system: *jobs_mod.JobSystem,
    asset_cache: ?*asset_cache_mod.AssetCache,
) !void {
    registry_ref = registry;
    parent_state_ref = parent_state;
    io_channel_ref = io_channel;
    env_ref = env;
    job_system_ref = job_system;
    asset_cache_ref = asset_cache;
    try registry.register("svg-stream", factory);
}

pub fn deinitGlobals() void {
    registry_ref = null;
    parent_state_ref = null;
    io_channel_ref = null;
    env_ref = null;
    job_system_ref = null;
    asset_cache_ref = null;
}

const DEFAULT_OPENAI_ENDPOINT = "https://api.openai.com/v1/chat/completions";
const DEFAULT_OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_MAX_TOKENS: u32 = 8000;

pub const Provider = enum {
    /// Only one for now — Recraft is served via OpenRouter, whose
    /// /chat/completions endpoint is OpenAI-shaped. Direct OpenAI
    /// doesn't host an SVG model, so there's no "vanilla openai"
    /// path here that isn't really OpenRouter.
    openai,

    pub fn parse(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "openai")) return .openai;
        return null;
    }
};

const Phase = enum { idle, loading, done, failed };

/// Cache-key shape version. Bump if the key inputs ever change so old
/// entries are silently bypassed (they remain on disk until evicted).
const CACHE_KEY_PREFIX = "svg-stream:v1";

fn computeCacheKey(c: *const Component) asset_cache_mod.Key {
    var mt_buf: [16]u8 = undefined;
    const mt = std.fmt.bufPrint(&mt_buf, "{d}", .{c.max_tokens}) catch "?";
    return asset_cache_mod.AssetCache.keyFor(&.{
        CACHE_KEY_PREFIX,
        @tagName(c.provider),
        c.endpoint,
        c.model,
        c.system orelse "",
        c.prompt,
        mt,
    });
}

const PendingSvgStream = struct {
    /// Polymorphic dispatch header — drainHandler reads this to
    /// route the completion. Must be first field.
    header: io.PendingHeader = .{ .handle_completion = handleCompletion },
    allocator: std.mem.Allocator,
    /// Null = cancelled. Subsequent completions release owned bytes
    /// and return.
    component: ?*Component,
    /// Snapshotted at submit time so a successful `.end` writes to
    /// the same key the request was issued under — even if the
    /// component's prompt or model has been mutated mid-flight.
    cache_key: asset_cache_mod.Key,
};

const Component = struct {
    allocator: std.mem.Allocator,
    scope: []u8, // component id, owned

    /// Raw HTTP response bytes accumulated from every chunk. Not
    /// SSE-parsed — Recraft returns a single non-streaming JSON
    /// document. Parsed once on `.end`.
    response: std.ArrayListUnmanaged(u8) = .{},

    phase: Phase = .loading,
    pending: ?*PendingSvgStream = null,
    handle: io.Handle = 0,

    // Cached mesh — c_allocator-owned, replaced each chunk.
    vertices: []tess.Vertex = &.{},
    indices: []u32 = &.{},
    view_x: f32 = 0,
    view_y: f32 = 0,
    view_w: f32 = 1,
    view_h: f32 = 1,

    // Display config
    width: box_helpers.Length,
    height: ?box_helpers.Length,
    model_label: []u8, // owned dupe — for the loading placeholder
    provider: Provider = .openai,

    // Request params — owned dupes, freed at deinit.
    model: []u8 = &.{},
    prompt: []u8 = &.{},
    endpoint: []u8 = &.{},
    system: ?[]u8 = null,
    api_key_env: ?[]u8 = null,
    max_tokens: u32 = DEFAULT_MAX_TOKENS,

    err_name: ?[]u8 = null,

    /// Bumped on phase transitions, mesh swap, handle_update — every
    /// path that changes the visible output. Drives retained
    /// layout-cache invalidation.
    version: u64 = 0,
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    if (registry_ref == null or parent_state_ref == null or io_channel_ref == null or job_system_ref == null) {
        return Error.SvgStreamNotInstalled;
    }
    const id_raw = spec.id orelse return Error.SvgStreamMissingId;
    const model = findAttr(spec.attrs, "model") orelse return Error.SvgStreamMissingModel;
    const prompt = findAttr(spec.attrs, "prompt") orelse return Error.SvgStreamMissingPrompt;
    const system = findAttr(spec.attrs, "system");
    const api_key_env = findAttr(spec.attrs, "api_key_env");
    const auto_start: bool = blk: {
        if (findAttr(spec.attrs, "auto_start")) |s| break :blk !std.mem.eql(u8, s, "false");
        break :blk false; // SVG generation is slow + costs tokens — default off
    };
    const max_tokens: u32 = blk: {
        if (findAttr(spec.attrs, "max_tokens")) |s| break :blk std.fmt.parseInt(u32, s, 10) catch DEFAULT_MAX_TOKENS;
        break :blk DEFAULT_MAX_TOKENS;
    };

    const provider: Provider = if (findAttr(spec.attrs, "provider")) |p|
        Provider.parse(p) orelse return Error.SvgStreamUnknownProvider
    else
        .openai;

    const endpoint = findAttr(spec.attrs, "endpoint") orelse DEFAULT_OPENROUTER_ENDPOINT;

    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const scope = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(scope);
    const model_label = try allocator.dupe(u8, model);
    errdefer allocator.free(model_label);

    const model_dup = try allocator.dupe(u8, model);
    errdefer allocator.free(model_dup);
    const prompt_dup = try allocator.dupe(u8, prompt);
    errdefer allocator.free(prompt_dup);
    const endpoint_dup = try allocator.dupe(u8, endpoint);
    errdefer allocator.free(endpoint_dup);
    const system_dup: ?[]u8 = if (system) |s| try allocator.dupe(u8, s) else null;
    errdefer if (system_dup) |s| allocator.free(s);
    const api_key_env_dup: ?[]u8 = if (api_key_env) |k| try allocator.dupe(u8, k) else null;
    errdefer if (api_key_env_dup) |k| allocator.free(k);

    c.* = .{
        .allocator = allocator,
        .scope = scope,
        .width = if (findAttr(spec.attrs, "width")) |s|
            box_helpers.parseLength(s) orelse .{ .pixels = 480 }
        else
            .{ .pixels = 480 },
        .height = if (findAttr(spec.attrs, "height")) |s|
            box_helpers.parseLength(s)
        else
            null,
        .model_label = model_label,
        .provider = provider,
        .model = model_dup,
        .prompt = prompt_dup,
        .endpoint = endpoint_dup,
        .system = system_dup,
        .api_key_env = api_key_env_dup,
        .max_tokens = max_tokens,
        .phase = if (auto_start) .loading else .idle,
    };

    if (auto_start) try kickStream(c);

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

/// Submit a fresh stream. Cancels any in-flight fetch, clears the
/// content + mesh, resubmits. Mirrors `llm_stream.kickStream`.
fn kickStream(c: *Component) !void {
    const ch = io_channel_ref orelse return Error.SvgStreamNotInstalled;

    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }
    c.response.clearRetainingCapacity();
    if (c.err_name) |e| {
        c.allocator.free(e);
        c.err_name = null;
    }
    freeMesh(c);
    c.phase = .loading;

    const cache_key = computeCacheKey(c);

    // Cache fast path. A hit skips the network entirely — read bytes,
    // run the same finalizeResponse the network path uses. On a
    // corrupt/incompatible cached entry, drop it and fall through.
    if (asset_cache_ref) |cache| {
        if (cache.get(cache_key) catch |e| blk: {
            std.log.warn("svg-stream: cache get failed: {s}", .{@errorName(e)});
            break :blk null;
        }) |cached_bytes| {
            defer c.allocator.free(cached_bytes);
            c.response.appendSlice(c.allocator, cached_bytes) catch |e| {
                std.log.warn("svg-stream: cache append failed: {s}; refetching", .{@errorName(e)});
                c.response.clearRetainingCapacity();
            };
            if (c.response.items.len > 0) {
                if (finalizeResponse(c)) |_| {
                    c.version +%= 1;
                    if (parent_state_ref) |ps| ps.dirty = true;
                    return;
                } else |e| {
                    std.log.warn("svg-stream: cache finalize failed: {s}; refetching", .{@errorName(e)});
                    c.response.clearRetainingCapacity();
                    c.phase = .loading;
                }
            }
        }
    }

    var scratch = std.heap.ArenaAllocator.init(c.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var body_buf = std.ArrayList(u8).init(sa);
    try buildRecraftBody(body_buf.writer(), c.model, c.prompt, c.system, c.max_tokens);

    var headers_buf: std.ArrayListUnmanaged(io.Header) = .{};
    const key_env = c.api_key_env orelse return Error.SvgStreamMissingApiKeyEnv;
    const env = env_ref orelse return Error.SvgStreamApiKeyNotFound;
    const key = env.get(key_env) orelse return Error.SvgStreamApiKeyNotFound;
    const auth_value = try std.fmt.allocPrint(sa, "Bearer {s}", .{key});
    try headers_buf.append(sa, .{ .name = "Authorization", .value = auth_value });

    const pending = try c.allocator.create(PendingSvgStream);
    errdefer c.allocator.destroy(pending);
    pending.* = .{ .allocator = c.allocator, .component = c, .cache_key = cache_key };

    const handle = try ch.submitHttpStream(.{
        .url = c.endpoint,
        .method = .POST,
        .body = body_buf.items,
        .content_type = "application/json",
        .extra_headers = headers_buf.items,
    }, @intFromPtr(pending));
    c.handle = handle;
    c.pending = pending;
}

fn handleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (!std.mem.eql(u8, action, "start")) return;

    if (body.len > 0) {
        const new_prompt = c.allocator.dupe(u8, body) catch |e| {
            std.log.err("svg-stream: prompt dupe failed: {s}", .{@errorName(e)});
            return;
        };
        c.allocator.free(c.prompt);
        c.prompt = new_prompt;
    }

    kickStream(c) catch |e| {
        std.log.err("svg-stream: kickStream failed: {s}", .{@errorName(e)});
        c.phase = .failed;
        const a = c.allocator;
        if (c.err_name) |old| a.free(old);
        c.err_name = a.dupe(u8, @errorName(e)) catch null;
    };
    c.version +%= 1;
    if (parent_state_ref) |ps| ps.dirty = true;
}

fn update(_: *anyopaque, _: *const components.Spec) anyerror!void {
    // Same policy as llm-stream — mid-stream attribute changes
    // don't re-prompt. Re-id (change `#id`) to force a recreate.
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }
    freeMesh(c);
    c.response.deinit(allocator);
    allocator.free(c.scope);
    allocator.free(c.model_label);
    allocator.free(c.model);
    allocator.free(c.prompt);
    allocator.free(c.endpoint);
    if (c.system) |s| allocator.free(s);
    if (c.api_key_env) |k| allocator.free(k);
    if (c.err_name) |e| allocator.free(e);
    allocator.destroy(c);
}

fn freeMesh(c: *Component) void {
    if (c.vertices.len > 0) std.heap.c_allocator.free(c.vertices);
    if (c.indices.len > 0) std.heap.c_allocator.free(c.indices);
    c.vertices = &.{};
    c.indices = &.{};
}

/// Build the Recraft request body. Key differences from a
/// chat-completion body:
///
///   * `stream: false` — Recraft is one-shot, not token-streamed.
///     Even when you ask for streaming, OpenRouter forwards just
///     heartbeat comments while the upstream renders, then returns
///     the whole image at once. Skip the SSE charade.
///   * `max_tokens` still useful as a cost cap (Recraft bills per
///     image_token, ~4000 tokens for a typical figure).
fn buildRecraftBody(
    writer: anytype,
    model: []const u8,
    prompt: []const u8,
    system: ?[]const u8,
    max_tokens: u32,
) !void {
    try writer.writeAll("{\"model\":");
    try std.json.stringify(model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    if (system) |s| {
        try writer.writeAll("{\"role\":\"system\",\"content\":");
        try std.json.stringify(s, .{}, writer);
        try writer.writeAll("},");
    }
    try writer.writeAll("{\"role\":\"user\",\"content\":");
    try std.json.stringify(prompt, .{}, writer);
    try writer.writeAll("}],\"stream\":false,\"max_tokens\":");
    try std.fmt.format(writer, "{d}", .{max_tokens});
    try writer.writeAll("}");
}

// ── Completion drain target ──────────────────────────────────────────

fn handleCompletion(comp: io.Completion) void {
    const p: *PendingSvgStream = @ptrFromInt(comp.user_data);

    switch (comp.result) {
        .chunk => |bytes| {
            defer if (io_channel_ref) |ch| ch.releaseOk(bytes);
            const c = p.component orelse return;
            // Just accumulate. Recraft's response isn't SSE — it's
            // a single JSON document delivered in HTTP chunks.
            c.response.appendSlice(c.allocator, bytes) catch |e| {
                std.log.err("svg-stream: append failed: {s}", .{@errorName(e)});
            };
        },
        .end => {
            if (p.component) |c| {
                c.pending = null;
                finalizeResponse(c) catch |e| {
                    std.log.warn("svg-stream: finalize failed: {s}", .{@errorName(e)});
                    c.phase = .failed;
                    const a = c.allocator;
                    if (c.err_name) |old| a.free(old);
                    c.err_name = a.dupe(u8, @errorName(e)) catch null;
                };
                // Persist successful responses to the asset cache so the
                // next run replays without burning another $0.08.
                if (c.phase == .done) {
                    if (asset_cache_ref) |cache| {
                        var source_buf: [256]u8 = undefined;
                        const source = std.fmt.bufPrint(&source_buf, "svg-stream:{s}:{s}", .{ @tagName(c.provider), c.model }) catch null;
                        cache.put(p.cache_key, c.response.items, .{
                            .source = source,
                            .content_type = "application/json",
                        }) catch |e| {
                            std.log.warn("svg-stream: cache put failed: {s}", .{@errorName(e)});
                        };
                    }
                }
                c.version +%= 1;
                if (parent_state_ref) |ps| ps.dirty = true;
            }
            freePending(p);
        },
        .end_err => |e| {
            if (p.component) |c| {
                c.phase = .failed;
                c.pending = null;
                const a = c.allocator;
                if (c.err_name) |old| a.free(old);
                c.err_name = a.dupe(u8, @errorName(e)) catch null;
                c.version +%= 1;
                if (parent_state_ref) |ps| ps.dirty = true;
            }
            freePending(p);
        },
        .ok, .err => {
            // Not us — defensive arm; the polymorphic header
            // routes correctly so this is unreachable in practice.
        },
    }
}

fn freePending(p: *PendingSvgStream) void {
    p.allocator.destroy(p);
}

/// One-shot completion handler. Parses the accumulated JSON,
/// extracts the SVG data URL, base64-decodes it, runs the SVG
/// through `svg.parse` + parallel tessellate, swaps the mesh.
fn finalizeResponse(c: *Component) !void {
    if (c.response.items.len == 0) return Error.SvgStreamApiKeyNotFound;

    var scratch = std.heap.ArenaAllocator.init(c.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Parse the chat-completion envelope, ignoring fields we don't
    // care about. `images[0].image_url.url` is the data URL.
    const Url = struct { url: []const u8 };
    const Image = struct { image_url: Url };
    const Message = struct { images: ?[]const Image = null };
    const Choice = struct { message: ?Message = null };
    const Envelope = struct { choices: ?[]const Choice = null };

    var parsed = try std.json.parseFromSlice(Envelope, sa, c.response.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const choices = parsed.value.choices orelse return error.MissingChoices;
    if (choices.len == 0) return error.MissingChoices;
    const msg = choices[0].message orelse return error.MissingMessage;
    const images = msg.images orelse return error.MissingImages;
    if (images.len == 0) return error.MissingImages;
    const data_url = images[0].image_url.url;

    // Strip "data:image/svg+xml;base64," prefix, base64-decode.
    const prefix = "data:image/svg+xml;base64,";
    if (!std.mem.startsWith(u8, data_url, prefix)) return error.UnexpectedImageFormat;
    const b64 = data_url[prefix.len..];

    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(b64);
    const svg_bytes = try sa.alloc(u8, decoded_len);
    try decoder.decode(svg_bytes, b64);

    // Parse + tessellate.
    const doc = try svg.parse(sa, svg_bytes);
    var mesh = tess.Mesh.init(std.heap.c_allocator);
    defer mesh.deinit();
    const js = job_system_ref orelse return Error.SvgStreamNotInstalled;
    try tess.tessellateParallel(c.allocator, doc.paths, &mesh, js, .{});

    // Swap into the cached fields.
    freeMesh(c);
    c.vertices = try mesh.vertices.toOwnedSlice();
    c.indices = try mesh.indices.toOwnedSlice();
    c.view_x = doc.view_x;
    c.view_y = doc.view_y;
    c.view_w = doc.view_w;
    c.view_h = doc.view_h;
    c.phase = .done;
}

// ── Layout / render ─────────────────────────────────────────────────

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    // Re-walks just bind the already-tessellated mesh into the
    // DrawList — O(N triangles) but they're already in c_allocator
    // memory; we just emit two slice references. Cheap.
    .parallel_layout_cheap = true,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 480;
    const w: f32 = c.width.resolve(max_w, fallback_w);
    const h: f32 = blk: {
        if (c.height) |hl| break :blk hl.resolve(max_w, fallback_w);
        if (c.view_w > 0 and c.view_h > 0) break :blk w * c.view_h / c.view_w;
        break :blk w; // pre-first-parse: square fallback
    };

    // If we have a mesh, draw it regardless of phase — the
    // streaming case wants visible progress alongside a "still
    // generating…" placeholder above/below. Phase placeholders
    // only render when there's no mesh yet.
    if (c.vertices.len > 0 and c.indices.len > 0) {
        return try renderMesh(c, origin, w, h, out);
    }

    return switch (c.phase) {
        .idle => try renderPlaceholder(c, "ready (click button to start)", .idle, origin, w, lc, out),
        .loading => try renderPlaceholder(c, "generating SVG…", .loading, origin, w, lc, out),
        .done => try renderPlaceholder(c, "stream ended without SVG", .failed, origin, w, lc, out),
        .failed => blk: {
            var buf: [256]u8 = undefined;
            const detail: []const u8 = c.err_name orelse "unknown";
            const msg = std.fmt.bufPrint(&buf, "SVG stream failed: {s}", .{detail}) catch "SVG stream failed";
            break :blk try renderPlaceholder(c, msg, .failed, origin, w, lc, out);
        },
    };
}

fn renderMesh(
    c: *Component,
    origin: [2]f32,
    w: f32,
    h: f32,
    out: *element.DrawList,
) !element.Box {
    const sx = w / c.view_w;
    const sy = h / c.view_h;
    const tx = origin[0] - c.view_x * sx;
    const ty = origin[1] - c.view_y * sy;

    const base_idx: u32 = @intCast(out.tris.items.len);
    try out.tris.ensureUnusedCapacity(c.vertices.len);
    for (c.vertices) |v| {
        out.tris.appendAssumeCapacity(.{
            .pos = .{ v.pos[0] * sx + tx, v.pos[1] * sy + ty },
            .color = v.color,
        });
    }
    try out.tri_indices.ensureUnusedCapacity(c.indices.len);
    for (c.indices) |i| out.tri_indices.appendAssumeCapacity(base_idx + i);

    return .{ .x = origin[0], .y = origin[1], .w = w, .h = h };
}

const PlaceholderScheme = enum { idle, loading, failed };

const PLACEHOLDER_RADIUS: f32 = 6;
const PLACEHOLDER_BORDER_PX: f32 = 2;
const PLACEHOLDER_PAD_X: f32 = 12;
const PLACEHOLDER_PAD_Y: f32 = 8;

const IDLE_BORDER: [4]f32 = .{ 0.40, 0.46, 0.54, 0.75 };
const IDLE_BG: [4]f32 = .{ 0.10, 0.12, 0.16, 0.55 };
const LOADING_BORDER: [4]f32 = .{ 0.45, 0.55, 0.85, 0.85 };
const LOADING_BG: [4]f32 = .{ 0.08, 0.12, 0.20, 0.55 };
const FAILED_BORDER: [4]f32 = .{ 0.85, 0.30, 0.30, 0.95 };
const FAILED_BG: [4]f32 = .{ 0.30, 0.08, 0.08, 0.60 };

fn renderPlaceholder(
    _: *Component,
    msg: []const u8,
    scheme: PlaceholderScheme,
    origin: [2]f32,
    w: f32,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) !element.Box {
    const border_rgba = switch (scheme) {
        .idle => IDLE_BORDER,
        .loading => LOADING_BORDER,
        .failed => FAILED_BORDER,
    };
    const bg_rgba = switch (scheme) {
        .idle => IDLE_BG,
        .loading => LOADING_BG,
        .failed => FAILED_BG,
    };
    const style = lc.theme.body;
    const m = lc.fonts.metrics(style.font_id);

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(aa, hb, msg);

    const total_w: f32 = w;
    const total_h: f32 = m.line_height + 2 * PLACEHOLDER_PAD_Y;

    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ total_w, total_h },
        .color = border_rgba,
        .radius = PLACEHOLDER_RADIUS,
    });
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + PLACEHOLDER_BORDER_PX, origin[1] + PLACEHOLDER_BORDER_PX },
        .dst_size = .{ total_w - 2 * PLACEHOLDER_BORDER_PX, total_h - 2 * PLACEHOLDER_BORDER_PX },
        .color = bg_rgba,
        .radius = @max(0, PLACEHOLDER_RADIUS - PLACEHOLDER_BORDER_PX),
    });

    const baseline_y = origin[1] + PLACEHOLDER_PAD_Y + m.ascender;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        run,
        style.font_id,
        origin[0] + PLACEHOLDER_PAD_X,
        baseline_y,
        style.color,
        style.hot_color,
        style.attention,
        lc.zoom,
    );

    return .{ .x = origin[0], .y = origin[1], .w = total_w, .h = total_h, .baseline = baseline_y };
}

fn findAttr(attrs: []const components.Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "svg-stream: Provider.parse round-trip + unknown" {
    try testing.expectEqual(Provider.openai, Provider.parse("openai").?);
    try testing.expect(Provider.parse("ollama") == null); // openai-only — Recraft has no local equivalent
    try testing.expect(Provider.parse("") == null);
}

test "svg-stream: buildRecraftBody emits stream:false + max_tokens" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildRecraftBody(buf.writer(), "recraft/recraft-v4.1-vector", "A bowl of petunias", null, 8000);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("recraft/recraft-v4.1-vector", obj.get("model").?.string);
    // Recraft is one-shot — explicitly stream:false despite the
    // OpenAI-shaped wrapper, because the model itself doesn't
    // stream and OpenRouter only forwards heartbeats while waiting.
    try testing.expect(obj.get("stream").?.bool == false);
    try testing.expectEqual(@as(i64, 8000), obj.get("max_tokens").?.integer);
}

test "svg-stream: parses Recraft envelope shape end-to-end (smoke)" {
    // A minimal-shape stand-in for Recraft's real response. The
    // SVG is two tiny paths; base64-encoded inside a data URL.
    // Confirms our envelope parsing + base64 decode + downstream
    // svg.parse all line up.
    const tiny_svg =
        "<svg viewBox=\"0 0 10 10\">" ++
        "<path d=\"M 0 0 L 10 0 L 10 10 L 0 10 z\" fill=\"rgb(255,0,0)\"/>" ++
        "</svg>";
    var b64_buf: [200]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, tiny_svg);
    var env_buf = std.ArrayList(u8).init(testing.allocator);
    defer env_buf.deinit();
    try env_buf.writer().print(
        "{{\"choices\":[{{\"message\":{{\"content\":null,\"images\":[{{\"image_url\":{{\"url\":\"data:image/svg+xml;base64,{s}\"}}}}]}}}}]}}",
        .{b64},
    );

    // Standalone envelope parse — mirror the inline parse in
    // finalizeResponse so the test catches shape drift even when
    // there's no IoChannel wired.
    const Url = struct { url: []const u8 };
    const Image = struct { image_url: Url };
    const Message = struct { images: ?[]const Image = null };
    const Choice = struct { message: ?Message = null };
    const Envelope = struct { choices: ?[]const Choice = null };
    var parsed = try std.json.parseFromSlice(Envelope, testing.allocator, env_buf.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data_url = parsed.value.choices.?[0].message.?.images.?[0].image_url.url;
    try testing.expect(std.mem.startsWith(u8, data_url, "data:image/svg+xml;base64,"));
    const stripped = data_url["data:image/svg+xml;base64,".len..];
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(stripped);
    const decoded = try testing.allocator.alloc(u8, out_len);
    defer testing.allocator.free(decoded);
    try decoder.decode(decoded, stripped);
    try testing.expectEqualStrings(tiny_svg, decoded);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try svg.parse(arena.allocator(), decoded);
    try testing.expectEqual(@as(usize, 1), doc.paths.len);
}
