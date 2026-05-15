//! `:::chart` — streaming sparkline component (stage 8b). The
//! visceral demo target for `Factory.handle_update`: an LLM (or the
//! demo's synthetic data source) streams individual sample values
//! through `:::update {#id action=append}\nVALUE\n:::` directives;
//! each one lands directly on the component's ring buffer via the
//! component-target dispatch path. No cmark, no Element walker, no
//! re-parse, no Binding refire.
//!
//! Visual: a filled-column sparkline. Each sample is a thin vertical
//! quad anchored at the chart's bottom edge, height proportional to
//! the sample's position between `min` and `max`. Axis-aligned quads
//! mean the existing rounded-quad pipeline carries it without any
//! rotation work — line-style charts can layer on later if needed.
//!
//! ### Why a ring buffer, not a `std.ArrayList`
//!
//! Append is the steady-state cost. A ring buffer is O(1) per append
//! with zero allocation churn after `create`; an ArrayList would
//! occasionally realloc + memmove, and at multi-kHz update rates
//! that becomes visible. The "scroll the chart" semantic — old
//! samples fall off when capacity fills — is also a natural fit for
//! ring-buffer addressing.
//!
//! ### Why no state binding
//!
//! Chart attrs (min/max/width/height/color) are static-at-author-time
//! by design — they configure the visualisation, not the data. The
//! data comes through `handle_update` and lives entirely in the
//! component's opaque ring buffer. So this component runs *without*
//! a Binding (no `${state.x}` in its attrs) which means component-
//! target updates land cleanly without fighting any reactive
//! re-substitution — the design pitfall flagged in [[box.zig]] doesn't
//! apply here.
//!
//! ### Attribute grammar
//!
//!     :::chart {#id type=line min=-1 max=1 width=320 height=120 capacity=128}
//!     :::
//!
//! Supported attrs:
//!   * `type` — `line` (the only mode at 8b; reserved for `bar` /
//!     `area` / `scatter` later).
//!   * `min`, `max` — sample bounds for the y-axis. Default -1..+1.
//!     Values outside this range clamp.
//!   * `width`, `height` — `:::box`-style length syntax (px / %).
//!   * `capacity` — ring buffer size. Default 128. Set at `create`
//!     only; `update` ignores changes (resize would discard history).
//!   * `color` — column fill colour.
//!   * `bg` — chart background colour.
//!
//! ### Update actions
//!
//!   * `action=append` — body=one float as a string. Pushes the
//!     sample; oldest falls off if buffer is full.
//!   * `action=clear` — empties the buffer.
//!   * Unknown actions: silent no-op (same policy as `:::box`).

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const box_mod = @import("box.zig");

const DEFAULT_CAPACITY: usize = 128;
const DEFAULT_COLOR: [4]f32 = .{ 0.40, 0.85, 0.92, 1.0 }; // cyan
const DEFAULT_BG: [4]f32 = .{ 0.10, 0.12, 0.18, 0.85 }; // dark slate

const Component = struct {
    allocator: std.mem.Allocator,
    samples: []f32,
    capacity: usize,
    write_idx: usize = 0,
    /// Number of valid samples. Saturates at `capacity` once the
    /// buffer wraps; `sampleAt` switches mapping at that point.
    filled: usize = 0,
    min_val: f32 = -1.0,
    max_val: f32 = 1.0,
    width: box_mod.Length = .{ .pixels = 320 },
    height: box_mod.Length = .{ .pixels = 120 },
    color: [4]f32 = DEFAULT_COLOR,
    bg: [4]f32 = DEFAULT_BG,
    radius: f32 = 4,
    /// Bumped on every visible-state mutation (append/clear/applySpec).
    /// Drives retained layout-cache invalidation.
    version: u64 = 0,

    /// Apply attrs from a Spec onto the component. Values that fail
    /// to parse keep the previous (or default) field value — louder
    /// than crashing, gentler than zeroing. Capacity is intentionally
    /// not honoured here; resizing would discard sample history.
    fn applySpec(self: *Component, spec: *const components.Spec) void {
        for (spec.attrs) |a| {
            if (std.mem.eql(u8, a.key, "min")) {
                self.min_val = std.fmt.parseFloat(f32, a.value) catch self.min_val;
            } else if (std.mem.eql(u8, a.key, "max")) {
                self.max_val = std.fmt.parseFloat(f32, a.value) catch self.max_val;
            } else if (std.mem.eql(u8, a.key, "width")) {
                if (box_mod.parseLength(a.value)) |l| self.width = l;
            } else if (std.mem.eql(u8, a.key, "height")) {
                if (box_mod.parseLength(a.value)) |l| self.height = l;
            } else if (std.mem.eql(u8, a.key, "color")) {
                if (box_mod.parseColor(a.value)) |c| self.color = c;
            } else if (std.mem.eql(u8, a.key, "bg")) {
                if (box_mod.parseColor(a.value)) |c| self.bg = c;
            } else if (std.mem.eql(u8, a.key, "radius")) {
                if (box_mod.parseLength(a.value)) |l| {
                    self.radius = switch (l) {
                        .pixels => |p| p,
                        else => self.radius,
                    };
                }
            }
        }
    }

    fn append(self: *Component, value: f32) void {
        self.samples[self.write_idx] = value;
        self.write_idx = (self.write_idx + 1) % self.capacity;
        if (self.filled < self.capacity) self.filled += 1;
        self.version +%= 1;
    }

    fn clear(self: *Component) void {
        self.write_idx = 0;
        self.filled = 0;
        self.version +%= 1;
    }

    /// Logical index 0..filled-1 (0 = oldest, filled-1 = newest).
    /// Once the buffer wraps, oldest lives at `write_idx`.
    fn sampleAt(self: *const Component, i: usize) f32 {
        if (self.filled < self.capacity) return self.samples[i];
        return self.samples[(self.write_idx + i) % self.capacity];
    }
};

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
    .handle_update = handleUpdate,
};

fn parseCapacity(spec: *const components.Spec) usize {
    for (spec.attrs) |a| {
        if (std.mem.eql(u8, a.key, "capacity")) {
            return std.fmt.parseInt(usize, a.value, 10) catch DEFAULT_CAPACITY;
        }
    }
    return DEFAULT_CAPACITY;
}

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const capacity = @max(@as(usize, 2), parseCapacity(spec));
    const samples = try allocator.alloc(f32, capacity);
    errdefer allocator.free(samples);
    const c = try allocator.create(Component);
    c.* = .{
        .allocator = allocator,
        .samples = samples,
        .capacity = capacity,
    };
    c.applySpec(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    c.applySpec(spec);
    c.version +%= 1;
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.samples);
    allocator.destroy(c);
}

fn handleUpdate(ctx: *anyopaque, action: []const u8, body: []const u8) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.eql(u8, action, "append")) {
        const v = std.fmt.parseFloat(f32, trimmed) catch return;
        c.append(v);
    } else if (std.mem.eql(u8, action, "clear")) {
        c.clear();
    }
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    _: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *const Component = @ptrCast(@alignCast(ctx));

    const max_w = constraints.max_w;
    const fallback_w: f32 = if (std.math.isFinite(max_w)) max_w else 320.0;
    const w = c.width.resolve(max_w, fallback_w);
    const h = c.height.resolve(max_w, 120.0);

    // Background panel.
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = c.bg,
        .radius = c.radius,
    });

    if (c.filled == 0) {
        return .{ .x = origin[0], .y = origin[1], .w = w, .h = h, .baseline = 0 };
    }

    // Column geometry. Each sample claims one slot across the full
    // width, regardless of how many samples are actually filled —
    // so the chart "scrolls in" from the right as data arrives.
    const slot_w = w / @as(f32, @floatFromInt(c.capacity));
    const gap = @min(@as(f32, 1.0), slot_w * 0.4);
    const bar_w = @max(@as(f32, 1.0), slot_w - gap);

    const range = c.max_val - c.min_val;
    const safe_range: f32 = if (@abs(range) > 1e-6) range else 1.0;
    const baseline_y = origin[1] + h;

    var i: usize = 0;
    while (i < c.filled) : (i += 1) {
        const v = c.sampleAt(i);
        const clamped = std.math.clamp(v, c.min_val, c.max_val);
        const norm = (clamped - c.min_val) / safe_range; // 0..1
        const bar_h = norm * h;
        const x = origin[0] + @as(f32, @floatFromInt(i)) * slot_w;
        try out.quads.append(.{
            .dst_pos = .{ x, baseline_y - bar_h },
            .dst_size = .{ bar_w, bar_h },
            .color = c.color,
            .radius = 0,
        });
    }

    return .{ .x = origin[0], .y = origin[1], .w = w, .h = h, .baseline = 0 };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn makeComponent(allocator: std.mem.Allocator, capacity: usize) !*Component {
    const samples = try allocator.alloc(f32, capacity);
    const c = try allocator.create(Component);
    c.* = .{ .allocator = allocator, .samples = samples, .capacity = capacity };
    return c;
}

fn destroyComponent(c: *Component) void {
    c.allocator.free(c.samples);
    c.allocator.destroy(c);
}

test "ring buffer: append + sampleAt before wrap" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    c.append(1.0);
    c.append(2.0);
    c.append(3.0);
    try testing.expectEqual(@as(usize, 3), c.filled);
    try testing.expectEqual(@as(f32, 1.0), c.sampleAt(0));
    try testing.expectEqual(@as(f32, 2.0), c.sampleAt(1));
    try testing.expectEqual(@as(f32, 3.0), c.sampleAt(2));
}

test "ring buffer: append wraps correctly after fill" {
    const c = try makeComponent(testing.allocator, 3);
    defer destroyComponent(c);
    c.append(1.0);
    c.append(2.0);
    c.append(3.0);
    c.append(4.0); // wraps — 1.0 falls off, 4.0 becomes newest
    try testing.expectEqual(@as(usize, 3), c.filled);
    try testing.expectEqual(@as(f32, 2.0), c.sampleAt(0)); // oldest
    try testing.expectEqual(@as(f32, 3.0), c.sampleAt(1));
    try testing.expectEqual(@as(f32, 4.0), c.sampleAt(2)); // newest

    c.append(5.0);
    try testing.expectEqual(@as(f32, 3.0), c.sampleAt(0));
    try testing.expectEqual(@as(f32, 5.0), c.sampleAt(2));
}

test "ring buffer: clear resets" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    c.append(1.0);
    c.append(2.0);
    c.clear();
    try testing.expectEqual(@as(usize, 0), c.filled);
    try testing.expectEqual(@as(usize, 0), c.write_idx);
    c.append(7.0);
    try testing.expectEqual(@as(f32, 7.0), c.sampleAt(0));
}

test "applySpec: parses min/max/width/height" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    const attrs = [_]components.Attr{
        .{ .key = "min", .value = "0" },
        .{ .key = "max", .value = "100" },
        .{ .key = "width", .value = "400px" },
        .{ .key = "height", .value = "80" },
        .{ .key = "color", .value = "orange" },
    };
    const spec: components.Spec = .{ .name = "chart", .attrs = &attrs };
    c.applySpec(&spec);
    try testing.expectEqual(@as(f32, 0), c.min_val);
    try testing.expectEqual(@as(f32, 100), c.max_val);
    try testing.expectEqual(@as(f32, 400), c.width.pixels);
    try testing.expectEqual(@as(f32, 80), c.height.pixels);
    try testing.expect(c.color[0] > 0.5); // orange has dominant red
}

test "applySpec: malformed min/max keeps previous value" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    c.min_val = -1.0;
    c.max_val = 1.0;
    const attrs = [_]components.Attr{
        .{ .key = "min", .value = "garbage" },
        .{ .key = "max", .value = "5" },
    };
    const spec: components.Spec = .{ .name = "chart", .attrs = &attrs };
    c.applySpec(&spec);
    try testing.expectEqual(@as(f32, -1.0), c.min_val); // unchanged
    try testing.expectEqual(@as(f32, 5.0), c.max_val);
}

test "handleUpdate: append parses float, pushes sample" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    try handleUpdate(@ptrCast(c), "append", "0.5");
    try testing.expectEqual(@as(usize, 1), c.filled);
    try testing.expectEqual(@as(f32, 0.5), c.sampleAt(0));

    // Trailing newline + whitespace trimmed.
    try handleUpdate(@ptrCast(c), "append", "  -0.25 \n");
    try testing.expectEqual(@as(f32, -0.25), c.sampleAt(1));
}

test "handleUpdate: append with garbage body silently no-ops" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    try handleUpdate(@ptrCast(c), "append", "not-a-number");
    try testing.expectEqual(@as(usize, 0), c.filled);
}

test "handleUpdate: clear empties the buffer" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    try handleUpdate(@ptrCast(c), "append", "1");
    try handleUpdate(@ptrCast(c), "append", "2");
    try testing.expectEqual(@as(usize, 2), c.filled);
    try handleUpdate(@ptrCast(c), "clear", "");
    try testing.expectEqual(@as(usize, 0), c.filled);
}

test "handleUpdate: unknown action silent no-op" {
    const c = try makeComponent(testing.allocator, 4);
    defer destroyComponent(c);
    try handleUpdate(@ptrCast(c), "explode", "boom");
    try testing.expectEqual(@as(usize, 0), c.filled);
}
