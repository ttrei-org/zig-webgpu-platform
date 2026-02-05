//! zig-webgpu-create-app: scaffolding tool for new zig-webgpu-platform projects.
//!
//! Creates a ready-to-build project directory with build configuration,
//! template files, and git repository initialization.
//!
//! Usage: zig-webgpu-create-app [directory]
//!   If no directory is given, uses the current working directory.

const std = @import("std");

const log = std.log.scoped(.create_app);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    run(allocator) catch |err| {
        printError("unexpected error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

/// Core logic, separated from main() for testability.
fn run(allocator: std.mem.Allocator) !void {
    const target_path = try resolveTargetPath(allocator);
    defer allocator.free(target_path);

    try validateDirectory(target_path);

    const project_name = try deriveProjectName(allocator, target_path);
    defer allocator.free(project_name);

    printInfo("Creating project \"{s}\" in {s}...", .{ project_name, target_path });

    try fetchTemplates(allocator, project_name, target_path);
    try generateBuildFiles(allocator, project_name, target_path);
    initGitRepo(project_name, target_path);
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

/// Parse CLI args and resolve to an absolute directory path.
/// If no argument is provided, returns the current working directory.
fn resolveTargetPath(allocator: std.mem.Allocator) ![]const u8 {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip argv[0] (the executable name).
    _ = args.next();

    if (args.next()) |raw_path| {
        // Resolve relative paths against CWD to get an absolute path.
        return std.fs.cwd().realpathAlloc(allocator, raw_path) catch {
            // Path doesn't exist yet — resolve manually against CWD.
            const cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd);

            if (std.fs.path.isAbsolute(raw_path)) {
                return try allocator.dupe(u8, raw_path);
            }
            return try std.fs.path.resolve(allocator, &.{ cwd, raw_path });
        };
    }

    // No argument: use current working directory.
    return try std.process.getCwdAlloc(allocator);
}

// ---------------------------------------------------------------------------
// Directory validation
// ---------------------------------------------------------------------------

/// Validate the target directory:
/// - If it doesn't exist, create it (including parents).
/// - If it exists and is non-empty, print an error and exit.
/// - If it exists and is empty, proceed.
fn validateDirectory(target_path: []const u8) !void {
    // Try opening the directory to check if it exists.
    var dir = std.fs.openDirAbsolute(target_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // Directory doesn't exist — create it (including parents).
            std.fs.makeDirAbsolute(target_path) catch |mkdir_err| switch (mkdir_err) {
                error.FileNotFound => {
                    // Parent directories don't exist — use makePath via CWD.
                    std.fs.cwd().makePath(target_path) catch |mp_err| {
                        printError("failed to create directory '{s}': {s}", .{ target_path, @errorName(mp_err) });
                        std.process.exit(1);
                    };
                    return;
                },
                else => {
                    printError("failed to create directory '{s}': {s}", .{ target_path, @errorName(mkdir_err) });
                    std.process.exit(1);
                },
            };
            return;
        },
        else => {
            printError("cannot open directory '{s}': {s}", .{ target_path, @errorName(err) });
            std.process.exit(1);
        },
    };
    defer dir.close();

    // Directory exists — check if it's empty.
    if (!try isDirEmpty(dir)) {
        printError("directory '{s}' is not empty", .{target_path});
        std.process.exit(1);
    }
}

/// Returns true if the directory contains no entries.
fn isDirEmpty(dir: std.fs.Dir) !bool {
    var iter = dir.iterate();
    if (try iter.next()) |_| {
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Project name derivation
// ---------------------------------------------------------------------------

/// Derive a valid Zig identifier from the directory basename.
/// Replaces '-' with '_' and validates the result.
fn deriveProjectName(allocator: std.mem.Allocator, target_path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(target_path);
    if (basename.len == 0) {
        printError("cannot derive project name: directory path has no basename", .{});
        std.process.exit(1);
    }

    // Replace '-' with '_'.
    const name = try allocator.alloc(u8, basename.len);
    for (basename, 0..) |c, i| {
        name[i] = if (c == '-') '_' else c;
    }

    if (!isValidZigIdentifier(name)) {
        defer allocator.free(name);
        printError(
            "'{s}' (from directory '{s}') is not a valid Zig identifier.\n" ++
                "  Project names must start with a letter or underscore,\n" ++
                "  and contain only letters, digits, and underscores.",
            .{ name, basename },
        );
        std.process.exit(1);
    }

    return name;
}

/// Check if a string is a valid Zig identifier:
/// starts with [a-zA-Z_], followed by [a-zA-Z0-9_].
fn isValidZigIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;

    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Template fetching
// ---------------------------------------------------------------------------

/// Base URL for fetching template files from GitHub.
const TEMPLATE_BASE_URL = "https://raw.githubusercontent.com/ttrei-org/zig-webgpu-platform/master/create-app/templates/";

/// Maximum response body size (1 MB) to prevent OOM from unexpected responses.
const MAX_RESPONSE_SIZE = 1024 * 1024;

/// Template file descriptor: source path (relative to templates/) and
/// destination path (relative to project directory).
const TemplateFile = struct {
    source: []const u8,
    dest: []const u8,
    executable: bool = false,
};

/// Hardcoded list of template files to fetch.
const TEMPLATE_FILES = [_]TemplateFile{
    .{ .source = "AGENTS.md", .dest = "AGENTS.md" },
    .{ .source = "DESIGN.md", .dest = "DESIGN.md" },
    .{ .source = "serve.py", .dest = "serve.py", .executable = true },
    .{ .source = "scripts/web_screenshot.sh", .dest = "scripts/web_screenshot.sh", .executable = true },
    .{ .source = "playwright-cli.json", .dest = "playwright-cli.json" },
    .{ .source = "gitignore", .dest = ".gitignore" },
    .{ .source = "index.html", .dest = "web/index.html" },
};

/// Fetch all template files from GitHub, substitute placeholders, and write
/// them into the project directory.
fn fetchTemplates(allocator: std.mem.Allocator, project_name: []const u8, target_path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var dir = try std.fs.openDirAbsolute(target_path, .{});
    defer dir.close();

    for (&TEMPLATE_FILES) |*tmpl| {
        try fetchOneTemplate(allocator, &client, dir, tmpl, project_name);
    }
}

/// Fetch a single template file, perform placeholder substitution, and write it.
fn fetchOneTemplate(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    dir: std.fs.Dir,
    tmpl: *const TemplateFile,
    project_name: []const u8,
) !void {
    printInfo("  Fetching {s}...", .{tmpl.source});

    // Build the full URL.
    const url = try std.mem.concat(allocator, u8, &.{ TEMPLATE_BASE_URL, tmpl.source });
    defer allocator.free(url);

    // Set up an allocating writer to collect the response body.
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body_writer.writer,
    }) catch |err| {
        printError("failed to fetch {s}: {s}", .{ url, @errorName(err) });
        std.process.exit(1);
    };

    if (result.status != .ok) {
        printError("HTTP {d} when fetching {s}", .{ @intFromEnum(result.status), url });
        std.process.exit(1);
    }

    const response_body = body_writer.written();

    // Perform {{PROJECT_NAME}} placeholder substitution.
    const content = try substitutePlaceholder(allocator, response_body, project_name);
    defer allocator.free(content);

    // Create parent directories (e.g. "scripts/", "web/").
    if (std.fs.path.dirname(tmpl.dest)) |parent| {
        dir.makePath(parent) catch |err| {
            printError("failed to create directory '{s}': {s}", .{ parent, @errorName(err) });
            std.process.exit(1);
        };
    }

    // Write the file.
    var file = dir.createFile(tmpl.dest, .{}) catch |err| {
        printError("failed to create file '{s}': {s}", .{ tmpl.dest, @errorName(err) });
        std.process.exit(1);
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        printError("failed to write file '{s}': {s}", .{ tmpl.dest, @errorName(err) });
        std.process.exit(1);
    };

    // Set executable permission for scripts.
    if (tmpl.executable) {
        file.setPermissions(.{ .inner = .{ .mode = 0o755 } }) catch |err| {
            printError("failed to set executable permission on '{s}': {s}", .{ tmpl.dest, @errorName(err) });
            std.process.exit(1);
        };
    }
}

/// Replace all occurrences of "{{PROJECT_NAME}}" with the actual project name.
fn substitutePlaceholder(allocator: std.mem.Allocator, input: []const u8, project_name: []const u8) ![]u8 {
    const placeholder = "{{PROJECT_NAME}}";

    // Count occurrences to calculate output size.
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, input, pos, placeholder)) |idx| {
        count += 1;
        pos = idx + placeholder.len;
    }

    if (count == 0) {
        return try allocator.dupe(u8, input);
    }

    const out_len = input.len - (count * placeholder.len) + (count * project_name.len);
    const output = try allocator.alloc(u8, out_len);

    var src: usize = 0;
    var dst: usize = 0;
    while (std.mem.indexOfPos(u8, input, src, placeholder)) |idx| {
        const chunk_len = idx - src;
        @memcpy(output[dst..][0..chunk_len], input[src..][0..chunk_len]);
        dst += chunk_len;
        @memcpy(output[dst..][0..project_name.len], project_name);
        dst += project_name.len;
        src = idx + placeholder.len;
    }
    // Copy the remaining tail.
    const tail_len = input.len - src;
    @memcpy(output[dst..][0..tail_len], input[src..][0..tail_len]);

    return output;
}

fn generateBuildFiles(allocator: std.mem.Allocator, project_name: []const u8, target_path: []const u8) !void {
    printInfo("Generating build files...", .{});

    var dir = try std.fs.openDirAbsolute(target_path, .{});
    defer dir.close();

    try writeBuildZig(allocator, dir, project_name);
    try writeBuildZigZon(allocator, dir, project_name);

    // Create src/ directory and write src/main.zig.
    dir.makeDir("src") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writeMainZig(allocator, dir, project_name);
}

/// Generate the project's build.zig.
///
/// The build system supports both native (Dawn/GLFW) and WASM (browser WebGPU)
/// targets using zig-webgpu-platform as its sole declared dependency.
fn writeBuildZig(allocator: std.mem.Allocator, dir: std.fs.Dir, project_name: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const target_arch = target.result.cpu.arch;
        \\    const target_os = target.result.os.tag;
        \\    const is_wasm = target_arch.isWasm();
        \\    const is_native = !is_wasm;
        \\
        \\    if (is_wasm) {
        \\        b.install_prefix = "zig-out/web";
        \\    }
        \\
        \\    const platform_dep = b.dependency("zig_webgpu_platform", .{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    // Fetch transitive dependencies through the platform dependency.
        \\    const zgpu_dep = platform_dep.builder.dependency("zgpu", .{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const zglfw_dep = if (is_native) platform_dep.builder.dependency("zglfw", .{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }) else null;
        \\
        \\    const root_module = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    // Import the platform library module so application code can @import("platform").
        \\    root_module.addImport("platform", platform_dep.module("zig-webgpu-platform"));
        \\
        \\    const exe = b.addExecutable(.{
        \\
    );
    try buf.print(allocator, "        .name = \"{s}\",\n", .{project_name});
    try buf.appendSlice(allocator,
        \\        .root_module = root_module,
        \\    });
        \\
        \\    if (is_native) {
        \\        // Guard: upstream Dawn prebuilt for aarch64-linux is broken.
        \\        if (target_os == .linux and target.result.cpu.arch.isAARCH64()) {
        \\            std.log.err(
        \\                "aarch64-linux-gnu is not supported: the upstream Dawn prebuilt " ++
        \\                    "contains x86-64 objects. WASM builds (-Dtarget=wasm32-emscripten) " ++
        \\                    "work on all architectures.",
        \\                .{},
        \\            );
        \\            return;
        \\        }
        \\
        \\        const zgpu_build = @import("zgpu");
        \\        zgpu_build.addLibraryPathsTo(exe);
        \\        zgpu_build.linkSystemDeps(b, exe);
        \\
        \\        exe.root_module.addIncludePath(zgpu_dep.path("libs/dawn/include"));
        \\        exe.root_module.addIncludePath(zgpu_dep.path("src"));
        \\
        \\        exe.linkSystemLibrary("dawn");
        \\        exe.linkLibC();
        \\        exe.linkLibCpp();
        \\
        \\        if (target_os == .linux) {
        \\            if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
        \\                if (target.result.cpu.arch.isX86()) {
        \\                    exe.root_module.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
        \\                }
        \\            }
        \\            exe.linkSystemLibrary("X11");
        \\        }
        \\
        \\        if (zglfw_dep) |dep| {
        \\            exe.root_module.linkLibrary(dep.artifact("glfw"));
        \\        }
        \\
        \\        exe.root_module.addCSourceFile(.{
        \\            .file = zgpu_dep.path("src/dawn.cpp"),
        \\            .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
        \\        });
        \\        exe.root_module.addCSourceFile(.{
        \\            .file = zgpu_dep.path("src/dawn_proc.c"),
        \\            .flags = &.{"-fno-sanitize=undefined"},
        \\        });
        \\    } else {
        \\        exe.export_memory = true;
        \\        exe.export_table = true;
        \\        exe.initial_memory = 64 * 1024 * 1024;
        \\        exe.max_memory = null;
        \\        exe.import_symbols = true;
        \\
        \\        exe.root_module.export_symbol_names = &.{"wasm_main"};
        \\        exe.entry = .disabled;
        \\    }
        \\
        \\    b.installArtifact(exe);
        \\
        \\    // For WASM builds, copy JS bindings and HTML to the output directory.
        \\    if (is_wasm) {
        \\        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        \\            platform_dep.path("web/wasm_bindings.js"),
        \\            .{ .custom = "." },
        \\
    );
    try buf.print(allocator, "            \"{s}.js\",\n", .{project_name});
    try buf.appendSlice(allocator,
        \\        ).step);
        \\        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        \\            b.path("web/index.html"),
        \\            .{ .custom = "." },
        \\            "index.html",
        \\        ).step);
        \\    }
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\    if (b.args) |args| {
        \\        run_cmd.addArgs(args);
        \\    }
        \\
        \\    const run_step = b.step("run", "Run the application");
        \\    run_step.dependOn(&run_cmd.step);
        \\
        \\    const test_step = b.step("test", "Run unit tests");
        \\    const test_module = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    test_module.addImport("platform", platform_dep.module("zig-webgpu-platform"));
        \\    const exe_tests = b.addTest(.{
        \\        .root_module = test_module,
        \\    });
        \\    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
        \\
        \\    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
        \\    test_step.dependOn(&fmt_check.step);
        \\}
        \\
    );

    var file = try dir.createFile("build.zig", .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Generate the project's build.zig.zon.
///
/// Uses a placeholder hash that `zig fetch --save` will replace.
fn writeBuildZigZon(allocator: std.mem.Allocator, dir: std.fs.Dir, project_name: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, ".{{\n    .name = .{s},\n", .{project_name});
    try buf.appendSlice(allocator,
        \\    .version = "0.1.0",
        \\
        \\    .paths = .{
        \\        "src",
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "web",
        \\    },
        \\
        \\    .dependencies = .{
        \\        .zig_webgpu_platform = .{
        \\            .url = "https://github.com/ttrei-org/zig-webgpu-platform/archive/master.tar.gz",
        \\            .hash = "placeholder_run_zig_fetch_save",
        \\        },
        \\    },
        \\}
        \\
    );

    var file = try dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Generate a minimal src/main.zig.
///
/// Renders a sky-blue background rectangle and a centered red circle.
fn writeMainZig(allocator: std.mem.Allocator, dir: std.fs.Dir, project_name: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const platform = @import("platform");
        \\
        \\const Canvas = platform.Canvas;
        \\const Color = platform.Color;
        \\const AppInterface = platform.AppInterface;
        \\const MouseState = platform.MouseState;
        \\
        \\pub const App = struct {
        \\    running: bool = true,
        \\
        \\    pub fn init() App {
        \\        return .{};
        \\    }
        \\
        \\    pub fn appInterface(self: *App) AppInterface {
        \\        return .{
        \\            .context = @ptrCast(self),
        \\            .updateFn = &updateImpl,
        \\            .renderFn = &renderImpl,
        \\            .isRunningFn = &isRunningImpl,
        \\            .requestQuitFn = &requestQuitImpl,
        \\            .deinitFn = &deinitImpl,
        \\            .shouldTakeScreenshotFn = null,
        \\            .onScreenshotCompleteFn = null,
        \\        };
        \\    }
        \\
        \\    fn updateImpl(iface: *AppInterface, delta_time: f32, mouse: MouseState) void {
        \\        _ = delta_time;
        \\        _ = mouse;
        \\        _ = iface;
        \\    }
        \\
        \\    fn renderImpl(iface: *AppInterface, canvas: *Canvas) void {
        \\        _ = iface;
        \\        // Sky-blue background
        \\        canvas.fillRect(0, 0, canvas.viewport.logical_width, canvas.viewport.logical_height, Color.fromHex(0x87CEEB));
        \\        // Red circle in the center
        \\        canvas.fillCircle(
        \\            canvas.viewport.logical_width / 2.0,
        \\            canvas.viewport.logical_height / 2.0,
        \\            30,
        \\            Color.red,
        \\            32,
        \\        );
        \\    }
        \\
        \\    fn isRunningImpl(iface: *const AppInterface) bool {
        \\        const self: *const App = @ptrCast(@alignCast(iface.context));
        \\        return self.running;
        \\    }
        \\
        \\    fn requestQuitImpl(iface: *AppInterface) void {
        \\        const self: *App = @ptrCast(@alignCast(iface.context));
        \\        self.running = false;
        \\    }
        \\
        \\    fn deinitImpl(iface: *AppInterface) void {
        \\        _ = iface;
        \\    }
        \\};
        \\
        \\pub fn main() void {
        \\    var app = App.init();
        \\    var iface = app.appInterface();
        \\    defer iface.deinit();
        \\
        \\    platform.run(&iface, .{
        \\        .viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },
        \\        .width = 800,
        \\        .height = 600,
        \\
    );
    try buf.print(allocator, "        .window_title = \"{s}\",\n", .{project_name});
    try buf.appendSlice(allocator,
        \\    });
        \\}
        \\
    );

    var src_dir = try dir.openDir("src", .{});
    defer src_dir.close();
    var file = try src_dir.createFile("main.zig", .{});
    defer file.close();
    try file.writeAll(buf.items);
}

fn initGitRepo(_: []const u8, _: []const u8) void {
    printInfo("TODO: initialize git repository", .{});
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn printInfo(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    defer writer.interface.flush() catch {};
    writer.interface.print(fmt ++ "\n", args) catch {};
}

fn printError(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    defer writer.interface.flush() catch {};
    writer.interface.print("error: " ++ fmt ++ "\n", args) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isValidZigIdentifier" {
    const valid = isValidZigIdentifier;
    // Valid identifiers
    try std.testing.expect(valid("foo"));
    try std.testing.expect(valid("_foo"));
    try std.testing.expect(valid("foo_bar"));
    try std.testing.expect(valid("Foo123"));
    try std.testing.expect(valid("_"));
    try std.testing.expect(valid("a"));

    // Invalid identifiers
    try std.testing.expect(!valid(""));
    try std.testing.expect(!valid("123foo"));
    try std.testing.expect(!valid("foo-bar"));
    try std.testing.expect(!valid("foo bar"));
    try std.testing.expect(!valid("foo.bar"));
    try std.testing.expect(!valid("3"));
}

test "deriveProjectName replaces hyphens" {
    const allocator = std.testing.allocator;
    const name = try deriveProjectName(allocator, "/tmp/my-cool-app");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("my_cool_app", name);
}

test "deriveProjectName simple name" {
    const allocator = std.testing.allocator;
    const name = try deriveProjectName(allocator, "/home/user/myapp");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("myapp", name);
}

test "substitutePlaceholder no placeholders" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "hello world", "myapp");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "substitutePlaceholder single replacement" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "name={{PROJECT_NAME}}", "myapp");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("name=myapp", result);
}

test "substitutePlaceholder multiple replacements" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "{{PROJECT_NAME}}.js and {{PROJECT_NAME}}.wasm", "cool_app");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("cool_app.js and cool_app.wasm", result);
}
