//! Headless platform implementation
//!
//! Provides a minimal platform implementation for automated testing and
//! headless rendering. Does not create any windows or require a display.
//! Used with OffscreenRenderTarget for GPU rendering without visual output.

const std = @import("std");
const builtin = @import("builtin");

const main = @import("../main.zig");
const Config = main.Config;

const platform_mod = @import("../platform.zig");
const Platform = platform_mod.Platform;
const MouseState = platform_mod.MouseState;
const Key = platform_mod.Key;
const Size = platform_mod.Size;

/// zglfw is only available on native desktop builds
const zglfw = if (platform_mod.is_native) @import("zglfw") else struct {
    pub const Window = opaque {};
};

const log = std.log.scoped(.headless_platform);

/// Headless platform for automated testing and headless rendering.
/// Does not require a display or create any windows.
/// Provides synthetic input state and timing for deterministic testing.
pub const HeadlessPlatform = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Configured dimensions for the render target.
    width: u32,
    height: u32,
    /// Synthetic frame counter for timing.
    frame_count: u64,
    /// Maximum frames to run in headless mode (0 = unlimited).
    max_frames: u64,
    /// Synthetic mouse state (for testing input handling).
    mouse_state: MouseState,
    /// Whether a quit has been requested.
    quit_requested: bool,

    /// Initialize the headless platform.
    /// Does NOT initialize GLFW or create any windows.
    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        log.info("initializing headless platform (no display required)", .{});
        log.info("headless render dimensions: {}x{}", .{ config.width, config.height });

        // In headless mode with screenshot, we render one frame and exit.
        // Otherwise, we run for a reasonable number of frames for testing.
        const max_frames: u64 = if (config.screenshot_filename != null) 1 else 10;

        return Self{
            .allocator = allocator,
            .width = config.width,
            .height = config.height,
            .frame_count = 0,
            .max_frames = max_frames,
            .mouse_state = .{
                .x = @as(f32, @floatFromInt(config.width)) / 2.0,
                .y = @as(f32, @floatFromInt(config.height)) / 2.0,
                .left_pressed = false,
                .right_pressed = false,
                .middle_pressed = false,
            },
            .quit_requested = false,
        };
    }

    /// Clean up platform resources (no-op for headless).
    pub fn deinit(self: *Self) void {
        log.info("headless platform shutdown after {} frames", .{self.frame_count});
    }

    /// Poll for events (increments frame counter in headless mode).
    pub fn pollEvents(self: *Self) void {
        self.frame_count += 1;
        log.debug("headless frame {}/{}", .{ self.frame_count, self.max_frames });
    }

    /// Check if the platform should quit.
    /// In headless mode, quits after max_frames or when quit is requested.
    pub fn shouldClose(self: *const Self) bool {
        if (self.quit_requested) {
            return true;
        }
        if (self.max_frames > 0 and self.frame_count >= self.max_frames) {
            return true;
        }
        return false;
    }

    /// Request the platform to quit.
    pub fn requestQuit(self: *Self) void {
        self.quit_requested = true;
    }

    /// Get the window/render target size.
    pub fn getWindowSize(self: *const Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Get the framebuffer size (same as window size in headless).
    pub fn getFramebufferSize(self: *const Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Check if a key is currently pressed (always false in headless).
    pub fn isKeyPressed(_: *const Self, _: Key) bool {
        return false;
    }

    /// Get the current mouse state (synthetic for headless).
    pub fn getMouseState(self: *const Self) MouseState {
        return self.mouse_state;
    }

    /// Get the time since initialization (synthetic for headless).
    /// Returns frame_count * 16.67ms to simulate 60 FPS.
    pub fn getTime(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.frame_count)) * (1.0 / 60.0);
    }

    // Platform interface implementation functions.

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

    fn platformGetWindow(_: *const Platform) ?*zglfw.Window {
        // Headless mode has no window
        return null;
    }

    /// Create a Platform interface from this HeadlessPlatform.
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

test "HeadlessPlatform init and deinit" {
    const config: Config = .{ .headless = true, .width = 640, .height = 480 };
    var headless = HeadlessPlatform.init(std.testing.allocator, config);
    defer headless.deinit();

    try std.testing.expectEqual(@as(u32, 640), headless.width);
    try std.testing.expectEqual(@as(u32, 480), headless.height);
    try std.testing.expect(!headless.shouldClose());
}

test "HeadlessPlatform synthetic mouse state" {
    const config: Config = .{ .headless = true, .width = 800, .height = 600 };
    var headless = HeadlessPlatform.init(std.testing.allocator, config);
    defer headless.deinit();

    const mouse = headless.getMouseState();
    // Mouse should be centered
    try std.testing.expectEqual(@as(f32, 400.0), mouse.x);
    try std.testing.expectEqual(@as(f32, 300.0), mouse.y);
}

test "HeadlessPlatform frame counting" {
    const config: Config = .{ .headless = true };
    var headless = HeadlessPlatform.init(std.testing.allocator, config);
    defer headless.deinit();

    // Should not quit initially
    try std.testing.expect(!headless.shouldClose());

    // Poll max_frames times
    for (0..10) |_| {
        headless.pollEvents();
    }

    // Should quit after max_frames
    try std.testing.expect(headless.shouldClose());
}
