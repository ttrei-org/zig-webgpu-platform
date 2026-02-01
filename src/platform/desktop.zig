//! Desktop platform implementation using GLFW
//!
//! Provides window creation and input handling for Linux and Windows
//! desktop environments via the zglfw bindings.

const std = @import("std");
const zglfw = @import("zglfw");

const log = std.log.scoped(.desktop_platform);

/// Desktop platform using GLFW for window management and input handling.
/// This is the primary platform for Linux and Windows builds.
pub const DesktopPlatform = struct {
    const Self = @This();

    window: ?*zglfw.Window,
    allocator: std.mem.Allocator,

    /// Initialize the desktop platform.
    /// Returns an error if GLFW initialization fails.
    pub fn init(allocator: std.mem.Allocator) !Self {
        log.debug("initializing desktop platform", .{});
        return Self{
            .window = null,
            .allocator = allocator,
        };
    }

    /// Clean up platform resources.
    pub fn deinit(self: *Self) void {
        log.debug("deinitializing desktop platform", .{});
        if (self.window) |window| {
            window.destroy();
            self.window = null;
        }
    }

    /// Create a new window with the specified dimensions and title.
    pub fn createWindow(self: *Self, width: u32, height: u32, title: [:0]const u8) !void {
        _ = self;
        _ = width;
        _ = height;
        _ = title;
        // Placeholder: GLFW window creation will be implemented in bd-2lk
        log.debug("createWindow placeholder called", .{});
    }

    /// Poll for pending events and process them.
    pub fn pollEvents(_: *Self) void {
        // Placeholder: will call zglfw.pollEvents()
    }

    /// Check if the window should close.
    pub fn shouldClose(self: *Self) bool {
        if (self.window) |window| {
            return window.shouldClose();
        }
        return false;
    }

    /// Get the current window size in pixels.
    pub fn getWindowSize(self: *Self) struct { width: u32, height: u32 } {
        if (self.window) |window| {
            const size = window.getSize();
            return .{
                .width = @intCast(size[0]),
                .height = @intCast(size[1]),
            };
        }
        return .{ .width = 0, .height = 0 };
    }

    /// Get the framebuffer size (may differ from window size on high-DPI displays).
    pub fn getFramebufferSize(self: *Self) struct { width: u32, height: u32 } {
        if (self.window) |window| {
            const size = window.getFramebufferSize();
            return .{
                .width = @intCast(size[0]),
                .height = @intCast(size[1]),
            };
        }
        return .{ .width = 0, .height = 0 };
    }
};

test "DesktopPlatform init and deinit" {
    var platform = try DesktopPlatform.init(std.testing.allocator);
    defer platform.deinit();

    // Window should be null before creation
    try std.testing.expect(platform.window == null);
    try std.testing.expect(!platform.shouldClose());
}
