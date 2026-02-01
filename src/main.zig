//! Zig GUI Experiment - Main entry point
//!
//! A GPU-accelerated terminal emulator experiment using zgpu and zglfw.

const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

const desktop = @import("platform/desktop.zig");

const log = std.log.scoped(.main);

// Export zgpu types for use in other modules
pub const GraphicsContext = zgpu.GraphicsContext;

pub fn main() void {
    log.info("zig-gui-experiment starting", .{});

    // Initialize platform
    var platform = desktop.DesktopPlatform.init(std.heap.page_allocator) catch |err| {
        log.err("failed to initialize platform: {}", .{err});
        return;
    };
    defer platform.deinit();

    // Create window
    platform.createWindow(800, 600, "Zig GUI Experiment") catch |err| {
        log.err("failed to create window: {}", .{err});
        return;
    };

    log.info("entering main loop", .{});

    // Main loop: poll events until window close is requested
    while (!platform.shouldClose()) {
        platform.pollEvents();
    }

    log.info("zig-gui-experiment exiting", .{});
}
