const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── glslc resolution ───────────────────────────────────────────
    // Fail-fast with a clear contributor-onboarding message if glslc
    // isn't reachable. `GLSLC=/path/to/glslc zig build` overrides the
    // PATH lookup — useful when the Vulkan SDK lives somewhere
    // unconventional or multiple toolchains are installed.
    const glslc_path = resolveGlslc(b);

    // ── Compile GLSL → SPIR-V ──────────────────────────────────────
    // Each shader gets `-I shaders/` so it can `#include` common helpers,
    // and `-MD -MF <name>.d` emits a make-style depfile that Zig's build
    // system parses so edits to included `.glsl` files invalidate the
    // cached SPIR-V — without this, only edits to the top-level file
    // would trigger a recompile.
    const text_vert_spv = compileShaderStage(b, glslc_path, "text", "vert", optimize);
    const text_frag_spv = compileShaderStage(b, glslc_path, "text", "frag", optimize);
    const quad_vert_spv = compileShaderStage(b, glslc_path, "quad", "vert", optimize);
    const quad_frag_spv = compileShaderStage(b, glslc_path, "quad", "frag", optimize);
    const tri_vert_spv = compileShaderStage(b, glslc_path, "tri", "vert", optimize);
    const tri_frag_spv = compileShaderStage(b, glslc_path, "tri", "frag", optimize);
    const image_vert_spv = compileShaderStage(b, glslc_path, "image", "vert", optimize);
    const image_frag_spv = compileShaderStage(b, glslc_path, "image", "frag", optimize);
    // Effects-spec Phase A.4 — first pass shader. Fullscreen-triangle
    // vertex passthrough shared by every effect fragment shader from
    // A.5 onward. The smoke test in `src/pass/shader_resolver.zig`
    // asserts these bytes land non-empty so the build infrastructure
    // is exercised before A.5 starts shipping real fragment shaders.
    const fullscreen_vert_spv = compileShaderStage(b, glslc_path, "fullscreen", "vert", optimize);
    // Effects-spec Phase A.5 — three canary pattern fragments with
    // deliberately distinct uniform shapes (vec4×2 + enum / enum +
    // int / int×2 + float) so the resolver's typed-marshalling gets
    // diverse coverage from the first effect commit.
    const gradient_frag_spv = compileShaderStage(b, glslc_path, "gradient", "frag", optimize);
    const pattern_frag_spv = compileShaderStage(b, glslc_path, "pattern", "frag", optimize);
    const noise_frag_spv = compileShaderStage(b, glslc_path, "noise", "frag", optimize);
    // Effects-spec Phase B.4.b.1 — single-source substrate smoke
    // shader. Passthrough composite paired with the combined-image-
    // sampler descriptor layout; first non-pattern pipeline shape,
    // validates the SingleSourcePipelineCache eager-compile path
    // before B.5 ships the first real filter (`:::drop_shadow`).
    const copy_frag_spv = compileShaderStage(b, glslc_path, "copy", "frag", optimize);
    // Effects-spec Phase B.6.d — third single_source filter. Rounded-
    // box SDF refraction + chromatic aberration + rim highlight +
    // tint, Apple-Liquid-Glass-inspired. First effect authored via
    // the B.6.c SingleSourceFactory generator.
    const liquid_glass_frag_spv = compileShaderStage(b, glslc_path, "liquid_glass", "frag", optimize);
    // Effects-spec Phase B.7 — default composite shader for the
    // `.host_slot` PassShape arm. Trivial passthrough sampler, no
    // push-constant block (HostSlotStep carries no uniforms in v1).
    // Distinct from `copy.frag` (the B.4.b SingleSourcePipelineCache
    // substrate test shader) which declares a push-constant `alpha`.
    const host_slot_passthrough_frag_spv = compileShaderStage(b, glslc_path, "host_slot_passthrough", "frag", optimize);
    // Effects-spec Phase C.2 — the two blur shaders. Same separable kernel
    // (`shaders/gaussian.glsl`), different endings: `_alpha` reduces to one
    // channel and tints by the coverage (`:::drop_shadow`), `_rgba` keeps
    // the colour and lays a wash over it (`:::frosted_glass`). Both run as
    // CHAIN steps, twice each — horizontally, then vertically. Neither has a
    // `.frag` of its own effect any more; `frosted_glass.frag` was a 9-tap
    // box blur and was deleted along with `drop_shadow.frag` before it.
    const gaussian_alpha_frag_spv = compileShaderStage(b, glslc_path, "gaussian_alpha", "frag", optimize);
    const gaussian_rgba_frag_spv = compileShaderStage(b, glslc_path, "gaussian_rgba", "frag", optimize);

    // ── Bundle SPIR-V into a generated Zig module ──────────────────
    // The compiled blobs need `align(4)` because Vulkan's `pCode` field
    // takes a `const uint32_t*`. Dereferencing the @embedFile and tagging
    // align(4) materialises the bytes in static data at a u32-aligned
    // address. Pattern lifted from tripvulkan/build.zig.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(text_vert_spv, "text.vert.spv");
    _ = wf.addCopyFile(text_frag_spv, "text.frag.spv");
    _ = wf.addCopyFile(quad_vert_spv, "quad.vert.spv");
    _ = wf.addCopyFile(quad_frag_spv, "quad.frag.spv");
    _ = wf.addCopyFile(tri_vert_spv, "tri.vert.spv");
    _ = wf.addCopyFile(tri_frag_spv, "tri.frag.spv");
    _ = wf.addCopyFile(image_vert_spv, "image.vert.spv");
    _ = wf.addCopyFile(image_frag_spv, "image.frag.spv");
    _ = wf.addCopyFile(fullscreen_vert_spv, "fullscreen.vert.spv");
    _ = wf.addCopyFile(gradient_frag_spv, "gradient.frag.spv");
    _ = wf.addCopyFile(pattern_frag_spv, "pattern.frag.spv");
    _ = wf.addCopyFile(noise_frag_spv, "noise.frag.spv");
    _ = wf.addCopyFile(copy_frag_spv, "copy.frag.spv");
    _ = wf.addCopyFile(liquid_glass_frag_spv, "liquid_glass.frag.spv");
    _ = wf.addCopyFile(host_slot_passthrough_frag_spv, "host_slot_passthrough.frag.spv");
    _ = wf.addCopyFile(gaussian_alpha_frag_spv, "gaussian_alpha.frag.spv");
    _ = wf.addCopyFile(gaussian_rgba_frag_spv, "gaussian_rgba.frag.spv");
    const shader_mod = wf.add("shaders.zig",
        \\pub const text_vert align(4) = @embedFile("text.vert.spv").*;
        \\pub const text_frag align(4) = @embedFile("text.frag.spv").*;
        \\pub const quad_vert align(4) = @embedFile("quad.vert.spv").*;
        \\pub const quad_frag align(4) = @embedFile("quad.frag.spv").*;
        \\pub const tri_vert align(4) = @embedFile("tri.vert.spv").*;
        \\pub const tri_frag align(4) = @embedFile("tri.frag.spv").*;
        \\pub const image_vert align(4) = @embedFile("image.vert.spv").*;
        \\pub const image_frag align(4) = @embedFile("image.frag.spv").*;
        \\pub const fullscreen_vert align(4) = @embedFile("fullscreen.vert.spv").*;
        \\pub const gradient_frag align(4) = @embedFile("gradient.frag.spv").*;
        \\pub const pattern_frag align(4) = @embedFile("pattern.frag.spv").*;
        \\pub const noise_frag align(4) = @embedFile("noise.frag.spv").*;
        \\pub const copy_frag align(4) = @embedFile("copy.frag.spv").*;
        \\pub const liquid_glass_frag align(4) = @embedFile("liquid_glass.frag.spv").*;
        \\pub const host_slot_passthrough_frag align(4) = @embedFile("host_slot_passthrough.frag.spv").*;
        \\pub const gaussian_alpha_frag align(4) = @embedFile("gaussian_alpha.frag.spv").*;
        \\pub const gaussian_rgba_frag align(4) = @embedFile("gaussian_rgba.frag.spv").*;
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
    // `spark` exposes the narrow cooperative-embed surface: a host
    // engine (matryoshka, the future terminal, in-game UI) does
    // `@import("spark")` and reaches the styled-text pipeline +
    // SPIR-V blobs. Vulkan / FreeType / HarfBuzz / glfw are the
    // host's link responsibility — same policy as `valkyr_gpu` in
    // tripvulkan/build.zig. Keeps link config singular when one host
    // embeds several cooperative libraries.
    const spark_mod = b.addModule("spark", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    spark_mod.addImport("shaders", shaders_module);
    // The library module's source files `@cImport` freetype +
    // harfbuzz + cmark + stb_image headers (FreeType library handle,
    // HB face/font, cmark parser, image decode). The compiler runs
    // those imports at module-build time, so the include paths need
    // to be on the module itself — the demo exe linking is a
    // separate concern.
    spark_mod.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    spark_mod.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    spark_mod.addIncludePath(b.path("vendor/cmark"));
    spark_mod.addIncludePath(b.path("vendor/stb"));

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
        .name = "spark_demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("shaders", shaders_module);
    exe.root_module.addImport("spark", spark_mod);

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
    // stb_image — single-translation-unit C library for PNG/JPG/etc.
    // decoding. Pattern matches matryoshka's `libs/stb_image.{c,h}`:
    // a .c stub defines `STB_IMAGE_IMPLEMENTATION` and includes the
    // header so the static functions get emitted exactly once.
    exe.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_image.c"),
        .flags = &.{"-std=c99"},
    });
    exe.addIncludePath(b.path("vendor/stb"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run spark_demo");
    run_step.dependOn(&run_cmd.step);

    // ── Minimal host (Phase 4 second consumer) ─────────────────────
    // Smallest possible binary that imports `spark` and stands up a
    // Spark instance against its public surface. Library-spec
    // §"Phase 4" — proves the boundary against a non-demo consumer
    // before matryoshka adoption. Same system-library link config
    // as the demo because it reaches through the same demo-supporting
    // re-exports (window/swapchain/renderer) for the host-side glue.
    const minimal_host = b.addExecutable(.{
        .name = "minimal_host",
        .root_source_file = b.path("examples/minimal_host.zig"),
        .target = target,
        .optimize = optimize,
    });
    minimal_host.root_module.addImport("spark", spark_mod);
    if (target.result.os.tag == .windows) {
        if (std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK")) |sdk| {
            minimal_host.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
            minimal_host.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
        } else |_| {}
        minimal_host.linkSystemLibrary("vulkan-1");
    } else {
        minimal_host.linkSystemLibrary("vulkan");
    }
    minimal_host.linkSystemLibrary("glfw");
    minimal_host.linkSystemLibrary("freetype2");
    minimal_host.linkSystemLibrary("harfbuzz");
    minimal_host.linkLibrary(cmark_lib);
    minimal_host.addIncludePath(b.path("vendor/cmark"));
    minimal_host.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_image.c"),
        .flags = &.{"-std=c99"},
    });
    minimal_host.addIncludePath(b.path("vendor/stb"));
    minimal_host.linkLibC();
    const minimal_host_step = b.step("minimal-host", "Build the Phase 4 minimal_host example");
    minimal_host_step.dependOn(&b.addInstallArtifact(minimal_host, .{}).step);

    const run_minimal_host = b.addRunArtifact(minimal_host);
    run_minimal_host.step.dependOn(&b.addInstallArtifact(minimal_host, .{}).step);
    const run_minimal_host_step = b.step("run-minimal-host", "Run the Phase 4 minimal_host example");
    run_minimal_host_step.dependOn(&run_minimal_host.step);

    // ── Unit tests ─────────────────────────────────────────────────
    // Single test entry point at `src/tests.zig` so the module root
    // is `src/` — needed because subdirectory test files
    // (`src/components/...`) reach up to siblings (`element.zig`)
    // via relative imports, and Zig's module system forbids
    // `../`-style escapes from a test file's own module root.
    // Same link config as the demo exe because most modules
    // transitively reach face / shape / vk through
    // `element.LayoutCtx` even when the test only touches pure-logic
    // paths — Zig resolves type layouts eagerly.
    // `-Dtest-filter=<substring>` runs only the tests whose names match.
    // The suite stands up a real Vulkan device for a dozen integration
    // tests, so a full run is a coffee; when one test is misbehaving, being
    // able to run only that one is the difference between bisecting in
    // minutes and bisecting in an afternoon.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this substring");
    const t = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    t.root_module.addImport("shaders", shaders_module);
    if (target.result.os.tag == .windows) {
        t.linkSystemLibrary("vulkan-1");
    } else {
        t.linkSystemLibrary("vulkan");
    }
    t.linkSystemLibrary("glfw");
    t.linkSystemLibrary("freetype2");
    t.linkSystemLibrary("harfbuzz");
    t.linkLibrary(cmark_lib);
    t.addIncludePath(b.path("vendor/cmark"));
    t.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_image.c"),
        .flags = &.{"-std=c99"},
    });
    t.addIncludePath(b.path("vendor/stb"));
    t.linkLibC();
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(t).step);
}

// Resolve the glslc executable path. Honours `GLSLC` env-var
// override first (for non-standard Vulkan SDK installs or when
// multiple toolchains coexist), then falls back to a PATH lookup.
// Fail-fast with a clear message — silent build failures are a
// known contributor-onboarding pain point.
fn resolveGlslc(b: *std.Build) []const u8 {
    if (std.process.getEnvVarOwned(b.allocator, "GLSLC")) |path| {
        return path;
    } else |_| {}
    return b.findProgram(&.{"glslc"}, &.{}) catch {
        std.debug.print(
            \\
            \\error: glslc not found on PATH.
            \\  Install the Vulkan SDK (https://vulkan.lunarg.com) to provide it,
            \\  or set GLSLC=/path/to/glslc to point at an existing install.
            \\
            \\
        , .{});
        std.process.exit(1);
    };
}

// Compile one shader stage (`name.<stage>` → `name.<stage>.spv`) via
// glslc. `stage` is "vert" / "frag" / "comp"; the source file is
// `shaders/<name>.<stage>`. Emits a depfile so #include'd helpers
// trigger rebuilds. Returns the LazyPath of the resulting .spv blob.
//
// Optimization map:
//   * `Debug`         → `-O0` (default — readable SPIR-V, validation friendly)
//   * `ReleaseSafe`   → `-O`  (perf optimisation, debug info preserved)
//   * `ReleaseFast`   → `-O`  (perf optimisation)
//   * `ReleaseSmall`  → `-Os` (size optimisation)
fn compileShaderStage(b: *std.Build, glslc: []const u8, name: []const u8, stage: []const u8, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const src = b.fmt("shaders/{s}.{s}", .{ name, stage });
    const spv = b.fmt("{s}.{s}.spv", .{ name, stage });
    const dep = b.fmt("{s}.{s}.d", .{ name, stage });
    const cmd = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.3" });
    cmd.addArg("-I");
    cmd.addDirectoryArg(b.path("shaders"));
    cmd.addArg("-MD");
    cmd.addArg("-MF");
    _ = cmd.addDepFileOutputArg(dep);
    switch (optimize) {
        .Debug => {}, // -O0 is glslc's default
        .ReleaseSafe, .ReleaseFast => cmd.addArg("-O"),
        .ReleaseSmall => cmd.addArg("-Os"),
    }
    cmd.addFileArg(b.path(src));
    cmd.addArg("-o");
    return cmd.addOutputFileArg(spv);
}
