//! zig-webgpu-create-app: scaffolding tool for new zig-webgpu-platform projects.
//!
//! Creates a ready-to-build project directory with build configuration,
//! template files, and git repository initialization.

const std = @import("std");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print("zig-webgpu-create-app: not yet implemented\n", .{});
}
