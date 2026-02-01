const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch zgpu dependency and get its module
    const zgpu_dep = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu_module = zgpu_dep.module("root");

    // Detect if building for native desktop (not emscripten/web)
    const is_native = target.result.os.tag != .emscripten;

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

    // Link Dawn/WebGPU and system dependencies
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
    const target_os = target.result.os.tag;
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

    b.installArtifact(exe);

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
