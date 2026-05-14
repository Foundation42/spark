const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Compile GLSL → SPIR-V ──────────────────────────────────────
    // Each shader gets `-I shaders/` so it can `#include` common helpers,
    // and `-MD -MF <name>.d` emits a make-style depfile that Zig's build
    // system parses so edits to included `.glsl` files invalidate the
    // cached SPIR-V — without this, only edits to the top-level file
    // would trigger a recompile.
    const text_vert_spv = compileShaderStage(b, "text", "vert");
    const text_frag_spv = compileShaderStage(b, "text", "frag");

    // ── Bundle SPIR-V into a generated Zig module ──────────────────
    // The compiled blobs need `align(4)` because Vulkan's `pCode` field
    // takes a `const uint32_t*`. Dereferencing the @embedFile and tagging
    // align(4) materialises the bytes in static data at a u32-aligned
    // address. Pattern lifted from tripvulkan/build.zig.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(text_vert_spv, "text.vert.spv");
    _ = wf.addCopyFile(text_frag_spv, "text.frag.spv");
    const shader_mod = wf.add("shaders.zig",
        \\pub const text_vert align(4) = @embedFile("text.vert.spv").*;
        \\pub const text_frag align(4) = @embedFile("text.frag.spv").*;
        \\
    );

    // ── Shaders module (shared) ────────────────────────────────────
    // ONE module instantiation backing both the library and the demo
    // exe. Zig 0.14.1 forbids the same source file becoming the root
    // of two different modules ("file exists in multiple modules"),
    // which is exactly what happens if both add it via
    // `addAnonymousImport` independently — they get module IDs but
    // collide on the underlying generated `shaders.zig`. Sharing a
    // single created module sidesteps that.
    const shaders_module = b.createModule(.{
        .root_source_file = shader_mod,
        .target = target,
        .optimize = optimize,
    });

    // ── Public Zig module for host-engine embedding ────────────────
    // `text_engine` exposes the narrow cooperative-embed surface: a
    // host engine (matryoshka, the future terminal, in-game UI) does
    // `@import("text_engine")` and reaches the styled-text pipeline +
    // SPIR-V blobs. Vulkan / FreeType / HarfBuzz / glfw are the
    // host's link responsibility — same policy as `valkyr_gpu` in
    // tripvulkan/build.zig. Keeps link config singular when one host
    // embeds several cooperative libraries.
    const text_engine_mod = b.addModule("text_engine", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_engine_mod.addImport("shaders", shaders_module);

    // ── Vendored cmark (CommonMark reference parser) ───────────────
    // Static archive linked into the demo. Vendored at 0.31.2 under
    // `vendor/cmark/` — we maintain hand-authored cmark_export.h
    // and cmark_version.h replacements for the CMake-generated ones.
    // Source files reach each other via local "..." includes; the
    // public header uses <cmark_export.h> + <cmark_version.h> from
    // the same dir via -I. CMARK_STATIC_DEFINE collapses the export
    // visibility macros to no-ops.
    const cmark_lib = b.addStaticLibrary(.{
        .name = "cmark",
        .target = target,
        .optimize = optimize,
    });
    const cmark_flags = &[_][]const u8{
        "-std=c99",
        "-DCMARK_STATIC_DEFINE",
        // Suppress upstream's strict-aliasing / sign-compare /
        // unused-parameter noise — third-party code, not ours to
        // chase clean.
        "-Wno-unused-parameter",
        "-Wno-unused-but-set-variable",
        "-Wno-sign-compare",
    };
    cmark_lib.addCSourceFiles(.{
        .files = &.{
            "vendor/cmark/blocks.c",
            "vendor/cmark/buffer.c",
            "vendor/cmark/cmark.c",
            "vendor/cmark/cmark_ctype.c",
            "vendor/cmark/commonmark.c",
            "vendor/cmark/houdini_href_e.c",
            "vendor/cmark/houdini_html_e.c",
            "vendor/cmark/houdini_html_u.c",
            "vendor/cmark/html.c",
            "vendor/cmark/inlines.c",
            "vendor/cmark/iterator.c",
            "vendor/cmark/latex.c",
            "vendor/cmark/man.c",
            "vendor/cmark/node.c",
            "vendor/cmark/references.c",
            "vendor/cmark/render.c",
            "vendor/cmark/scanners.c",
            "vendor/cmark/utf8.c",
            "vendor/cmark/xml.c",
        },
        .flags = cmark_flags,
    });
    cmark_lib.addIncludePath(b.path("vendor/cmark"));
    cmark_lib.linkLibC();

    // ── Standalone demo executable ─────────────────────────────────
    // Owns its own glfw window + Vulkan context, exercises the library
    // via the same module a host engine would. Build-system stress test
    // and the dogfood surface during library development. Production
    // hosts (matryoshka HUD, terminal app) come later and use the
    // cooperative attach surface, not this exe.
    const exe = b.addExecutable(.{
        .name = "text_engine_demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("shaders", shaders_module);
    exe.root_module.addImport("text_engine", text_engine_mod);

    // System libraries the demo links against. The library module
    // itself does *not* link these — host's responsibility.
    if (target.result.os.tag == .windows) {
        if (std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK")) |sdk| {
            exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
            exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
        } else |_| {}
        exe.linkSystemLibrary("vulkan-1");
    } else {
        exe.linkSystemLibrary("vulkan");
    }
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("freetype2");
    exe.linkSystemLibrary("harfbuzz");
    exe.linkLibrary(cmark_lib);
    exe.addIncludePath(b.path("vendor/cmark"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run text_engine_demo");
    run_step.dependOn(&run_cmd.step);
}

// Compile one shader stage (`name.<stage>` → `name.<stage>.spv`) via
// glslc. `stage` is "vert" / "frag" / "comp"; the source file is
// `shaders/<name>.<stage>`. Emits a depfile so #include'd helpers
// trigger rebuilds. Returns the LazyPath of the resulting .spv blob.
fn compileShaderStage(b: *std.Build, name: []const u8, stage: []const u8) std.Build.LazyPath {
    const src = b.fmt("shaders/{s}.{s}", .{ name, stage });
    const spv = b.fmt("{s}.{s}.spv", .{ name, stage });
    const dep = b.fmt("{s}.{s}.d", .{ name, stage });
    const cmd = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3" });
    cmd.addArg("-I");
    cmd.addDirectoryArg(b.path("shaders"));
    cmd.addArg("-MD");
    cmd.addArg("-MF");
    _ = cmd.addDepFileOutputArg(dep);
    cmd.addFileArg(b.path(src));
    cmd.addArg("-o");
    return cmd.addOutputFileArg(spv);
}
