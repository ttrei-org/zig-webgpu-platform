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

        // Link X11 on Linux for Dawn's surface support
        if (target_os == .linux) {
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
        exe.initial_memory = 64 * 1024 * 1024; // 64MB initial heap
        exe.max_memory = null; // Allow memory growth (no upper limit)
        exe.import_symbols = true; // Allow imports from JS environment

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
        // This provides the minimal glue code needed to load and run the WASM
        // in a browser with WebGPU support
        const js_glue = b.addWriteFiles();
        _ = js_glue.add("zig_gui_experiment.js",
            \\// Generated JavaScript glue code for zig_gui_experiment.wasm
            \\// This module provides WebGPU integration and WASM loading
            \\
            \\export async function init(wasmPath) {
            \\    if (!navigator.gpu) {
            \\        throw new Error("WebGPU is not supported in this browser");
            \\    }
            \\
            \\    const adapter = await navigator.gpu.requestAdapter();
            \\    if (!adapter) {
            \\        throw new Error("Failed to get WebGPU adapter");
            \\    }
            \\
            \\    const device = await adapter.requestDevice();
            \\
            \\    const response = await fetch(wasmPath || "zig_gui_experiment.wasm");
            \\    const wasmBytes = await response.arrayBuffer();
            \\
            \\    const importObject = {
            \\        env: {
            \\            // WebGPU device will be passed to WASM via imports
            \\            // Memory is exported from WASM, not imported
            \\        },
            \\    };
            \\
            \\    const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
            \\
            \\    return {
            \\        instance,
            \\        device,
            \\        adapter,
            \\        exports: instance.exports,
            \\    };
            \\}
            \\
            \\export default { init };
            \\
        );

        // Install the JS glue file to the web output directory
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            js_glue.getDirectory().path(b, "zig_gui_experiment.js"),
            .{ .custom = "." },
            "zig_gui_experiment.js",
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
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}
