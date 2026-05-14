//! text_engine_demo — Stage 1 of session 2:
//!
//! Same visual output as session 1 (heading + subtitle + mixed paragraph
//! + emoji line + rainbow SDF "ATTENTION"), but composed as an
//! `Element` tree and rendered through the new `element_layout` walker.
//! Sole point of the migration this stage: prove the contract holds
//! against session 1's content before adding markdown / ANSI engines on
//! top of it.
//!
//! The pulse-span trick from session 1 survives unchanged: layout the
//! top stack first, capture `glyphs.items.len`, then layout the SDF
//! paragraph — the new glyphs are the ones to animate. Phase B will
//! probably replace this with named ranges on the `DrawList`, but
//! it's not load-bearing for stage 1.

const std = @import("std");
const text_engine = @import("text_engine");
const win = @import("window.zig");
const vk = @import("gpu/vk.zig");
const swap = @import("gpu/swapchain.zig");
const renderer = @import("gpu/renderer.zig");
const atlas_mod = @import("gpu/atlas.zig");
const tp = @import("gpu/text_pipeline.zig");
const face_mod = @import("font/face.zig");
const registry_mod = @import("font/registry.zig");
const glyph_cache_mod = @import("text/glyph_cache.zig");
const element = @import("element.zig");
const element_layout = @import("element_layout.zig");

// Vendored cmark — see vendor/cmark/. Smoke-tested below; the actual
// markdown → Element mapper lands in stage 3b.
const cmark = @cImport({
    @cInclude("cmark.h");
});

const ATLAS_MONO_SIZE: u32 = 768;
const ATLAS_COLOR_SIZE: u32 = 1024;
const MAX_GLYPHS: u32 = 2048;

const FrameCtx = struct {
    pipeline: *tp.TextPipeline,
    n_glyphs: u32,
    /// Borrowed slice into the DrawList's glyph buffer — mutated per
    /// frame for the attention wave. Stable for the lifetime of the
    /// frame loop because we don't append after the layout pass.
    glyphs: []tp.GlyphInstance,
    /// Index range covering the animated SDF span — the wave
    /// rewrites only these entries each frame.
    pulse_start: u32,
    pulse_count: u32,
    /// Frame loop start time so the wave's phase is consistent.
    start_ms: i64,
};

fn drawCb(ctx: ?*anyopaque, cmd: vk.c.VkCommandBuffer, extent: vk.c.VkExtent2D) void {
    const fc: *const FrameCtx = @ptrCast(@alignCast(ctx.?));
    fc.pipeline.recordDraw(cmd, extent, fc.n_glyphs);
}

/// HSV → RGB conversion using the standard six-sextant formula. `h`
/// is degrees [0, 360); `s` and `v` are [0, 1]. Used by the demo to
/// paint each animated SDF glyph with its own rainbow hue.
fn hsvToRgb(h_deg: f32, s: f32, v: f32) [3]f32 {
    const c = v * s;
    const h_prime = @mod(h_deg / 60.0, 6.0);
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m = v - c;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (h_prime < 1.0) {
        r = c;
        g = x;
    } else if (h_prime < 2.0) {
        r = x;
        g = c;
    } else if (h_prime < 3.0) {
        g = c;
        b = x;
    } else if (h_prime < 4.0) {
        g = x;
        b = c;
    } else if (h_prime < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{ r + m, g + m, b + m };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("text_engine demo — session 2 / stage 3a (cmark vendored)\n", .{});
    try stdout.print("  vertex SPIR-V bytes:   {d}\n", .{text_engine.shaders.text_vert.len});
    try stdout.print("  fragment SPIR-V bytes: {d}\n", .{text_engine.shaders.text_frag.len});

    // ── cmark smoke test ───────────────────────────────────────────
    // Proves the vendored library links + parses + walks before we
    // build the markdown→Element mapper on top of it. Counts the
    // top-level block nodes the parser produces from a small input.
    {
        const src =
            \\# Hello
            \\
            \\A paragraph with **bold** and *italic*.
            \\
            \\- one
            \\- two
        ;
        const root = cmark.cmark_parse_document(src, src.len, cmark.CMARK_OPT_DEFAULT) orelse {
            try stdout.print("  cmark parse FAILED\n", .{});
            return error.CmarkParseFailed;
        };
        defer cmark.cmark_node_free(root);
        var n_blocks: u32 = 0;
        var child = cmark.cmark_node_first_child(root);
        while (child != null) : (child = cmark.cmark_node_next(child)) {
            n_blocks += 1;
        }
        try stdout.print("  cmark {s}: {d} top-level blocks\n", .{
            std.mem.sliceTo(cmark.cmark_version_string(), 0),
            n_blocks,
        });
    }

    var window = try win.Window.init(1280, 720, "text_engine_demo");
    defer window.deinit();

    var ctx = try vk.Context.init(allocator, &window, "text_engine_demo");
    defer ctx.deinit();
    try stdout.print("  vulkan device:         {s}\n", .{std.mem.sliceTo(ctx.deviceName(), 0)});

    var swapchain = try swap.Swapchain.init(allocator, &ctx, &window);
    defer swapchain.deinit();

    var atlas_mono = try atlas_mod.Atlas.init(&ctx, ATLAS_MONO_SIZE, ATLAS_MONO_SIZE, .mono_r8);
    defer atlas_mono.deinit();
    var atlas_color = try atlas_mod.Atlas.init(&ctx, ATLAS_COLOR_SIZE, ATLAS_COLOR_SIZE, .color_rgba8);
    defer atlas_color.deinit();

    var pipeline = try tp.TextPipeline.init(&ctx, swapchain.format, &atlas_mono, &atlas_color, MAX_GLYPHS);
    defer pipeline.deinit();

    const font_path = std.posix.getenv("TEXT_ENGINE_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans.ttf";
    const italic_path = std.posix.getenv("TEXT_ENGINE_ITALIC_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf";
    const bold_path = std.posix.getenv("TEXT_ENGINE_BOLD_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf";
    const bold_italic_path = std.posix.getenv("TEXT_ENGINE_BOLD_ITALIC_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSans-BoldOblique.ttf";
    const mono_path = std.posix.getenv("TEXT_ENGINE_MONO_FONT") orelse
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf";
    const emoji_path = std.posix.getenv("TEXT_ENGINE_EMOJI_FONT") orelse
        "/usr/share/fonts/noto/NotoColorEmoji.ttf";

    var ft = try face_mod.Library.init();
    defer ft.deinit();

    var fonts = registry_mod.FontRegistry.init(allocator, ft);
    defer fonts.deinit();

    const heading_id = try fonts.load(font_path.ptr, 56);
    const subtitle_id = try fonts.load(font_path.ptr, 18);
    const body_id = try fonts.load(font_path.ptr, 22);
    const italic_id = try fonts.load(italic_path.ptr, 22);
    const bold_id = try fonts.load(bold_path.ptr, 22);
    const bold_italic_id = try fonts.load(bold_italic_path.ptr, 22);
    const code_inline_id = try fonts.load(mono_path.ptr, 22);
    const accent_id = try fonts.load(font_path.ptr, 28);
    const emoji_id = try fonts.load(emoji_path.ptr, 28);
    const code_block_id = try fonts.load(mono_path.ptr, 18);
    const sdf_id = try fonts.loadSdf(font_path.ptr, 44);

    var cache = glyph_cache_mod.GlyphCache.init(allocator);
    defer cache.deinit();

    // ── Build the Theme ────────────────────────────────────────────
    // Single visual policy the rest of the demo cascades from. Stage
    // 3's markdown parser will look the same — load fonts, build a
    // Theme, hand it to LayoutCtx, parser uses `theme.apply*` to
    // resolve inline cascade onto text leaves.
    const white: [4]f32 = .{ 0.95, 0.95, 0.98, 1.0 };
    const grey: [4]f32 = .{ 0.58, 0.62, 0.72, 1.0 };
    const yellow: [4]f32 = .{ 0.99, 0.84, 0.32, 1.0 };
    const orange: [4]f32 = .{ 0.99, 0.55, 0.30, 1.0 };
    const marker_color: [4]f32 = .{ 0.65, 0.72, 0.85, 1.0 };

    const theme: element.Theme = .{
        .body = .{ .font_id = body_id, .color = white },
        .heading = .{
            // h1..h6 — stage 2c demo only uses h1, others fall back
            // to heading-1 styling. The parser in stage 3 will fill
            // these with distinct sizes.
            .{ .font_id = heading_id, .color = white },
            .{ .font_id = heading_id, .color = white },
            .{ .font_id = heading_id, .color = white },
            .{ .font_id = heading_id, .color = white },
            .{ .font_id = heading_id, .color = white },
            .{ .font_id = heading_id, .color = white },
        },
        .code_block = .{ .font_id = code_block_id, .color = .{ 0.72, 0.88, 1.0, 1.0 } },
        .list_marker = .{ .font_id = body_id, .color = marker_color },
        .emphasis_font_id = italic_id,
        .strong_font_id = bold_id,
        .bold_italic_font_id = bold_italic_id,
        .code_inline_font_id = code_inline_id,
    };

    // Convenience locals derived from the theme — caller-side
    // cascade for the hand-built tree. Stage 3's parser does the
    // same calls but from CommonMark events instead of by hand.
    const body_style = theme.body;
    const em_style = theme.applyEmphasis(theme.body);
    const strong_style = theme.applyStrong(theme.body);
    const bold_italic_style = theme.applyEmphasis(theme.applyStrong(theme.body));
    const code_inline_style = theme.applyCodeInline(theme.body);
    const link_style = theme.applyLink(theme.body);

    // Heading.
    const heading_children = [_]element.Element{
        .{ .text = .{ .content = "text_engine", .style = theme.heading[0] } },
    };
    const heading_block = element.Element{ .heading = .{ .level = 1, .content = &heading_children } };

    // Subtitle.
    const subtitle_children = [_]element.Element{
        .{ .text = .{ .content = "Stage 2c — Theme + inline structural kinds", .style = .{ .font_id = subtitle_id, .color = grey } } },
    };
    const subtitle_block = element.Element{ .paragraph = &subtitle_children };

    // Mixed-size, mixed-colour inline (session-1 demo line, preserved
    // for regression coverage).
    const mixed_children = [_]element.Element{
        .{ .text = .{ .content = "Mix ", .style = body_style } },
        .{ .text = .{ .content = "fonts", .style = .{ .font_id = body_id, .color = yellow } } },
        .{ .text = .{ .content = ", ", .style = body_style } },
        .{ .text = .{ .content = "sizes", .style = .{ .font_id = accent_id, .color = orange } } },
        .{ .text = .{ .content = ", colours inline; ", .style = body_style } },
        .{ .text = .{ .content = "🎉🦊🚀", .style = .{ .font_id = emoji_id, .color = white } } },
        .{ .text = .{ .content = " emoji.", .style = body_style } },
    };
    const mixed_block = element.Element{ .paragraph = &mixed_children };

    // ── Inline structural kinds via theme cascade ──────────────────
    // Each styled span is an inline structural Element whose
    // descendant text leaf carries the cascade-resolved Style. The
    // walker treats emphasis / strong / code / link as transparent
    // at render time — the visual distinction is purely in the
    // child text leaves' Style, which `theme.apply*` produced.
    const em_inner = [_]element.Element{
        .{ .text = .{ .content = "italic", .style = em_style } },
    };
    const strong_inner = [_]element.Element{
        .{ .text = .{ .content = "bold", .style = strong_style } },
    };
    const bold_italic_inner = [_]element.Element{
        .{ .text = .{ .content = "bold-italic", .style = bold_italic_style } },
    };
    const code_inner = [_]element.Element{
        .{ .text = .{ .content = "inline code", .style = code_inline_style } },
    };
    const link_inner = [_]element.Element{
        .{ .text = .{ .content = "link", .style = link_style } },
    };
    const styled_children = [_]element.Element{
        .{ .text = .{ .content = "Inline cascade: ", .style = body_style } },
        .{ .emphasis = &em_inner },
        .{ .text = .{ .content = ", ", .style = body_style } },
        .{ .strong = &strong_inner },
        .{ .text = .{ .content = ", ", .style = body_style } },
        .{ .strong = &bold_italic_inner },
        .{ .text = .{ .content = ", ", .style = body_style } },
        .{ .code = &code_inner },
        .{ .text = .{ .content = ", and a ", .style = body_style } },
        .{ .link = .{ .target = "https://example.com", .content = &link_inner } },
        .{ .text = .{ .content = ".", .style = body_style } },
    };
    const styled_block = element.Element{ .paragraph = &styled_children };

    // ── Unordered list with nested ordered list ────────────────────
    // Builds bottom-up because each list_item carries a child slice
    // that needs to live before its parent references it.
    const item1_p_children = [_]element.Element{
        .{ .text = .{ .content = "block kinds nest", .style = body_style } },
    };
    const item1_children = [_]element.Element{
        .{ .paragraph = &item1_p_children },
    };

    const max_w_code = [_]element.Element{
        .{ .text = .{ .content = "max_w", .style = code_inline_style } },
    };
    const item2_p_children = [_]element.Element{
        .{ .text = .{ .content = "indent shrinks ", .style = body_style } },
        .{ .code = &max_w_code },
        .{ .text = .{ .content = " for nested content", .style = body_style } },
    };
    const item2_children = [_]element.Element{
        .{ .paragraph = &item2_p_children },
    };

    // Item 3 contains a paragraph AND a nested ordered list — the
    // "multiple blocks per item" case CommonMark allows.
    const item3_p_children = [_]element.Element{
        .{ .text = .{ .content = "and items hold multiple blocks:", .style = body_style } },
    };
    const nested_item_a_p = [_]element.Element{
        .{ .text = .{ .content = "first nested", .style = body_style } },
    };
    const nested_item_a_children = [_]element.Element{
        .{ .paragraph = &nested_item_a_p },
    };
    const nested_item_b_p = [_]element.Element{
        .{ .text = .{ .content = "second nested", .style = body_style } },
    };
    const nested_item_b_children = [_]element.Element{
        .{ .paragraph = &nested_item_b_p },
    };
    const nested_items = [_]element.Element{
        .{ .list_item = .{ .children = &nested_item_a_children } },
        .{ .list_item = .{ .children = &nested_item_b_children } },
    };
    const nested_list = element.Element{ .list = .{
        .ordered = true,
        .items = &nested_items,
        .start = 1,
    } };
    const item3_children = [_]element.Element{
        .{ .paragraph = &item3_p_children },
        nested_list,
    };

    const unordered_items = [_]element.Element{
        .{ .list_item = .{ .children = &item1_children } },
        .{ .list_item = .{ .children = &item2_children } },
        .{ .list_item = .{ .children = &item3_children } },
    };
    const unordered_list = element.Element{ .list = .{
        .ordered = false,
        .items = &unordered_items,
    } };

    // ── Block quote containing a paragraph ─────────────────────────
    // Long-enough content to force the inline-flow wrap on the
    // quote's shrunken max_w — the stage-2b proof point.
    const quote_p_children = [_]element.Element{
        .{ .text = .{ .content = "Quotes indent their content, and indent propagates through Constraints so the inline-flow inside this quote wraps on the narrower available width — not on the full viewport width.", .style = body_style } },
    };
    const quote_children = [_]element.Element{
        .{ .paragraph = &quote_p_children },
    };
    const quote_block = element.Element{ .quote = .{ .children = &quote_children } };

    // ── Code block (preformatted monospace) ────────────────────────
    const code_block_inst = element.Element{ .code_block = .{ .content = .{ .raw = .{
        .text =
        \\fn render(elem: Element) !void {
        \\    // code blocks: monospace, preformatted
        \\}
        ,
        .style = theme.code_block,
    } } } };

    // ── Top stack assembling everything ────────────────────────────
    const sp8 = element.Element{ .spacer = .{ .height = 8 } };
    const sp12 = element.Element{ .spacer = .{ .height = 12 } };

    const top_stack_children = [_]element.Element{
        heading_block,
        subtitle_block,
        sp12,
        mixed_block,
        sp8,
        styled_block,
        sp12,
        unordered_list,
        sp12,
        quote_block,
        sp12,
        code_block_inst,
        sp8,
    };
    const top_stack = element.Element{ .container = .{
        .layout = .stack_v,
        .children = &top_stack_children,
        .gap = 0,
    } };

    // SDF "ATTENTION" paragraph — separate from the top stack so we
    // can capture the glyph index range for per-frame animation.
    // Default per-span `attention = 0.5`; the frame loop overwrites
    // each glyph's `.attention` individually for the wave.
    const sdf_children = [_]element.Element{
        .{ .text = .{ .content = "ATTENTION", .style = .{
            .font_id = sdf_id,
            .color = white,
            .attention = 0.5,
        } } },
    };
    const sdf_block = element.Element{ .paragraph = &sdf_children };

    // ── Lay out + render ───────────────────────────────────────────
    var dl = element.DrawList.init(allocator);
    defer dl.deinit();

    var lc = element.LayoutCtx{
        .allocator = allocator,
        .fonts = &fonts,
        .cache = &cache,
        .mono_atlas = &atlas_mono,
        .color_atlas = &atlas_color,
        .theme = &theme,
    };

    // Viewport-anchored content width — 40px left + 40px right gutter
    // on a 1280px window gives ~1200px for the document. Wrap
    // decisions inside the tree honour this, with quotes / lists
    // further shrinking it as their indents accumulate.
    const content_max_w: f32 = 1280.0 - 80.0;
    const top_constraints: element.Constraints = .{ .max_w = content_max_w };

    const top_box = try element_layout.layoutAndRender(
        top_stack,
        .{ 40, 40 },
        top_constraints,
        &lc,
        &dl,
    );
    const sdf_y = top_box.y + top_box.h;

    const pulse_start: u32 = @intCast(dl.glyphs.items.len);
    _ = try element_layout.layoutAndRender(
        sdf_block,
        .{ 40, sdf_y },
        top_constraints,
        &lc,
        &dl,
    );
    const pulse_count: u32 = @intCast(dl.glyphs.items.len - pulse_start);

    try pipeline.writeGlyphs(dl.glyphs.items);
    try stdout.print("  glyphs:                {d} (pulse span: {d} glyphs)\n", .{
        dl.glyphs.items.len,
        pulse_count,
    });
    try stdout.print("  cache:                 {d} miss / {d} hit ({d:.1}% hit rate)\n", .{
        cache.misses,
        cache.hits,
        cache.hitRate() * 100.0,
    });

    var rdr = try renderer.Renderer.init(allocator, &ctx, &swapchain, &window);
    defer rdr.deinit();

    var frame_ctx = FrameCtx{
        .pipeline = &pipeline,
        .n_glyphs = @intCast(dl.glyphs.items.len),
        .glyphs = dl.glyphs.items,
        .pulse_start = pulse_start,
        .pulse_count = pulse_count,
        .start_ms = std.time.milliTimestamp(),
    };
    rdr.draw_fn = drawCb;
    rdr.draw_ctx = @ptrCast(&frame_ctx);

    const exit_after_ms: ?i64 = if (std.process.getEnvVarOwned(allocator, "TEXT_ENGINE_EXIT_AFTER")) |s| blk: {
        defer allocator.free(s);
        const secs = std.fmt.parseFloat(f64, s) catch break :blk null;
        break :blk @intFromFloat(secs * 1000.0);
    } else |_| null;

    var frame_count: u64 = 0;
    while (!window.shouldClose()) {
        window.pollEvents();

        // ── Per-frame attention wave ────────────────────────────────
        const elapsed: f32 = @floatFromInt(std.time.milliTimestamp() - frame_ctx.start_ms);
        const t_sec: f32 = elapsed * 0.001;
        var i: u32 = 0;
        while (i < pulse_count) : (i += 1) {
            const idx = pulse_start + i;
            const phase = t_sec * 3.0 - @as(f32, @floatFromInt(i)) * 0.6;
            const w = (std.math.sin(phase) + 1.0) * 0.5;
            frame_ctx.glyphs[idx].attention = w;

            const hue = @mod(@as(f32, @floatFromInt(i)) * 40.0 + t_sec * 30.0, 360.0);
            const rgb = hsvToRgb(hue, 0.85, 1.0);
            frame_ctx.glyphs[idx].hot_color = .{ rgb[0], rgb[1], rgb[2], 1.0 };
        }
        try pipeline.writeGlyphs(frame_ctx.glyphs);

        try rdr.drawFrame();
        frame_count += 1;
        if (exit_after_ms) |limit| {
            if (std.time.milliTimestamp() - frame_ctx.start_ms >= limit) break;
        }
    }

    const elapsed_ms = std.time.milliTimestamp() - frame_ctx.start_ms;
    try stdout.print("  frames:                {d} in {d}ms ({d:.1} fps)\n", .{
        frame_count,
        elapsed_ms,
        if (elapsed_ms > 0) @as(f64, @floatFromInt(frame_count)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms)) else 0,
    });
}
