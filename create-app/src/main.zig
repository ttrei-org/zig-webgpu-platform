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

    // Subsequent steps (implemented by later beads)
    fetchTemplates(project_name, target_path);
    generateBuildFiles(project_name, target_path);
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
// Stub functions for subsequent beads
// ---------------------------------------------------------------------------

fn fetchTemplates(_: []const u8, _: []const u8) void {
    printInfo("TODO: fetch template files", .{});
}

fn generateBuildFiles(_: []const u8, _: []const u8) void {
    printInfo("TODO: generate build.zig, build.zig.zon, and src/main.zig", .{});
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
