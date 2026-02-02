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
/// Core Emscripten runtime functions are available via std.os.emscripten.
/// HTML5 event APIs (mouse, keyboard, etc.) are defined here as they are not
/// part of Zig's standard library.
const emscripten = struct {
    // Re-export core runtime functions from std.os.emscripten for convenience
    const std_em = std.os.emscripten;

    /// Main loop callback function type.
    pub const em_callback_func = std_em.em_callback_func;

    /// Main loop callback with user data.
    pub const em_arg_callback_func = std_em.em_arg_callback_func;

    /// Set the main loop callback. The browser calls this each frame.
    /// @param fps: Target FPS (0 = use requestAnimationFrame)
    /// @param simulate_infinite_loop: If 1, function doesn't return
    pub const emscripten_set_main_loop = std_em.emscripten_set_main_loop;

    /// Set main loop with user data pointer passed to callback.
    pub const emscripten_set_main_loop_arg = std_em.emscripten_set_main_loop_arg;

    /// Cancel the main loop.
    pub const emscripten_cancel_main_loop = std_em.emscripten_cancel_main_loop;

    /// Get canvas size (deprecated but still available).
    pub const emscripten_get_canvas_size = std_em.emscripten_get_canvas_size;

    /// Set canvas size (deprecated but still available).
    pub const emscripten_set_canvas_size = std_em.emscripten_set_canvas_size;

    /// Get device pixel ratio for high-DPI displays.
    pub const emscripten_get_device_pixel_ratio = std_em.emscripten_get_device_pixel_ratio;

    /// Get high-resolution timestamp in milliseconds.
    pub const emscripten_get_now = std_em.emscripten_get_now;

    /// Get screen dimensions.
    pub const emscripten_get_screen_size = std_em.emscripten_get_screen_size;

    // =========================================================================
    // HTML5 Event API Types and Functions
    // These are not in std.os.emscripten and must be declared as extern.
    // =========================================================================

    /// Result codes for Emscripten HTML5 API functions.
    pub const EMSCRIPTEN_RESULT = c_int;
    pub const EMSCRIPTEN_RESULT_SUCCESS: EMSCRIPTEN_RESULT = 0;
    pub const EMSCRIPTEN_RESULT_DEFERRED: EMSCRIPTEN_RESULT = 1;
    pub const EMSCRIPTEN_RESULT_NOT_SUPPORTED: EMSCRIPTEN_RESULT = -1;
    pub const EMSCRIPTEN_RESULT_FAILED_NOT_DEFERRED: EMSCRIPTEN_RESULT = -2;
    pub const EMSCRIPTEN_RESULT_INVALID_TARGET: EMSCRIPTEN_RESULT = -3;
    pub const EMSCRIPTEN_RESULT_UNKNOWN_TARGET: EMSCRIPTEN_RESULT = -4;
    pub const EMSCRIPTEN_RESULT_INVALID_PARAM: EMSCRIPTEN_RESULT = -5;
    pub const EMSCRIPTEN_RESULT_FAILED: EMSCRIPTEN_RESULT = -6;
    pub const EMSCRIPTEN_RESULT_NO_DATA: EMSCRIPTEN_RESULT = -7;

    /// Event type constants for HTML5 events.
    pub const EMSCRIPTEN_EVENT_KEYPRESS: c_int = 1;
    pub const EMSCRIPTEN_EVENT_KEYDOWN: c_int = 2;
    pub const EMSCRIPTEN_EVENT_KEYUP: c_int = 3;
    pub const EMSCRIPTEN_EVENT_CLICK: c_int = 4;
    pub const EMSCRIPTEN_EVENT_MOUSEDOWN: c_int = 5;
    pub const EMSCRIPTEN_EVENT_MOUSEUP: c_int = 6;
    pub const EMSCRIPTEN_EVENT_DBLCLICK: c_int = 7;
    pub const EMSCRIPTEN_EVENT_MOUSEMOVE: c_int = 8;
    pub const EMSCRIPTEN_EVENT_WHEEL: c_int = 9;
    pub const EMSCRIPTEN_EVENT_RESIZE: c_int = 10;

    /// String length constants for HTML5 event structs.
    pub const EM_HTML5_SHORT_STRING_LEN_BYTES = 32;
    pub const EM_HTML5_LONG_STRING_LEN_BYTES = 128;

    /// Mouse event data structure.
    /// Matches the C struct EmscriptenMouseEvent from html5.h.
    pub const EmscriptenMouseEvent = extern struct {
        timestamp: f64,
        screenX: c_int,
        screenY: c_int,
        clientX: c_int,
        clientY: c_int,
        ctrlKey: bool,
        shiftKey: bool,
        altKey: bool,
        metaKey: bool,
        button: c_ushort,
        buttons: c_ushort,
        movementX: c_int,
        movementY: c_int,
        targetX: c_int,
        targetY: c_int,
        canvasX: c_int,
        canvasY: c_int,
        padding: c_int,
    };

    /// Keyboard event data structure.
    /// Matches the C struct EmscriptenKeyboardEvent from html5.h.
    pub const EmscriptenKeyboardEvent = extern struct {
        timestamp: f64,
        location: c_uint,
        ctrlKey: bool,
        shiftKey: bool,
        altKey: bool,
        metaKey: bool,
        repeat: bool,
        charCode: c_uint,
        keyCode: c_uint,
        which: c_uint,
        key: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
        code: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
        charValue: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
        locale: [EM_HTML5_SHORT_STRING_LEN_BYTES]u8,
    };

    /// Wheel event data structure.
    /// Matches the C struct EmscriptenWheelEvent from html5.h.
    pub const EmscriptenWheelEvent = extern struct {
        mouse: EmscriptenMouseEvent,
        deltaX: f64,
        deltaY: f64,
        deltaZ: f64,
        deltaMode: c_uint,
    };

    /// UI event data structure (for resize/scroll events).
    /// Matches the C struct EmscriptenUiEvent from html5.h.
    pub const EmscriptenUiEvent = extern struct {
        detail: c_int,
        documentBodyClientWidth: c_int,
        documentBodyClientHeight: c_int,
        windowInnerWidth: c_int,
        windowInnerHeight: c_int,
        windowOuterWidth: c_int,
        windowOuterHeight: c_int,
        scrollTop: c_int,
        scrollLeft: c_int,
    };

    /// Mouse event callback function type.
    /// Returns true to indicate event was consumed, false to propagate.
    pub const em_mouse_callback_func = ?*const fn (
        event_type: c_int,
        mouse_event: *const EmscriptenMouseEvent,
        user_data: ?*anyopaque,
    ) callconv(.c) bool;

    /// Keyboard event callback function type.
    pub const em_key_callback_func = ?*const fn (
        event_type: c_int,
        key_event: *const EmscriptenKeyboardEvent,
        user_data: ?*anyopaque,
    ) callconv(.c) bool;

    /// Wheel event callback function type.
    pub const em_wheel_callback_func = ?*const fn (
        event_type: c_int,
        wheel_event: *const EmscriptenWheelEvent,
        user_data: ?*anyopaque,
    ) callconv(.c) bool;

    /// UI event callback function type (resize, scroll).
    pub const em_ui_callback_func = ?*const fn (
        event_type: c_int,
        ui_event: *const EmscriptenUiEvent,
        user_data: ?*anyopaque,
    ) callconv(.c) bool;

    // =========================================================================
    // Mouse Event Registration Functions
    // =========================================================================

    /// Register a callback for mouse click events on a target element.
    pub extern "c" fn emscripten_set_click_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for mouse down events.
    pub extern "c" fn emscripten_set_mousedown_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for mouse up events.
    pub extern "c" fn emscripten_set_mouseup_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for mouse move events.
    pub extern "c" fn emscripten_set_mousemove_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for mouse enter events.
    pub extern "c" fn emscripten_set_mouseenter_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for mouse leave events.
    pub extern "c" fn emscripten_set_mouseleave_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    // =========================================================================
    // Keyboard Event Registration Functions
    // =========================================================================

    /// Register a callback for key press events.
    pub extern "c" fn emscripten_set_keypress_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_key_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for key down events.
    pub extern "c" fn emscripten_set_keydown_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_key_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    /// Register a callback for key up events.
    pub extern "c" fn emscripten_set_keyup_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_key_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    // =========================================================================
    // Wheel Event Registration Functions
    // =========================================================================

    /// Register a callback for mouse wheel events.
    pub extern "c" fn emscripten_set_wheel_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_wheel_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    // =========================================================================
    // UI Event Registration Functions
    // =========================================================================

    /// Register a callback for window/element resize events.
    pub extern "c" fn emscripten_set_resize_callback_on_thread(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_ui_callback_func,
        target_thread: c_long,
    ) EMSCRIPTEN_RESULT;

    // =========================================================================
    // Canvas Element Size Functions (HTML5 API)
    // =========================================================================

    /// Get the size of a canvas element in CSS pixels.
    /// @param target: CSS selector for the canvas element (e.g., "#canvas")
    /// @param width: Output parameter for width
    /// @param height: Output parameter for height
    pub extern "c" fn emscripten_get_canvas_element_size(
        target: [*:0]const u8,
        width: *c_int,
        height: *c_int,
    ) EMSCRIPTEN_RESULT;

    /// Set the size of a canvas element in CSS pixels.
    pub extern "c" fn emscripten_set_canvas_element_size(
        target: [*:0]const u8,
        width: c_int,
        height: c_int,
    ) EMSCRIPTEN_RESULT;

    /// Get the CSS size of an element.
    pub extern "c" fn emscripten_get_element_css_size(
        target: [*:0]const u8,
        width: *f64,
        height: *f64,
    ) EMSCRIPTEN_RESULT;

    /// Set the CSS size of an element.
    pub extern "c" fn emscripten_set_element_css_size(
        target: [*:0]const u8,
        width: f64,
        height: f64,
    ) EMSCRIPTEN_RESULT;

    // =========================================================================
    // Event Cleanup
    // =========================================================================

    /// Remove all registered HTML5 event listeners.
    pub extern "c" fn emscripten_html5_remove_all_event_listeners() void;

    // =========================================================================
    // Convenience Constants for Event Targets
    // These magic values are used as target strings in Emscripten.
    // =========================================================================

    /// Target the document object.
    pub const EMSCRIPTEN_EVENT_TARGET_DOCUMENT: [*:0]const u8 = @ptrFromInt(1);
    /// Target the window object.
    pub const EMSCRIPTEN_EVENT_TARGET_WINDOW: [*:0]const u8 = @ptrFromInt(2);

    /// Thread context for callbacks: calling thread (default for single-threaded).
    pub const EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD: c_long = 2;

    // =========================================================================
    // Convenience Wrappers (equivalent to C macros in html5.h)
    // These call the _on_thread variants with the calling thread context.
    // =========================================================================

    /// Set mouse move callback (convenience wrapper).
    pub fn emscripten_set_mousemove_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_mousemove_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }

    /// Set mouse down callback (convenience wrapper).
    pub fn emscripten_set_mousedown_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_mousedown_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }

    /// Set mouse up callback (convenience wrapper).
    pub fn emscripten_set_mouseup_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_mouse_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_mouseup_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }

    /// Set key down callback (convenience wrapper).
    pub fn emscripten_set_keydown_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_key_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_keydown_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }

    /// Set key up callback (convenience wrapper).
    pub fn emscripten_set_keyup_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_key_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_keyup_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }

    /// Set resize callback (convenience wrapper).
    pub fn emscripten_set_resize_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_ui_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_resize_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }

    /// Set wheel callback (convenience wrapper).
    pub fn emscripten_set_wheel_callback(
        target: [*:0]const u8,
        user_data: ?*anyopaque,
        use_capture: bool,
        callback: em_wheel_callback_func,
    ) EMSCRIPTEN_RESULT {
        return emscripten_set_wheel_callback_on_thread(
            target,
            user_data,
            use_capture,
            callback,
            EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD,
        );
    }
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
