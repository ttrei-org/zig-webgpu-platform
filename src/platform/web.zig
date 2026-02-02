//! Web platform implementation for Emscripten/browser environment
//!
//! Provides a platform implementation for WASM builds targeting web browsers.
//! This module is only compiled for wasm32-emscripten targets and implements
//! the Platform interface using browser APIs via Emscripten bindings.
//!
//! Browser APIs are accessed through Emscripten's C-compatible external function
//! imports, which are provided by JavaScript at module instantiation time.

const std = @import("std");
const builtin = @import("builtin");

const platform_mod = @import("../platform.zig");
const Platform = platform_mod.Platform;
const MouseState = platform_mod.MouseState;
const Key = platform_mod.Key;
const Size = platform_mod.Size;

const log = std.log.scoped(.web_platform);

// Compile-time check: this module should only be used for WASM targets.
comptime {
    if (!builtin.cpu.arch.isWasm()) {
        @compileError("web.zig is only for wasm32-emscripten targets");
    }
}

/// External functions imported from JavaScript/Emscripten environment.
/// These are provided by the browser runtime and declared as external symbols
/// that will be linked at WASM instantiation time.
///
/// Note: These are placeholders that will be implemented in a follow-up task
/// (bd-2wo: Define Emscripten external function imports).
const emscripten = struct {
    // Placeholder declarations for future Emscripten imports.
    // These will be filled in when browser-side JavaScript is implemented.
    //
    // Expected imports include:
    // - emscripten_set_main_loop: Register frame callback
    // - emscripten_get_canvas_element_size: Get canvas dimensions
    // - Mouse/keyboard event registration functions
    //
    // For now, we provide stub implementations that enable compilation.
};

/// Web platform for browser-based execution via Emscripten.
/// Implements the Platform interface using browser APIs for input handling
/// and canvas-based rendering.
///
/// This platform differs from desktop/headless in several ways:
/// - No GLFW; uses browser's requestAnimationFrame for the main loop
/// - Canvas element provides the rendering surface
/// - Input events come from DOM event listeners
/// - WebGPU is provided by the browser's navigator.gpu API
pub const WebPlatform = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Canvas/viewport width in pixels.
    width: u32,
    /// Canvas/viewport height in pixels.
    height: u32,
    /// Current mouse state, updated by browser event callbacks.
    mouse_state: MouseState,
    /// Whether a quit has been requested (e.g., page unload).
    quit_requested: bool,
    /// Frame counter for timing and debugging.
    frame_count: u64,

    /// Initialize the web platform.
    /// Sets up initial state; actual browser bindings are established
    /// when JavaScript calls into the WASM module.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Self {
        log.info("initializing web platform for {}x{} canvas", .{ width, height });

        return Self{
            .allocator = allocator,
            .width = width,
            .height = height,
            .mouse_state = .{
                .x = @as(f32, @floatFromInt(width)) / 2.0,
                .y = @as(f32, @floatFromInt(height)) / 2.0,
                .left_pressed = false,
                .right_pressed = false,
                .middle_pressed = false,
            },
            .quit_requested = false,
            .frame_count = 0,
        };
    }

    /// Clean up platform resources.
    /// In the browser, this may trigger cleanup of event listeners.
    pub fn deinit(self: *Self) void {
        log.info("web platform shutdown after {} frames", .{self.frame_count});
        // Future: Remove DOM event listeners registered during init
    }

    /// Poll for events.
    /// In browser context, events are delivered asynchronously via callbacks.
    /// This method increments the frame counter for timing purposes.
    pub fn pollEvents(self: *Self) void {
        self.frame_count += 1;
        // Browser events are handled asynchronously via JavaScript callbacks.
        // The mouse_state and key states are updated by those callbacks.
    }

    /// Check if the platform should quit.
    /// Returns true if quit was requested (e.g., by page navigation or explicit call).
    pub fn shouldClose(self: *const Self) bool {
        return self.quit_requested;
    }

    /// Request the platform to quit.
    /// In browser context, this might trigger cleanup before page unload.
    pub fn requestQuit(self: *Self) void {
        self.quit_requested = true;
    }

    /// Get the canvas/viewport size in pixels.
    pub fn getWindowSize(self: *const Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Get the framebuffer size.
    /// For web, this is the same as canvas size (no high-DPI scaling handled here;
    /// that's managed by CSS devicePixelRatio in JavaScript).
    pub fn getFramebufferSize(self: *const Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Check if a key is currently pressed.
    /// Key state is updated by JavaScript keyboard event handlers.
    pub fn isKeyPressed(_: *const Self, _: Key) bool {
        // TODO: Implement when keyboard bindings are added
        return false;
    }

    /// Get the current mouse state.
    /// Mouse state is updated by JavaScript mouse event handlers.
    pub fn getMouseState(self: *const Self) MouseState {
        return self.mouse_state;
    }

    /// Update mouse position from JavaScript callback.
    /// Called by exported functions that JavaScript invokes on mouse events.
    pub fn updateMousePosition(self: *Self, x: f32, y: f32) void {
        self.mouse_state.x = x;
        self.mouse_state.y = y;
    }

    /// Update mouse button state from JavaScript callback.
    pub fn updateMouseButton(self: *Self, button: platform_mod.MouseButton, pressed: bool) void {
        switch (button) {
            .left => self.mouse_state.left_pressed = pressed,
            .right => self.mouse_state.right_pressed = pressed,
            .middle => self.mouse_state.middle_pressed = pressed,
        }
    }

    /// Update canvas size from JavaScript (e.g., on window resize).
    pub fn updateCanvasSize(self: *Self, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        log.debug("canvas resized to {}x{}", .{ width, height });
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

    fn platformGetWindow(_: *const Platform) ?*anyopaque {
        // Web platform has no GLFW window; returns null.
        // The browser canvas is accessed via JavaScript, not a window pointer.
        return null;
    }

    /// Create a Platform interface from this WebPlatform.
    /// The returned Platform delegates to this WebPlatform's methods.
    /// The WebPlatform must outlive the returned Platform.
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
            .getWindowFn = @ptrCast(&platformGetWindow),
        };
    }
};

// Exported functions for JavaScript to call into WASM.
// These allow the browser to send events to the web platform.

/// Global web platform instance for JavaScript callbacks.
/// This is set when the web platform is initialized and used by exported functions.
var global_web_platform: ?*WebPlatform = null;

/// Set the global web platform instance for JavaScript callbacks.
/// Must be called after WebPlatform.init() to enable event handling.
pub fn setGlobalPlatform(p: *WebPlatform) void {
    global_web_platform = p;
}

/// Clear the global web platform instance.
/// Should be called before WebPlatform.deinit() to prevent dangling pointer.
pub fn clearGlobalPlatform() void {
    global_web_platform = null;
}

/// Exported function for JavaScript to update mouse position.
export fn web_update_mouse_position(x: f32, y: f32) callconv(.c) void {
    if (global_web_platform) |p| {
        p.updateMousePosition(x, y);
    }
}

/// Exported function for JavaScript to update mouse button state.
/// button: 0=left, 1=middle, 2=right (matching DOM MouseEvent.button)
export fn web_update_mouse_button(button: u32, pressed: bool) callconv(.c) void {
    if (global_web_platform) |p| {
        const btn: platform_mod.MouseButton = switch (button) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => return, // Ignore unknown buttons
        };
        p.updateMouseButton(btn, pressed);
    }
}

/// Exported function for JavaScript to update canvas size on resize.
export fn web_update_canvas_size(width: u32, height: u32) callconv(.c) void {
    if (global_web_platform) |p| {
        p.updateCanvasSize(width, height);
    }
}

/// Exported function for JavaScript to request quit (e.g., on page unload).
export fn web_request_quit() callconv(.c) void {
    if (global_web_platform) |p| {
        p.requestQuit();
    }
}
