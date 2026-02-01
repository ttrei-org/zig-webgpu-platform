//! Desktop platform implementation using GLFW
//!
//! Provides window creation and input handling for Linux and Windows
//! desktop environments via the zglfw bindings.

const std = @import("std");
const zglfw = @import("zglfw");

const log = std.log.scoped(.desktop_platform);

/// Error type for desktop platform operations.
pub const Error = error{
    /// GLFW initialization failed.
    GlfwInitFailed,
    /// Window creation failed.
    WindowCreationFailed,
};

/// Desktop platform using GLFW for window management and input handling.
/// This is the primary platform for Linux and Windows builds.
pub const DesktopPlatform = struct {
    const Self = @This();

    window: ?*zglfw.Window,
    allocator: std.mem.Allocator,
    glfw_initialized: bool,

    /// Initialize the desktop platform.
    /// Initializes GLFW and sets window hints for WebGPU (no OpenGL context).
    /// Returns an error if GLFW initialization fails.
    pub fn init(allocator: std.mem.Allocator) Error!Self {
        log.debug("initializing desktop platform", .{});

        zglfw.init() catch |err| {
            log.err("failed to initialize GLFW: {}", .{err});
            return Error.GlfwInitFailed;
        };

        // Set window hints for WebGPU - we don't need an OpenGL context
        zglfw.windowHint(.client_api, .no_api);

        log.info("GLFW initialized successfully", .{});

        return Self{
            .window = null,
            .allocator = allocator,
            .glfw_initialized = true,
        };
    }

    /// Clean up platform resources.
    /// Destroys any window and terminates GLFW if it was initialized.
    pub fn deinit(self: *Self) void {
        log.debug("deinitializing desktop platform", .{});
        if (self.window) |window| {
            window.destroy();
            self.window = null;
        }
        if (self.glfw_initialized) {
            zglfw.terminate();
            self.glfw_initialized = false;
            log.info("GLFW terminated", .{});
        }
    }

    /// Create a new window with the specified dimensions and title.
    /// Uses glfwCreateWindow() to create the window. The window handle is stored
    /// in the platform struct for later use in rendering and input handling.
    pub fn createWindow(self: *Self, width: u32, height: u32, title: [:0]const u8) Error!void {
        log.debug("creating window: {}x{} \"{}\"", .{ width, height, title.ptr });

        const window = zglfw.Window.create(
            @intCast(width),
            @intCast(height),
            title,
            null,
            null,
        ) catch |err| {
            log.err("failed to create GLFW window: {}", .{err});
            return Error.WindowCreationFailed;
        };

        self.window = window;
        log.info("window created successfully: {}x{}", .{ width, height });
    }

    /// Poll for pending events and process them.
    pub fn pollEvents(self: *Self) void {
        if (self.glfw_initialized) {
            zglfw.pollEvents();
        }
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
    // GLFW initialization may fail on headless systems (e.g., CI without display)
    var platform = DesktopPlatform.init(std.testing.allocator) catch |err| {
        // Skip test if GLFW can't initialize (no display available)
        log.warn("skipping test: GLFW init failed with {}", .{err});
        return;
    };
    defer platform.deinit();

    // Verify initialization state
    try std.testing.expect(platform.glfw_initialized);
    // Window should be null before creation
    try std.testing.expect(platform.window == null);
    try std.testing.expect(!platform.shouldClose());
}
