//! Platform abstraction interface
//!
//! Defines a common interface for platform-specific functionality, enabling
//! the application to run on desktop (GLFW), web (WASM), or headless backends.
//! The Platform struct uses function pointers to allow runtime polymorphism
//! without dynamic dispatch overhead when inlined.

const std = @import("std");
const builtin = @import("builtin");

/// True if building for native desktop (not WASM/web)
pub const is_native = !builtin.cpu.arch.isWasm();

/// zglfw is only available on native desktop builds
const zglfw = if (is_native) @import("zglfw") else struct {
    pub const Window = opaque {};
};

const log = std.log.scoped(.platform);

/// Mouse button identifiers for input handling.
pub const MouseButton = enum {
    left,
    right,
    middle,
};

/// Platform event representing user input or window state changes.
///
/// Events are returned from pollEvents() for the main loop to process.
/// This tagged union is designed to be extensible for additional event
/// types such as keyboard input.
pub const PlatformEvent = union(enum) {
    /// No event available (used when polling returns nothing).
    none,

    /// Window close or application exit request.
    /// The main loop should terminate when receiving this event.
    quit,

    /// Mouse cursor movement event.
    mouse_move: struct {
        /// X position in screen coordinates (pixels from left edge).
        x: f32,
        /// Y position in screen coordinates (pixels from top edge).
        y: f32,
    },

    /// Mouse button press or release event.
    mouse_button: struct {
        /// Which button was pressed or released.
        button: MouseButton,
        /// True if the button was pressed, false if released.
        pressed: bool,
    },
};

/// Mouse state containing position and button states.
pub const MouseState = struct {
    /// X position in screen coordinates (pixels from left edge).
    x: f32,
    /// Y position in screen coordinates (pixels from top edge).
    y: f32,
    /// Left mouse button is pressed.
    left_pressed: bool,
    /// Right mouse button is pressed.
    right_pressed: bool,
    /// Middle mouse button is pressed.
    middle_pressed: bool,

    /// Check if a button is currently pressed.
    pub fn isPressed(self: MouseState, button: MouseButton) bool {
        return switch (button) {
            .left => self.left_pressed,
            .right => self.right_pressed,
            .middle => self.middle_pressed,
        };
    }

    /// Detect if a button was just pressed this frame.
    /// Returns true if the button is pressed now but was not pressed in the previous state.
    /// Useful for triggering one-shot actions on click (e.g., button activation, selection).
    pub fn buttonJustPressed(current: MouseState, prev: MouseState, button: MouseButton) bool {
        return current.isPressed(button) and !prev.isPressed(button);
    }

    /// Detect if a button was just released this frame.
    /// Returns true if the button is not pressed now but was pressed in the previous state.
    /// Useful for triggering actions on mouse up (e.g., drag end, button release confirmation).
    pub fn buttonJustReleased(current: MouseState, prev: MouseState, button: MouseButton) bool {
        return !current.isPressed(button) and prev.isPressed(button);
    }
};

/// Key identifiers for keyboard input.
/// Currently exposes commonly needed keys; extend as needed.
pub const Key = enum {
    escape,
    space,
    enter,
    up,
    down,
    left,
    right,
    // Add more keys as needed
};

/// Size structure for window and framebuffer dimensions.
pub const Size = struct {
    width: u32,
    height: u32,
};

/// Platform-agnostic interface for window management and input handling.
///
/// This struct provides a unified API across different backends:
/// - Desktop (GLFW): Full windowing and input support
/// - Web (WASM): Canvas-based rendering with browser events
/// - Headless: Minimal implementation for testing/CI
///
/// The interface uses function pointers to enable runtime backend selection
/// while keeping the calling code simple and type-safe.
pub const Platform = struct {
    const Self = @This();

    /// Opaque pointer to backend-specific context (e.g., DesktopPlatform).
    /// Cast back to the concrete type in the function pointer implementations.
    context: *anyopaque,

    /// Memory allocator for dynamic allocations.
    allocator: std.mem.Allocator,

    // Function pointer vtable for polymorphic dispatch.
    // Each backend provides implementations for these operations.

    /// Clean up platform resources.
    deinitFn: *const fn (self: *Self) void,

    /// Poll for and process pending input events.
    pollEventsFn: *const fn (self: *Self) void,

    /// Check if the platform has requested quit (e.g., window close button).
    shouldQuitFn: *const fn (self: *const Self) bool,

    /// Get the current mouse state (position and button states).
    getMouseStateFn: *const fn (self: *const Self) MouseState,

    /// Check if a specific key is currently pressed.
    isKeyPressedFn: *const fn (self: *const Self, key: Key) bool,

    /// Get the window size in screen coordinates.
    getWindowSizeFn: *const fn (self: *const Self) Size,

    /// Get the framebuffer size in pixels (may differ on high-DPI displays).
    getFramebufferSizeFn: *const fn (self: *const Self) Size,

    /// Get the native window handle for renderer initialization.
    /// Returns null if no window has been created.
    getWindowFn: *const fn (self: *const Self) ?*zglfw.Window,

    // Public API methods that delegate to the function pointers.
    // These provide a clean interface for callers.

    /// Clean up platform resources.
    /// Call this when shutting down the application.
    pub fn deinit(self: *Self) void {
        self.deinitFn(self);
    }

    /// Poll for and process pending input events.
    /// Call this once per frame to update input state.
    pub fn pollEvents(self: *Self) void {
        self.pollEventsFn(self);
    }

    /// Check if the platform has requested application quit.
    /// Returns true if the window close button was clicked or equivalent.
    pub fn shouldQuit(self: *const Self) bool {
        return self.shouldQuitFn(self);
    }

    /// Get the current mouse state including position and button states.
    pub fn getMouseState(self: *const Self) MouseState {
        return self.getMouseStateFn(self);
    }

    /// Check if a specific key is currently pressed.
    pub fn isKeyPressed(self: *const Self, key: Key) bool {
        return self.isKeyPressedFn(self, key);
    }

    /// Get the window size in screen coordinates.
    pub fn getWindowSize(self: *const Self) Size {
        return self.getWindowSizeFn(self);
    }

    /// Get the framebuffer size in pixels.
    /// May differ from window size on high-DPI/Retina displays.
    pub fn getFramebufferSize(self: *const Self) Size {
        return self.getFramebufferSizeFn(self);
    }

    /// Get the native window handle for renderer initialization.
    /// Returns null if no window has been created.
    pub fn getWindow(self: *const Self) ?*zglfw.Window {
        return self.getWindowFn(self);
    }
};

test "MouseState.isPressed returns correct button state" {
    const state: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = true,
        .right_pressed = false,
        .middle_pressed = true,
    };

    try std.testing.expect(state.isPressed(.left));
    try std.testing.expect(!state.isPressed(.right));
    try std.testing.expect(state.isPressed(.middle));
}

test "MouseState.buttonJustPressed detects press transitions" {
    const prev: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = false,
        .right_pressed = true,
        .middle_pressed = false,
    };
    const current: MouseState = .{
        .x = 10,
        .y = 20,
        .left_pressed = true, // Just pressed
        .right_pressed = true, // Still held
        .middle_pressed = false, // Still released
    };

    // Left was just pressed (false -> true)
    try std.testing.expect(MouseState.buttonJustPressed(current, prev, .left));
    // Right is held, not just pressed (true -> true)
    try std.testing.expect(!MouseState.buttonJustPressed(current, prev, .right));
    // Middle is still released (false -> false)
    try std.testing.expect(!MouseState.buttonJustPressed(current, prev, .middle));
}

test "MouseState.buttonJustPressed returns false on release" {
    const prev: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = true,
        .right_pressed = false,
        .middle_pressed = false,
    };
    const current: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = false, // Just released
        .right_pressed = false,
        .middle_pressed = false,
    };

    // Left was released, not pressed (true -> false)
    try std.testing.expect(!MouseState.buttonJustPressed(current, prev, .left));
}

test "MouseState.buttonJustReleased detects release transitions" {
    const prev: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = true, // Was pressed
        .right_pressed = false,
        .middle_pressed = true, // Was pressed
    };
    const current: MouseState = .{
        .x = 10,
        .y = 20,
        .left_pressed = false, // Just released
        .right_pressed = false, // Still released
        .middle_pressed = true, // Still held
    };

    // Left was just released (true -> false)
    try std.testing.expect(MouseState.buttonJustReleased(current, prev, .left));
    // Right is still released, not just released (false -> false)
    try std.testing.expect(!MouseState.buttonJustReleased(current, prev, .right));
    // Middle is held, not released (true -> true)
    try std.testing.expect(!MouseState.buttonJustReleased(current, prev, .middle));
}

test "MouseState.buttonJustReleased returns false on press" {
    const prev: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = false,
        .right_pressed = false,
        .middle_pressed = false,
    };
    const current: MouseState = .{
        .x = 0,
        .y = 0,
        .left_pressed = true, // Just pressed
        .right_pressed = false,
        .middle_pressed = false,
    };

    // Left was pressed, not released (false -> true)
    try std.testing.expect(!MouseState.buttonJustReleased(current, prev, .left));
}
