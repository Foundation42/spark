//! `:::button` — clickable rectangle that fires a `:::update`-style
//! dispatch when its primary mouse button is released inside it
//! (stage 13b).
//!
//! Attribute grammar:
//!
//!     :::button {label="Run" target=#chat_local action=start width=120}
//!     :::
//!
//! - `label`  (required) — text rendered inside the button.
//! - `target` (required) — `#id` of the component to dispatch the
//!   action onto. `#` prefix is optional; we strip it. State-target
//!   dispatch (`target=state.path`) is deferred — pair this with the
//!   existing `:::update` directive emitter when that case comes up.
//! - `action` (required) — the `action=NAME` passed through to the
//!   target's `Factory.handle_update(ctx, action, body)`.
//! - `body`   (optional) — passed verbatim as the update body.
//!   Default empty.
//! - `width`  (optional) — pixel literal or `100%`. Default: intrinsic
//!   to the label width plus padding.
//! - `height` (optional) — pixel literal. Default 36.
//!
//! ### Click → dispatch
//!
//! Wires `on_input` to receive mouse events; on `mouse_up` of button 0
//! (left), invokes `registry.handleUpdate(target, action, body)`. The
//! state pointer passed to `on_input` is unused — the dispatch goes
//! through the registry directly, not through state — so a button
//! inside an `:::embedded-document` reaches the *host* registry, which
//! is what we want (a button in a child doc that triggers a parent-
//! scope component, or a sibling component in the same scope, etc).
//!
//! Hover state is not yet plumbed — `mouse_move` doesn't propagate
//! until the hit-test layer carries a "mouse entered" event. v0 button
//! is constant colour. Real hover lands when we wire enter/leave
//! signals.

const std = @import("std");
const element = @import("../element.zig");
const components = @import("../markdown_components.zig");
const component_mod = @import("../component.zig");
const text_layout = @import("../text/layout.zig");
const shape = @import("../font/shape.zig");
const box_helpers = @import("box.zig");

pub const Error = error{
    ButtonMissingLabel,
    ButtonMissingTarget,
    ButtonMissingAction,
    ButtonNotInstalled,
};

// Module global — set by install(). Used by onInput to dispatch.
var registry_ref: ?*component_mod.Registry = null;

pub fn install(registry: *component_mod.Registry) !void {
    registry_ref = registry;
    try registry.register("button", factory);
}

pub fn deinitGlobals() void {
    registry_ref = null;
}

pub const factory: component_mod.Factory = .{
    .create = create,
    .update = update,
    .deinit = deinit_,
};

const Component = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    target: []u8, // stripped of leading `#`
    action: []u8,
    body: []u8,
    width: ?box_helpers.Length, // null = intrinsic
    height: f32,
    last_box: element.Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Bumped on every spec ingest so the retained layout cache
    /// re-walks the button when its attrs change.
    version: u64 = 0,

    fn ingest(self: *Component, spec: *const components.Spec) !void {
        const a = self.allocator;
        var label_raw: ?[]const u8 = null;
        var target_raw: ?[]const u8 = null;
        var action_raw: ?[]const u8 = null;
        var body_raw: []const u8 = "";
        var width_opt: ?box_helpers.Length = self.width;
        var height_opt: f32 = self.height;

        for (spec.attrs) |attr| {
            if (std.mem.eql(u8, attr.key, "label")) {
                label_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "target")) {
                target_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "action")) {
                action_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "body")) {
                body_raw = attr.value;
            } else if (std.mem.eql(u8, attr.key, "width")) {
                if (box_helpers.parseLength(attr.value)) |l| width_opt = l;
            } else if (std.mem.eql(u8, attr.key, "height")) {
                if (box_helpers.parseLength(attr.value)) |l| {
                    height_opt = switch (l) {
                        .pixels => |p| p,
                        else => height_opt,
                    };
                }
            }
        }

        const label = label_raw orelse return Error.ButtonMissingLabel;
        const target_full = target_raw orelse return Error.ButtonMissingTarget;
        const action = action_raw orelse return Error.ButtonMissingAction;

        const target = if (target_full.len > 0 and target_full[0] == '#')
            target_full[1..]
        else
            target_full;

        const new_label = try a.dupe(u8, label);
        errdefer a.free(new_label);
        const new_target = try a.dupe(u8, target);
        errdefer a.free(new_target);
        const new_action = try a.dupe(u8, action);
        errdefer a.free(new_action);
        const new_body = try a.dupe(u8, body_raw);
        errdefer a.free(new_body);

        // Old field cleanup — only after every new dupe succeeded.
        a.free(self.label);
        a.free(self.target);
        a.free(self.action);
        a.free(self.body);
        self.label = new_label;
        self.target = new_target;
        self.action = new_action;
        self.body = new_body;
        self.width = width_opt;
        self.height = height_opt;
        self.version +%= 1;
    }
};

fn create(allocator: std.mem.Allocator, spec: *const components.Spec) anyerror!component_mod.Instance {
    const c = try allocator.create(Component);
    errdefer allocator.destroy(c);
    c.* = .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, ""),
        .action = try allocator.dupe(u8, ""),
        .body = try allocator.dupe(u8, ""),
        .width = null,
        .height = 36,
    };
    try c.ingest(spec);
    return .{ .vtable = &vtable, .ctx = @ptrCast(c) };
}

fn update(ctx: *anyopaque, spec: *const components.Spec) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    try c.ingest(spec);
}

fn deinit_(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    allocator.free(c.label);
    allocator.free(c.target);
    allocator.free(c.action);
    allocator.free(c.body);
    allocator.destroy(c);
}

const vtable: element.ElementVTable = .{
    .layout_and_render = layoutAndRender,
    .on_input = onInput,
    .content_version = contentVersion,
};

fn contentVersion(ctx: *anyopaque) u64 {
    const c: *const Component = @ptrCast(@alignCast(ctx));
    return c.version;
}

// ── Visual constants ────────────────────────────────────────────────

const BUTTON_BG: [4]f32 = .{ 0.20, 0.36, 0.62, 1.0 };
const BUTTON_BORDER: [4]f32 = .{ 0.45, 0.68, 0.95, 1.0 };
const BUTTON_LABEL: [4]f32 = .{ 0.98, 0.98, 1.0, 1.0 };
const BUTTON_BORDER_PX: f32 = 1.5;
const BUTTON_RADIUS: f32 = 6;
const BUTTON_PAD_X: f32 = 16;

fn layoutAndRender(
    ctx: *anyopaque,
    origin: [2]f32,
    constraints: element.Constraints,
    lc: *element.LayoutCtx,
    out: *element.DrawList,
) anyerror!element.Box {
    const c: *Component = @ptrCast(@alignCast(ctx));
    const style = lc.theme.body;

    var arena = std.heap.ArenaAllocator.init(lc.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const hb = lc.fonts.hbFont(style.font_id);
    const run = try shape.shapeUtf8(aa, hb, c.label);
    const fscale = lc.fonts.scale(style.font_id);
    var text_w: f32 = 0;
    for (run.glyphs) |g| text_w += g.x_advance * fscale;

    const intrinsic_w = text_w + 2 * BUTTON_PAD_X;
    const max_w = constraints.max_w;
    const fallback_w = if (std.math.isFinite(max_w)) max_w else intrinsic_w;
    const w: f32 = if (c.width) |wl| wl.resolve(max_w, fallback_w) else intrinsic_w;
    const h = c.height;

    // Border + body
    try out.quads.append(.{
        .dst_pos = .{ origin[0], origin[1] },
        .dst_size = .{ w, h },
        .color = BUTTON_BORDER,
        .radius = BUTTON_RADIUS,
    });
    try out.quads.append(.{
        .dst_pos = .{ origin[0] + BUTTON_BORDER_PX, origin[1] + BUTTON_BORDER_PX },
        .dst_size = .{ w - 2 * BUTTON_BORDER_PX, h - 2 * BUTTON_BORDER_PX },
        .color = BUTTON_BG,
        .radius = @max(0, BUTTON_RADIUS - BUTTON_BORDER_PX),
    });

    // Label centred
    const m = lc.fonts.metrics(style.font_id);
    const baseline_y = origin[1] + (h - m.line_height) * 0.5 + m.ascender;
    const text_x = origin[0] + (w - text_w) * 0.5;
    _ = try text_layout.appendShapedRun(
        &out.glyphs,
        lc.fonts,
        lc.cache,
        lc.mono_atlas,
        lc.color_atlas,
        lc.glyph_cache_lock,
        run,
        style.font_id,
        text_x,
        baseline_y,
        BUTTON_LABEL,
        style.hot_color,
        style.attention,
    );

    const box: element.Box = .{
        .x = origin[0],
        .y = origin[1],
        .w = w,
        .h = h,
        .baseline = baseline_y,
    };
    c.last_box = box;

    // Register as hit target — emits a Hit so the dispatcher can
    // route mouse events to onInput.
    try out.hits.append(.{
        .box = box,
        .vtable = &vtable,
        .ctx = @ptrCast(c),
        .state = lc.state,
    });

    return box;
}

fn onInput(
    ctx: *anyopaque,
    event: element.InputEvent,
    _: *anyopaque,
) anyerror!void {
    const c: *Component = @ptrCast(@alignCast(ctx));
    switch (event) {
        .mouse_up => |m| {
            if (m.button != 0) return; // primary only
            if (c.target.len == 0 or c.action.len == 0) return;
            const r = registry_ref orelse return;
            r.handleUpdate(c.target, c.action, c.body) catch |e| {
                std.log.warn(":::button: dispatch failed: target=#{s} action={s} err={s}", .{
                    c.target, c.action, @errorName(e),
                });
            };
        },
        else => {},
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const state_mod = @import("../state.zig");

test "button: ingest stores label/target/action/body, strips # from target" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Run" },
        .{ .key = "target", .value = "#chat_local" },
        .{ .key = "action", .value = "start" },
        .{ .key = "body", .value = "go" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };

    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);
    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("Run", c.label);
    try testing.expectEqualStrings("chat_local", c.target); // # stripped
    try testing.expectEqualStrings("start", c.action);
    try testing.expectEqualStrings("go", c.body);
}

test "button: missing label rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "target", .value = "#x" },
        .{ .key = "action", .value = "go" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    try testing.expectError(Error.ButtonMissingLabel, create(testing.allocator, &spec));
}

test "button: missing target rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "action", .value = "go" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    try testing.expectError(Error.ButtonMissingTarget, create(testing.allocator, &spec));
}

test "button: missing action rejected" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "x" },
        .{ .key = "target", .value = "y" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    try testing.expectError(Error.ButtonMissingAction, create(testing.allocator, &spec));
}

test "button: update re-ingests attrs (label change)" {
    const attrs = [_]components.Attr{
        .{ .key = "label", .value = "Old" },
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec: components.Spec = .{ .name = "button", .attrs = &attrs };
    const inst = try create(testing.allocator, &spec);
    defer deinit_(inst.ctx, testing.allocator);

    const attrs2 = [_]components.Attr{
        .{ .key = "label", .value = "New" },
        .{ .key = "target", .value = "t" },
        .{ .key = "action", .value = "a" },
    };
    const spec2: components.Spec = .{ .name = "button", .attrs = &attrs2 };
    try update(inst.ctx, &spec2);

    const c: *Component = @ptrCast(@alignCast(inst.ctx));
    try testing.expectEqualStrings("New", c.label);
}
