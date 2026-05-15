//! `:::llm-stream` — live document content authored by an LLM.
//!
//! Stage 13a — first concrete use of `IoChannel.submitHttpStream`.
//! Posts a `stream: true` chat request to an Ollama-shaped endpoint;
//! NDJSON chunks arrive on the IoChannel's drain queue; each line
//! gets parsed for its `message.content` token and appended to a
//! display buffer; the accumulated buffer is re-parsed as markdown
//! on each chunk so the child Element tree grows in lockstep with
//! the stream.
//!
//! Author writes:
//!
//!     :::llm-stream {#chat model=qwen3.5:2b prompt="Tell me a 3-line haiku about Vulkan"}
//!     :::
//!
//! Required attrs:
//!   * `model`   — Ollama model name (`qwen3.5:2b`, `phi4-mini`, …)
//!   * `prompt`  — user message; templated `${state.x}` is fine here
//!     (the parser substitutes from parent state before the spec
//!     reaches this factory).
//!
//! Optional attrs:
//!   * `endpoint`     — defaults to `http://localhost:11434/api/chat`
//!   * `max_tokens`   — passed as `options.num_predict`; default 256
//!   * `system`       — system message prepended to the chat
//!
//! ### Phases
//!
//!   * `.loading`   — submitted, no chunks yet. Renders a soft
//!     "{model} thinking…" placeholder.
//!   * `.streaming` — first chunk arrived; render the accumulated
//!     content as a child markdown tree, re-parsed per chunk.
//!   * `.done`      — stream finished cleanly. Same render as
//!     `.streaming`, just no further re-parses.
//!   * `.failed`    — stream errored. Renders a red error
//!     placeholder with the error name.
//!
//! ### Cancellation discipline
//!
//! Identical shape to [`embedded-document`](embedded_document.zig):
//! a `PendingStream` is heap-allocated at submit time; the
//! Component holds a back-pointer to it for the cancel-signal only.
//! The completion handler owns its lifetime — frees `pending` when
//! `.end` or `.end_err` arrives. If the Component is destroyed
//! mid-stream, `deinit_` nulls `pending.component`; subsequent
//! chunk/end completions release any owned bytes and return.
//!
//! Re-uses [[project-io-channel-cancellation]]'s invariant
//! verbatim — see that memory file before refactoring.

const std = @import("std");
const element = @import("../element.zig");
const element_layout = @import("../element_layout.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const markdown = @import("../markdown.zig");
const state_mod = @import("../state.zig");
const io = @import("../io_channel.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const dotenv = @import("../dotenv.zig");

pub const Error = error{
    LlmStreamMissingId,
    LlmStreamMissingModel,
    LlmStreamMissingPrompt,
    LlmStreamMissingApiKeyEnv,
    LlmStreamApiKeyNotFound,
    LlmStreamUnknownProvider,
    LlmStreamNotInstalled,
};

// Module globals; same pattern as embedded-document.
var registry_ref: ?*component_mod.Registry = null;
var theme_ref: ?*const element.Theme = null;
var parent_state_ref: ?*state_mod.State = null;
var io_channel_ref: ?*io.IoChannel = null;
var env_ref: ?*const dotenv.DotEnv = null;

pub fn install(
    registry: *component_mod.Registry,
    theme: *const element.Theme,
    parent_state: *state_mod.State,
    io_channel: *io.IoChannel,
    env: ?*const dotenv.DotEnv,
) !void {
    registry_ref = registry;
    theme_ref = theme;
    parent_state_ref = parent_state;
    io_channel_ref = io_channel;
    env_ref = env;
    try registry.register("llm-stream", factory);
}

pub fn deinitGlobals() void {
    registry_ref = null;
    theme_ref = null;
    parent_state_ref = null;
    io_channel_ref = null;
    env_ref = null;
}

const DEFAULT_OLLAMA_ENDPOINT = "http://localhost:11434/api/chat";
const DEFAULT_OPENAI_ENDPOINT = "https://api.openai.com/v1/chat/completions";
const DEFAULT_MAX_TOKENS: u32 = 256;

pub const Provider = enum {
    ollama,
    /// Covers OpenAI proper, DeepSeek, Together, Groq, OpenRouter,
    /// and anything else that speaks `POST /chat/completions` with
    /// SSE-framed `choices[*].delta.content` payloads.
    openai,

    pub fn parse(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        return null;
    }
};

const Phase = enum {
    /// `auto_start=false` and the stream hasn't been triggered yet.
    /// Renders a subtle "ready" placeholder; waits for a
    /// `handle_update(action=start)` (typically fired by a sibling
    /// `:::button`).
    idle,
    loading,
    streaming,
    done,
    failed,
};

const PendingStream = struct {
    allocator: std.mem.Allocator,
    /// Null = cancelled. Subsequent chunk/end completions release
    /// owned bytes and discard.
    component: ?*Component,
    /// Last-seen error name when phase flipped to .failed; held so
    /// the placeholder can show useful detail.
    err_name: ?[]u8 = null,
};

const Component = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    child_state: *state_mod.State,
    root: element.Element,
    scope: []u8,

    /// Accumulated `message.content` from every chunk parsed so
    /// far. Re-parsed as markdown each chunk.
    content: std.ArrayListUnmanaged(u8) = .{},
    /// NDJSON line-reassembly buffer — raw bytes may not land on
    /// line boundaries.
    line_buf: std.ArrayListUnmanaged(u8) = .{},

    phase: Phase = .loading,
    pending: ?*PendingStream = null,
    handle: io.Handle = 0,

    model_label: []u8, // owned dupe — used for the loading placeholder
    provider: Provider = .ollama,

    // Request params held for re-firing on `handle_update(start)`.
    // All owned dupes; freed in deinit_.
    model: []u8 = &.{},
    prompt: []u8 = &.{},
    endpoint: []u8 = &.{},
    system: ?[]u8 = null,
    api_key_env: ?[]u8 = null,
    max_tokens: u32 = DEFAULT_MAX_TOKENS,

    /// Set when `.failed`. Owned by the Component.
    err_name: ?[]u8 = null,
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    if (registry_ref == null or theme_ref == null or parent_state_ref == null or io_channel_ref == null) {
        return Error.LlmStreamNotInstalled;
    }
    const id_raw = spec.id orelse return Error.LlmStreamMissingId;
    const model = findAttr(spec.attrs, "model") orelse return Error.LlmStreamMissingModel;
    const prompt = findAttr(spec.attrs, "prompt") orelse return Error.LlmStreamMissingPrompt;
    const system = findAttr(spec.attrs, "system");
    const api_key_env = findAttr(spec.attrs, "api_key_env");
    const auto_start: bool = blk: {
        if (findAttr(spec.attrs, "auto_start")) |s| {
            break :blk !std.mem.eql(u8, s, "false");
        }
        break :blk true; // default preserves stage-13a behavior
    };
    const max_tokens: u32 = blk: {
        if (findAttr(spec.attrs, "max_tokens")) |s| {
            break :blk std.fmt.parseInt(u32, s, 10) catch DEFAULT_MAX_TOKENS;
        }
        break :blk DEFAULT_MAX_TOKENS;
    };

    const provider: Provider = if (findAttr(spec.attrs, "provider")) |p|
        Provider.parse(p) orelse return Error.LlmStreamUnknownProvider
    else
        .ollama;

    const default_endpoint: []const u8 = switch (provider) {
        .ollama => DEFAULT_OLLAMA_ENDPOINT,
        .openai => DEFAULT_OPENAI_ENDPOINT,
    };
    const endpoint = findAttr(spec.attrs, "endpoint") orelse default_endpoint;

    // Per-instance allocations.
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const child_state = try allocator.create(state_mod.State);
    errdefer allocator.destroy(child_state);
    child_state.* = state_mod.State.init(allocator);
    errdefer child_state.deinit();
    child_state.parent = parent_state_ref;

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
        .arena = arena,
        .child_state = child_state,
        .root = element.Element{ .paragraph = &[_]element.Element{} },
        .scope = scope,
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

    if (auto_start) {
        try kickStream(c);
    }

    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

/// Submit (or re-submit) a fresh stream. Cancels any in-flight
/// fetch from this component first (chunks already queued in the
/// channel will land but be discarded — `PendingStream.component`
/// is null'd before the new submission). Clears the content buffer
/// so the re-render is from scratch.
fn kickStream(c: *Component) !void {
    const ch = io_channel_ref orelse return Error.LlmStreamNotInstalled;

    // Cancel any in-flight stream from this component.
    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }

    // Reset content + line buffer so the new run paints fresh.
    c.content.clearRetainingCapacity();
    c.line_buf.clearRetainingCapacity();
    if (c.err_name) |e| {
        c.allocator.free(e);
        c.err_name = null;
    }
    // Drop the cached parsed tree by resetting the arena.
    _ = c.arena.reset(.retain_capacity);
    c.root = element.Element{ .paragraph = &[_]element.Element{} };
    c.phase = .loading;

    // Build body + headers in a scratch arena; submitHttpStream
    // dupes them, so the arena can drop right after.
    var scratch = std.heap.ArenaAllocator.init(c.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var body_buf = std.ArrayList(u8).init(sa);
    switch (c.provider) {
        .ollama => try buildOllamaBody(body_buf.writer(), c.model, c.prompt, c.system, c.max_tokens),
        .openai => try buildOpenAiBody(body_buf.writer(), c.model, c.prompt, c.system, c.max_tokens),
    }

    var headers_buf: std.ArrayListUnmanaged(io.Header) = .{};
    if (c.provider == .openai) {
        const key_env = c.api_key_env orelse return Error.LlmStreamMissingApiKeyEnv;
        const env = env_ref orelse return Error.LlmStreamApiKeyNotFound;
        const key = env.get(key_env) orelse return Error.LlmStreamApiKeyNotFound;
        const auth_value = try std.fmt.allocPrint(sa, "Bearer {s}", .{key});
        try headers_buf.append(sa, .{ .name = "Authorization", .value = auth_value });
    }

    const pending = try c.allocator.create(PendingStream);
    errdefer c.allocator.destroy(pending);
    pending.* = .{ .allocator = c.allocator, .component = c };

    const handle = try ch.submitHttpStream(.{
        .url = c.endpoint,
        .method = .POST,
        .body = body_buf.items,
        .content_type = "application/json",
        .extra_headers = if (headers_buf.items.len > 0) headers_buf.items else null,
    }, @intFromPtr(pending));
    c.handle = handle;
    c.pending = pending;
}

/// Component-target dispatch. Today's only action is `start` —
/// trigger (or re-trigger) the stream. `body` is unused for now;
/// reserved for future "alter prompt and run" or "set system
/// message on the fly" cases.
fn handleUpdate(ctx: *anyopaque, action: []const u8, _: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, action, "start")) {
        kickStream(c) catch |e| {
            std.log.err("llm-stream: kickStream failed: {s}", .{@errorName(e)});
            c.phase = .failed;
            const a = c.allocator;
            if (c.err_name) |old| a.free(old);
            c.err_name = a.dupe(u8, @errorName(e)) catch null;
        };
        if (parent_state_ref) |ps| ps.dirty = true;
    }
}

fn update(ctx: *anyopaque, _: *const components.Spec) anyerror!void {
    _ = ctx;
    // Attr changes on a live stream don't re-prompt — the user is
    // expected to flip `#id` to force a recreate (just like
    // embedded-document's `src=` rule). Implementing
    // mid-stream-restart would mean cancelling the in-flight request
    // (which we can't do today — IoChannel has no cancel hook) and
    // re-submitting. Deferred until we have a real use case.
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    if (c.pending) |p| {
        p.component = null;
        c.pending = null;
    }
    if (registry_ref) |r| r.deinitScope(c.scope);
    c.content.deinit(allocator);
    c.line_buf.deinit(allocator);
    c.child_state.deinit();
    allocator.destroy(c.child_state);
    c.arena.deinit();
    allocator.destroy(c.arena);
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

/// Build the Ollama chat-completion request body. `think:false`
/// suppresses qwen-style reasoning traces; `options.num_predict`
/// caps generation length.
fn buildOllamaBody(
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
    try writer.writeAll("}],\"stream\":true,\"think\":false,\"options\":{\"num_predict\":");
    try std.fmt.format(writer, "{d}", .{max_tokens});
    try writer.writeAll("}}");
}

/// Build an OpenAI-compatible chat completion request body. Same
/// wire format as DeepSeek, Together, Groq, OpenRouter, etc — they
/// all consume `POST /chat/completions` with this shape.
fn buildOpenAiBody(
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
    try writer.writeAll("}],\"stream\":true,\"max_tokens\":");
    try std.fmt.format(writer, "{d}", .{max_tokens});
    try writer.writeAll("}");
}

// ── Completion drain target ──────────────────────────────────────────

pub fn handleCompletion(comp: io.Completion) void {
    const p: *PendingStream = @ptrFromInt(comp.user_data);

    switch (comp.result) {
        .chunk => |bytes| {
            defer if (io_channel_ref) |ch| ch.releaseOk(bytes);
            const c = p.component orelse return;
            processChunk(c, bytes) catch |e| {
                std.log.err("llm-stream: chunk processing failed: {s}", .{@errorName(e)});
            };
            if (parent_state_ref) |ps| ps.dirty = true;
        },
        .end => {
            if (p.component) |c| {
                c.phase = .done;
                c.pending = null;
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
                if (parent_state_ref) |ps| ps.dirty = true;
            }
            freePending(p);
        },
        .ok, .err => {
            // Not us — embedded-document owns those. Re-posting
            // would loop the channel, so we silently ignore the
            // mis-route (the routing fix lives one layer up in
            // main.zig's drainHandler).
        },
    }
}

fn freePending(p: *PendingStream) void {
    if (p.err_name) |e| p.allocator.free(e);
    p.allocator.destroy(p);
}

fn processChunk(c: *Component, bytes: []const u8) !void {
    try c.line_buf.appendSlice(c.allocator, bytes);
    switch (c.provider) {
        .ollama => drainNdjsonLines(c),
        .openai => drainSseEvents(c),
    }
    try rerenderContent(c);
}

/// Ollama wire format: NDJSON — one complete JSON object per line.
fn drainNdjsonLines(c: *Component) void {
    while (true) {
        const nl_idx = std.mem.indexOfScalar(u8, c.line_buf.items, '\n') orelse break;
        const line = c.line_buf.items[0..nl_idx];
        if (line.len > 0) {
            applyOllamaLine(c, line) catch |e| {
                std.log.warn("llm-stream/ollama: bad json line: {s}", .{@errorName(e)});
            };
        }
        consumeLineBuf(c, nl_idx + 1);
    }
}

/// OpenAI / DeepSeek / Together / Groq wire format: SSE — events
/// separated by blank lines (`\n\n`); each event contains one or
/// more `field: value` lines. We only care about `data: ...`. The
/// literal payload `[DONE]` is the terminator marker.
fn drainSseEvents(c: *Component) void {
    while (true) {
        const sep = std.mem.indexOf(u8, c.line_buf.items, "\n\n") orelse break;
        const event = c.line_buf.items[0..sep];
        var lines = std.mem.splitScalar(u8, event, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimRight(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            // Accept both "data: ..." and "data:..." (SSE allows
            // both per spec, though `data: ` is canonical).
            var payload = line["data:".len..];
            if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
            if (std.mem.eql(u8, payload, "[DONE]")) {
                c.phase = .done;
                continue;
            }
            if (payload.len == 0) continue;
            applyOpenAiPayload(c, payload) catch |e| {
                std.log.warn("llm-stream/openai: bad data payload: {s}", .{@errorName(e)});
            };
        }
        consumeLineBuf(c, sep + 2);
    }
}

fn consumeLineBuf(c: *Component, drop_len: usize) void {
    const remaining_len = c.line_buf.items.len - drop_len;
    if (remaining_len > 0) {
        std.mem.copyForwards(u8, c.line_buf.items[0..remaining_len], c.line_buf.items[drop_len..]);
    }
    c.line_buf.shrinkRetainingCapacity(remaining_len);
}

const OllamaChunk = struct {
    message: ?struct {
        content: ?[]const u8 = null,
    } = null,
    done: bool = false,
    done_reason: ?[]const u8 = null,
};

fn applyOllamaLine(c: *Component, line: []const u8) !void {
    var parsed = try std.json.parseFromSlice(
        OllamaChunk,
        c.allocator,
        line,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value.message) |m| {
        if (m.content) |content| {
            if (content.len > 0) {
                try c.content.appendSlice(c.allocator, content);
                if (c.phase == .loading) c.phase = .streaming;
            }
        }
    }
    if (parsed.value.done) {
        c.phase = .done;
    }
}

const OpenAiDelta = struct {
    content: ?[]const u8 = null,
};

const OpenAiChoice = struct {
    delta: ?OpenAiDelta = null,
    finish_reason: ?[]const u8 = null,
};

const OpenAiChunk = struct {
    choices: ?[]const OpenAiChoice = null,
};

fn applyOpenAiPayload(c: *Component, json_str: []const u8) !void {
    var parsed = try std.json.parseFromSlice(
        OpenAiChunk,
        c.allocator,
        json_str,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const choices = parsed.value.choices orelse return;
    if (choices.len == 0) return;
    if (choices[0].delta) |d| {
        if (d.content) |content| {
            if (content.len > 0) {
                try c.content.appendSlice(c.allocator, content);
                if (c.phase == .loading) c.phase = .streaming;
            }
        }
    }
    // Some providers signal stream end via finish_reason on the
    // last choice; the `[DONE]` SSE marker also covers it. Either
    // is sufficient.
    if (choices[0].finish_reason) |_| {
        c.phase = .done;
    }
}

fn rerenderContent(c: *Component) !void {
    _ = c.arena.reset(.retain_capacity);
    const root = markdown.parseWithStateAndScope(
        c.arena.allocator(),
        c.content.items,
        theme_ref.?,
        registry_ref.?,
        c.child_state,
        c.scope,
    ) catch |e| {
        std.log.err("llm-stream: re-parse failed: {s}", .{@errorName(e)});
        return;
    };
    c.root = root;
}

// ── Layout / render ─────────────────────────────────────────────────

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
};

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *const Component = @ptrCast(@alignCast(ctx));

    switch (c.phase) {
        .idle => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} — ready", .{c.model_label}) catch "ready";
            return try renderPlaceholder(msg, .idle, origin, constraints, lc, out);
        },
        .loading => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} thinking…", .{c.model_label}) catch "thinking…";
            return try renderPlaceholder(msg, .loading, origin, constraints, lc, out);
        },
        .streaming, .done => {
            const saved = lc.state;
            lc.state = @ptrCast(c.child_state);
            defer lc.state = saved;
            return try element_layout.layoutAndRender(c.root, origin, constraints, lc, out);
        },
        .failed => {
            var buf: [256]u8 = undefined;
            const detail: []const u8 = c.err_name orelse "unknown error";
            const msg = std.fmt.bufPrint(&buf, "LLM stream failed: {s}", .{detail}) catch "LLM stream failed";
            return try renderPlaceholder(msg, .failed, origin, constraints, lc, out);
        },
    }
}

// ── Placeholders ────────────────────────────────────────────────────

const PlaceholderScheme = enum { idle, loading, failed };

const PLACEHOLDER_RADIUS: f32 = 6;
const PLACEHOLDER_BORDER_PX: f32 = 2;
const PLACEHOLDER_PAD_X: f32 = 12;
const PLACEHOLDER_PAD_Y: f32 = 8;
const PLACEHOLDER_MIN_W: f32 = 240;

const IDLE_BORDER: [4]f32 = .{ 0.40, 0.46, 0.54, 0.75 };
const IDLE_BG: [4]f32 = .{ 0.10, 0.12, 0.16, 0.55 };
const LOADING_BORDER: [4]f32 = .{ 0.45, 0.65, 0.55, 0.85 };
const LOADING_BG: [4]f32 = .{ 0.08, 0.16, 0.12, 0.55 };
const FAILED_BORDER: [4]f32 = .{ 0.85, 0.30, 0.30, 0.95 };
const FAILED_BG: [4]f32 = .{ 0.30, 0.08, 0.08, 0.60 };

fn renderPlaceholder(
    msg: []const u8,
    scheme: PlaceholderScheme,
    origin: [2]f32,
    constraints: element.Constraints,
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
    const arena_alloc = arena.allocator();

    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(arena_alloc, hb, msg);

    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const intrinsic_w = text_w + 2 * PLACEHOLDER_PAD_X;
    const total_w: f32 = if (std.math.isFinite(constraints.max_w))
        constraints.max_w
    else
        @max(intrinsic_w, PLACEHOLDER_MIN_W);
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
        run,
        style.font_id,
        origin[0] + PLACEHOLDER_PAD_X,
        baseline_y,
        style.color,
        style.hot_color,
        style.attention,
    );

    return .{
        .x = origin[0],
        .y = origin[1],
        .w = total_w,
        .h = total_h,
        .baseline = baseline_y,
    };
}

fn findAttr(attrs: []const components.Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "buildOllamaBody: produces valid JSON with stream + think:false" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildOllamaBody(buf.writer(), "qwen3.5:2b", "say hi", null, 64);

    // Round-trip parse to confirm well-formed JSON shape.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("qwen3.5:2b", obj.get("model").?.string);
    try testing.expect(obj.get("stream").?.bool == true);
    try testing.expect(obj.get("think").?.bool == false);
    const messages = obj.get("messages").?.array;
    try testing.expectEqual(@as(usize, 1), messages.items.len);
    try testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try testing.expectEqualStrings("say hi", messages.items[0].object.get("content").?.string);
    try testing.expectEqual(@as(i64, 64), obj.get("options").?.object.get("num_predict").?.integer);
}

test "buildOllamaBody: includes system message when provided" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildOllamaBody(buf.writer(), "qwen3.5:2b", "go", "be brief", 32);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array;
    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expectEqualStrings("system", messages.items[0].object.get("role").?.string);
    try testing.expectEqualStrings("be brief", messages.items[0].object.get("content").?.string);
}

test "buildOllamaBody: escapes special characters in prompt" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildOllamaBody(buf.writer(), "m", "line1\nline2 with \"quotes\"\tand tab", null, 8);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
    try testing.expectEqualStrings("line1\nline2 with \"quotes\"\tand tab", content);
}

test "buildOpenAiBody: omits Ollama-specific options, uses max_tokens" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildOpenAiBody(buf.writer(), "deepseek-chat", "hello", null, 128);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("deepseek-chat", obj.get("model").?.string);
    try testing.expect(obj.get("stream").?.bool == true);
    try testing.expect(obj.get("think") == null); // Ollama-only
    try testing.expect(obj.get("options") == null); // Ollama-only
    try testing.expectEqual(@as(i64, 128), obj.get("max_tokens").?.integer);
}

test "Provider.parse: round-trip + unknown returns null" {
    try testing.expectEqual(Provider.ollama, Provider.parse("ollama").?);
    try testing.expectEqual(Provider.openai, Provider.parse("openai").?);
    try testing.expect(Provider.parse("gemini") == null);
    try testing.expect(Provider.parse("") == null);
}
