//! examples/minimal_host.zig — smallest possible second consumer of
//! the spark library. Phase 4 of the library-spec.
//!
//! Single import: `@import("spark")`. The GLFW window, Vulkan
//! instance/device/swapchain, and per-frame Renderer used here are
//! re-exported from `spark.{window, swapchain, renderer}` — they
//! are demo-supporting code, not stable public API. Real production
//! hosts (matryoshka HUD, terminal app) will write their own; this
//! file copies the cooperative-embed dance they will use against the
//! stable surface (Spark, Document, FrameInfo, attachCmd/beginFrame/
//! layoutAndRender/endFrame/tick).
//!
//! What this proves:
//!   * `Spark.init` + `attachToRegistry` + `installCoreComponents`
//!     stand up without reaching into any internal module.
//!   * One Document with a `:::box` and a `:::slider` parses,
//!     lays out, and renders.
//!   * Mouse dispatch into Spark drives the slider's value, which
//!     updates `state.radius`, which `${state.radius}` re-binds onto
//!     the box's radius — all through the public API.
//!   * ESC closes the window, deinit runs clean.

const std = @import("std");
const spark = @import("spark");

const win = spark.window;
const vk = spark.vk;
const swap = spark.swapchain;
const renderer = spark.renderer;

/// Embedded markdown. Frontmatter seeds `state.radius = 16` so the
/// slider has a known starting position; the box reads the same key
/// through `${state.radius}`. `target=radius` on the slider writes
/// back to that key on drag.
const doc_md =
    \\---
    \\state:
    \\  radius: 16
    \\---
    \\
    \\# Spark — minimal host
    \\
    \\Drag the slider to resize the box corners.
    \\
    \\:::box {color=teal width=240 height=120 radius=${state.radius}}
    \\:::
    \\
    \\:::slider {target=radius min=0 max=60 value=${state.radius} width=320}
    \\:::
    \\
    \\Effects-spec Phase A.6.b — first visible gradient.
    \\
    \\:::gradient {from=#1a1a2e to=#0f3460 direction=vertical width=320 height=80}
    \\:::
    \\
;

/// Host frame context — passed to the Renderer's draw_fn through its
/// opaque pointer slot. Keeps Spark, the root State, and the Document
/// reachable inside the per-frame callback, and tracks the previous
/// extent so we can detect viewport resize without computing a hash.
const HostCtx = struct {
    spark: *spark.Spark,
    state: *spark.State,
    doc: *spark.Document,
    last_extent: vk.c.VkExtent2D = .{ .width = 0, .height = 0 },
};

/// Renderer pre_draw_fn. Fires before `vkCmdBeginRendering`. Does
/// all spark work that must complete before the main render pass
/// opens: attachCmd + beginFrame + layoutAndRender + Phase 1
/// offscreen passes (single_source effects scope here since Vulkan
/// forbids nested render passes).
fn preDrawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) anyerror!void {
    const h: *HostCtx = @ptrCast(@alignCast(ctx.?));

    const extent_changed = extent.width != h.last_extent.width or extent.height != h.last_extent.height;
    h.last_extent = extent;
    const reset = h.state.dirty or extent_changed;

    h.spark.attachCmd(cmd, 0, 0);
    h.spark.beginFrame(
        .{ .extent = extent, .zoom = 1.0, .scroll_offset = .{ 0, 0 } },
        .{ .reset = reset },
    ) catch return;

    if (reset) {
        const w: f32 = @floatFromInt(extent.width);
        const constraints: spark.Constraints = .{ .max_w = @max(w - 80, 200) };
        _ = h.spark.layoutAndRender(h.doc, .{ 40, 40 }, constraints) catch return;
        h.state.clearDirty();
    }

    try h.spark.dispatchOffscreenPasses(cmd);
}

/// Renderer draw_fn. Called inside `vkCmdBeginRendering` — records
/// rasterizer draws + Phase 2 composes via `endFrame`.
fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const h: *HostCtx = @ptrCast(@alignCast(ctx.?));
    _ = cmd;
    _ = extent;
    h.spark.endFrame() catch return;
}

/// GLFW key callback — ESC closes the window. Goes through
/// `glfwSetWindowShouldClose` so the destructor sequence matches
/// a user pressing the X button.
fn keyCb(window: ?*win.c.GLFWwindow, key: c_int, _: c_int, action: c_int, _: c_int) callconv(.C) void {
    if (action != win.c.GLFW_PRESS) return;
    if (key == win.c.GLFW_KEY_ESCAPE) {
        win.c.glfwSetWindowShouldClose(window, win.c.GLFW_TRUE);
    }
}

/// Per-frame mouse plumbing. Reads GLFW state once, dispatches the
/// edge (button-down or button-up) through Spark; on a held drag,
/// dispatches the move so the slider's captured Hit gets updates.
/// The state.dirty flag tripped inside Spark's dispatch path causes
/// the next frame's `reset` to fire a re-layout.
fn processInput(window: *win.Window, h: *HostCtx) !void {
    var x_raw: f64 = 0;
    var y_raw: f64 = 0;
    win.c.glfwGetCursorPos(window.handle, &x_raw, &y_raw);
    const x: f32 = @floatCast(x_raw);
    const y: f32 = @floatCast(y_raw);
    const button_now = win.c.glfwGetMouseButton(window.handle, win.c.GLFW_MOUSE_BUTTON_LEFT) == win.c.GLFW_PRESS;

    if (button_now != h.spark.mouse_down) {
        try h.spark.dispatchMouseButton(x, y, button_now);
    } else if (button_now) {
        try h.spark.dispatchMouseMove(x, y);
    } else {
        h.spark.mouse_x = x;
        h.spark.mouse_y = y;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── Host-owned window + Vulkan + swapchain ────────────────────
    var window = try win.Window.init(800, 600, "spark — minimal host");
    defer window.deinit();

    var ctx = try vk.Context.init(allocator, &window, "minimal_host");
    defer ctx.deinit();

    var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
    defer swapchain.deinit();

    // ── Host-owned font building ──────────────────────────────────
    // FreeType library + a single FontRegistry. Five sizes against
    // one font face is enough for h1 + body + code; minimal_host
    // doesn't ship italic / bold / emoji to keep the surface small.
    var ft = try spark.font.Library.init();
    defer ft.deinit();

    const fonts = try allocator.create(spark.FontRegistry);
    fonts.* = spark.FontRegistry.init(allocator, ft);

    const sans_path = "/usr/share/fonts/TTF/DejaVuSans.ttf";
    const mono_path = "/usr/share/fonts/TTF/DejaVuSansMono.ttf";
    const h1_id = try fonts.load(sans_path, 32);
    const body_id = try fonts.load(sans_path, 20);
    const code_id = try fonts.load(mono_path, 18);

    // ── Theme (host-owned) ────────────────────────────────────────
    const fg: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const dim: [4]f32 = .{ 0.78, 0.83, 0.92, 1.0 };
    const theme: spark.Theme = .{
        .body = .{ .font_id = body_id, .color = fg },
        .heading = .{
            .{ .font_id = h1_id, .color = fg },
            .{ .font_id = h1_id, .color = fg },
            .{ .font_id = body_id, .color = dim },
            .{ .font_id = body_id, .color = dim },
            .{ .font_id = body_id, .color = dim },
            .{ .font_id = body_id, .color = dim },
        },
        .code_block = .{ .font_id = code_id, .color = .{ 0.72, 0.88, 1.0, 1.0 } },
        .list_marker = .{ .font_id = body_id, .color = dim },
        .emphasis_font_id = body_id,
        .strong_font_id = body_id,
        .bold_italic_font_id = body_id,
        .code_inline_font_id = code_id,
        .fallback_font_id = body_id,
        .font_registry = fonts,
    };

    // ── Host-owned reactive state ─────────────────────────────────
    // Parsed from the doc's frontmatter (`state.radius = 16`). Shared
    // with the Document below via LoadOpts so the slider's writes
    // and the ${state.radius} reads see the same value.
    var host_state = (try spark.stateFromSource(allocator, doc_md)) orelse spark.State.init(allocator);
    defer host_state.deinit();

    // ── Spark.init ────────────────────────────────────────────────
    // Takes ownership of `fonts`. attachToRegistry wires the
    // registry's back-pointer; installCoreComponents registers
    // box / slider / and the other core factories.
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
    try spark.installCoreComponents(&sp);

    // ── Document ──────────────────────────────────────────────────
    var doc = try sp.loadDocument(doc_md, .{ .shared_state = &host_state });
    defer doc.deinit();

    // ── Host-owned per-frame renderer (acquire / record / submit
    //    / present). Spark records into the cmd buffer this hands
    //    out via the draw_fn.
    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var host_ctx = HostCtx{
        .spark = &sp,
        .state = &host_state,
        .doc = &doc,
    };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&host_ctx);
    rdr.pre_draw_fn = preDrawCb;

    win.c.glfwSetWindowUserPointer(window.handle, @ptrCast(&host_ctx));
    _ = win.c.glfwSetKeyCallback(window.handle, keyCb);

    // ── Optional timed exit (regression-detection hook) ───────────
    // `SPARK_EXIT_AFTER=N` (seconds, float) sets
    // glfwSetWindowShouldClose after N seconds — same destructor
    // sequence as a user pressing X. Not part of the cooperative-
    // embed surface; strip when copying this file as a template.
    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "SPARK_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;
    const start_ms = std.time.milliTimestamp();

    // ── Frame loop ────────────────────────────────────────────────
    while (!window.shouldClose()) {
        window.pollEvents();
        processInput(&window, &host_ctx) catch {};
        sp.tick();
        try rdr.drawFrame();
        if (exit_after_ms) |limit| {
            if (std.time.milliTimestamp() - start_ms >= limit) {
                win.c.glfwSetWindowShouldClose(window.handle, win.c.GLFW_TRUE);
            }
        }
    }

    // Drain the GPU before sp.deinit destroys pipelines + atlases.
    _ = vk.c.vkDeviceWaitIdle(ctx.device);
}
