//! Vulkan 1.3 context for text_engine.
//!
//! Mirrors the shape of `tripvulkan/src/gpu/vk.zig` (init / attach
//! split with ownership flags) but configured for graphics + present
//! rather than headless compute:
//!
//!   * Instance enables VK_KHR_surface + the platform-specific child
//!     surface extension (supplied by GLFW) and, in Debug/ReleaseSafe,
//!     VK_EXT_debug_utils for the validation messenger.
//!   * Physical-device pick prefers DISCRETE_GPU, then INTEGRATED.
//!   * Queue-family pick requires GRAPHICS_BIT *and* presentation
//!     support against the surface — modern drivers always satisfy
//!     this with one universal family, so we don't bother with a
//!     separate-graphics-and-present-queue dance.
//!   * Logical device enables VK_KHR_swapchain and Vulkan 1.3 core
//!     features `dynamicRendering` + `synchronization2`.
//!
//! Surface is borrowed, not owned — the demo's Window created it from
//! the glfw handle. Context destroys it in deinit (vkDestroySurfaceKHR
//! needs the instance, so this is the natural place).

const std = @import("std");
const builtin = @import("builtin");
const win = @import("../window.zig");

pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub fn check(result: c.VkResult) !void {
    if (result == c.VK_SUCCESS) return;
    std.debug.print("Vulkan call failed: VkResult={d}\n", .{result});
    return error.VkFailed;
}

const enable_validation = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

const validation_layer_name = "VK_LAYER_KHRONOS_validation";

fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

fn deviceTypeStr(t: c.VkPhysicalDeviceType) []const u8 {
    return switch (t) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => "discrete",
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => "integrated",
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => "virtual",
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => "cpu",
        else => "other",
    };
}

fn hasInstanceLayer(name: []const u8) bool {
    var count: u32 = 0;
    if (c.vkEnumerateInstanceLayerProperties(&count, null) != c.VK_SUCCESS) return false;
    if (count == 0) return false;
    var props: [32]c.VkLayerProperties = undefined;
    var got: u32 = @min(count, @as(u32, props.len));
    if (c.vkEnumerateInstanceLayerProperties(&got, &props) != c.VK_SUCCESS) return false;
    for (props[0..got]) |lp| {
        const layer_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&lp.layerName)), 0);
        if (std.mem.eql(u8, layer_name, name)) return true;
    }
    return false;
}

/// Per-instance debug-utils callback. Validation layer messages route
/// here via the messenger registered in `Context.init`. We print to
/// stderr (unconditionally — if a message reached us, the developer
/// wants to see it) and return VK_FALSE so the offending call still
/// proceeds rather than being aborted, which matches the Khronos
/// recommendation for development workflows.
fn debugCallback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    msg_type: c.VkDebugUtilsMessageTypeFlagsEXT,
    data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    _ = msg_type;
    _ = user_data;
    const sev_tag: []const u8 = if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0)
        "ERROR"
    else if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT != 0)
        "WARN"
    else if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT != 0)
        "INFO"
    else
        "VERBOSE";
    if (data) |d| {
        const msg = if (d.pMessage != null) std.mem.sliceTo(d.pMessage, 0) else "(null)";
        std.debug.print("[vk:{s}] {s}\n", .{ sev_tag, msg });
    }
    return c.VK_FALSE;
}

fn debugMessengerCreateInfo() c.VkDebugUtilsMessengerCreateInfoEXT {
    var ci = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
    ci.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    ci.messageSeverity =
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    ci.messageType =
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    ci.pfnUserCallback = debugCallback;
    return ci;
}

/// Resolves an extension entry point (vkCreate/Destroy DebugUtilsMessengerEXT)
/// through vkGetInstanceProcAddr. Extension functions aren't part of the
/// statically-linked loader symbol set; this is how every Vulkan project
/// gets at them. Returns null if the extension wasn't actually enabled,
/// which is the right outcome — we just skip messenger setup in that case.
fn getInstanceProc(comptime T: type, instance: c.VkInstance, name: [*:0]const u8) ?T {
    const generic = c.vkGetInstanceProcAddr(instance, name) orelse return null;
    return @as(T, @ptrCast(generic));
}

pub const Context = struct {
    instance: c.VkInstance,
    debug_messenger: c.VkDebugUtilsMessengerEXT, // null when validation off
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue_family: u32,
    queue: c.VkQueue,
    props: c.VkPhysicalDeviceProperties,

    // Ownership flags — same pattern as tripvulkan's Context. `init`
    // mode sets these true so deinit destroys everything; a future
    // `attach` mode for matryoshka embedding would set them false.
    owns_instance: bool,
    owns_device: bool,
    owns_surface: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *const win.Window,
        app_name: [*:0]const u8,
    ) !Context {
        const verbose = std.process.hasEnvVarConstant("TEXT_ENGINE_VK_VERBOSE");

        // ── Instance ────────────────────────────────────────────────
        // GLFW tells us the platform-specific surface extension chain
        // (VK_KHR_surface + e.g. VK_KHR_wayland_surface). We append
        // VK_EXT_debug_utils when validation is on, which the messenger
        // setup below depends on.
        var ext_list = std.ArrayList([*:0]const u8).init(allocator);
        defer ext_list.deinit();
        for (win.Window.requiredInstanceExtensions()) |e| try ext_list.append(e);

        const want_validation = enable_validation and hasInstanceLayer(validation_layer_name);
        if (want_validation) {
            try ext_list.append(c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        } else if (enable_validation) {
            std.debug.print(
                "note: VK_LAYER_KHRONOS_validation not installed; running without validation. " ++
                    "Install vulkan-validation-layers (Arch) to enable.\n",
                .{},
            );
        }

        var app_info = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = app_name;
        app_info.applicationVersion = makeApiVersion(0, 0, 1, 0);
        app_info.pEngineName = "text_engine";
        app_info.engineVersion = makeApiVersion(0, 0, 1, 0);
        app_info.apiVersion = makeApiVersion(0, 1, 3, 0);

        const validation_layers = [_][*:0]const u8{validation_layer_name};
        var ici = std.mem.zeroes(c.VkInstanceCreateInfo);
        ici.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        ici.pApplicationInfo = &app_info;
        ici.enabledExtensionCount = @intCast(ext_list.items.len);
        ici.ppEnabledExtensionNames = if (ext_list.items.len == 0) null else @ptrCast(ext_list.items.ptr);
        if (want_validation) {
            ici.enabledLayerCount = validation_layers.len;
            ici.ppEnabledLayerNames = @ptrCast(&validation_layers);
        }

        // Wiring the debug-utils messenger create-info as pNext catches
        // problems that happen *during* vkCreateInstance itself
        // (e.g. an invalid extension name). Without this, the validation
        // layer can't talk back until after the instance exists.
        var dbg_ci = debugMessengerCreateInfo();
        if (want_validation) ici.pNext = &dbg_ci;

        var instance: c.VkInstance = null;
        try check(c.vkCreateInstance(&ici, null, &instance));
        errdefer c.vkDestroyInstance(instance, null);

        // ── Debug messenger (now that the instance exists) ──────────
        var debug_messenger: c.VkDebugUtilsMessengerEXT = null;
        if (want_validation) {
            const create_fn = getInstanceProc(
                c.PFN_vkCreateDebugUtilsMessengerEXT,
                instance,
                "vkCreateDebugUtilsMessengerEXT",
            );
            if (create_fn) |f| {
                try check(f.?(instance, &dbg_ci, null, &debug_messenger));
            }
        }
        errdefer if (debug_messenger != null) {
            if (getInstanceProc(
                c.PFN_vkDestroyDebugUtilsMessengerEXT,
                instance,
                "vkDestroyDebugUtilsMessengerEXT",
            )) |f| f.?(instance, debug_messenger, null);
        };

        // ── Surface (borrowed from the window) ──────────────────────
        var surface: c.VkSurfaceKHR = null;
        try check(win.c.glfwCreateWindowSurface(
            @ptrCast(instance),
            window.handle,
            null,
            @ptrCast(&surface),
        ));
        errdefer c.vkDestroySurfaceKHR(instance, surface, null);

        // ── Physical-device pick ────────────────────────────────────
        // Score by deviceType: discrete > integrated > virtual > cpu.
        // Then require a queue family that's both graphics-capable and
        // can present to our surface; if no candidate family exists,
        // skip the device. Modern drivers always have one universal
        // family that satisfies both.
        var dev_count: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(instance, &dev_count, null));
        if (dev_count == 0) return error.NoVulkanDevice;
        var devs: [16]c.VkPhysicalDevice = undefined;
        const cap = @min(dev_count, devs.len);
        dev_count = cap;
        try check(c.vkEnumeratePhysicalDevices(instance, &dev_count, &devs));

        const rank = struct {
            fn score(t: c.VkPhysicalDeviceType) u32 {
                return switch (t) {
                    c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4,
                    c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 3,
                    c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
                    c.VK_PHYSICAL_DEVICE_TYPE_CPU => 1,
                    else => 0,
                };
            }
        };

        var picked: c.VkPhysicalDevice = null;
        var picked_props: c.VkPhysicalDeviceProperties = undefined;
        var picked_qf: u32 = 0;
        var best_score: u32 = 0;
        for (devs[0..dev_count]) |pd| {
            var p: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(pd, &p);
            if (verbose) std.debug.print("vk:   checking {s}\n", .{std.mem.sliceTo(&p.deviceName, 0)});

            const qf = findGraphicsPresentFamily(pd, surface) catch |e| {
                if (verbose) std.debug.print("vk:     no graphics+present family ({s})\n", .{@errorName(e)});
                continue;
            };
            if (!deviceHasSwapchainExtension(allocator, pd)) {
                if (verbose) std.debug.print("vk:     missing VK_KHR_swapchain\n", .{});
                continue;
            }

            const s = rank.score(p.deviceType);
            if (verbose) {
                const name_slice = std.mem.sliceTo(&p.deviceName, 0);
                std.debug.print("vk:   - [{s}] {s} (qf={d})\n", .{
                    deviceTypeStr(p.deviceType),
                    name_slice,
                    qf,
                });
            }
            if (picked == null or s > best_score) {
                picked = pd;
                picked_props = p;
                picked_qf = qf;
                best_score = s;
            }
        }
        if (picked == null) return error.NoSuitableVulkanDevice;
        if (verbose) {
            const picked_name = std.mem.sliceTo(&picked_props.deviceName, 0);
            std.debug.print("vk: picked [{s}] {s} (qf={d})\n", .{
                deviceTypeStr(picked_props.deviceType),
                picked_name,
                picked_qf,
            });
        }

        // ── Logical device with 1.3 dynamic rendering + sync2 ───────
        // `synchronization2` is what lets us use the modern `vkCmdPipelineBarrier2`
        // / `VkImageMemoryBarrier2` shape, which we'll want for the
        // pre-render layout transition. `dynamicRendering` is the
        // VkRenderPass replacement we agreed to use (see chat.md).
        var f13 = std.mem.zeroes(c.VkPhysicalDeviceVulkan13Features);
        f13.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
        f13.dynamicRendering = c.VK_TRUE;
        f13.synchronization2 = c.VK_TRUE;

        var f2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
        f2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        f2.pNext = &f13;

        const dev_exts = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        const queue_priority: f32 = 1.0;
        var dqci = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        dqci.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        dqci.queueFamilyIndex = picked_qf;
        dqci.queueCount = 1;
        dqci.pQueuePriorities = &queue_priority;

        var dci = std.mem.zeroes(c.VkDeviceCreateInfo);
        dci.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dci.pNext = &f2;
        dci.queueCreateInfoCount = 1;
        dci.pQueueCreateInfos = &dqci;
        dci.enabledExtensionCount = dev_exts.len;
        dci.ppEnabledExtensionNames = @ptrCast(&dev_exts);

        var device: c.VkDevice = null;
        try check(c.vkCreateDevice(picked, &dci, null, &device));
        errdefer c.vkDestroyDevice(device, null);

        var queue: c.VkQueue = null;
        c.vkGetDeviceQueue(device, picked_qf, 0, &queue);

        return .{
            .instance = instance,
            .debug_messenger = debug_messenger,
            .surface = surface,
            .physical_device = picked,
            .device = device,
            .queue_family = picked_qf,
            .queue = queue,
            .props = picked_props,
            .owns_instance = true,
            .owns_device = true,
            .owns_surface = true,
        };
    }

    pub fn deinit(self: *Context) void {
        // Order matters: device-owned resources, then device, then
        // anything instance-scoped (surface + debug messenger), then
        // instance. Other code (swapchain, pipelines, command pools)
        // must already have been destroyed before reaching here.
        if (self.owns_device and self.device != null) {
            c.vkDestroyDevice(self.device, null);
        }
        if (self.owns_surface and self.surface != null) {
            c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        }
        if (self.debug_messenger != null) {
            if (getInstanceProc(
                c.PFN_vkDestroyDebugUtilsMessengerEXT,
                self.instance,
                "vkDestroyDebugUtilsMessengerEXT",
            )) |f| f.?(self.instance, self.debug_messenger, null);
        }
        if (self.owns_instance and self.instance != null) {
            c.vkDestroyInstance(self.instance, null);
        }
        self.* = undefined;
    }

    pub fn deviceName(self: *const Context) [*:0]const u8 {
        return @ptrCast(&self.props.deviceName);
    }
};

// Returns the index of a queue family with GRAPHICS_BIT that also
// supports presentation against `surface`. Modern drivers expose one
// universal family that fits — if not, errors out and the device is
// skipped in the pick loop. Keeping this strict (one family) avoids
// the cross-family ownership-transfer dance later in the swapchain.
fn findGraphicsPresentFamily(pd: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !u32 {
    var qf_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
    var qfs: [16]c.VkQueueFamilyProperties = undefined;
    const qf_cap = @min(qf_count, qfs.len);
    qf_count = qf_cap;
    c.vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, &qfs);

    for (qfs[0..qf_count], 0..) |qf, i| {
        if ((qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) == 0) continue;
        var supports_present: c.VkBool32 = c.VK_FALSE;
        if (c.vkGetPhysicalDeviceSurfaceSupportKHR(
            pd,
            @intCast(i),
            surface,
            &supports_present,
        ) != c.VK_SUCCESS) continue;
        if (supports_present == c.VK_TRUE) return @intCast(i);
    }
    return error.NoGraphicsPresentQueue;
}

fn deviceHasSwapchainExtension(allocator: std.mem.Allocator, pd: c.VkPhysicalDevice) bool {
    var count: u32 = 0;
    if (c.vkEnumerateDeviceExtensionProperties(pd, null, &count, null) != c.VK_SUCCESS) return false;
    if (count == 0) return false;
    // Heap-allocate sized to the actual count — modern drivers (NVIDIA on
    // 2026 Linux ships >260 device extensions) overflow any reasonable
    // stack buffer, and a too-small buffer gets back VK_INCOMPLETE rather
    // than VK_SUCCESS so the check below false-negatives.
    const buf = allocator.alloc(c.VkExtensionProperties, count) catch return false;
    defer allocator.free(buf);
    if (c.vkEnumerateDeviceExtensionProperties(pd, null, &count, buf.ptr) != c.VK_SUCCESS) return false;
    const target = std.mem.span(@as([*:0]const u8, c.VK_KHR_SWAPCHAIN_EXTENSION_NAME));
    for (buf[0..count]) |ep| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ep.extensionName)), 0);
        if (std.mem.eql(u8, name, target)) return true;
    }
    return false;
}
