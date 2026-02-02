//! Desktop platform implementation using GLFW
//!
//! Provides window creation and input handling for Linux and Windows
//! desktop environments via the zglfw bindings. Implements the Platform
//! interface defined in platform.zig.

const std = @import("std");
const zglfw = @import("zglfw");

const platform_mod = @import("../platform.zig");
const Platform = platform_mod.Platform;
const MouseState = platform_mod.MouseState;
const Key = platform_mod.Key;
const Size = platform_mod.Size;

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
        log.debug("creating window: {}x{} \"{s}\"", .{ width, height, title });

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
        _ = self;
        zglfw.pollEvents();
    }

    /// Check if the window should close.
    pub fn shouldClose(self: *const Self) bool {
        if (self.window) |window| {
            return window.shouldClose();
        }
        return false;
    }

    /// Get the current window size in pixels.
    pub fn getWindowSize(self: *const Self) Size {
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
    pub fn getFramebufferSize(self: *const Self) Size {
        if (self.window) |window| {
            const size = window.getFramebufferSize();
            return .{
                .width = @intCast(size[0]),
                .height = @intCast(size[1]),
            };
        }
        return .{ .width = 0, .height = 0 };
    }

    /// Check if a key is currently pressed.
    pub fn isKeyPressed(self: *const Self, key: Key) bool {
        if (self.window) |window| {
            const glfw_key = keyToGlfw(key);
            return window.getKey(glfw_key) == .press;
        }
        return false;
    }

    /// Check if a GLFW key is currently pressed (direct GLFW key code).
    pub fn isGlfwKeyPressed(self: *const Self, key: zglfw.Key) bool {
        if (self.window) |window| {
            return window.getKey(key) == .press;
        }
        return false;
    }

    /// Get the current mouse state.
    pub fn getMouseState(self: *const Self) MouseState {
        if (self.window) |window| {
            const pos = window.getCursorPos();
            const left = window.getMouseButton(.left) == .press;
            const right = window.getMouseButton(.right) == .press;
            const middle = window.getMouseButton(.middle) == .press;
            return .{
                .x = @floatCast(pos[0]),
                .y = @floatCast(pos[1]),
                .left_pressed = left,
                .right_pressed = right,
                .middle_pressed = middle,
            };
        }
        return .{
            .x = 0,
            .y = 0,
            .left_pressed = false,
            .right_pressed = false,
            .middle_pressed = false,
        };
    }

    /// Convert platform-agnostic Key to GLFW key code.
    fn keyToGlfw(key: Key) zglfw.Key {
        return switch (key) {
            .escape => .escape,
            .space => .space,
            .enter => .enter,
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
        };
    }

    // Platform interface implementation functions.
    // These are the vtable entries that delegate to the concrete methods.

    fn platformDeinit(p: *Platform) void {
        const self: *Self = @ptrCast(@alignCast(p.context));
        self.deinit();
    }

    fn platformPollEvents(p: *Platform) void {
        const self: *Self = @ptrCast(@alignCast(p.context));
        self.pollEvents();
    }

    fn platformShouldQuit(p: *const Platform) bool {
        const self: *const Self = @ptrCast(@alignCast(p.context));
        return self.shouldClose();
    }

    fn platformGetMouseState(p: *const Platform) MouseState {
        const self: *const Self = @ptrCast(@alignCast(p.context));
        return self.getMouseState();
    }

    fn platformIsKeyPressed(p: *const Platform, key: Key) bool {
        const self: *const Self = @ptrCast(@alignCast(p.context));
        return self.isKeyPressed(key);
    }

    fn platformGetWindowSize(p: *const Platform) Size {
        const self: *const Self = @ptrCast(@alignCast(p.context));
        return self.getWindowSize();
    }

    fn platformGetFramebufferSize(p: *const Platform) Size {
        const self: *const Self = @ptrCast(@alignCast(p.context));
        return self.getFramebufferSize();
    }

    fn platformGetWindow(p: *const Platform) ?*zglfw.Window {
        const self: *const Self = @ptrCast(@alignCast(p.context));
        return self.window;
    }

    /// Create a Platform interface from this DesktopPlatform.
    /// The returned Platform delegates to this DesktopPlatform's methods.
    /// The DesktopPlatform must outlive the returned Platform.
    pub fn platform(self: *Self) Platform {
        return .{
            .context = self,
            .allocator = self.allocator,
            .deinitFn = platformDeinit,
            .pollEventsFn = platformPollEvents,
            .shouldQuitFn = platformShouldQuit,
            .getMouseStateFn = platformGetMouseState,
            .isKeyPressedFn = platformIsKeyPressed,
            .getWindowSizeFn = platformGetWindowSize,
            .getFramebufferSizeFn = platformGetFramebufferSize,
            .getWindowFn = platformGetWindow,
        };
    }
};

test "DesktopPlatform init and deinit" {
    // GLFW initialization may fail on headless systems (e.g., CI without display)
    var desktop_platform = DesktopPlatform.init(std.testing.allocator) catch |err| {
        // Skip test if GLFW can't initialize (no display available)
        log.warn("skipping test: GLFW init failed with {}", .{err});
        return;
    };
    defer desktop_platform.deinit();

    // Verify initialization state
    try std.testing.expect(desktop_platform.glfw_initialized);
    // Window should be null before creation
    try std.testing.expect(desktop_platform.window == null);
    try std.testing.expect(!desktop_platform.shouldClose());
}

test "DesktopPlatform platform interface" {
    // GLFW initialization may fail on headless systems (e.g., CI without display)
    var desktop_platform = DesktopPlatform.init(std.testing.allocator) catch |err| {
        // Skip test if GLFW can't initialize (no display available)
        log.warn("skipping test: GLFW init failed with {}", .{err});
        return;
    };
    defer desktop_platform.deinit();

    // Get the platform interface
    const p = desktop_platform.platform();

    // Test that the interface works
    try std.testing.expect(!p.shouldQuit());
    try std.testing.expect(p.getWindow() == null);

    const size = p.getWindowSize();
    try std.testing.expectEqual(@as(u32, 0), size.width);
    try std.testing.expectEqual(@as(u32, 0), size.height);
}
