//! spark_demo — host-side scaffolding for the spark library
//! after the Phase 3 library-ification flip.
//!
//! Imports `@import("spark")` only for everything the library
//! owns: Spark, Document, FrameInfo, Theme, Element, State, registry,
//! per-frame methods, input dispatch. The host still owns the
//! cooperative-embed surface: GLFW window, Vulkan instance/device/
//! swapchain, the per-frame Renderer (cmd buffer + acquire/submit/
//! present), font building from env vars, persistent state path
//! resolution, demo HTTP server, the timer-driven update + chart
//! feed, scroll-tween + zoom policy.
//!
//! Pass a markdown path as `argv[1]` to load that document; otherwise
//! the embedded `demo.md` runs. `--core-only` skips DotEnv + AssetCache
//! + every extras factory so the demo runs on just the core component
//! set (proves the boundary). `src/hello.md` is the FPS canary
//! baseline; see `docs/library-spec.md`.

const std = @import("std");
const spark = @import("spark");

// Host-only modules. Vulkan + GLFW + the demo's per-frame Renderer
// and the test HTTP server stay outside spark — the spec calls these
// out as host responsibilities in §"Cooperative Vulkan handshake".
// Pulled in via the spark namespace so Zig doesn't see the
// same source files rooted in two modules at once.
const win = spark.window;
const vk = spark.vk;
const swap = spark.swapchain;
const renderer = spark.renderer;
const demo_server_mod = @import("demo_server.zig");

/// Embedded fallback markdown. Used when no `argv[1]` doc path is
/// passed. `src/hello.md` is the FPS canary baseline; pass it
/// explicitly for stable measurements.
const demo_md = @embedFile("demo.md");

/// Small ANSI fixture rendered alongside the markdown via the
/// library's `spark.ansi.parse`. The `\x1b` escapes resolve at
/// compile time to real ESC bytes so the parser sees authentic
/// terminal output.
const ansi_demo =
    "\x1b[1;31m\xE2\x97\x8F\x1b[0m bold red    " ++
    "\x1b[1;32m\xE2\x97\x8F\x1b[0m bold green    " ++
    "\x1b[1;33m\xE2\x97\x8F\x1b[0m bold yellow\n" ++
    "\x1b[34mblue\x1b[0m  " ++
    "\x1b[38;5;202m256: orange\x1b[0m  " ++
    "\x1b[38;2;255;127;80mtrue: coral\x1b[0m  " ++
    "\x1b[3mitalic\x1b[0m\n";

/// Per-host frame context. Holds scroll/zoom tween bookkeeping, the
/// shared State, and pointers to Spark + the two Documents. The
/// renderer's `draw_fn` receives this through its `*anyopaque` slot.
const HostCtx = struct {
    spark: *spark.Spark,
    state: *spark.State,
    top_doc: *spark.Document,
    ansi_doc: *spark.Document,

    // Scroll + zoom policy lives on the host. spark.frame_info takes
    // a scroll_offset + zoom each beginFrame; host computes them.
    scroll_y: f32 = 0,
    target_scroll_y: f32 = 0,
    zoom: f32 = 1.0,
    max_scroll_y: f32 = 0,
    last_frame_ms: i64 = 0,
    last_extent: vk.c.VkExtent2D = .{ .width = 0, .height = 0 },

    start_ms: i64 = 0,
    overflow_logged: bool = false,
};

/// Renderer pre_draw_fn. Fires after the swapchain transition but
/// BEFORE `vkCmdBeginRendering`. Does ALL spark work that has to
/// happen before the main render pass opens:
///   * attachCmd + beginFrame (per-frame state setup)
///   * layoutAndRender (populates pass_dispatches + drawlist)
///   * dispatchOffscreenPasses (effects-spec Phase 1 single-source
///     offscreen render passes — scope here so they don't nest
///     inside the main render pass, which Vulkan forbids)
///
/// drawCb (draw_fn) below handles only endFrame — recording
/// rasterizer draws + Phase 2 composes into the active main pass.
fn preDrawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) anyerror!void {
    const h: *HostCtx = @ptrCast(@alignCast(ctx.?));

    // ── Scroll tween ───────────────────────────────────────────────
    const now_ms = std.time.milliTimestamp();
    if (h.last_frame_ms == 0) h.last_frame_ms = now_ms;
    const dt_ms: f32 = @floatFromInt(now_ms - h.last_frame_ms);
    h.last_frame_ms = now_ms;
    if (@abs(h.target_scroll_y - h.scroll_y) > 0.5) {
        const tau_ms: f32 = 60.0;
        const clamped_dt = @min(dt_ms, 50.0);
        const alpha = 1.0 - std.math.exp(-clamped_dt / tau_ms);
        h.scroll_y += (h.target_scroll_y - h.scroll_y) * alpha;
        h.state.dirty = true;
    } else if (h.scroll_y != h.target_scroll_y) {
        h.scroll_y = h.target_scroll_y;
        h.state.dirty = true;
    }

    const extent_changed = extent.width != h.last_extent.width or extent.height != h.last_extent.height;
    const re_layout = extent_changed or h.state.dirty;
    h.last_extent = extent;

    h.spark.attachCmd(cmd, 0, 0);
    h.spark.beginFrame(
        .{ .extent = extent, .zoom = h.zoom, .scroll_offset = .{ 0, h.scroll_y } },
        .{ .reset = re_layout },
    ) catch |err| {
        if (!h.overflow_logged) {
            std.debug.print("WARN: beginFrame failed: {s}\n", .{@errorName(err)});
            h.overflow_logged = true;
        }
        return;
    };

    if (re_layout) {
        const w: f32 = @floatFromInt(extent.width);
        const viewport_world_w: f32 = w / h.zoom;
        const max_w: f32 = @max(viewport_world_w - 80.0, 200.0);
        const constraints: spark.Constraints = .{ .max_w = max_w };

        const top_box = h.spark.layoutAndRender(h.top_doc, .{ 40, 40 }, constraints) catch |err| switch (err) {
            error.AtlasFull => {
                std.debug.print("INFO: AtlasFull at zoom={d:.3} — resetting caches\n", .{h.zoom});
                h.spark.invalidateCaches() catch {};
                return;
            },
            else => {
                if (!h.overflow_logged) {
                    std.debug.print(
                        "WARN: layoutAndRender(top) failed ({s}) at zoom={d:.3}, extent={d}x{d}\n",
                        .{ @errorName(err), h.zoom, extent.width, extent.height },
                    );
                    h.overflow_logged = true;
                }
                return;
            },
        };

        const ansi_box = h.spark.layoutAndRender(
            h.ansi_doc,
            .{ 40, top_box.y + top_box.h + 8 },
            constraints,
        ) catch |err| {
            if (!h.overflow_logged) {
                std.debug.print("WARN: layoutAndRender(ansi) failed ({s})\n", .{@errorName(err)});
                h.overflow_logged = true;
            }
            return;
        };

        const content_bottom_world = ansi_box.y + ansi_box.h;
        const viewport_h_world: f32 = @as(f32, @floatFromInt(extent.height)) / h.zoom;
        const bottom_margin: f32 = 40;
        h.max_scroll_y = @max(@as(f32, 0), content_bottom_world + bottom_margin - viewport_h_world);
        if (h.scroll_y > h.max_scroll_y) h.scroll_y = h.max_scroll_y;
        if (h.scroll_y < 0) h.scroll_y = 0;

        h.state.clearDirty();
    }

    try h.spark.dispatchOffscreenPasses(cmd);
}

/// Renderer draw_fn. Called per frame WITH the active cmd buffer
/// already inside `vkCmdBeginRendering` (the renderer.zig wraps with
/// loadOp=CLEAR + the demo's clear colour). Spark records draws into
/// the open scope via `endFrame`.
fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const h: *HostCtx = @ptrCast(@alignCast(ctx.?));
    _ = cmd; // spark has it via attachCmd from preDrawCb
    _ = extent;

    h.spark.endFrame() catch |err| {
        if (!h.overflow_logged) {
            std.debug.print("WARN: endFrame failed: {s}\n", .{@errorName(err)});
            h.overflow_logged = true;
        }
        return;
    };
}

// ── Input plumbing ────────────────────────────────────────────────

fn processInput(window: *win.Window, h: *HostCtx) !void {
    var x_raw: f64 = 0;
    var y_raw: f64 = 0;
    win.c.glfwGetCursorPos(window.handle, &x_raw, &y_raw);
    // Un-transform: screen → world (inverse of `screen = (world - scroll) * zoom`).
    const x: f32 = @as(f32, @floatCast(x_raw)) / h.zoom;
    const y: f32 = @as(f32, @floatCast(y_raw)) / h.zoom + h.scroll_y;
    const button_now = win.c.glfwGetMouseButton(window.handle, win.c.GLFW_MOUSE_BUTTON_LEFT) == win.c.GLFW_PRESS;

    if (button_now != h.spark.mouse_down) {
        try h.spark.dispatchMouseButton(x, y, button_now);
    } else if (button_now) {
        // Held + position update → drag move.
        try h.spark.dispatchMouseMove(x, y);
    } else {
        // No press, just update the position cache (used by future hover).
        h.spark.mouse_x = x;
        h.spark.mouse_y = y;
    }
}

// GLFW key callback — keyboard navigation + zoom + focused-component
// routing. Esc clears focus globally.
fn keyCb(window: ?*win.c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.C) void {
    if (action != win.c.GLFW_PRESS and action != win.c.GLFW_REPEAT) return;
    const ud = win.c.glfwGetWindowUserPointer(window);
    if (ud == null) return;
    const h: *HostCtx = @ptrCast(@alignCast(ud));

    if (key == win.c.GLFW_KEY_ESCAPE and h.spark.focused != null) {
        h.spark.clearFocus();
        h.state.dirty = true;
        return;
    }

    // Focused component eats keys.
    if (h.spark.focused != null) {
        h.spark.dispatchKey(.{ .key = @intCast(key), .mods = @intCast(mods) }) catch {};
        h.state.dirty = true;
        return;
    }

    const ctrl = (mods & win.c.GLFW_MOD_CONTROL) != 0;
    if (ctrl) {
        switch (key) {
            win.c.GLFW_KEY_EQUAL, win.c.GLFW_KEY_KP_ADD => {
                h.zoom = std.math.clamp(h.zoom * 1.10, 0.25, 4.0);
                h.state.dirty = true;
            },
            win.c.GLFW_KEY_MINUS, win.c.GLFW_KEY_KP_SUBTRACT => {
                h.zoom = std.math.clamp(h.zoom / 1.10, 0.25, 4.0);
                h.state.dirty = true;
            },
            win.c.GLFW_KEY_0, win.c.GLFW_KEY_KP_0 => {
                h.zoom = 1.0;
                h.state.dirty = true;
            },
            else => {},
        }
        return;
    }

    const viewport_h: f32 = @as(f32, @floatFromInt(h.last_extent.height)) / h.zoom;
    const page: f32 = @max(viewport_h - 80, 100);
    switch (key) {
        win.c.GLFW_KEY_PAGE_DOWN => h.target_scroll_y = std.math.clamp(h.target_scroll_y + page, 0, h.max_scroll_y),
        win.c.GLFW_KEY_PAGE_UP => h.target_scroll_y = std.math.clamp(h.target_scroll_y - page, 0, h.max_scroll_y),
        win.c.GLFW_KEY_HOME => h.target_scroll_y = 0,
        win.c.GLFW_KEY_END => h.target_scroll_y = h.max_scroll_y,
        else => return,
    }
}

fn charCb(window: ?*win.c.GLFWwindow, codepoint: c_uint) callconv(.C) void {
    const ud = win.c.glfwGetWindowUserPointer(window);
    if (ud == null) return;
    const h: *HostCtx = @ptrCast(@alignCast(ud));
    if (h.spark.focused == null) return;
    h.spark.dispatchChar(@intCast(codepoint)) catch {};
    h.state.dirty = true;
}

fn scrollCb(window: ?*win.c.GLFWwindow, _: f64, yoffset: f64) callconv(.C) void {
    const ud = win.c.glfwGetWindowUserPointer(window);
    if (ud == null) return;
    const h: *HostCtx = @ptrCast(@alignCast(ud));

    const ctrl = win.c.glfwGetKey(window, win.c.GLFW_KEY_LEFT_CONTROL) == win.c.GLFW_PRESS or
        win.c.glfwGetKey(window, win.c.GLFW_KEY_RIGHT_CONTROL) == win.c.GLFW_PRESS;

    if (ctrl) {
        const step: f32 = 1.10;
        const dy: f32 = @floatCast(yoffset);
        if (dy > 0) h.zoom *= std.math.pow(f32, step, dy);
        if (dy < 0) h.zoom /= std.math.pow(f32, step, -dy);
        h.zoom = std.math.clamp(h.zoom, 0.25, 4.0);
    } else {
        const px_per_notch: f32 = 60.0;
        h.target_scroll_y -= @as(f32, @floatCast(yoffset)) * px_per_notch;
        h.target_scroll_y = std.math.clamp(h.target_scroll_y, 0, h.max_scroll_y);
    }
    h.state.dirty = true;
}

// ── Paths (XDG conventions) ───────────────────────────────────────

fn computeAssetCacheDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg| {
        defer allocator.free(xdg);
        return try std.fs.path.join(allocator, &.{ xdg, "spark", "assets" });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".cache", "spark", "assets" });
}

fn computeStateFilePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg| {
        defer allocator.free(xdg);
        return try std.fs.path.join(allocator, &.{ xdg, "spark", "state.json" });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".local", "state", "spark", "state.json" });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("spark demo — session 20 (library-spec closed: Phases 1-5 + rename)\n", .{});
    try stdout.print("  vertex SPIR-V bytes:   {d}\n", .{spark.shaders.text_vert.len});
    try stdout.print("  fragment SPIR-V bytes: {d}\n", .{spark.shaders.text_frag.len});

    // ── CLI parsing ───────────────────────────────────────────────
    var core_only: bool = false;
    var doc_path_owned: ?[]u8 = null;
    {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--core-only")) {
                core_only = true;
            } else if (doc_path_owned == null) {
                doc_path_owned = try allocator.dupe(u8, args[i]);
            }
        }
    }
    defer if (doc_path_owned) |p| allocator.free(p);

    // `doc_bytes_owned`: when a CLI path was given, the read bytes
    // are owned by the host and must outlive every consumer that
    // holds a slice into them (top_doc.arena holds parsed-Element
    // string slices; host_state retains frontmatter slices). Freed
    // by the defer below, ORDERED so it runs AFTER top_doc.deinit()
    // + host_state.deinit() (Zig fires defers LIFO — declare this
    // one first).
    var doc_bytes_owned: ?[]u8 = null;
    defer if (doc_bytes_owned) |b| allocator.free(b);

    const doc_source: []const u8 = doc_blk: {
        if (doc_path_owned) |path| {
            const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |e| {
                try stdout.print("  doc {s} load failed: {s} — falling back to embedded demo.md\n", .{ path, @errorName(e) });
                break :doc_blk demo_md;
            };
            doc_bytes_owned = bytes;
            try stdout.print("  doc:                  {d} bytes ({s})\n", .{ bytes.len, path });
            break :doc_blk bytes;
        }
        try stdout.print("  doc (embedded):       {d} bytes (demo.md — pass a path to override)\n", .{demo_md.len});
        break :doc_blk demo_md;
    };
    if (core_only) try stdout.print("  mode:                 --core-only (extras + DotEnv + AssetCache skipped)\n", .{});

    // ── Host-owned Vulkan + window ────────────────────────────────
    var window = try win.Window.init(1280, 720, "spark_demo");
    defer window.deinit();

    var ctx = try vk.Context.init(allocator, &window, "spark_demo");
    defer ctx.deinit();
    try stdout.print("  vulkan device:         {s}\n", .{std.mem.sliceTo(ctx.deviceName(), 0)});

    var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
    defer swapchain.deinit();

    // ── Host-owned font building ──────────────────────────────────
    // FT + FontRegistry are built here, then handed to Spark by
    // ownership transfer. Theme references the resulting font_ids.
    const font_path = std.posix.getenv("SPARK_FONT") orelse "/usr/share/fonts/TTF/DejaVuSans.ttf";
    const italic_path = std.posix.getenv("SPARK_ITALIC_FONT") orelse "/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf";
    const bold_path = std.posix.getenv("SPARK_BOLD_FONT") orelse "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf";
    const bold_italic_path = std.posix.getenv("SPARK_BOLD_ITALIC_FONT") orelse "/usr/share/fonts/TTF/DejaVuSans-BoldOblique.ttf";
    const mono_path = std.posix.getenv("SPARK_MONO_FONT") orelse "/usr/share/fonts/TTF/DejaVuSansMono.ttf";
    const emoji_path = std.posix.getenv("SPARK_EMOJI_FONT") orelse "/usr/share/fonts/noto/NotoColorEmoji.ttf";

    var ft = try spark.font.Library.init();
    defer ft.deinit();

    var fonts = try allocator.create(spark.FontRegistry);
    fonts.* = spark.FontRegistry.init(allocator, ft);

    const h1_id = try fonts.load(font_path.ptr, 48);
    const h2_id = try fonts.load(font_path.ptr, 32);
    const h3_id = try fonts.load(font_path.ptr, 24);
    const body_id = try fonts.load(font_path.ptr, 20);
    const italic_id = try fonts.load(italic_path.ptr, 20);
    const bold_id = try fonts.load(bold_path.ptr, 20);
    const bold_italic_id = try fonts.load(bold_italic_path.ptr, 20);
    const code_inline_id = try fonts.load(mono_path.ptr, 20);
    const code_block_id = try fonts.load(mono_path.ptr, 18);
    const emoji_id = try fonts.load(emoji_path.ptr, 28);

    // ── Theme ─────────────────────────────────────────────────────
    const white: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const heading_color: [4]f32 = .{ 0.95, 0.96, 0.99, 1.0 };
    const heading_dim: [4]f32 = .{ 0.78, 0.83, 0.92, 1.0 };
    const marker_color: [4]f32 = .{ 0.65, 0.72, 0.85, 1.0 };

    const theme: spark.Theme = .{
        .body = .{ .font_id = body_id, .color = white },
        .heading = .{
            .{ .font_id = h1_id, .color = heading_color },
            .{ .font_id = h2_id, .color = heading_color },
            .{ .font_id = h3_id, .color = heading_dim },
            .{ .font_id = h3_id, .color = heading_dim },
            .{ .font_id = h3_id, .color = heading_dim },
            .{ .font_id = h3_id, .color = heading_dim },
        },
        .code_block = .{ .font_id = code_block_id, .color = .{ 0.72, 0.88, 1.0, 1.0 } },
        .list_marker = .{ .font_id = body_id, .color = marker_color },
        .emphasis_font_id = italic_id,
        .strong_font_id = bold_id,
        .bold_italic_font_id = bold_italic_id,
        .code_inline_font_id = code_inline_id,
        .fallback_font_id = emoji_id,
        .font_registry = fonts,
    };

    // ── Host-owned reactive state ─────────────────────────────────
    // Built from the doc's frontmatter (best-effort) and seeded with
    // any persisted values from the previous session. Shared with
    // both Documents below via LoadOpts.shared_state.
    var host_state = (try spark.stateFromSource(allocator, doc_source)) orelse spark.State.init(allocator);
    defer host_state.deinit();

    const state_path = try computeStateFilePath(allocator);
    defer allocator.free(state_path);
    host_state.loadFromFile(state_path) catch |e| switch (e) {
        error.FileNotFound => try stdout.print("  state file:           (none yet) — first run\n", .{}),
        else => try stdout.print("  state file:           {s} (load failed: {s})\n", .{ state_path, @errorName(e) }),
    };

    // ── Spark.init — owns atlases, pipelines, glyph cache, layout
    //    cache, layout context, registry, io_channel, JobSystems.
    //    Takes ownership of the FontRegistry built above.
    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &ctx,
        .color_format = swapchain.format,
        .theme = &theme,
        .fonts = fonts,
        .host_state = &host_state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts);
    }
    sp.attachToRegistry();

    // ── Component installs ────────────────────────────────────────
    try spark.installCoreComponents(&sp);

    if (!core_only) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const env_path = try std.fs.path.join(allocator, &.{ home, ".env" });
        defer allocator.free(env_path);
        sp.installDotEnv(env_path) catch |e| {
            try stdout.print("  installDotEnv:        {s} (continuing)\n", .{@errorName(e)});
        };

        const asset_cache_dir = try computeAssetCacheDir(allocator);
        defer allocator.free(asset_cache_dir);
        try sp.installAssetCache(asset_cache_dir, 500 * 1024 * 1024);
        if (sp.asset_cache) |ac| {
            const s = ac.stats();
            try stdout.print(
                "  asset cache:          {d} entries / {d:.1} MB / {d:.0} MB budget @ {s}\n",
                .{
                    s.entry_count,
                    @as(f64, @floatFromInt(s.total_bytes)) / (1024.0 * 1024.0),
                    @as(f64, @floatFromInt(s.budget_bytes)) / (1024.0 * 1024.0),
                    asset_cache_dir,
                },
            );
        }

        try spark.extras.embedded_document_http.install(&sp);
        try spark.extras.llm_stream.install(&sp);
        try spark.extras.svg_stream.install(&sp);
        try spark.extras.image_stream.install(&sp);
    }

    // ── Demo HTTP server (test fixture for embedded-document URL src=).
    const demo_server = try demo_server_mod.Server.start(allocator, "src/widgets", 8080);
    defer demo_server.stop();

    // ── Load the markdown doc via the library ─────────────────────
    var top_doc = try sp.loadDocument(doc_source, .{ .shared_state = &host_state });
    defer top_doc.deinit();

    // ── Build the ANSI tree separately and wrap it as a Document ──
    // ansi.parse produces an Element tree from terminal escape
    // sequences — not markdown — so we use wrapElement instead of
    // loadDocument. The arena hands ownership to the Document so
    // its deinit cleans up.
    var ansi_theme = theme;
    ansi_theme.body = .{ .font_id = code_inline_id, .color = .{ 0.92, 0.94, 0.98, 1.0 } };

    const ansi_arena = try allocator.create(std.heap.ArenaAllocator);
    ansi_arena.* = std.heap.ArenaAllocator.init(allocator);
    const ansi_root = try spark.ansi.parse(ansi_arena.allocator(), ansi_demo, &ansi_theme);
    var ansi_doc = spark.wrapElement(allocator, ansi_arena, ansi_root, &host_state, &ansi_theme);
    defer ansi_doc.deinit();

    // Tree swap complete — GC stale cached component instances.
    sp.registry.gc();

    // ── Renderer (host-owned per-frame loop) ──────────────────────
    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var host_ctx = HostCtx{
        .spark = &sp,
        .state = &host_state,
        .top_doc = &top_doc,
        .ansi_doc = &ansi_doc,
        .start_ms = std.time.milliTimestamp(),
    };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&host_ctx);
    rdr.pre_draw_fn = preDrawCb;
    // Light surface so the drop_shadow's dark shadow is visible —
    // temporary demo polish while B.5 is fresh. Revert to the
    // dark default (.{0.04, 0.04, 0.07, 1.0}) once the effect's
    // calibrated.
    rdr.clear_color = .{ 0.93, 0.94, 0.96, 1.0 };

    win.c.glfwSetWindowUserPointer(window.handle, @ptrCast(&host_ctx));
    _ = win.c.glfwSetScrollCallback(window.handle, scrollCb);
    _ = win.c.glfwSetKeyCallback(window.handle, keyCb);
    _ = win.c.glfwSetCharCallback(window.handle, charCb);

    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "SPARK_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;

    // ── Timer-driven update feeds (color cycle + chart) ──────────
    const UPDATE_CYCLE_MS: i64 = 1500;
    const cycle_colors = [_][]const u8{ "blue", "purple", "cyan", "green", "orange" };
    var color_idx: usize = 0;
    var last_update_ms = std.time.milliTimestamp();

    const CHART_TICK_MS: i64 = 16;
    var last_chart_ms = std.time.milliTimestamp();
    var chart_phase: f32 = 0;
    var chart_rng = std.Random.DefaultPrng.init(0xC04EE);

    var frame_count: u64 = 0;
    var update_count: u64 = 0;
    while (!window.shouldClose()) {
        window.pollEvents();
        processInput(&window, &host_ctx) catch {};

        // Drain async I/O completions on the main thread.
        sp.tick();

        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_update_ms >= UPDATE_CYCLE_MS) {
            color_idx = (color_idx + 1) % cycle_colors.len;
            var buf: [256]u8 = undefined;
            const directive = std.fmt.bufPrint(&buf,
                \\:::update {{target=state.box_color}}
                \\{s}
                \\:::
                \\
            , .{cycle_colors[color_idx]}) catch unreachable;
            const n = sp.applyUpdate(directive) catch 0;
            update_count += n;
            last_update_ms = now_ms;
        }

        if (now_ms - last_chart_ms >= CHART_TICK_MS) {
            chart_phase += 0.06;
            const base = std.math.sin(chart_phase);
            const harmonic = 0.40 * std.math.sin(chart_phase * 3.1);
            const detail = 0.18 * std.math.sin(chart_phase * 7.7);
            const noise = (chart_rng.random().float(f32) - 0.5) * 0.15;
            const sample = std.math.clamp(base * 0.6 + harmonic + detail + noise, -1.0, 1.0);

            var buf: [128]u8 = undefined;
            const directive = std.fmt.bufPrint(&buf,
                \\:::update {{#telemetry action=append}}
                \\{d:.4}
                \\:::
                \\
            , .{sample}) catch unreachable;
            const n = sp.applyUpdate(directive) catch 0;
            update_count += n;
            last_chart_ms = now_ms;
        }

        try rdr.drawFrame();
        frame_count += 1;

        const PERSIST_INTERVAL_FRAMES: u64 = 60;
        if (frame_count % PERSIST_INTERVAL_FRAMES == 0 and host_state.persist_dirty) {
            host_state.saveToFile(state_path) catch |e| {
                std.log.warn("state save failed: {s}", .{@errorName(e)});
            };
            host_state.clearPersistDirty();
        }

        if (exit_after_ms) |limit| {
            // Mirror the user's X-button path: set the GLFW
            // should-close flag instead of `break`ing the loop. The
            // loop continues one more iteration, then the next
            // shouldClose() returns true and the loop exits via the
            // same path a real close would take.
            if (std.time.milliTimestamp() - host_ctx.start_ms >= limit) {
                win.c.glfwSetWindowShouldClose(window.handle, win.c.GLFW_TRUE);
            }
        }
    }

    if (host_state.persist_dirty) {
        host_state.saveToFile(state_path) catch |e| {
            std.log.warn("state final flush failed: {s}", .{@errorName(e)});
        };
        host_state.clearPersistDirty();
    }

    // Drain the GPU before tearing down (Spark.deinit destroys
    // pipelines + atlases — the queue must be idle first).
    _ = vk.c.vkDeviceWaitIdle(ctx.device);

    const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - host_ctx.start_ms);
    const fps: f64 = if (elapsed_ms > 0)
        @as(f64, @floatFromInt(frame_count)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms))
    else
        0;
    try stdout.print("  frames:                {d} in {d}ms ({d:.1} fps)\n", .{ frame_count, elapsed_ms, fps });
    try stdout.print("  updates applied:       {d} via :::update wire format\n", .{update_count});
}
