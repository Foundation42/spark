//! A host-visible GPU buffer that sizes itself to the frame.
//!
//! **The bug this file is paid for.** Every per-frame buffer in spark
//! used to be sized once, at `Spark.init`, from a number a host picked
//! out of the air. One primitive over that number and `writeGlyphs` /
//! `writeQuads` / `writeMesh` refused the whole batch, `endFrame`
//! returned `error.SsboOverflow`, and the page went BLACK — not
//! clipped, not truncated, black, with one line on stderr. spark's own
//! demo hit it (`14aedd9`, "the document outgrew its glyph budget, and
//! the failure is total") and the fix was to hand-raise the number,
//! which is the ritual this module exists to abolish.
//!
//! **The shape.** The CPU drawlist is unbounded and complete before any
//! of it is recorded, so the size a frame needs is KNOWN, not
//! discovered by failing. `reserve(needed)` is called at that boundary;
//! if the buffer is too small it allocates a bigger one, and the frame
//! that outgrew its budget renders correctly instead of not at all.
//!
//! **Why one type and not three near-identical grow paths.** A grown
//! buffer must have exactly the memory properties the original had —
//! host-visible, host-coherent, permanently mapped. The surest way to
//! guarantee that is for `init` and the grow to call the same code,
//! which is what this is. The three pipelines differ only in element
//! type and usage flags, and both are parameters.

const std = @import("std");
const vk = @import("vk.zig");

const c = vk.c;

/// What a refusal past the ceiling is called. One member per buffer so
/// the `@errorName` a host prints says WHICH buffer ran away — an error
/// lands on the node that refused, and "SsboOverflow" named nothing.
pub const Overflow = error{
    TooManyGlyphs,
    TooManyQuads,
    TooManyTriVertices,
    TooManyTriIndices,
};

/// The hard stop, per buffer. Past this a frame is refused by name
/// rather than grown.
///
/// **Why 64 MiB and why per buffer.** The largest document spark has
/// ever laid out is its own `demo.md` — 27 KB of markdown, a little
/// over 30k glyphs, 2.4 MB of glyph instances. 64 MiB is 838,860
/// glyphs: twenty-eight times the number the demo host used to
/// hand-raise to, and roughly fifty times what the biggest real
/// document needs. Nothing that is a document reaches it. A component
/// that emits primitives in a loop reaches it in one frame, which is
/// exactly who this is for.
///
/// The four buffers bound each other's worst case: 256 MiB of
/// host-visible memory is the most a runaway can take before it is
/// stopped by name. On a discrete GPU that is a slice of the BAR heap;
/// on an integrated one it is system RAM. Either way it is bounded,
/// which is the property the old code did not have in the other
/// direction (it was bounded at a number too small to render).
///
/// **Deliberately not a host knob.** Making the ceiling settable would
/// recreate the ritual: a host would hit it once and raise it, and we
/// would be back to a number nobody can justify. It is a safety rail,
/// it has one value, and it lives here.
pub const CEILING_BYTES: u64 = 64 * 1024 * 1024;

/// Capacity to allocate for a frame that needed `needed` elements:
/// half again as much, rounded up to a power of two, never past the
/// ceiling.
///
/// **The hysteresis is the point.** A document that creeps upward — a
/// log pane gaining a line a frame, a stream appending a token — would
/// reallocate on EVERY frame if we grew to exactly what was asked for,
/// and each reallocation costs a device idle. Half again plus the
/// power-of-two round means the headroom after a grow is never less
/// than 50%, so a document growing one primitive at a time reallocates
/// a logarithmic number of times over its whole life, not a linear one.
///
/// There is no shrink, on purpose. A document that pulses between two
/// sizes — a fold opening and closing, a tooltip — would thrash a
/// shrink policy into a realloc per pulse, and the memory it would give
/// back is bounded by the ceiling anyway. If a shrink is ever wanted it
/// should be an explicit host call at a quiet moment (a document
/// closing, a panel unmounting), never an automatic reaction to one
/// small frame.
fn nextCapacity(needed: usize, ceiling: u32) u32 {
    const want = needed + needed / 2;
    if (want >= ceiling) return ceiling;
    // `want < ceiling <= maxInt(u32)`, so the cast and the round are
    // both in range. `ceilPowerOfTwo` of 0 is 1; a zero-needed frame
    // never gets here because it never exceeds a capacity.
    const rounded = std.math.ceilPowerOfTwo(u64, @max(1, want)) catch unreachable;
    return @intCast(@min(rounded, ceiling));
}

/// A permanently-mapped, host-visible, host-coherent buffer of `T` that
/// grows to fit. `what` names it in the log line and in test failures;
/// `refusal` is the error it returns past the ceiling.
pub fn Growable(
    comptime T: type,
    comptime what: []const u8,
    comptime refusal: Overflow,
) type {
    return struct {
        const Self = @This();

        /// How many `T` fit under `CEILING_BYTES`. Comptime, so the
        /// number in a refusal is a constant a reader can look up.
        pub const ceiling: u32 = @intCast(CEILING_BYTES / @sizeOf(T));

        buffer: c.VkBuffer = null,
        memory: c.VkDeviceMemory = null,
        mapped: [*]T = undefined,
        capacity: u32 = 0,

        /// How many times this buffer has been replaced by a bigger
        /// one. Read by the gates: growth must happen ONCE for a
        /// document that settles at a size, and the only honest way to
        /// assert that is to count.
        growths: u32 = 0,

        usage: c.VkBufferUsageFlags = 0,
        device: c.VkDevice = null,
        /// Kept so a grow can re-query memory requirements the same way
        /// `init` did. Borrowed from the host's `vk.Context`, which
        /// outlives every pipeline.
        physical_device: c.VkPhysicalDevice = null,

        pub fn init(
            ctx: *const vk.Context,
            usage: c.VkBufferUsageFlags,
            initial_capacity: u32,
        ) !Self {
            var self: Self = .{
                .usage = usage,
                .device = ctx.device,
                .physical_device = ctx.physical_device,
            };
            errdefer self.deinit();
            try self.allocate(initial_capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.release();
            self.* = undefined;
        }

        /// Make room for `needed` elements. Returns true when it
        /// actually grew — the caller uses that to re-point anything
        /// holding the old handle (a descriptor set, in the two SSBO
        /// pipelines).
        ///
        /// The common call is three integer compares and a `false`.
        pub fn reserve(self: *Self, needed: usize) !bool {
            if (needed <= self.capacity) return false;
            if (needed > ceiling) {
                // **The loud part is the RETURNED ERROR**, which names
                // the buffer — a host printing `@errorName` gets
                // "TooManyGlyphs", not a shrug, and it propagates out
                // of `endFrame` to whoever asked for the frame. This
                // line is the detail the error value cannot carry: how
                // far past, and past what.
                //
                // `warn` and not `err` on purpose: Zig's test runner
                // fails any test that logs at error level, and the gate
                // for this refusal has to provoke it deliberately. A
                // diagnostic that cannot be gated is worse than one a
                // level quieter.
                std.log.warn(
                    "spark: {s} buffer refused {d} entries — the ceiling is {d} ({d} MiB). " ++
                        "Something is emitting primitives in a loop.",
                    .{ what, needed, ceiling, CEILING_BYTES / (1024 * 1024) },
                );
                return refusal;
            }

            const old_capacity = self.capacity;
            const old_buffer = self.buffer;
            const old_memory = self.memory;
            const new_capacity = nextCapacity(needed, ceiling);

            // Allocate the replacement BEFORE letting go of anything.
            // A failed allocation must leave the old buffer intact and
            // the frame renderable at its old size, not leave the
            // pipeline holding a null handle.
            var fresh: Self = .{
                .usage = self.usage,
                .device = self.device,
                .physical_device = self.physical_device,
            };
            errdefer fresh.release();
            try fresh.allocate(new_capacity);

            // **How we know the old buffer is not in flight.**
            // `vkDeviceWaitIdle` returns only when every queue on the
            // device is idle, which means no submitted command buffer
            // is still executing, which means nothing can be reading
            // the memory we are about to free. That is the whole
            // argument, and it is the strongest one available here:
            // spark does not own the host's fences (the host waits on
            // its own `in_flight[frame]` before calling in) and cannot
            // know how many frames the host keeps in flight, so a
            // deferred-destruction ring would be guessing at a number
            // spark is not told. Idling is not a guess.
            //
            // It costs one pipeline bubble, once per grow. Growth is
            // rare by construction (see `nextCapacity`'s hysteresis)
            // and a document that has settled never pays it again.
            try vk.check(c.vkDeviceWaitIdle(self.device));

            self.buffer = fresh.buffer;
            self.memory = fresh.memory;
            self.mapped = fresh.mapped;
            self.capacity = new_capacity;
            self.growths += 1;
            // Handed over, not abandoned: nulling the handles rather
            // than `= undefined` keeps the errdefer above a no-op if a
            // later line ever learns how to fail.
            fresh.buffer = null;
            fresh.memory = null;

            destroy(self.device, old_buffer, old_memory);

            // Once per growth EVENT, which is not once per frame —
            // that distinction is what the hysteresis buys, and saying
            // so here is what stops the next person from moving this
            // line into the frame loop.
            std.log.info(
                "spark: {s} buffer grew {d} → {d} ({d} → {d} KiB) — nothing to raise by hand",
                .{
                    what,
                    old_capacity,
                    new_capacity,
                    @as(u64, old_capacity) * @sizeOf(T) / 1024,
                    @as(u64, new_capacity) * @sizeOf(T) / 1024,
                },
            );
            return true;
        }

        /// Copy `items` into the mapped buffer. Host-coherent memory,
        /// so the write is visible to the next submit with no flush.
        ///
        /// The bounds check is a can't-happen: every path into this
        /// runs `Spark.reserveForDrawlist` first, at a boundary where
        /// the count is already known. It stays because a can't-happen
        /// that is checked is a bug report and a can't-happen that is
        /// not is memory corruption.
        pub fn write(self: *Self, items: []const T) error{SsboOverflow}!void {
            if (items.len > self.capacity) return error.SsboOverflow;
            @memcpy(self.mapped[0..items.len], items);
        }

        fn allocate(self: *Self, count: u32) !void {
            // At least one whole element, never one byte. A host that
            // starts a buffer at zero would otherwise get a descriptor
            // whose range is smaller than the struct the shader reads,
            // which the validation layer is right to complain about.
            const bytes: u64 = @as(u64, @max(1, count)) * @sizeOf(T);
            var bci = std.mem.zeroes(c.VkBufferCreateInfo);
            bci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
            bci.size = bytes;
            bci.usage = self.usage;
            bci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
            try vk.check(c.vkCreateBuffer(self.device, &bci, null, &self.buffer));

            var req: c.VkMemoryRequirements = undefined;
            c.vkGetBufferMemoryRequirements(self.device, self.buffer, &req);
            const mt = try findMemoryType(
                self.physical_device,
                req.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
            var mai = std.mem.zeroes(c.VkMemoryAllocateInfo);
            mai.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            mai.allocationSize = req.size;
            mai.memoryTypeIndex = mt;
            try vk.check(c.vkAllocateMemory(self.device, &mai, null, &self.memory));
            try vk.check(c.vkBindBufferMemory(self.device, self.buffer, self.memory, 0));

            var raw: ?*anyopaque = null;
            try vk.check(c.vkMapMemory(self.device, self.memory, 0, bytes, 0, &raw));
            self.mapped = @ptrCast(@alignCast(raw.?));
            self.capacity = count;
        }

        /// Free what this holds without poisoning the struct — used by
        /// `deinit` and by the errdefer on a half-built replacement.
        fn release(self: *Self) void {
            destroy(self.device, self.buffer, self.memory);
            self.buffer = null;
            self.memory = null;
            self.capacity = 0;
        }
    };
}

/// Unmap, free, destroy — in that order, because the mapping is a
/// property of the memory and Vulkan wants it gone before the
/// allocation is. Tolerates nulls so every caller can be unconditional.
fn destroy(dev: c.VkDevice, buffer: c.VkBuffer, memory: c.VkDeviceMemory) void {
    if (memory != null) {
        c.vkUnmapMemory(dev, memory);
        c.vkFreeMemory(dev, memory, null);
    }
    if (buffer != null) c.vkDestroyBuffer(dev, buffer, null);
}

fn findMemoryType(
    pd: c.VkPhysicalDevice,
    type_bits: u32,
    required: c.VkMemoryPropertyFlags,
) !u32 {
    var props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(pd, &props);
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if ((type_bits & bit) == 0) continue;
        if ((props.memoryTypes[i].propertyFlags & required) == required) return i;
    }
    return error.NoSuitableMemoryType;
}

// ── Gates ──────────────────────────────────────────────────────────

const testing = std.testing;

test "growth leaves headroom, so a document creeping upward stops reallocating" {
    // Mutation that paid for this: `nextCapacity` returning `needed`
    // exactly (drop the `+ needed / 2` and the power-of-two round).
    // Compiles, and every assertion below that asks for MORE than was
    // needed goes red — which is the whole hysteresis claim.
    const big: u32 = 1 << 30;
    try testing.expectEqual(@as(u32, 32768), nextCapacity(16385, big));
    try testing.expectEqual(@as(u32, 131072), nextCapacity(65536, big));
    // Every result is at least half again the ask — the property, not
    // a table of values.
    for ([_]usize{ 1, 7, 100, 2047, 2048, 2049, 40000, 500000 }) |n| {
        try testing.expect(nextCapacity(n, big) >= n + n / 2);
    }
}

test "growth never steps over the ceiling" {
    const ceiling: u32 = 838_860; // what 64 MiB of 80-byte glyphs is

    // The early return: an ask whose half-again already reaches the
    // ceiling gets the ceiling.
    try testing.expectEqual(ceiling, nextCapacity(700_000, ceiling));
    try testing.expectEqual(ceiling, nextCapacity(ceiling, ceiling));

    // **And the ROUNDING has to be clamped separately**, which is a
    // different arm and was decoration until this line existed: at
    // 400_000 the half-again is 600_000, comfortably under the ceiling,
    // but the next power of two above it is 1_048_576 — 80 MiB of
    // glyphs out of a ceiling that says 64. The first version of this
    // gate only tested values that took the early return, and dropping
    // the `@min` survived it.
    try testing.expect(400_000 + 400_000 / 2 < ceiling);
    try testing.expectEqual(ceiling, nextCapacity(400_000, ceiling));
}
