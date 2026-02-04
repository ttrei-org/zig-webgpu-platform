const std = @import("std");

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
        .name = "zig_gui_experiment",
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
        };

        // For emscripten specifically, mark that we don't need a standard entry point
        // since the browser/JS will call our exported wasm_main function
        exe.entry = .disabled;
    }

    b.installArtifact(exe);

    // For web builds, also generate JavaScript glue code
    if (is_wasm) {
        // Create JavaScript loader file that instantiates the WASM module
        // This provides Emscripten runtime stubs and WebGPU integration
        const js_glue = b.addWriteFiles();
        _ = js_glue.add("zig_gui_experiment.js", @embedFile("web/wasm_bindings.js"));

        // Install the JS glue file to the web output directory
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            js_glue.getDirectory().path(b, "zig_gui_experiment.js"),
            .{ .custom = "." },
            "zig_gui_experiment.js",
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
}
