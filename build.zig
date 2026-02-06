const std = @import("std");

/// Link all native dependencies (Dawn, GLFW, system SDKs) needed for a desktop
/// build against zig-webgpu-platform. Consumer projects call this in their build.zig
/// via `@import("zig_webgpu_platform").linkNativeDeps(platform_dep, exe)`.
///
/// This encapsulates the complex native linking (Dawn prebuilt library paths,
/// system SDK paths, GLFW artifact, C++ source compilation) so consumer projects
/// don't need to know the internal dependency structure.
///
/// Note: lazy dependencies (dawn prebuilts, system_sdk) are resolved through the
/// platform's own builder, not the consumer's, because the consumer's build.zig.zon
/// does not (and should not) list these transitive dependencies.
pub fn linkNativeDeps(platform_dep: *std.Build.Dependency, exe: *std.Build.Step.Compile) void {
    const target = exe.rootModuleTarget();
    const target_os = target.os.tag;
    const platform_b = platform_dep.builder;

    // Access zgpu and zglfw through the platform's own dependency tree.
    const zgpu_dep = platform_b.dependency("zgpu", .{
        .target = exe.root_module.resolved_target.?,
        .optimize = exe.root_module.optimize.?,
    });

    // Resolve Dawn prebuilt library paths through the platform's builder
    // (not the consumer's) since the dawn lazy deps live in our build.zig.zon.
    switch (target_os) {
        .windows => {
            if (platform_b.lazyDependency("dawn_x86_64_windows_gnu", .{})) |dawn_prebuilt| {
                exe.addLibraryPath(dawn_prebuilt.path(""));
            }
        },
        .linux => {
            if (target.cpu.arch.isX86()) {
                if (platform_b.lazyDependency("dawn_x86_64_linux_gnu", .{})) |dawn_prebuilt| {
                    exe.addLibraryPath(dawn_prebuilt.path(""));
                }
            }
            // Note: aarch64-linux is guarded against in the consumer's build.zig.
        },
        .macos => {
            if (target.cpu.arch.isAARCH64()) {
                if (platform_b.lazyDependency("dawn_aarch64_macos", .{})) |dawn_prebuilt| {
                    exe.addLibraryPath(dawn_prebuilt.path(""));
                }
            } else if (target.cpu.arch.isX86()) {
                if (platform_b.lazyDependency("dawn_x86_64_macos", .{})) |dawn_prebuilt| {
                    exe.addLibraryPath(dawn_prebuilt.path(""));
                }
            }
        },
        else => {},
    }

    // Link system SDK through the platform's builder.
    switch (target_os) {
        .windows => {
            if (platform_b.lazyDependency("system_sdk", .{})) |system_sdk| {
                exe.addLibraryPath(system_sdk.path("windows/lib/x86_64-windows-gnu"));
            }
            exe.linkSystemLibrary("ole32");
            exe.linkSystemLibrary("dxguid");
        },
        .linux => {
            if (platform_b.lazyDependency("system_sdk", .{})) |system_sdk| {
                if (target.cpu.arch.isX86()) {
                    exe.root_module.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
                }
            }
            exe.linkSystemLibrary("X11");
        },
        .macos => {
            if (platform_b.lazyDependency("system_sdk", .{})) |system_sdk| {
                exe.addLibraryPath(system_sdk.path("macos12/usr/lib"));
                exe.addFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
            }
            exe.linkSystemLibrary("objc");
            exe.linkFramework("Metal");
            exe.linkFramework("CoreGraphics");
            exe.linkFramework("Foundation");
            exe.linkFramework("IOKit");
            exe.linkFramework("IOSurface");
            exe.linkFramework("QuartzCore");
        },
        else => {},
    }

    exe.root_module.addIncludePath(zgpu_dep.path("libs/dawn/include"));
    exe.root_module.addIncludePath(zgpu_dep.path("src"));

    exe.linkSystemLibrary("dawn");
    exe.linkLibC();
    exe.linkLibCpp();

    const zglfw_dep = platform_b.dependency("zglfw", .{
        .target = exe.root_module.resolved_target.?,
        .optimize = exe.root_module.optimize.?,
    });
    exe.root_module.linkLibrary(zglfw_dep.artifact("glfw"));

    exe.root_module.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    exe.root_module.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn_proc.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Detect if building for web/WASM target
    const target_arch = target.result.cpu.arch;
    const target_os = target.result.os.tag;
    const is_wasm = target_arch.isWasm();
    const is_native = !is_wasm;

    // Configure output path: zig-out/web/ for WASM builds, default for native
    if (is_wasm) {
        b.install_prefix = "zig-out/web";
    }

    // Fetch zgpu dependency and get its module
    const zgpu_dep = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu_module = zgpu_dep.module("root");

    // Create the root module for the executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zgpu import
    root_module.addImport("zgpu", zgpu_module);

    // Fetch zigimg dependency and add import
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zigimg", zigimg_dep.module("zigimg"));

    // Fetch zglfw dependency and add import for desktop builds only
    var zglfw_dep: ?*std.Build.Dependency = null;
    if (is_native) {
        zglfw_dep = b.dependency("zglfw", .{
            .target = target,
            .optimize = optimize,
        });
        root_module.addImport("zglfw", zglfw_dep.?.module("root"));
    }

    const exe = b.addExecutable(.{
        .name = "zig_webgpu_platform",
        .root_module = root_module,
    });

    // Native-only: Link Dawn/WebGPU and system dependencies
    // Emscripten uses browser's WebGPU implementation
    if (is_native) {
        // Guard: the upstream Dawn prebuilt for aarch64-linux-gnu contains
        // x86-64 objects (upstream bug, unfixed since July 2023).
        // Fail early with a clear message instead of hundreds of linker errors.
        if (target_os == .linux and target.result.cpu.arch.isAARCH64()) {
            std.log.err(
                "aarch64-linux-gnu native builds are not supported: the upstream Dawn " ++
                    "prebuilt (michal-z/webgpu_dawn-aarch64-linux-gnu) contains x86-64 " ++
                    "objects instead of aarch64 objects. See bead bd-1v1n for details. " ++
                    "WASM builds (-Dtarget=wasm32-emscripten) work on all architectures.",
                .{},
            );
            return;
        }

        const zgpu_build = @import("zgpu");
        zgpu_build.addLibraryPathsTo(exe);
        zgpu_build.linkSystemDeps(b, exe);

        // Add include path for Dawn headers
        exe.root_module.addIncludePath(zgpu_dep.path("libs/dawn/include"));
        exe.root_module.addIncludePath(zgpu_dep.path("src"));

        // Link Dawn and C++ runtime
        exe.linkSystemLibrary("dawn");
        exe.linkLibC();
        exe.linkLibCpp();

        // Link X11 on Linux for Dawn's surface support.
        // For cross-compilation, the system_sdk provides the X11 library
        // since it won't be on the host system.
        if (target_os == .linux) {
            if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
                if (target.result.cpu.arch.isX86()) {
                    exe.root_module.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
                }
            }
            exe.linkSystemLibrary("X11");
        }

        // Link GLFW library for desktop builds
        if (zglfw_dep) |dep| {
            exe.root_module.linkLibrary(dep.artifact("glfw"));
        }

        // Add C source files for Dawn bindings
        exe.root_module.addCSourceFile(.{
            .file = zgpu_dep.path("src/dawn.cpp"),
            .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
        });
        exe.root_module.addCSourceFile(.{
            .file = zgpu_dep.path("src/dawn_proc.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
    } else {
        // WASM-specific configuration
        // Export WebGPU entry points and set up for browser environment
        //
        // Memory settings:
        // - export_memory: Required for JS to access WASM memory
        // - initial_memory: 64MB starting heap (sufficient for basic rendering)
        // - max_memory: null allows growth (equivalent to -sALLOW_MEMORY_GROWTH)
        //
        // Note: Browser-side settings (-sUSE_WEBGPU=1, -sMODULARIZE, -sEXPORT_ES6)
        // are configured in the HTML/JS loader, not the WASM build itself.
        // The browser provides WebGPU via navigator.gpu, no linking required.

        exe.export_memory = true;
        exe.export_table = true; // Export function table for emscripten_set_main_loop callbacks
        exe.initial_memory = 64 * 1024 * 1024; // 64MB initial heap
        exe.max_memory = null; // Allow memory growth (no upper limit)
        exe.import_symbols = true; // Allow imports from JS environment

        // Note: We do NOT link libc for WASM builds.
        // Zig doesn't have libc support for wasm32-emscripten targets.
        // Instead, we use custom emscripten bindings in web.zig that don't require libc.
        // The extern functions are imported from the JavaScript environment at runtime.

        // Export the wasm_main entry point which is explicitly defined for WASM builds.
        // We don't export _start/main to avoid triggering the standard library's
        // start.zig which doesn't support wasm32-emscripten architecture.
        exe.root_module.export_symbol_names = &.{
            "wasm_main", // Our custom WASM entry point
            "web_update_mouse_position", // JS → WASM mouse move events
            "web_update_mouse_button", // JS → WASM mouse button events
            "web_update_key_state", // JS → WASM keyboard events
            "web_update_canvas_size", // JS → WASM canvas resize events
            "web_request_quit", // JS → WASM quit request
        };

        // For emscripten specifically, mark that we don't need a standard entry point
        // since the browser/JS will call our exported wasm_main function
        exe.entry = .disabled;
    }

    b.installArtifact(exe);

    // Export the library module for consumers who want to use this as a dependency.
    // The module exports the public API surface (Canvas, Color, Viewport, etc.)
    // through src/lib.zig, keeping internal modules hidden.
    const lib_module = b.addModule("zig-webgpu-platform", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Library module needs the same dependencies as the executable
    lib_module.addImport("zgpu", zgpu_module);
    lib_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    if (zglfw_dep) |dep| {
        lib_module.addImport("zglfw", dep.module("root"));
    }

    // For web builds, also generate JavaScript glue code
    if (is_wasm) {
        // Create JavaScript loader file that instantiates the WASM module
        // This provides Emscripten runtime stubs and WebGPU integration
        const js_glue = b.addWriteFiles();
        _ = js_glue.add("zig_webgpu_platform.js", @embedFile("web/wasm_bindings.js"));

        // Install the JS glue file to the web output directory
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            js_glue.getDirectory().path(b, "zig_webgpu_platform.js"),
            .{ .custom = "." },
            "zig_webgpu_platform.js",
        ).step);

        // Copy index.html from web/ to the web output directory
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path("web/index.html"),
            .{ .custom = "." },
            "index.html",
        ).step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Tests need the same imports as the main executable so that transitive
    // imports (e.g. canvas -> renderer -> zgpu) resolve correctly.
    test_module.addImport("zgpu", zgpu_module);
    test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    if (zglfw_dep) |dep| {
        test_module.addImport("zglfw", dep.module("root"));
    }
    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);

    // Backend comparison step (integration test)
    // Runs compare_backends.sh which captures screenshots from desktop and web,
    // then compares them with ImageMagick to detect rendering regressions.
    const compare_step = b.step("compare-backends", "Compare screenshots from desktop and web backends");
    const compare_cmd = b.addSystemCommand(&.{"./scripts/compare_backends.sh"});
    compare_step.dependOn(&compare_cmd.step);
}
