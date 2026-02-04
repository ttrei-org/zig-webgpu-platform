//! Application interface for the platform framework
//!
//! Defines the contract between the platform's frame orchestrator and application
//! implementations. Any struct that provides the required methods can be used as
//! an application by implementing the vtable pattern.
//!
//! This decouples the platform framework from any concrete application, making it
//! reusable as a library. The concrete App in app.zig is one implementation.
//!
//! The interface follows the same vtable pattern used by Platform (platform.zig)
//! and RenderTarget (render_target.zig).

const std = @import("std");

const platform_mod = @import("platform.zig");
const MouseState = platform_mod.MouseState;

const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;

/// Application interface for the platform's frame orchestrator.
///
/// The frame orchestrator calls these methods each frame:
/// 1. `update(delta_time, mouse_state)` — advance application state
/// 2. `render(canvas)` — issue draw commands
/// 3. `isRunning()` — check if the app wants to continue
///
/// Optional methods:
/// - `requestQuit()` — signal the app to stop (e.g., on Escape key)
/// - `shouldTakeScreenshot()` — check if a screenshot is pending
/// - `onScreenshotComplete()` — notify the app that a screenshot was taken
///
/// Usage:
/// ```zig
/// var app = MyApp.init(allocator);
/// var iface = app.appInterface();
/// // The frame orchestrator now uses iface instead of the concrete type
/// iface.update(dt, mouse);
/// iface.render(&canvas);
/// ```
pub const AppInterface = struct {
    const Self = @This();

    /// Opaque pointer to the concrete application struct.
    /// Cast back to the concrete type in the function pointer implementations.
    context: *anyopaque,

    // Required function pointers — every app must provide these.

    /// Called once per frame to advance application state.
    /// delta_time is seconds since last frame; mouse_state is in logical viewport coords.
    updateFn: *const fn (self: *Self, delta_time: f32, mouse_state: MouseState) void,

    /// Called once per frame to issue draw commands via the Canvas.
    renderFn: *const fn (self: *Self, canvas: *Canvas) void,

    /// Returns true if the application should continue running.
    isRunningFn: *const fn (self: *const Self) bool,

    /// Request the application to stop gracefully.
    requestQuitFn: *const fn (self: *Self) void,

    /// Clean up application resources.
    deinitFn: *const fn (self: *Self) void,

    // Optional function pointers — for screenshot workflow.
    // Null if the app does not support screenshots.

    /// Check if a screenshot should be taken after the current frame.
    /// Returns the screenshot path if pending, null otherwise.
    shouldTakeScreenshotFn: ?*const fn (self: *const Self) ?[]const u8,

    /// Called after a screenshot has been successfully taken.
    onScreenshotCompleteFn: ?*const fn (self: *Self) void,

    // Public API methods that delegate to the function pointers.

    /// Advance application state for the current frame.
    pub fn update(self: *Self, delta_time: f32, mouse_state: MouseState) void {
        self.updateFn(self, delta_time, mouse_state);
    }

    /// Issue draw commands for the current frame.
    pub fn render(self: *Self, canvas: *Canvas) void {
        self.renderFn(self, canvas);
    }

    /// Check if the application should continue running.
    pub fn isRunning(self: *const Self) bool {
        return self.isRunningFn(self);
    }

    /// Request the application to stop gracefully.
    pub fn requestQuit(self: *Self) void {
        self.requestQuitFn(self);
    }

    /// Clean up application resources.
    pub fn deinit(self: *Self) void {
        self.deinitFn(self);
    }

    /// Check if a screenshot should be taken after the current frame.
    /// Returns the screenshot path if pending, null if the app doesn't support
    /// screenshots or no screenshot is pending.
    pub fn shouldTakeScreenshot(self: *const Self) ?[]const u8 {
        if (self.shouldTakeScreenshotFn) |func| {
            return func(self);
        }
        return null;
    }

    /// Notify the app that a screenshot was taken.
    /// No-op if the app doesn't support screenshots.
    pub fn onScreenshotComplete(self: *Self) void {
        if (self.onScreenshotCompleteFn) |func| {
            func(self);
        }
    }
};

test "AppInterface struct has expected function pointers" {
    // Compile-time check: verify the struct has all expected fields.
    // This test passes if the module compiles without errors.
    const info = @typeInfo(AppInterface);
    const fields = info.@"struct".fields;

    // Should have context + 5 required fn pointers + 2 optional fn pointers = 8 fields
    try std.testing.expectEqual(@as(usize, 8), fields.len);
}

test "AppInterface methods delegate correctly" {
    // Verify that the public API methods compile and have correct signatures.
    // We test the optional method null-handling without needing a real implementation.
    var iface: AppInterface = .{
        .context = undefined,
        .updateFn = undefined,
        .renderFn = undefined,
        .isRunningFn = undefined,
        .requestQuitFn = undefined,
        .deinitFn = undefined,
        .shouldTakeScreenshotFn = null,
        .onScreenshotCompleteFn = null,
    };

    // Optional methods should return null / no-op when function pointers are null
    try std.testing.expectEqual(@as(?[]const u8, null), iface.shouldTakeScreenshot());
    iface.onScreenshotComplete(); // Should be a no-op, not crash
}
