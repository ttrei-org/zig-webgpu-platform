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

/// Parsed CLI options.
const CliOptions = struct {
    target_path: []const u8,
    templates_dir: ?[]const u8 = null,
    platform_path: ?[]const u8 = null,

    fn deinit(self: *const CliOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.target_path);
        if (self.templates_dir) |p| allocator.free(p);
        if (self.platform_path) |p| allocator.free(p);
    }
};

/// Core logic, separated from main() for testability.
fn run(allocator: std.mem.Allocator) !void {
    const opts = try parseCliOptions(allocator);
    defer opts.deinit(allocator);

    try validateDirectory(opts.target_path);

    const project_name = try deriveProjectName(allocator, opts.target_path);
    defer allocator.free(project_name);

    printInfo("Creating project \"{s}\" in {s}...", .{ project_name, opts.target_path });

    if (opts.templates_dir) |dir| {
        try copyLocalTemplates(allocator, project_name, opts.target_path, dir);
    } else {
        try fetchTemplates(allocator, project_name, opts.target_path);
    }
    try generateBuildFiles(allocator, project_name, opts.target_path, opts.platform_path);
    initGitRepo(allocator, project_name, opts.target_path, opts.platform_path);
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

/// Parse CLI args: positional target path plus optional flags.
///   zig-webgpu-create-app [options] [directory]
///     --templates-dir=PATH   Copy templates from a local directory instead of fetching from GitHub
///     --platform-path=PATH   Use a local path dependency for zig-webgpu-platform instead of GitHub URL
fn parseCliOptions(allocator: std.mem.Allocator) !CliOptions {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip argv[0].
    _ = args.next();

    var opts: CliOptions = .{ .target_path = undefined };
    var raw_target: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (parseFlag(arg, "--templates-dir=")) |val| {
            opts.templates_dir = try resolveAbsolutePath(allocator, val);
        } else if (parseFlag(arg, "--platform-path=")) |val| {
            opts.platform_path = try resolveAbsolutePath(allocator, val);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            printError("unknown flag: {s}", .{arg});
            std.process.exit(1);
        } else {
            if (raw_target != null) {
                printError("unexpected extra argument: {s}", .{arg});
                std.process.exit(1);
            }
            raw_target = arg;
        }
    }

    if (raw_target) |rp| {
        opts.target_path = try resolveAbsolutePath(allocator, rp);
    } else {
        opts.target_path = try std.process.getCwdAlloc(allocator);
    }

    return opts;
}

/// Extract the value portion of a `--flag=VALUE` argument, or null if it doesn't match.
fn parseFlag(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) {
        return arg[prefix.len..];
    }
    return null;
}

/// Resolve a possibly-relative path to an absolute path.
fn resolveAbsolutePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, raw_path) catch {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        if (std.fs.path.isAbsolute(raw_path)) {
            return try allocator.dupe(u8, raw_path);
        }
        return try std.fs.path.resolve(allocator, &.{ cwd, raw_path });
    };
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

/// Git SSH URL for cloning the repository (works with private repos via SSH key).
const REPO_GIT_URL = "git@github.com:ttrei-org/zig-webgpu-platform.git";

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

/// Copy template files from a local directory, substitute placeholders, and
/// write them into the project directory. Used when --templates-dir is specified.
fn copyLocalTemplates(allocator: std.mem.Allocator, project_name: []const u8, target_path: []const u8, templates_dir: []const u8) !void {
    var src_dir = std.fs.openDirAbsolute(templates_dir, .{}) catch |err| {
        printError("cannot open templates directory '{s}': {s}", .{ templates_dir, @errorName(err) });
        std.process.exit(1);
    };
    defer src_dir.close();

    var dst_dir = try std.fs.openDirAbsolute(target_path, .{});
    defer dst_dir.close();

    for (&TEMPLATE_FILES) |*tmpl| {
        printInfo("  Copying {s}...", .{tmpl.source});

        // Read the source file.
        const content_raw = src_dir.readFileAlloc(allocator, tmpl.source, MAX_RESPONSE_SIZE) catch |err| {
            printError("failed to read template '{s}': {s}", .{ tmpl.source, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(content_raw);

        // Substitute placeholders.
        const content = try substitutePlaceholder(allocator, content_raw, project_name);
        defer allocator.free(content);

        // Create parent directories.
        if (std.fs.path.dirname(tmpl.dest)) |parent| {
            dst_dir.makePath(parent) catch |err| {
                printError("failed to create directory '{s}': {s}", .{ parent, @errorName(err) });
                std.process.exit(1);
            };
        }

        // Write the file.
        var file = dst_dir.createFile(tmpl.dest, .{}) catch |err| {
            printError("failed to create file '{s}': {s}", .{ tmpl.dest, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close();

        file.writeAll(content) catch |err| {
            printError("failed to write file '{s}': {s}", .{ tmpl.dest, @errorName(err) });
            std.process.exit(1);
        };

        if (tmpl.executable) {
            file.setPermissions(.{ .inner = .{ .mode = 0o755 } }) catch |err| {
                printError("failed to set executable permission on '{s}': {s}", .{ tmpl.dest, @errorName(err) });
                std.process.exit(1);
            };
        }
    }
}

/// Fetch all template files by cloning the repository via git SSH,
/// then copying the template files from the clone. This works with
/// private repos because it uses the user's SSH key for authentication.
fn fetchTemplates(allocator: std.mem.Allocator, project_name: []const u8, target_path: []const u8) !void {
    printInfo("Cloning template repository...", .{});

    // Create a temporary directory for the shallow clone.
    const tmp_dir = "/tmp/zig-webgpu-create-app-clone";

    // Remove any leftover temp dir from a previous failed run.
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Shallow-clone the repo with sparse checkout to minimize bandwidth.
    if (!runCommand(allocator, "/tmp", &.{
        "git", "clone", "--depth=1", "--filter=blob:none", "--sparse", REPO_GIT_URL, tmp_dir,
    })) {
        printError(
            "failed to clone {s}\n" ++
                "  Ensure git is installed and you have SSH access to the repository.\n" ++
                "  Alternatively, use --templates-dir to provide templates from a local directory.",
            .{REPO_GIT_URL},
        );
        std.process.exit(1);
    }

    // Set sparse checkout to only fetch the templates directory.
    if (!runCommand(allocator, tmp_dir, &.{
        "git", "sparse-checkout", "set", "create-app/templates",
    })) {
        printError("failed to configure sparse checkout", .{});
        cleanupTmpDir(tmp_dir);
        std.process.exit(1);
    }

    // Now copy templates from the clone using the same logic as copyLocalTemplates.
    const templates_path = tmp_dir ++ "/create-app/templates";
    copyLocalTemplates(allocator, project_name, target_path, templates_path) catch |err| {
        printError("failed to copy templates from clone: {s}", .{@errorName(err)});
        cleanupTmpDir(tmp_dir);
        return err;
    };

    cleanupTmpDir(tmp_dir);
}

/// Remove the temporary clone directory. Best-effort — failures are ignored
/// since leaving a temp dir is harmless.
fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
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

fn generateBuildFiles(allocator: std.mem.Allocator, project_name: []const u8, target_path: []const u8, platform_path: ?[]const u8) !void {
    printInfo("Generating build files...", .{});

    var dir = try std.fs.openDirAbsolute(target_path, .{});
    defer dir.close();

    try writeBuildZig(allocator, dir, project_name);
    try writeBuildZigZon(allocator, dir, project_name, platform_path, target_path);

    // Create src/ directory and write src/main.zig.
    dir.makeDir("src") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try writeMainZig(allocator, dir, project_name);

    // Zig requires a valid fingerprint in build.zig.zon. Run `zig build` once
    // to get the suggested value, then patch the file.
    try fixFingerprint(allocator, target_path);
}

/// Run `zig build` to discover the required fingerprint, then patch build.zig.zon.
/// The placeholder 0x0000000000000000 triggers an error with the correct value.
fn fixFingerprint(allocator: std.mem.Allocator, target_path: []const u8) !void {
    printInfo("Resolving package fingerprint...", .{});

    var child = std.process.Child.init(&.{ "zig", "build" }, allocator);
    child.cwd = target_path;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        printError("could not run 'zig build' for fingerprint detection: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 256 * 1024) catch {};
    _ = child.wait() catch {};

    const stderr_output = stderr_buf.items;

    // Look for: "use this value: 0x<hex>"
    const marker = "use this value: ";
    if (std.mem.indexOf(u8, stderr_output, marker)) |idx| {
        const start = idx + marker.len;
        // Find end of the hex value (until semicolon, newline, or end).
        var end = start;
        while (end < stderr_output.len and stderr_output[end] != '\n' and stderr_output[end] != ';') {
            end += 1;
        }
        const fingerprint_str = stderr_output[start..end];

        // Read the current build.zig.zon and replace the placeholder.
        const zon_path = std.fs.path.join(allocator, &.{ target_path, "build.zig.zon" }) catch unreachable;
        defer allocator.free(zon_path);

        var zon_dir = std.fs.openDirAbsolute(target_path, .{}) catch unreachable;
        defer zon_dir.close();

        const zon_content = zon_dir.readFileAlloc(allocator, "build.zig.zon", MAX_RESPONSE_SIZE) catch |err| {
            printError("failed to read build.zig.zon for fingerprint patching: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(zon_content);

        const patched = substitutePlaceholder2(allocator, zon_content, "0x0000000000000000", fingerprint_str) catch |err| {
            printError("failed to patch fingerprint: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(patched);

        var file = zon_dir.createFile("build.zig.zon", .{}) catch |err| {
            printError("failed to write patched build.zig.zon: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        defer file.close();
        file.writeAll(patched) catch |err| {
            printError("failed to write patched build.zig.zon: {s}", .{@errorName(err)});
            std.process.exit(1);
        };

        printInfo("  Fingerprint resolved: {s}", .{fingerprint_str});
    } else {
        // No fingerprint error — the placeholder was accepted or something else went wrong.
        // Either way, continue and let the user discover any build errors themselves.
        printInfo("  Warning: could not detect fingerprint suggestion from zig build output.", .{});
    }
}

/// Compute a relative path from `from_dir` to `to_path`. Both must be absolute.
/// E.g., from="/tmp/myapp" to="/home/user/platform" → "../../home/user/platform"
fn computeRelativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_path: []const u8) ![]u8 {
    // Split both paths by separator and find the common prefix.
    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(allocator);
    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(allocator);

    var from_iter = std.mem.splitScalar(u8, from_dir, '/');
    while (from_iter.next()) |part| {
        if (part.len > 0) try from_parts.append(allocator, part);
    }
    var to_iter = std.mem.splitScalar(u8, to_path, '/');
    while (to_iter.next()) |part| {
        if (part.len > 0) try to_parts.append(allocator, part);
    }

    // Find common prefix length.
    const min_len = @min(from_parts.items.len, to_parts.items.len);
    var common: usize = 0;
    while (common < min_len and std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) {
        common += 1;
    }

    // Build relative path: go up for each remaining from_part, then down for each remaining to_part.
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    const ups = from_parts.items.len - common;
    for (0..ups) |i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }

    for (to_parts.items[common..]) |part| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }

    if (result.items.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    return try allocator.dupe(u8, result.items);
}

/// Simple string replacement (single occurrence). Like substitutePlaceholder but
/// replaces an arbitrary needle rather than "{{PROJECT_NAME}}".
fn substitutePlaceholder2(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, input, needle)) |idx| {
        const out_len = input.len - needle.len + replacement.len;
        const output = try allocator.alloc(u8, out_len);
        @memcpy(output[0..idx], input[0..idx]);
        @memcpy(output[idx..][0..replacement.len], replacement);
        const tail_start = idx + needle.len;
        @memcpy(output[idx + replacement.len ..][0 .. input.len - tail_start], input[tail_start..]);
        return output;
    }
    return try allocator.dupe(u8, input);
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
        \\const platform_build = @import("zig_webgpu_platform");
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
        \\        // Link Dawn, GLFW, and system dependencies through the platform helper.
        \\        platform_build.linkNativeDeps(platform_dep, exe);
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
/// When platform_path is set, uses a `.path` dependency for local development.
/// Otherwise, uses a `.url` + `.hash` placeholder that `zig fetch --save` will replace.
fn writeBuildZigZon(allocator: std.mem.Allocator, dir: std.fs.Dir, project_name: []const u8, platform_path: ?[]const u8, target_dir_path: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, ".{{\n    .name = .{s},\n", .{project_name});
    // Placeholder fingerprint — will be patched by fixFingerprint() after initial `zig build`.
    try buf.appendSlice(allocator, "    .fingerprint = 0x0000000000000000,\n");
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
        \\
    );

    if (platform_path) |pp| {
        // Zig requires relative paths in build.zig.zon. Compute the relative
        // path from the project directory to the platform source.
        const rel_path = try computeRelativePath(allocator, target_dir_path, pp);
        defer allocator.free(rel_path);
        try buf.print(allocator, "            .path = \"{s}\",\n", .{rel_path});
    } else {
        try buf.appendSlice(allocator,
            \\            .url = "git+https://github.com/ttrei-org/zig-webgpu-platform.git#master",
            \\            .hash = "placeholder_run_zig_fetch_save",
            \\
        );
    }

    try buf.appendSlice(allocator,
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
        \\const builtin = @import("builtin");
        \\const platform = @import("platform");
        \\
        \\const Canvas = platform.Canvas;
        \\const Color = platform.Color;
        \\const AppInterface = platform.AppInterface;
        \\const MouseState = platform.MouseState;
        \\
        \\const is_wasm = builtin.cpu.arch.isWasm();
        \\
        \\// WASM overrides: the default std.log and panic handlers use threads/stderr
        \\// which are not supported on wasm32-emscripten.
        \\pub const std_options: std.Options = .{
        \\    .log_level = .info,
        \\    .logFn = if (is_wasm) wasmLogFn else std.log.defaultLog,
        \\};
        \\
        \\fn wasmLogFn(
        \\    comptime level: std.log.Level,
        \\    comptime scope: @TypeOf(.EnumLiteral),
        \\    comptime format: []const u8,
        \\    args: anytype,
        \\) void {
        \\    _ = level;
        \\    _ = scope;
        \\    _ = format;
        \\    _ = args;
        \\}
        \\
        \\pub const panic = if (is_wasm) WasmPanic else std.debug.FullPanic(std.debug.defaultPanic);
        \\
        \\const WasmPanic = struct {
        \\    pub fn call(_: []const u8, _: ?usize) noreturn { @trap(); }
        \\    pub fn sentinelMismatch(_: anytype, _: anytype) noreturn { @trap(); }
        \\    pub fn unwrapError(_: anyerror) noreturn { @trap(); }
        \\    pub fn outOfBounds(_: usize, _: usize) noreturn { @trap(); }
        \\    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn { @trap(); }
        \\    pub fn inactiveUnionField(_: anytype, _: anytype) noreturn { @trap(); }
        \\    pub fn sliceCastLenRemainder(_: usize) noreturn { @trap(); }
        \\    pub fn reachedUnreachable() noreturn { @trap(); }
        \\    pub fn unwrapNull() noreturn { @trap(); }
        \\    pub fn castToNull() noreturn { @trap(); }
        \\    pub fn incorrectAlignment() noreturn { @trap(); }
        \\    pub fn invalidErrorCode() noreturn { @trap(); }
        \\    pub fn integerOutOfBounds() noreturn { @trap(); }
        \\    pub fn integerOverflow() noreturn { @trap(); }
        \\    pub fn shlOverflow() noreturn { @trap(); }
        \\    pub fn shrOverflow() noreturn { @trap(); }
        \\    pub fn divideByZero() noreturn { @trap(); }
        \\    pub fn exactDivisionRemainder() noreturn { @trap(); }
        \\    pub fn integerPartOutOfBounds() noreturn { @trap(); }
        \\    pub fn corruptSwitch() noreturn { @trap(); }
        \\    pub fn shiftRhsTooBig() noreturn { @trap(); }
        \\    pub fn invalidEnumValue() noreturn { @trap(); }
        \\    pub fn forLenMismatch() noreturn { @trap(); }
        \\    pub fn copyLenMismatch() noreturn { @trap(); }
        \\    pub fn memcpyAlias() noreturn { @trap(); }
        \\    pub fn noreturnReturned() noreturn { @trap(); }
        \\};
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
        \\// For WASM builds, we need a custom entry point.
        \\pub const main = if (!is_wasm) nativeMain else struct {};
        \\
        \\fn nativeMain() void {
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
        \\// WASM entry point: static storage because emscripten_set_main_loop doesn't return.
        \\const wasm_entry = if (is_wasm) struct {
        \\    var static_app: App = undefined;
        \\    var static_iface: AppInterface = undefined;
        \\
        \\    pub fn wasm_main() callconv(.c) void {
        \\        static_app = App.init();
        \\        static_iface = static_app.appInterface();
        \\        platform.run(&static_iface, .{
        \\            .viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },
        \\        });
        \\    }
        \\} else struct {};
        \\
        \\comptime {
        \\    if (is_wasm) {
        \\        @export(&wasm_entry.wasm_main, .{ .name = "wasm_main" });
        \\    }
        \\}
        \\
        \\pub const _start = if (is_wasm) struct {
        \\    fn entry() callconv(.c) void {}
        \\}.entry else {};
        \\
    );

    var src_dir = try dir.openDir("src", .{});
    defer src_dir.close();
    var file = try src_dir.createFile("main.zig", .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Initialize a git repository, add playwright-cli submodule, run zig fetch,
/// and create an initial commit. Git is optional (a warning is printed if
/// missing), but zig is required for the fetch step.
fn initGitRepo(allocator: std.mem.Allocator, project_name: []const u8, target_path: []const u8, platform_path: ?[]const u8) void {
    // Step 1: git init
    printInfo("Initializing git repository...", .{});
    const git_available = runCommand(allocator, target_path, &.{ "git", "init" });

    if (!git_available) {
        printInfo("Warning: git not found or 'git init' failed. Skipping git setup.", .{});
    } else {
        // Step 2: git submodule add playwright-cli
        printInfo("Adding playwright-cli submodule...", .{});
        const submodule_ok = runCommand(allocator, target_path, &.{
            "git",                                                  "submodule",             "add",
            "https://github.com/nicholasgasior/playwright-cli.git", "skills/playwright-cli",
        });
        if (!submodule_ok) {
            printInfo("Warning: failed to add playwright-cli submodule. Continuing...", .{});
        }
    }

    // Step 3: zig fetch --save (only when using remote URL, not local path)
    if (platform_path == null) {
        printInfo("Fetching zig-webgpu-platform dependency (this may take a moment)...", .{});
        const zig_ok = runCommand(allocator, target_path, &.{
            "zig",                                                             "fetch", "--save",
            "git+https://github.com/ttrei-org/zig-webgpu-platform.git#master",
        });
        if (!zig_ok) {
            printError("'zig fetch --save' failed. Ensure zig is installed and you have access to the repository.", .{});
            std.process.exit(1);
        }
    } else {
        printInfo("Using local platform path — skipping zig fetch.", .{});
    }

    // Step 4: git add -A && git commit
    if (git_available) {
        printInfo("Creating initial commit...", .{});
        const add_ok = runCommand(allocator, target_path, &.{ "git", "add", "-A" });
        if (add_ok) {
            _ = runCommand(allocator, target_path, &.{
                "git", "commit", "-m", "Initial project scaffold",
            });
        }
    }

    // Step 5: Success message
    printInfo(
        \\
        \\Project "{s}" created successfully in {s}
        \\
        \\To build and run:
        \\  zig build run          # Native desktop
        \\  zig build -Dtarget=wasm32-emscripten  # Web/WASM build
        \\  python3 serve.py       # Serve web build at http://localhost:8000
        \\
        \\To take screenshots:
        \\  xvfb-run zig build run -- --screenshot=/tmp/screenshot.png  # Native
        \\  ./scripts/web_screenshot.sh /tmp/web_screenshot.png          # Web
    , .{ project_name, target_path });
}

/// Run a command in the given directory. Returns true on success (exit code 0),
/// false if the command could not be spawned or exited with non-zero status.
fn runCommand(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        printInfo("  Could not run '{s}': {s}", .{ argv[0], @errorName(err) });
        return false;
    };

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 256 * 1024) catch |err| {
        printInfo("  Error collecting output from '{s}': {s}", .{ argv[0], @errorName(err) });
        _ = child.wait() catch {};
        return false;
    };

    const term = child.wait() catch |err| {
        printInfo("  Error waiting for '{s}': {s}", .{ argv[0], @errorName(err) });
        return false;
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => {
            printInfo("  '{s}' terminated abnormally", .{argv[0]});
            return false;
        },
    };

    if (exit_code != 0) {
        const stderr_output = stderr_buf.items;
        if (stderr_output.len > 0) {
            printInfo("  '{s}' failed (exit {d}): {s}", .{ argv[0], exit_code, stderr_output });
        } else {
            printInfo("  '{s}' failed with exit code {d}", .{ argv[0], exit_code });
        }
        return false;
    }

    return true;
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
