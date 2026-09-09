//! Buffers that size themselves to the frame — gated on a real device,
//! against real pixels.
//!
//! **The bug.** Every per-frame GPU buffer used to be sized once at
//! `Spark.init` from a number a host picked. One primitive past it and
//! `writeGlyphs` refused the batch, `endFrame` returned
//! `error.SsboOverflow`, and the whole page went black — spark's own
//! demo hit it (`14aedd9`) and the fix was to raise the number by hand.
//! `gpu/growable.zig` replaces the number with a measurement.
//!
//! **Why pixels and not "did endFrame return".** The obvious gate — call
//! `endFrame` on an oversized document and assert no error — passes
//! perfectly on a frame that drew NOTHING, which is the exact failure
//! being fixed. So the load-bearing gate renders the same document
//! twice, once at a starting size it fits inside and once at a starting
//! size that forces a grow, and demands the two readbacks be
//! byte-identical. That catches black, catches truncation, and needs no
//! golden image: the frame that did not have to grow IS the golden.
//!
//! **Why some claims are only visible through the validation layer.**
//! "The buffer we freed was not one a submitted command buffer still
//! refers to" and "the old allocation did not leak" have no return
//! code to read. The only witness is `VK_LAYER_KHRONOS_validation`, so
//! two gates below assert on `vk.validation_errors` instead. They are
//! honest about it in their comments, and they are no-ops (they still
//! pass, watching nothing) on a machine with the layer not installed —
//! which is stated here rather than hidden, because a gate that cannot
//! fail is decoration.

const std = @import("std");
const testing = std.testing;
const spark = @import("../lib.zig");
const vk = spark.vk;
const fixture = @import("fixture.zig");

const c = vk.c;

/// Big enough that a paragraph of body text actually lands inside it —
/// an 8×8 target like `display_transform.zig`'s would compare two
/// frames of nothing and call them equal. `R8G8B8A8_UNORM` for the same
/// reason that file gives: an `_SRGB` target would apply its own EOTF
/// on write and the readback would measure two transforms stacked.
const TARGET_W: u32 = 320;
const TARGET_H: u32 = 200;
const TARGET_FORMAT = c.VK_FORMAT_R8G8B8A8_UNORM;

/// A document with enough text to blow past a deliberately tiny
/// starting cap, and enough SHAPE (boxes, a rule) that quads and
/// triangles are exercised too — a gate that grew only the glyph buffer
/// would miss three of the four.
const wordy_doc =
    \\# A document that outgrew its budget
    \\
    \\Some body text to exercise glyph emission, and then rather more of
    \\it, because the whole point is to cross a line that used to turn
    \\the page black.
    \\
    \\:::box {color=teal width=160 height=40 radius=8}
    \\:::
    \\
    \\The second paragraph exists so the glyph count is comfortably past
    \\a starting capacity chosen to be too small, and so that a run that
    \\truncated instead of growing would visibly lose a line.
    \\
    \\- a list item
    \\- another list item
    \\- a third, for the markers
    \\
    \\:::box {color=orange width=120 height=30 radius=4}
    \\:::
    \\
    \\A closing paragraph, mostly for length.
    \\
;

/// Starting sizes for one run. The gates drive these directly rather
/// than through a huge document: the property under test is "a frame
/// bigger than the starting size renders correctly", and crossing that
/// line at 64 glyphs proves exactly what crossing it at 16384 would,
/// in milliseconds instead of seconds.
const Start = struct {
    glyphs: u32,
    quads: u32,
    tri_vertices: u32 = 65536,
    tri_indices: u32 = 196608,
};

/// Roomy enough that `wordy_doc` never grows anything — the control.
const roomy: Start = .{ .glyphs = 16384, .quads = 2048 };
/// Small enough that `wordy_doc` grows the glyph AND the quad buffer.
const cramped: Start = .{ .glyphs = 8, .quads = 1 };

const Rendered = struct {
    /// `TARGET_W * TARGET_H * 4` bytes, caller-owned.
    pixels: []u8,
    drawlist_glyphs: usize,
    drawlist_quads: usize,
    glyph_capacity: u32,
    glyph_growths: u32,
    quad_growths: u32,

    fn deinit(self: Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// How many of the readback's pixels are not the clear colour.
    /// A black frame answers zero, which is the number the old failure
    /// produced and the number this whole beat exists to avoid.
    fn painted(self: Rendered) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            if (self.pixels[i] != 0 or self.pixels[i + 1] != 0 or
                self.pixels[i + 2] != 0 or self.pixels[i + 3] != 0) n += 1;
        }
        return n;
    }
};

/// Stand up a whole Spark on the fixture's device, render `source` for
/// `frames` frames into an offscreen `R8G8B8A8_UNORM` target, and hand
/// back the last frame's pixels plus what the buffers did.
///
/// This drives the REAL frame cycle — `attachCmd`, `beginFrame`,
/// `layoutAndRender`, `dispatchOffscreenPasses`, the host's
/// `vkCmdBeginRendering`, `endFrame` — because the growth's whole
/// safety argument is about where in that cycle it happens, and a
/// harness that skipped a phase would be gating a different program.
fn render(
    allocator: std.mem.Allocator,
    fx: *fixture.Fixture,
    source: []const u8,
    start: Start,
    frames: u32,
) !Rendered {
    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var host_state = spark.State.init(allocator);
    defer host_state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = TARGET_FORMAT,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &host_state,
        .initial_glyphs = start.glyphs,
        .initial_quads = start.quads,
        .initial_tri_vertices = start.tri_vertices,
        .initial_tri_indices = start.tri_indices,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var doc = try sp.loadDocument(source, .{ .shared_state = &host_state });
    defer doc.deinit();

    var rb = try Readback.init(&fx.ctx);
    defer rb.deinit();

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        try rb.frame(&sp, &doc);
    }

    return .{
        .pixels = try rb.copyPixels(allocator),
        .drawlist_glyphs = sp.drawlist.glyphs.items.len,
        .drawlist_quads = sp.drawlist.quads.items.len,
        .glyph_capacity = sp.text_pipeline.glyphs.capacity,
        .glyph_growths = sp.text_pipeline.glyphs.growths,
        .quad_growths = sp.quad_pipeline.quads.growths,
    };
}

// ── The gates ──────────────────────────────────────────────────────

test "a document past its starting cap renders the same pixels as one that fits" {
    // **Mutations this is paid for — all three executed, all three
    // red:**
    //
    //   1. Delete `try self.reserveForDrawlist()` from `endFrame` and
    //      from `dispatchOffscreenPasses`. The cramped run then fails
    //      with `error.SsboOverflow` — the old black page, caught at
    //      the `try render(...)`.
    //   2. The same, plus `Growable.write` truncating instead of
    //      refusing (`n = @min(items.len, self.capacity)`). That
    //      compiles, returns NO error, and draws something — and the
    //      pixel comparison goes red at byte 16048 where an "endFrame
    //      returned no error" assertion would have gone green. This is
    //      why the gate compares images: silent truncation is exactly
    //      the failure a weaker gate would bless.
    //   3. `TextPipeline.reserve` ignoring the `grew` flag
    //      (`_ = try self.glyphs.reserve(n);`), so the buffer grows but
    //      the descriptor still points at the old one. The validation
    //      layer says "the storage buffer descriptor ... is using
    //      buffer ... that is invalid or has been destroyed", and the
    //      pixels differ. That is the bug this whole mechanism could
    //      most plausibly have shipped with.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fits = try render(allocator, &fx, wordy_doc, roomy, 1);
    defer fits.deinit(allocator);
    const grew = try render(allocator, &fx, wordy_doc, cramped, 1);
    defer grew.deinit(allocator);

    // First: the cramped run really did cross its starting size. A
    // gate whose "oversized" document happened to fit would pass every
    // line below while watching nothing.
    try testing.expect(grew.drawlist_glyphs > cramped.glyphs);
    try testing.expect(grew.drawlist_quads > cramped.quads);

    // Not black. The old failure's readback is all clear-colour, and
    // this number is what tells the two apart.
    try testing.expect(fits.painted() > 500);

    // Not truncated, not shifted, not dimmed: the frame that had to
    // grow is the frame that did not, pixel for pixel. This line comes
    // BEFORE the growth counters on purpose — a counter assertion that
    // fired first would mask it, and this is the assertion that carries
    // the weight (mutation 2 above is invisible to every other line).
    try testing.expectEqualSlices(u8, fits.pixels, grew.pixels);

    // And it got there by growing, not by having been big enough.
    try testing.expect(grew.glyph_growths > 0);
    try testing.expectEqual(@as(u32, 0), fits.glyph_growths);
}

test "growth happens once — the frame after a grow does not grow again" {
    // Mutation: drop the `if (needed <= self.capacity) return false;`
    // early-out in `Growable.reserve` (the rest of the body already
    // handles `needed <= capacity` by allocating a bigger buffer
    // anyway, so it compiles and runs). Ten frames then report ten
    // growths and this goes red — which is the hysteresis claim, and
    // the difference between one device stall per document and one per
    // frame forever.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const ten = try render(allocator, &fx, wordy_doc, cramped, 10);
    defer ten.deinit(allocator);

    // One grow for the glyphs, one for the quads, and then never
    // again — nine further frames of the same document cost nothing.
    try testing.expectEqual(@as(u32, 1), ten.glyph_growths);
    try testing.expectEqual(@as(u32, 1), ten.quad_growths);
    // And it landed with headroom, not on the nose — a capacity equal
    // to the count is a capacity that reallocates on the next glyph.
    try testing.expect(ten.glyph_capacity >= ten.drawlist_glyphs + ten.drawlist_glyphs / 2);
}

test "past the ceiling the refusal is named, and it is not SsboOverflow" {
    // Mutation: delete the `if (needed > ceiling)` arm in
    // `Growable.reserve`. It compiles, and the reserve then tries to
    // allocate ~256 MiB of host-visible memory for a frame that has no
    // business existing — the expectError goes red either way (it
    // succeeds, or it fails as a Vulkan error rather than by name),
    // which is the point: past the ceiling the refusal must land on
    // the node that refused.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var host_state = spark.State.init(allocator);
    defer host_state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = TARGET_FORMAT,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &host_state,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }

    const glyph_ceiling = spark.TextPipeline.Glyphs.ceiling;
    const quad_ceiling = spark.QuadPipeline.Quads.ceiling;
    // The ask has to be over the line and not absurd — an ask this
    // side of the ceiling must still be *grantable*, or the gate would
    // pass for the wrong reason.
    try testing.expectError(error.TooManyGlyphs, sp.text_pipeline.reserve(glyph_ceiling + 1));
    try testing.expectError(error.TooManyQuads, sp.quad_pipeline.reserve(quad_ceiling + 1));
    try testing.expectError(
        error.TooManyTriIndices,
        sp.tri_pipeline.reserve(0, spark.TrianglePipeline.Indices.ceiling + 1),
    );

    // A refusal must leave the buffer it refused for exactly as it
    // was — the old capacity, no allocation, no growth counted. A
    // refusal that half-grew would be worse than the black page.
    try testing.expectEqual(@as(u32, 16384), sp.text_pipeline.glyphs.capacity);
    try testing.expectEqual(@as(u32, 0), sp.text_pipeline.glyphs.growths);

    // And the ceiling is a real number, not an accident of `u32`
    // arithmetic: 64 MiB of 80-byte glyphs.
    try testing.expectEqual(@as(u32, 64 * 1024 * 1024 / 80), glyph_ceiling);
}

test "a drawlist that grew after Phase 1 is refused by name, not grown under a recorded bind" {
    // The one place growth CANNOT happen. `dispatchOffscreenPasses`
    // may already have bound buffer handles and descriptor sets into
    // this frame's command buffer; replacing those buffers afterwards
    // leaves the recorded binds pointing at freed memory, and the host
    // submits that command buffer regardless — spark's own demo prints
    // an `endFrame` error and lets `drawFrame` submit anyway. So the
    // answer is a refusal, not a grow.
    //
    // Mutation: delete the `if (self.offscreen_recorded and
    // self.needsRoom())` line from `endFrame`. It compiles, the grow
    // then happens, and this goes red — `endFrame` returns nothing
    // instead of the named error. (Under a validation build the
    // mutation also produces a dangling-buffer complaint, which is the
    // bug the refusal exists to prevent.)
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var host_state = spark.State.init(allocator);
    defer host_state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = TARGET_FORMAT,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &host_state,
        // Room for the first document and not the second.
        .initial_glyphs = 64,
        .initial_quads = 64,
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    // A `:::gradient` is what puts an entry in `pass_dispatches` — the
    // flag keys on Phase 1 having something to record, and a document
    // with no effects at all can still grow inside `endFrame` safely.
    var effected = try sp.loadDocument(
        \\:::gradient {from=#1a1a2e to=#16213e direction=vertical width=100 height=40}
        \\:::
        \\
    , .{ .shared_state = &host_state });
    defer effected.deinit();
    var big = try sp.loadDocument(wordy_doc, .{ .shared_state = &host_state });
    defer big.deinit();

    var rb = try Readback.init(&fx.ctx);
    defer rb.deinit();

    const dev = fx.ctx.device;
    var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = rb.pool;
    ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    var cmd: c.VkCommandBuffer = null;
    try vk.check(c.vkAllocateCommandBuffers(dev, &ai, &cmd));
    defer c.vkFreeCommandBuffers(dev, rb.pool, 1, &cmd);
    var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

    sp.attachCmd(cmd, 0, 0);
    try sp.beginFrame(.{ .extent = .{ .width = TARGET_W, .height = TARGET_H } }, .{});
    _ = try sp.layoutAndRender(&effected, .{ 8, 8 }, .{ .max_w = TARGET_W - 16 });
    try sp.dispatchOffscreenPasses(cmd);
    try testing.expect(sp.offscreen_recorded);

    // Out of contract: the host appends a whole document AFTER Phase 1.
    _ = try sp.layoutAndRender(&big, .{ 8, 60 }, .{ .max_w = TARGET_W - 16 });
    try testing.expect(sp.drawlist.glyphs.items.len > sp.text_pipeline.glyphs.capacity);

    try testing.expectError(error.DrawlistGrewAfterDispatch, sp.endFrame());
    // Refused, and nothing was replaced under the recorded binds.
    try testing.expectEqual(@as(u32, 0), sp.text_pipeline.glyphs.growths);

    // Never submitted — this command buffer is abandoned on purpose.
    try vk.check(c.vkEndCommandBuffer(cmd));
}

test "a grow does not free a buffer a submitted frame still refers to" {
    // **Only the validation layer can witness this**, so say so: there
    // is no return code for "you freed memory the GPU may still read",
    // and a timing gate would be a race that passes by luck. The layer
    // holds a command buffer in the in-flight state from
    // `vkQueueSubmit` until the application synchronises, so this gate
    // submits a frame, never waits on its fence, and THEN forces a
    // grow. Deterministic, not racy: what is being consulted is the
    // layer's bookkeeping, not the GPU's actual progress.
    //
    // Mutation: delete the `vkDeviceWaitIdle` from `Growable.reserve`.
    // The layer then fires VUID-vkFreeMemory-memory-00677 ("Cannot
    // free VkDeviceMemory that is in use by a command buffer") and the
    // counter moves — red.
    //
    // **The first version of this gate SURVIVED that mutation**, and
    // the reason is written into the shape below. It grew by rendering
    // a second frame, and a second frame rasterizes new glyphs, and the
    // glyph atlas uploads them with a `vkWaitForFences` of its own — a
    // wait on a later submission retires everything earlier on the same
    // queue, so frame one was no longer in flight by the time the grow
    // happened and there was nothing left to catch. Nothing may sit
    // between the un-waited submit and the grow.
    //
    // Honest limit: with `VK_LAYER_KHRONOS_validation` absent this gate
    // passes while watching nothing. `vk.zig` prints a note at instance
    // creation when that is the case.
    const allocator = testing.allocator;
    var fx = try fixture.Fixture.init(allocator);
    defer fx.deinit();

    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var host_state = spark.State.init(allocator);
    defer host_state.deinit();

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = TARGET_FORMAT,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &host_state,
        // Roomy on purpose: frame one must NOT grow anything, or the
        // buffer left in flight would already be the replacement and
        // the gate would be staging nothing.
    });
    defer {
        sp.deinit();
        allocator.destroy(fonts.registry);
    }
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    var small = try sp.loadDocument("Short.\n", .{ .shared_state = &host_state });
    defer small.deinit();

    var rb = try Readback.init(&fx.ctx);
    defer rb.deinit();

    // Frame one. Its recorded draws read the glyph SSBO. Submitted with
    // a fence, and deliberately never waited on.
    try rb.frameNoWait(&sp, &small);
    try testing.expectEqual(@as(u32, 0), sp.text_pipeline.glyphs.growths);

    const before = vk.validation_errors.load(.monotonic);

    // Grow, with NOTHING in between — see the note above about the
    // atlas. The claim under test belongs to `Growable.reserve`, so
    // ask it directly rather than through a second frame that would
    // synchronise behind our back.
    try sp.text_pipeline.reserve(@as(usize, sp.text_pipeline.glyphs.capacity) * 4);
    try testing.expectEqual(@as(u32, 1), sp.text_pipeline.glyphs.growths);
    try testing.expectEqual(before, vk.validation_errors.load(.monotonic));

    _ = c.vkDeviceWaitIdle(fx.ctx.device);
}

test "a grow leaves nothing behind — no CPU leak, no orphaned GPU allocation" {
    // Two leaks, two witnesses.
    //
    // CPU: `testing.allocator` fails the test on any unfreed byte, and
    // this gate builds and tears down a whole Spark. Mutation: leak the
    // `Rendered.pixels` copy — red immediately.
    //
    // GPU: a `VkBuffer` or `VkDeviceMemory` that outlives its owner has
    // no allocator to notice it. The validation layer does: it reports
    // every live object at `vkDestroyDevice`. So this gate does its own
    // teardown INSIDE the test body, before reading the counter, rather
    // than deferring it past the assertions. Mutation: delete the
    // `destroy(self.device, old_buffer, old_memory)` line in
    // `Growable.reserve` — three grows then orphan three buffers and
    // three allocations, the layer says so at device destroy, and the
    // counter moves.
    const allocator = testing.allocator;
    const before = vk.validation_errors.load(.monotonic);

    var fx = try fixture.Fixture.init(allocator);
    const fonts = try fixture.makeFonts(allocator, fx.ft);
    const theme = fixture.makeTheme(fonts);
    var host_state = spark.State.init(allocator);

    var sp = try spark.Spark.init(allocator, .{
        .vk_ctx = &fx.ctx,
        .color_format = TARGET_FORMAT,
        .theme = &theme,
        .fonts = fonts.registry,
        .host_state = &host_state,
        // One glyph of headroom at a time, so a document of this size
        // walks the buffer up through several distinct allocations
        // instead of one. Three-plus grows means three-plus chances to
        // orphan something.
        .initial_glyphs = 2,
        .initial_quads = 1,
    });
    sp.attachToRegistry();
    try spark.installCoreComponents(&sp);

    {
        var doc = try sp.loadDocument("Short.\n", .{ .shared_state = &host_state });
        var rb = try Readback.init(&fx.ctx);
        try rb.frame(&sp, &doc);
        rb.deinit();
        doc.deinit();
    }
    {
        var doc = try sp.loadDocument(wordy_doc, .{ .shared_state = &host_state });
        var rb = try Readback.init(&fx.ctx);
        try rb.frame(&sp, &doc);
        rb.deinit();
        doc.deinit();
    }
    try testing.expect(sp.text_pipeline.glyphs.growths >= 2);

    // Explicit teardown, in the body: the counter has to be read AFTER
    // `vkDestroyDevice`, which is where the layer reports leaked
    // objects, and a `defer` would run after the assertion.
    sp.deinit();
    allocator.destroy(fonts.registry);
    host_state.deinit();
    fx.deinit();

    try testing.expectEqual(before, vk.validation_errors.load(.monotonic));
}

// ── Harness ────────────────────────────────────────────────────────

/// One offscreen colour attachment plus the host-visible buffer its
/// pixels are copied into, and the command-buffer dance around a real
/// Spark frame. Local to this file for the same reason
/// `display_transform.zig` keeps its own: spark has no readback path,
/// because nothing but a gate has ever wanted one.
const Readback = struct {
    ctx: *const vk.Context,
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    buffer: c.VkBuffer = null,
    buffer_memory: c.VkDeviceMemory = null,
    pool: c.VkCommandPool = null,
    /// Fences for submits this harness deliberately never waits on.
    /// They exist so the submit is legal and so teardown can be made
    /// safe with one `vkDeviceWaitIdle`.
    fences: std.BoundedArray(c.VkFence, 8) = .{},

    const bytes: u64 = @as(u64, TARGET_W) * TARGET_H * 4;

    fn init(ctx: *const vk.Context) !Readback {
        var self = Readback{ .ctx = ctx };
        errdefer self.deinit();
        const dev = ctx.device;

        var ici = std.mem.zeroes(c.VkImageCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = c.VK_IMAGE_TYPE_2D;
        ici.format = TARGET_FORMAT;
        ici.extent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        ici.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        ici.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try vk.check(c.vkCreateImage(dev, &ici, null, &self.image));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(dev, self.image, &req);
        var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
        mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(ctx, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.memory));
        try vk.check(c.vkBindImageMemory(dev, self.image, self.memory, 0));

        var vci = std.mem.zeroes(c.VkImageViewCreateInfo);
        vci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vci.image = self.image;
        vci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        vci.format = TARGET_FORMAT;
        vci.subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        try vk.check(c.vkCreateImageView(dev, &vci, null, &self.view));

        var bci = std.mem.zeroes(c.VkBufferCreateInfo);
        bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = bytes;
        bci.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try vk.check(c.vkCreateBuffer(dev, &bci, null, &self.buffer));

        c.vkGetBufferMemoryRequirements(dev, self.buffer, &req);
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = try findMemoryType(
            ctx,
            req.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        try vk.check(c.vkAllocateMemory(dev, &mai, null, &self.buffer_memory));
        try vk.check(c.vkBindBufferMemory(dev, self.buffer, self.buffer_memory, 0));

        var cpci = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        cpci.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        cpci.queueFamilyIndex = ctx.queue_family;
        try vk.check(c.vkCreateCommandPool(dev, &cpci, null, &self.pool));

        return self;
    }

    fn deinit(self: *Readback) void {
        const dev = self.ctx.device;
        // Anything this harness submitted without waiting is drained
        // here — including the frame `frameNoWait` deliberately left
        // outstanding. Destroying a pool with a command buffer still
        // executing is a different bug, and not the one under test.
        _ = c.vkDeviceWaitIdle(dev);
        for (self.fences.slice()) |f| if (f != null) c.vkDestroyFence(dev, f, null);
        if (self.pool != null) c.vkDestroyCommandPool(dev, self.pool, null);
        if (self.buffer != null) c.vkDestroyBuffer(dev, self.buffer, null);
        if (self.buffer_memory != null) c.vkFreeMemory(dev, self.buffer_memory, null);
        if (self.view != null) c.vkDestroyImageView(dev, self.view, null);
        if (self.image != null) c.vkDestroyImage(dev, self.image, null);
        if (self.memory != null) c.vkFreeMemory(dev, self.memory, null);
        self.* = undefined;
    }

    /// The whole frame cycle, submitted and waited on.
    fn frame(self: *Readback, sp: *spark.Spark, doc: *const spark.Document) !void {
        const cmd = try self.recordFrame(sp, doc, TARGET_H);
        defer c.vkFreeCommandBuffers(self.ctx.device, self.pool, 1, @constCast(&cmd));
        var si = std.mem.zeroes(c.VkSubmitInfo);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        try vk.check(c.vkQueueSubmit(self.ctx.queue, 1, &si, null));
        try vk.check(c.vkQueueWaitIdle(self.ctx.queue));
    }

    /// The same, submitted with a fence NOBODY waits on — so the
    /// validation layer keeps the command buffer, and every resource it
    /// reads, in the in-flight state.
    fn frameNoWait(self: *Readback, sp: *spark.Spark, doc: *const spark.Document) !void {
        const cmd = try self.recordFrame(sp, doc, std.math.inf(f32));
        var fence: c.VkFence = null;
        var fci = std.mem.zeroes(c.VkFenceCreateInfo);
        fci.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        try vk.check(c.vkCreateFence(self.ctx.device, &fci, null, &fence));
        try self.fences.append(fence);
        var si = std.mem.zeroes(c.VkSubmitInfo);
        si.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        try vk.check(c.vkQueueSubmit(self.ctx.queue, 1, &si, fence));
        // No wait. The command buffer is intentionally never freed
        // either — the pool goes at `deinit`, after a device idle.
    }

    fn recordFrame(
        self: *Readback,
        sp: *spark.Spark,
        doc: *const spark.Document,
        max_h: f32,
    ) !c.VkCommandBuffer {
        const dev = self.ctx.device;
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = self.pool;
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try vk.check(c.vkAllocateCommandBuffers(dev, &ai, &cmd));

        var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try vk.check(c.vkBeginCommandBuffer(cmd, &bi));

        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        );

        // The host half of the cycle, in the order `src/main.zig` does
        // it: attach, begin, lay out, Phase 1, then the main pass.
        sp.attachCmd(cmd, 0, 0);
        try sp.beginFrame(.{ .extent = .{ .width = TARGET_W, .height = TARGET_H } }, .{});
        _ = try sp.layoutAndRender(doc, .{ 8, 8 }, .{ .max_w = TARGET_W - 16, .max_h = max_h });
        try sp.dispatchOffscreenPasses(cmd);

        var att = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        att.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        att.imageView = self.view;
        att.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        att.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        att.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        // Transparent black, so `Rendered.painted` counts exactly the
        // pixels spark wrote — and a black page counts zero.
        att.clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };

        var ri = std.mem.zeroes(c.VkRenderingInfo);
        ri.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        ri.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = TARGET_W, .height = TARGET_H } };
        ri.layerCount = 1;
        ri.colorAttachmentCount = 1;
        ri.pColorAttachments = &att;
        c.vkCmdBeginRendering(cmd, &ri);
        try sp.endFrame();
        c.vkCmdEndRendering(cmd);

        barrier(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            c.VK_ACCESS_TRANSFER_READ_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        region.imageExtent = .{ .width = TARGET_W, .height = TARGET_H, .depth = 1 };
        c.vkCmdCopyImageToBuffer(
            cmd,
            self.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.buffer,
            1,
            &region,
        );
        try vk.check(c.vkEndCommandBuffer(cmd));
        return cmd;
    }

    fn copyPixels(self: *Readback, allocator: std.mem.Allocator) ![]u8 {
        const dev = self.ctx.device;
        var raw: ?*anyopaque = null;
        try vk.check(c.vkMapMemory(dev, self.buffer_memory, 0, bytes, 0, &raw));
        defer c.vkUnmapMemory(dev, self.buffer_memory);
        const px: [*]const u8 = @ptrCast(raw.?);
        const out = try allocator.alloc(u8, bytes);
        @memcpy(out, px[0..bytes]);
        return out;
    }
};

fn barrier(
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    old: c.VkImageLayout,
    new: c.VkImageLayout,
    src_access: c.VkAccessFlags,
    dst_access: c.VkAccessFlags,
    src_stage: c.VkPipelineStageFlags,
    dst_stage: c.VkPipelineStageFlags,
) void {
    var b = std.mem.zeroes(c.VkImageMemoryBarrier);
    b.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    b.oldLayout = old;
    b.newLayout = new;
    b.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    b.subresourceRange = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
}

fn findMemoryType(ctx: *const vk.Context, type_bits: u32, required: c.VkMemoryPropertyFlags) !u32 {
    var props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &props);
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if ((type_bits & bit) == 0) continue;
        if ((props.memoryTypes[i].propertyFlags & required) == required) return i;
    }
    return error.NoSuitableMemoryType;
}
