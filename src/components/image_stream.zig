//! `:::image-stream` — async raster image from an image-class model
//! (stage 14c). Sibling of [`:::svg-stream`](svg_stream.zig);
//! identical wire format (OpenAI-shaped /chat/completions returning
//! a base64 data URL) but the data URL contents are PNG/JPG instead
//! of SVG, and we decode + upload to a GPU texture instead of
//! tessellating to triangles.
//!
//! Default target: google/gemini-3.1-flash-image-preview on
//! OpenRouter. The model returns `data:image/png;base64,...` in
//! `message.images[0].image_url.url`. We strip the prefix, base64-
//! decode, hand the bytes to stb_image, and upload the RGBA8 result
//! to a per-component GPU texture.
//!
//! Author writes:
//!
//!     :::image-stream {#fresh_image
//!       model=google/gemini-3.1-flash-image-preview
//!       endpoint=https://openrouter.ai/api/v1/chat/completions
//!       api_key_env=OPENROUTER_DYNABOOK
//!       prompt="A robot holding a steaming mug of coffee."
//!       width=480
//!       auto_start=false }
//!     :::
//!
//! ### Texture lifecycle
//!
//! Each Component owns one `ImageTexture` + one descriptor set from
//! the host's `ImagePipeline` pool. The texture is created on the
//! first successful response (sized to the decoded image's
//! dimensions) and reused for re-fires only if the new image has
//! the same dimensions — otherwise the texture is destroyed and a
//! new one allocated, and the descriptor is rewritten in place
//! (allocation churn is bounded by re-fire rate). Component destroy
//! frees the descriptor + texture in that order so the pool slot
//! returns to the pipeline cleanly.
//!
//! ### Cancellation invariant
//!
//! Same as [[project-io-channel-cancellation]] — Pending lifetime
//! owned by completion handler; Component holds back-pointer for
//! cancel signal only.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const spark_mod = @import("../spark.zig");
const state_mod = @import("../state.zig");
const io = @import("../io_channel.zig");
const dotenv = @import("../dotenv.zig");
const vk = @import("../gpu/vk.zig");
const image_texture_mod = @import("../gpu/image_texture.zig");
const image_pipeline_mod = @import("../gpu/image_pipeline.zig");
const asset_cache_mod = @import("../asset_cache.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

const c_stb = @cImport({
    @cInclude("stb_image.h");
});

pub const Error = error{
    ImageStreamMissingId,
    ImageStreamMissingModel,
    ImageStreamMissingPrompt,
    ImageStreamMissingApiKeyEnv,
    ImageStreamApiKeyNotFound,
    ImageStreamUnknownProvider,
    ImageStreamNotInstalled,
    ImageStreamDecodeFailed,
};

pub fn install(spark: *spark_mod.Spark) !void {
    try spark.registry.register("image-stream", factory);
}

const DEFAULT_OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_MAX_TOKENS: u32 = 8000;

pub const Provider = enum {
    /// Gemini image preview is served via OpenRouter's /chat/completions
    /// — same shape as Recraft. Direct Gemini API uses a different
    /// route (generativelanguage.googleapis.com) which we don't
    /// support here; if needed, add a `.gemini` provider variant
    /// with its own body builder.
    openai,

    pub fn parse(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "openai")) return .openai;
        return null;
    }
};

const Phase = enum { idle, loading, done, failed };

/// Cache-key shape version. Bump if the key inputs ever change so old
/// entries are silently bypassed (they remain on disk until evicted).
const CACHE_KEY_PREFIX = "image-stream:v1";

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

const PendingImageStream = struct {
    /// Polymorphic dispatch header — drainHandler reads this to
    /// route the completion. Must be first field.
    header: io.PendingHeader = .{ .handle_completion = handleCompletion },
    allocator: std.mem.Allocator,
    /// Null = cancelled. Subsequent completions release owned bytes
    /// and return.
    component: ?*Component,
    /// Snapshotted at submit time so a successful `.end` writes to
    /// the same key the request was issued under.
    cache_key: asset_cache_mod.Key,
    /// Snapshot of the spark pointer — completion handler accesses
    /// io_channel + host_state + asset_cache through it even if
    /// the Component has been destroyed.
    spark: *spark_mod.Spark,
};

const Component = struct {
    allocator: std.mem.Allocator,
    /// Captured at create time. Every cross-cutting concern (registry,
    /// parent state, io_channel, dotenv, vk_ctx, image_pipeline,
    /// asset_cache) is one hop through here.
    spark: *spark_mod.Spark,
    scope: []u8,

    /// Raw HTTP response bytes accumulated from every chunk. Gemini
    /// image preview returns a single JSON document.
    response: std.ArrayListUnmanaged(u8) = .{},

    phase: Phase = .loading,
    pending: ?*PendingImageStream = null,
    handle: io.Handle = 0,

    /// GPU texture + descriptor. Both null until the first successful
    /// decode lands; populated lazily by `finalizeResponse`.
    texture: ?image_texture_mod.ImageTexture = null,
    descriptor_set: ?*anyopaque = null, // VkDescriptorSet

    // Display config — width is honoured; height defaults to the
    // decoded image's aspect ratio if not supplied.
    width: box_helpers.Length,
    height: ?box_helpers.Length,
    model_label: []u8,
    provider: Provider = .openai,

    // Request params — owned dupes, freed at deinit.
    model: []u8 = &.{},
    prompt: []u8 = &.{},
    endpoint: []u8 = &.{},
    system: ?[]u8 = null,
    api_key_env: ?[]u8 = null,
    max_tokens: u32 = DEFAULT_MAX_TOKENS,

    err_name: ?[]u8 = null,

    /// Bumped on every visible-state mutation — drives layout cache
    /// invalidation in [[stage 14a]].
    version: u64 = 0,
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

fn create(spark: *spark_mod.Spark, allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const id_raw = spec.id orelse return Error.ImageStreamMissingId;
    const model = findAttr(spec.attrs, "model") orelse return Error.ImageStreamMissingModel;
    const prompt = findAttr(spec.attrs, "prompt") orelse return Error.ImageStreamMissingPrompt;
    const system = findAttr(spec.attrs, "system");
    const api_key_env = findAttr(spec.attrs, "api_key_env");
    const auto_start: bool = blk: {
        if (findAttr(spec.attrs, "auto_start")) |s| break :blk !std.mem.eql(u8, s, "false");
        break :blk false; // image gen is slow + costs tokens
    };
    const max_tokens: u32 = blk: {
        if (findAttr(spec.attrs, "max_tokens")) |s| break :blk std.fmt.parseInt(u32, s, 10) catch DEFAULT_MAX_TOKENS;
        break :blk DEFAULT_MAX_TOKENS;
    };
    const provider: Provider = if (findAttr(spec.attrs, "provider")) |p|
        Provider.parse(p) orelse return Error.ImageStreamUnknownProvider
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
        .spark = spark,
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

fn kickStream(c: *Component) !void {
    const ch = c.spark.io_channel;

    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }
    c.response.clearRetainingCapacity();
    if (c.err_name) |e| {
        c.allocator.free(e);
        c.err_name = null;
    }
    // Texture stays — we'll resize+reupload in finalizeResponse if the
    // new image's dimensions differ. Cheaper than tearing down GPU
    // resources unconditionally per re-fire.
    c.phase = .loading;

    const cache_key = computeCacheKey(c);

    // Cache fast path. Bypass the network if we already have this
    // request's envelope on disk; on parse/finalize failure, fall
    // through to a fresh fetch.
    if (c.spark.asset_cache) |cache| {
        if (cache.get(cache_key) catch |e| blk: {
            std.log.warn("image-stream: cache get failed: {s}", .{@errorName(e)});
            break :blk null;
        }) |cached_bytes| {
            defer c.allocator.free(cached_bytes);
            c.response.appendSlice(c.allocator, cached_bytes) catch |e| {
                std.log.warn("image-stream: cache append failed: {s}; refetching", .{@errorName(e)});
                c.response.clearRetainingCapacity();
            };
            if (c.response.items.len > 0) {
                if (finalizeResponse(c)) |_| {
                    c.version +%= 1;
                    c.spark.host_state.dirty = true;
                    return;
                } else |e| {
                    std.log.warn("image-stream: cache finalize failed: {s}; refetching", .{@errorName(e)});
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
    try buildRequestBody(body_buf.writer(), c.model, c.prompt, c.system, c.max_tokens);

    var headers_buf: std.ArrayListUnmanaged(io.Header) = .{};
    const key_env = c.api_key_env orelse return Error.ImageStreamMissingApiKeyEnv;
    const env = c.spark.dotenv orelse return Error.ImageStreamApiKeyNotFound;
    const key = env.get(key_env) orelse return Error.ImageStreamApiKeyNotFound;
    const auth_value = try std.fmt.allocPrint(sa, "Bearer {s}", .{key});
    try headers_buf.append(sa, .{ .name = "Authorization", .value = auth_value });

    const pending = try c.allocator.create(PendingImageStream);
    errdefer c.allocator.destroy(pending);
    pending.* = .{ .allocator = c.allocator, .component = c, .cache_key = cache_key, .spark = c.spark };

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
            std.log.err("image-stream: prompt dupe failed: {s}", .{@errorName(e)});
            return;
        };
        c.allocator.free(c.prompt);
        c.prompt = new_prompt;
    }

    kickStream(c) catch |e| {
        std.log.err("image-stream: kickStream failed: {s}", .{@errorName(e)});
        c.phase = .failed;
        const a = c.allocator;
        if (c.err_name) |old| a.free(old);
        c.err_name = a.dupe(u8, @errorName(e)) catch null;
    };
    c.version +%= 1;
    c.spark.host_state.dirty = true;
}

fn update(_: *anyopaque, _: *const components.Spec) anyerror!void {
    // Same policy as svg-stream / llm-stream: mid-flight attribute
    // changes don't re-prompt. Re-id to force a recreate.
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }
    freeGpuResources(c);
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

fn freeGpuResources(c: *Component) void {
    if (c.descriptor_set) |ds| {
        c.spark.image_pipeline.freeDescriptor(@ptrCast(@alignCast(ds)));
        c.descriptor_set = null;
    }
    if (c.texture) |*t| {
        t.deinit();
        c.texture = null;
    }
}

/// Build the chat-completion request body. Same shape as Recraft —
/// `stream:false`, single user message. Gemini image preview also
/// expects a single user message; the response shape is the same
/// (`message.images[0].image_url.url` as a `data:image/png;base64,…`).
fn buildRequestBody(
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
    const p: *PendingImageStream = @ptrFromInt(comp.user_data);

    const host_state = p.spark.host_state;
    switch (comp.result) {
        .chunk => |bytes| {
            defer p.spark.io_channel.releaseOk(bytes);
            const c = p.component orelse return;
            c.response.appendSlice(c.allocator, bytes) catch |e| {
                std.log.err("image-stream: append failed: {s}", .{@errorName(e)});
            };
        },
        .end => {
            if (p.component) |c| {
                c.pending = null;
                finalizeResponse(c) catch |e| {
                    std.log.warn("image-stream: finalize failed: {s}", .{@errorName(e)});
                    c.phase = .failed;
                    const a = c.allocator;
                    if (c.err_name) |old| a.free(old);
                    c.err_name = a.dupe(u8, @errorName(e)) catch null;
                };
                if (c.phase == .done) {
                    if (p.spark.asset_cache) |cache| {
                        var source_buf: [256]u8 = undefined;
                        const source = std.fmt.bufPrint(&source_buf, "image-stream:{s}:{s}", .{ @tagName(c.provider), c.model }) catch null;
                        cache.put(p.cache_key, c.response.items, .{
                            .source = source,
                            .content_type = "application/json",
                        }) catch |e| {
                            std.log.warn("image-stream: cache put failed: {s}", .{@errorName(e)});
                        };
                    }
                }
                c.version +%= 1;
                host_state.dirty = true;
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
                host_state.dirty = true;
            }
            freePending(p);
        },
        .ok, .err => {},
    }
}

fn freePending(p: *PendingImageStream) void {
    p.allocator.destroy(p);
}

/// Parse the chat-completion envelope, extract the data URL,
/// base64-decode the image bytes, hand them to stb_image to decode
/// into RGBA8 pixels, then resize the GPU texture if needed and
/// upload.
///
/// Accepts `data:image/png;base64,...` and `data:image/jpeg;base64,...`
/// (stb_image handles both); rejects unknown MIMEs.
fn finalizeResponse(c: *Component) !void {
    if (c.response.items.len == 0) return error.EmptyResponse;

    var scratch = std.heap.ArenaAllocator.init(c.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

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

    // Strip "data:image/<mime>;base64," prefix. We accept any image
    // MIME — stb_image autodetects format from the byte stream.
    const prefix_marker = ";base64,";
    const sep_idx = std.mem.indexOf(u8, data_url, prefix_marker) orelse return error.UnexpectedImageFormat;
    if (!std.mem.startsWith(u8, data_url, "data:image/")) return error.UnexpectedImageFormat;
    const b64 = data_url[sep_idx + prefix_marker.len ..];

    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(b64);
    const encoded_bytes = try sa.alloc(u8, decoded_len);
    try decoder.decode(encoded_bytes, b64);

    // stb_image decode → RGBA8.
    var iw: c_int = 0;
    var ih: c_int = 0;
    var ch_count: c_int = 0;
    const pixels_ptr = c_stb.stbi_load_from_memory(
        @ptrCast(encoded_bytes.ptr),
        @intCast(encoded_bytes.len),
        &iw,
        &ih,
        &ch_count,
        4, // force RGBA
    );
    if (pixels_ptr == null) return Error.ImageStreamDecodeFailed;
    defer c_stb.stbi_image_free(pixels_ptr);

    const w: u32 = @intCast(iw);
    const h: u32 = @intCast(ih);
    const pixels = pixels_ptr[0 .. @as(usize, w) * @as(usize, h) * 4];

    // Allocate or resize the GPU texture. If the new image's
    // dimensions match the existing texture, reuse it (one upload).
    // Otherwise free and recreate; the descriptor needs to be
    // rewritten in either case because vkUpdateDescriptorSets is the
    // sanctioned way to repoint a slot at a new view.
    const need_new_texture: bool = blk: {
        if (c.texture) |t| {
            if (t.extent.width == w and t.extent.height == h) break :blk false;
            break :blk true;
        }
        break :blk true;
    };

    const vk_ctx = c.spark.vk_ctx;
    const ip = c.spark.image_pipeline;

    if (need_new_texture) {
        if (c.texture) |*t| {
            t.deinit();
            c.texture = null;
        }
        c.texture = try image_texture_mod.ImageTexture.init(vk_ctx, w, h);
        // First-time descriptor allocation, or after a release-then-
        // realloc cycle.
        if (c.descriptor_set == null) {
            const ds = try ip.allocDescriptor();
            c.descriptor_set = @ptrCast(@alignCast(ds));
        }
    }

    try c.texture.?.upload(pixels);

    // (Re-)point the descriptor at the (possibly new) view + sampler.
    // Cheap even when nothing changed; vkUpdateDescriptorSets is
    // idempotent for the same handle pair.
    ip.writeDescriptor(@ptrCast(@alignCast(c.descriptor_set.?)), c.texture.?.view, c.texture.?.sampler);

    c.phase = .done;
}

// ── Layout / render ─────────────────────────────────────────────────

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
    // Re-walks emit a single ImageDraw entry (descriptor + rect).
    // The expensive bit (PNG decode + texture upload) happened in
    // finalizeResponse; the layout walk itself is microseconds.
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
        if (c.texture) |t| {
            if (t.extent.width > 0 and t.extent.height > 0) {
                const aspect = @as(f32, @floatFromInt(t.extent.height)) / @as(f32, @floatFromInt(t.extent.width));
                break :blk w * aspect;
            }
        }
        break :blk w;
    };

    // If we have a texture + descriptor, draw it regardless of phase.
    // Lets a re-fire continue showing the prior image while the new
    // one renders, which feels much better than a placeholder flash.
    if (c.texture != null and c.descriptor_set != null) {
        try out.images.append(.{
            .descriptor_set = c.descriptor_set.?,
            .dst_pos = origin,
            .dst_size = .{ w, h },
        });
        return .{ .x = origin[0], .y = origin[1], .w = w, .h = h };
    }

    return switch (c.phase) {
        .idle => try renderPlaceholder("ready (click button to start)", .idle, origin, w, lc, out),
        .loading => try renderPlaceholder("generating image…", .loading, origin, w, lc, out),
        .done => try renderPlaceholder("stream ended without image", .failed, origin, w, lc, out),
        .failed => blk: {
            var buf: [256]u8 = undefined;
            const detail: []const u8 = c.err_name orelse "unknown";
            const msg = std.fmt.bufPrint(&buf, "image stream failed: {s}", .{detail}) catch "image stream failed";
            break :blk try renderPlaceholder(msg, .failed, origin, w, lc, out);
        },
    };
}

const PlaceholderScheme = enum { idle, loading, failed };

const PLACEHOLDER_RADIUS: f32 = 6;
const PLACEHOLDER_BORDER_PX: f32 = 2;
const PLACEHOLDER_PAD_X: f32 = 12;
const PLACEHOLDER_PAD_Y: f32 = 8;

const IDLE_BORDER: [4]f32 = .{ 0.40, 0.46, 0.54, 0.75 };
const IDLE_BG: [4]f32 = .{ 0.10, 0.12, 0.16, 0.55 };
const LOADING_BORDER: [4]f32 = .{ 0.85, 0.60, 0.40, 0.90 };
const LOADING_BG: [4]f32 = .{ 0.18, 0.13, 0.08, 0.55 };
const FAILED_BORDER: [4]f32 = .{ 0.85, 0.30, 0.30, 0.95 };
const FAILED_BG: [4]f32 = .{ 0.30, 0.08, 0.08, 0.60 };

fn renderPlaceholder(
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

test "image-stream: Provider.parse" {
    try testing.expect(Provider.parse("openai") == .openai);
    try testing.expect(Provider.parse("anthropic") == null);
}

test "image-stream: data URL prefix detection accepts png + jpeg" {
    // The actual decode path needs Vulkan + a real model response; here we
    // just smoke-check the URL-prefix scan against the two MIMEs we expect
    // from OpenRouter image-class models.
    const urls = [_][]const u8{
        "data:image/png;base64,iVBORw0KGgo=",
        "data:image/jpeg;base64,/9j/4AAQ=",
    };
    for (urls) |url| {
        try testing.expect(std.mem.startsWith(u8, url, "data:image/"));
        try testing.expect(std.mem.indexOf(u8, url, ";base64,") != null);
    }
    try testing.expect(std.mem.indexOf(u8, "data:audio/wav;base64,xxx", ";base64,") != null);
    try testing.expect(!std.mem.startsWith(u8, "data:audio/wav;base64,xxx", "data:image/"));
}

test "image-stream: buildRequestBody shape" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildRequestBody(buf.writer(), "google/gemini-3.1-flash-image-preview", "draw a duck", null, 4000);
    // Sanity: model field present, stream:false, prompt embedded.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"model\":\"google/gemini-3.1-flash-image-preview\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"stream\":false") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"draw a duck\"") != null);
}
