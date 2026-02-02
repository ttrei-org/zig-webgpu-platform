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

/// Default canvas CSS selector used for Emscripten canvas operations.
/// This matches the default canvas element created by Emscripten's shell HTML.
const DEFAULT_CANVAS_SELECTOR: [*:0]const u8 = "#canvas";

/// Import zgpu for WebGPU types.
/// Used to create WebGPU surface from canvas element.
const zgpu = @import("zgpu");

/// Request a WebGPU adapter from the browser via navigator.gpu.requestAdapter().
///
/// This function initiates an asynchronous request for a WebGPU adapter in the
/// browser environment. In the browser, WebGPU adapters are obtained through
/// the navigator.gpu API, which requires asynchronous handling.
///
/// The adapter represents the browser's WebGPU implementation and is required
/// before requesting a device. Unlike desktop Dawn-based implementations where
/// adapter requests can complete synchronously, browser requests are inherently
/// async due to the JavaScript event loop.
///
/// Parameters:
/// - instance: WebGPU instance from which to request the adapter.
/// - surface: Optional compatible surface for presentation. Pass the surface
///   created from createSurfaceFromCanvas() to ensure the adapter can render
///   to the canvas. Pass null for compute-only workloads.
/// - callback: Function called when the adapter request completes.
/// - userdata: Opaque pointer passed to the callback.
///
/// The callback receives:
/// - status: Success/failure status of the request
/// - adapter: The WebGPU adapter handle (valid only if status is success)
/// - message: Error message if the request failed
/// - userdata: The userdata pointer passed to requestAdapter
///
/// Example:
/// ```zig
/// const Ctx = struct {
///     adapter: ?zgpu.wgpu.Adapter = null,
///     status: zgpu.wgpu.RequestAdapterStatus = .unknown,
/// };
/// var ctx: Ctx = .{};
///
/// requestAdapter(instance, surface, &adapterCallback, &ctx);
/// // ... later, in the main loop or async continuation ...
/// if (ctx.status == .success) {
///     // Use ctx.adapter
/// }
/// ```
///
/// Note: On web, this function returns immediately. The callback is invoked
/// asynchronously when the browser completes the adapter request. You must
/// use Emscripten's main loop or async/await patterns to wait for completion.
pub fn requestAdapter(
    instance: zgpu.wgpu.Instance,
    surface: ?zgpu.wgpu.Surface,
    callback: zgpu.wgpu.RequestAdapterCallback,
    userdata: ?*anyopaque,
) void {
    log.info("requesting WebGPU adapter from browser", .{});

    // Request adapter with high-performance preference.
    // On web, this maps to navigator.gpu.requestAdapter() with powerPreference: "high-performance".
    // The compatible_surface ensures the adapter can present to our canvas.
    instance.requestAdapter(
        .{
            .next_in_chain = null,
            .compatible_surface = surface,
            .power_preference = .high_performance,
            .backend_type = .undef, // Browser chooses (typically WebGPU native)
            .force_fallback_adapter = false,
            .compatibility_mode = false,
        },
        callback,
        userdata,
    );
}

/// Request a WebGPU adapter from the browser synchronously (blocking pattern).
///
/// This is a convenience wrapper that provides a synchronous-looking API for
/// adapter requests. However, on web targets, true synchronous adapter requests
/// are not possible due to the browser's async nature.
///
/// IMPORTANT: This function uses a blocking pattern that may not work correctly
/// in all browser environments. For production use, prefer the async version
/// (requestAdapter) with proper callback handling.
///
/// Parameters:
/// - instance: WebGPU instance from which to request the adapter.
/// - surface: Optional compatible surface for presentation.
///
/// Returns:
/// - The WebGPU adapter if the request succeeded, or null if it failed.
///
/// Note: This function is provided for API compatibility with desktop code paths.
/// In the browser, the actual adapter availability depends on browser WebGPU
/// support and GPU driver availability.
pub fn requestAdapterSync(
    instance: zgpu.wgpu.Instance,
    surface: ?zgpu.wgpu.Surface,
) ?zgpu.wgpu.Adapter {
    const Response = struct {
        adapter: ?zgpu.wgpu.Adapter = null,
        status: zgpu.wgpu.RequestAdapterStatus = .unknown,
    };

    var response: Response = .{};

    // Make the async request.
    // On web, this initiates the request but the callback may not fire
    // until the browser's event loop processes it.
    requestAdapter(instance, surface, &adapterCallback, @ptrCast(&response));

    // Note: In a true browser async environment, we would need to yield
    // to the main loop here. For Emscripten with synchronous WebGPU
    // (which some versions support), this may work directly.

    if (response.status != .success) {
        log.warn("adapter request failed with status: {}", .{response.status});
        return null;
    }

    if (response.adapter) |adapter| {
        log.info("WebGPU adapter obtained successfully", .{});
        return adapter;
    }

    return null;
}

/// Callback for adapter request - stores result in the response struct.
fn adapterCallback(
    status: zgpu.wgpu.RequestAdapterStatus,
    adapter: zgpu.wgpu.Adapter,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const response: *struct {
        adapter: ?zgpu.wgpu.Adapter,
        status: zgpu.wgpu.RequestAdapterStatus,
    } = @ptrCast(@alignCast(userdata));

    response.status = status;

    if (status == .success) {
        response.adapter = adapter;
        log.info("browser WebGPU adapter request succeeded", .{});
    } else {
        const msg = message orelse "unknown error";
        log.err("browser WebGPU adapter request failed: {s}", .{msg});
    }
}

/// Request a WebGPU device from an adapter.
///
/// Once an adapter is obtained, this function requests a logical device from it.
/// The device is the primary interface for creating GPU resources (buffers,
/// textures, pipelines) and submitting commands.
///
/// Parameters:
/// - adapter: WebGPU adapter from which to request the device.
/// - callback: Function called when the device request completes.
/// - userdata: Opaque pointer passed to the callback.
///
/// Example:
/// ```zig
/// requestDevice(adapter, &deviceCallback, &ctx);
/// ```
pub fn requestDevice(
    adapter: zgpu.wgpu.Adapter,
    callback: zgpu.wgpu.RequestDeviceCallback,
    userdata: ?*anyopaque,
) void {
    log.info("requesting WebGPU device from browser adapter", .{});

    // Request device with default limits (sufficient for 2D rendering).
    // The browser will provide a device with at least the default limits
    // specified by the WebGPU specification.
    adapter.requestDevice(
        .{
            .next_in_chain = null,
            .label = "Web Primary Device",
            .required_features_count = 0,
            .required_features = null,
            .required_limits = null,
            .default_queue = .{
                .next_in_chain = null,
                .label = "Web Default Queue",
            },
            .device_lost_callback = null,
            .device_lost_user_data = null,
        },
        callback,
        userdata,
    );
}

/// Request a WebGPU device synchronously (blocking pattern).
///
/// Convenience wrapper providing synchronous-looking API for device requests.
/// See requestAdapterSync() for important caveats about browser async behavior.
///
/// Parameters:
/// - adapter: WebGPU adapter from which to request the device.
///
/// Returns:
/// - The WebGPU device if the request succeeded, or null if it failed.
pub fn requestDeviceSync(adapter: zgpu.wgpu.Adapter) ?zgpu.wgpu.Device {
    const Response = struct {
        device: ?zgpu.wgpu.Device = null,
        status: zgpu.wgpu.RequestDeviceStatus = .unknown,
    };

    var response: Response = .{};

    requestDevice(adapter, &deviceCallback, @ptrCast(&response));

    if (response.status != .success) {
        log.warn("device request failed with status: {}", .{response.status});
        return null;
    }

    if (response.device) |device| {
        log.info("WebGPU device obtained successfully", .{});
        return device;
    }

    return null;
}

/// Callback for device request - stores result in the response struct.
fn deviceCallback(
    status: zgpu.wgpu.RequestDeviceStatus,
    device: zgpu.wgpu.Device,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const response: *struct {
        device: ?zgpu.wgpu.Device,
        status: zgpu.wgpu.RequestDeviceStatus,
    } = @ptrCast(@alignCast(userdata));

    response.status = status;

    if (status == .success) {
        response.device = device;
        log.info("browser WebGPU device request succeeded", .{});
    } else {
        const msg = message orelse "unknown error";
        log.err("browser WebGPU device request failed: {s}", .{msg});
    }
}

/// Create a WebGPU surface from an HTML canvas element.
///
/// This function creates a WebGPU surface bound to the specified canvas element,
/// enabling GPU rendering to the browser's canvas. The surface is the WebGPU
/// equivalent of the rendering context obtained via `canvas.getContext('webgpu')`
/// in JavaScript.
///
/// Parameters:
/// - instance: WebGPU instance from which to create the surface.
/// - canvas_selector: CSS selector for the target canvas (e.g., "#canvas").
///   This selector is passed to the browser to identify which canvas element
///   should receive the WebGPU rendering output.
///
/// Returns:
/// - A WebGPU surface bound to the canvas, or null if creation failed.
///
/// Usage:
/// ```zig
/// const surface = createSurfaceFromCanvas(instance, "#canvas");
/// if (surface) |s| {
///     // Use surface for swap chain creation
/// }
/// ```
///
/// Note: This function is only available on web/WASM builds. On desktop,
/// surfaces are created from native window handles (HWND, X11 Window, etc.)
/// via a different code path in renderer.zig.
pub fn createSurfaceFromCanvas(
    instance: zgpu.wgpu.Instance,
    canvas_selector: [*:0]const u8,
) ?zgpu.wgpu.Surface {
    // Create the canvas HTML selector descriptor.
    // This tells WebGPU which canvas element to bind the surface to.
    // The struct_type identifies this as a canvas selector descriptor
    // in the chained descriptor pattern used by WebGPU.
    var canvas_desc: zgpu.wgpu.SurfaceDescriptorFromCanvasHTMLSelector = .{
        .chain = .{
            .next = null,
            .struct_type = .surface_descriptor_from_canvas_html_selector,
        },
        .selector = canvas_selector,
    };

    // Create the surface using the chained descriptor.
    // The next_in_chain pointer connects to the canvas selector descriptor,
    // allowing WebGPU to interpret the surface creation request correctly.
    const surface = instance.createSurface(.{
        .next_in_chain = @ptrCast(&canvas_desc.chain),
        .label = "Web Canvas Surface",
    });

    // Check if surface creation succeeded.
    // A null/zero pointer indicates the browser failed to create the surface
    // (e.g., WebGPU not supported, canvas not found, or invalid selector).
    if (@intFromPtr(surface.ptr) == 0) {
        log.err("failed to create WebGPU surface from canvas '{s}'", .{canvas_selector});
        return null;
    }

    log.info("WebGPU surface created from canvas '{s}'", .{canvas_selector});
    return surface;
}

/// Create a swap chain from the canvas WebGPU context.
///
/// This function configures the swap chain (GPUCanvasContext.configure) to connect
/// the WebGPU device to the canvas for presenting frames. The swap chain manages
/// the textures used for double/triple buffering and handles presentation to the
/// browser's compositor.
///
/// Parameters:
/// - device: WebGPU device to create the swap chain with. Must be a valid device
///   obtained from requestDeviceSync() or an async device request.
/// - surface: WebGPU surface created from the canvas via createSurfaceFromCanvas().
///   The surface represents the canvas element as a render target.
/// - width: Width of the swap chain textures in pixels. Should match the canvas
///   element's backing store size (CSS size * device pixel ratio for high-DPI).
/// - height: Height of the swap chain textures in pixels.
///
/// Returns:
/// - A configured SwapChain for rendering to the canvas, or null if creation failed.
///
/// Configuration details:
/// - Format: bgra8_unorm - standard format for web, matches browser compositor expectations
/// - Usage: render_attachment - enables use as a render pass color attachment
/// - Present mode: fifo - VSync enabled for smooth presentation
/// - Alpha mode: Opaque (implicit) - canvas background shows through
///
/// Example:
/// ```zig
/// const surface = createSurfaceFromCanvas(instance, "#canvas");
/// const device = requestDeviceSync(adapter);
/// const swap_chain = createSwapChain(device.?, surface.?, 800, 600);
/// if (swap_chain) |sc| {
///     // Use swap_chain.getCurrentTextureView() in render loop
/// }
/// ```
///
/// Note: The swap chain must be recreated when the canvas size changes.
/// Monitor for resize events and call createSwapChain with new dimensions.
pub fn createSwapChain(
    device: zgpu.wgpu.Device,
    surface: zgpu.wgpu.Surface,
    width: u32,
    height: u32,
) ?zgpu.wgpu.SwapChain {
    log.info("creating swap chain for canvas: {}x{}", .{ width, height });

    // Create swap chain with standard settings for browser 2D rendering.
    // Configuration matches the desktop renderer settings for consistency.
    const swap_chain = device.createSwapChain(
        surface,
        .{
            .next_in_chain = null,
            .label = "Web Canvas Swap Chain",
            .usage = .{ .render_attachment = true },
            .format = .bgra8_unorm, // Standard format for browser WebGPU
            .width = width,
            .height = height,
            .present_mode = .fifo, // VSync enabled for smooth presentation
        },
    );

    // Check if swap chain creation succeeded.
    // A null/zero pointer indicates the browser failed to configure the canvas context.
    if (@intFromPtr(swap_chain.ptr) == 0) {
        log.err("failed to create swap chain for canvas (device or surface may be invalid)", .{});
        return null;
    }

    log.info("WebGPU swap chain created successfully: {}x{}", .{ width, height });
    return swap_chain;
}

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
    /// Canvas/viewport width in CSS pixels.
    width: u32,
    /// Canvas/viewport height in CSS pixels.
    height: u32,
    /// Device pixel ratio for high-DPI displays.
    /// Used to scale canvas backing store for crisp rendering.
    pixel_ratio: f64,
    /// CSS selector for the canvas element (stored for event registration).
    canvas_selector: [*:0]const u8,
    /// Current mouse state, updated by browser event callbacks.
    mouse_state: MouseState,
    /// Whether a quit has been requested (e.g., page unload).
    quit_requested: bool,
    /// Frame counter for timing and debugging.
    frame_count: u64,

    /// Initialize the web platform by querying the canvas element.
    ///
    /// This function:
    /// 1. Gets the canvas element dimensions from the browser via Emscripten
    /// 2. Queries the device pixel ratio for high-DPI support
    /// 3. Initializes input state with mouse centered in canvas
    ///
    /// The canvas selector defaults to "#canvas" (Emscripten's default).
    /// For custom canvas elements, use initWithSelector().
    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithSelector(allocator, DEFAULT_CANVAS_SELECTOR);
    }

    /// Initialize the web platform with a custom canvas selector.
    ///
    /// Use this when your HTML page has a custom canvas element ID.
    /// For example: initWithSelector(allocator, "#my-game-canvas")
    pub fn initWithSelector(allocator: std.mem.Allocator, canvas_selector: [*:0]const u8) Self {
        log.info("initializing web platform with canvas selector", .{});

        // Query canvas element dimensions from the browser
        var canvas_width: c_int = 0;
        var canvas_height: c_int = 0;
        const size_result = emscripten.emscripten_get_canvas_element_size(
            canvas_selector,
            &canvas_width,
            &canvas_height,
        );

        if (size_result != emscripten.EMSCRIPTEN_RESULT_SUCCESS) {
            log.warn("failed to get canvas size (result={}), using defaults 800x600", .{size_result});
            canvas_width = 800;
            canvas_height = 600;
        }

        const width: u32 = @intCast(@max(1, canvas_width));
        const height: u32 = @intCast(@max(1, canvas_height));

        // Query device pixel ratio for high-DPI displays
        const pixel_ratio = emscripten.emscripten_get_device_pixel_ratio();
        log.info("canvas dimensions: {}x{}, pixel ratio: {d:.2}", .{ width, height, pixel_ratio });

        // Register mousemove event listener via Emscripten HTML5 API.
        // The callback receives mouse coordinates which we use to update platform state.
        // Target the canvas element so we only capture movement over the rendering area.
        const mousemove_result = emscripten.emscripten_set_mousemove_callback(
            canvas_selector,
            null, // user_data - we use global_web_platform instead
            true, // use_capture - capture phase for reliable event handling
            mousemoveCallback,
        );

        if (mousemove_result != emscripten.EMSCRIPTEN_RESULT_SUCCESS) {
            log.warn("failed to register mousemove callback (result={})", .{mousemove_result});
        } else {
            log.info("mousemove event listener registered on canvas", .{});
        }

        return Self{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixel_ratio = pixel_ratio,
            .canvas_selector = canvas_selector,
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

    /// Emscripten mousemove event callback.
    /// Called by the browser when the mouse moves over the canvas element.
    /// Updates the global platform's mouse position using canvas-relative coordinates.
    ///
    /// The callback uses canvasX/canvasY which are coordinates relative to the canvas
    /// element's top-left corner, accounting for CSS transforms and scroll position.
    fn mousemoveCallback(
        _: c_int, // event_type - always EMSCRIPTEN_EVENT_MOUSEMOVE
        mouse_event: *const emscripten.EmscriptenMouseEvent,
        _: ?*anyopaque, // user_data - unused, we use global_web_platform
    ) callconv(.c) bool {
        // Access the global platform instance to update mouse state.
        // This is safe because the callback is only registered when the platform is initialized,
        // and we remove all event listeners in deinit() before deallocating.
        if (global_web_platform) |p| {
            // Use canvasX/canvasY for coordinates relative to the canvas element.
            // These are the most useful for UI hit testing as they account for
            // canvas position, scrolling, and CSS transforms.
            p.updateMousePosition(
                @floatFromInt(mouse_event.canvasX),
                @floatFromInt(mouse_event.canvasY),
            );
        }
        // Return false to allow event propagation to other handlers.
        // This enables coexisting with JavaScript event listeners if needed.
        return false;
    }

    /// Clean up platform resources.
    ///
    /// In browser context, most cleanup is handled automatically on page unload.
    /// However, for clean page reload scenarios (e.g., hot module replacement),
    /// we explicitly:
    /// 1. Clear the global platform pointer to prevent dangling pointer access
    /// 2. Cancel the Emscripten main loop to stop frame callbacks
    /// 3. Remove all registered HTML5 event listeners
    /// 4. Reset internal state
    ///
    /// This ensures the WASM module can be cleanly reinitialized without stale state.
    pub fn deinit(self: *Self) void {
        log.info("web platform shutdown after {} frames", .{self.frame_count});

        // Clear global platform pointer first to prevent JavaScript callbacks
        // from accessing this platform during or after cleanup.
        clearGlobalPlatform();

        // Cancel the main loop to stop requestAnimationFrame callbacks.
        // This is important for clean reload scenarios where we want to
        // stop the old loop before starting a new one.
        emscripten.emscripten_cancel_main_loop();

        // Remove all HTML5 event listeners registered via Emscripten APIs.
        // This includes mouse, keyboard, resize, and wheel event handlers.
        // Without this, listeners could fire into deallocated memory on reload.
        emscripten.emscripten_html5_remove_all_event_listeners();

        // Reset internal state for clean restart
        self.quit_requested = false;
        self.frame_count = 0;
        self.mouse_state = .{
            .x = 0,
            .y = 0,
            .left_pressed = false,
            .right_pressed = false,
            .middle_pressed = false,
        };

        log.info("web platform cleanup complete", .{});
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

    /// Get the framebuffer size in physical pixels.
    /// On high-DPI displays, this is larger than the CSS pixel canvas size,
    /// scaled by the device pixel ratio for crisp rendering.
    pub fn getFramebufferSize(self: *const Self) Size {
        const scaled_width: u32 = @intFromFloat(@as(f64, @floatFromInt(self.width)) * self.pixel_ratio);
        const scaled_height: u32 = @intFromFloat(@as(f64, @floatFromInt(self.height)) * self.pixel_ratio);
        return .{ .width = scaled_width, .height = scaled_height };
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
        // Re-query pixel ratio in case display changed (e.g., moved to different monitor)
        self.pixel_ratio = emscripten.emscripten_get_device_pixel_ratio();
        log.debug("canvas resized to {}x{}, pixel ratio: {d:.2}", .{ width, height, self.pixel_ratio });
    }

    /// Refresh canvas dimensions by re-querying from the browser.
    /// Call this after CSS layout changes or window resizes that may not
    /// trigger JavaScript resize events.
    pub fn refreshCanvasSize(self: *Self) void {
        var canvas_width: c_int = 0;
        var canvas_height: c_int = 0;
        const result = emscripten.emscripten_get_canvas_element_size(
            self.canvas_selector,
            &canvas_width,
            &canvas_height,
        );

        if (result == emscripten.EMSCRIPTEN_RESULT_SUCCESS) {
            self.width = @intCast(@max(1, canvas_width));
            self.height = @intCast(@max(1, canvas_height));
            self.pixel_ratio = emscripten.emscripten_get_device_pixel_ratio();
            log.debug("canvas refreshed: {}x{}, pixel ratio: {d:.2}", .{ self.width, self.height, self.pixel_ratio });
        } else {
            log.warn("failed to refresh canvas size (result={})", .{result});
        }
    }

    /// Get the canvas CSS selector for event registration.
    /// Returns the selector used to target this canvas in Emscripten APIs.
    pub fn getCanvasSelector(self: *const Self) [*:0]const u8 {
        return self.canvas_selector;
    }

    /// Get the device pixel ratio for high-DPI scaling.
    pub fn getPixelRatio(self: *const Self) f64 {
        return self.pixel_ratio;
    }

    /// Create a WebGPU surface from this platform's canvas.
    ///
    /// This is a convenience method that calls createSurfaceFromCanvas()
    /// with the platform's configured canvas selector. The returned surface
    /// can be used to create a swap chain for rendering to the browser canvas.
    ///
    /// Parameters:
    /// - instance: WebGPU instance from which to create the surface.
    ///
    /// Returns:
    /// - A WebGPU surface bound to the platform's canvas, or null if creation failed.
    ///
    /// Example:
    /// ```zig
    /// var platform = WebPlatform.init(allocator);
    /// // ... after obtaining WebGPU instance ...
    /// const surface = platform.createSurface(instance);
    /// if (surface) |s| {
    ///     // Create swap chain with surface
    /// }
    /// ```
    pub fn createSurface(self: *const Self, instance: zgpu.wgpu.Instance) ?zgpu.wgpu.Surface {
        return createSurfaceFromCanvas(instance, self.canvas_selector);
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
/// Public to allow access from the main loop callback in main.zig.
pub var global_web_platform: ?*WebPlatform = null;

// Import App and Renderer types.
// These are forward-declared here to avoid circular dependencies since web.zig
// is only compiled for WASM targets where these modules exist.
const App = @import("../app.zig").App;
const renderer_mod = @import("../renderer.zig");
const Renderer = renderer_mod.Renderer;
const RenderTarget = @import("../render_target.zig").RenderTarget;

/// Global state for the Emscripten main loop callback.
/// The callback is a C function pointer that cannot capture context, so we
/// store App and Renderer pointers here for access from the callback.
///
/// This struct groups all runtime state needed by mainLoopCallback():
/// - platform: WebPlatform for input/window management
/// - app: Application state and logic
/// - renderer: WebGPU rendering context (null until WebGPU is initialized)
/// - render_target: RenderTarget for the current frame (null until initialized)
///
/// All pointers must be initialized before calling emscripten_set_main_loop.
/// The callback accesses these via the global `global_app_state` variable.
pub const GlobalAppState = struct {
    /// Web platform for input handling and canvas management.
    platform: *WebPlatform,
    /// Application state containing game logic and UI.
    app: *App,
    /// WebGPU renderer for drawing. Null until WebGPU context is obtained.
    /// On web, WebGPU initialization is asynchronous and happens after
    /// the main loop starts, so this may be null during initial frames.
    renderer: ?*Renderer,
    /// Frame timing: timestamp of last frame (milliseconds from emscripten_get_now).
    last_frame_time: f64,
    /// Render target for frame rendering. Must be initialized after renderer.
    /// This is a pointer to an externally-owned SwapChainRenderTarget.
    render_target: ?*RenderTarget,
};

/// Global application state for the Emscripten main loop callback.
/// Must be initialized via initGlobalAppState() before starting the main loop.
/// This is separate from global_web_platform to support the full app lifecycle.
pub var global_app_state: ?*GlobalAppState = null;

/// Initialize the global application state for main loop callback access.
/// Call this after creating WebPlatform and App, but before emscripten_set_main_loop.
///
/// Parameters:
/// - state: Pointer to GlobalAppState struct with initialized platform and app.
///   The struct must outlive the main loop (typically static or heap-allocated).
///
/// Note: The renderer field in state can be null initially. Set it via
/// setGlobalRenderer() once WebGPU is initialized.
pub fn initGlobalAppState(state: *GlobalAppState) void {
    global_app_state = state;
    // Also set the platform global for backward compatibility with event handlers
    global_web_platform = state.platform;
    log.info("global app state initialized for main loop callback", .{});
}

/// Set the renderer reference in the global app state.
/// Call this after WebGPU initialization completes (asynchronously on web).
///
/// Prerequisites:
/// - initGlobalAppState() must have been called first
///
/// Parameters:
/// - renderer: Pointer to initialized Renderer
pub fn setGlobalRenderer(renderer: *Renderer) void {
    if (global_app_state) |state| {
        state.renderer = renderer;
        log.info("global renderer set for main loop callback", .{});
    } else {
        log.warn("setGlobalRenderer called before initGlobalAppState", .{});
    }
}

/// Set the render target reference in the global app state.
/// Call this after creating the render target from the renderer.
///
/// Prerequisites:
/// - initGlobalAppState() must have been called first
/// - setGlobalRenderer() should have been called to set up the renderer
///
/// Parameters:
/// - render_target: Pointer to initialized RenderTarget (e.g., from SwapChainRenderTarget.asRenderTarget())
pub fn setGlobalRenderTarget(render_target: *RenderTarget) void {
    if (global_app_state) |state| {
        state.render_target = render_target;
        log.info("global render target set for main loop callback", .{});
    } else {
        log.warn("setGlobalRenderTarget called before initGlobalAppState", .{});
    }
}

/// Clear the global application state.
/// Should be called during cleanup to prevent dangling pointer access.
pub fn clearGlobalAppState() void {
    global_app_state = null;
    global_web_platform = null;
    log.info("global app state cleared", .{});
}

/// Set the global web platform instance for JavaScript callbacks.
/// Must be called after WebPlatform.init() to enable event handling.
///
/// Note: Prefer using initGlobalAppState() which sets this automatically.
/// This function is kept for backward compatibility.
pub fn setGlobalPlatform(p: *WebPlatform) void {
    global_web_platform = p;
}

/// Clear the global web platform instance.
/// Should be called before WebPlatform.deinit() to prevent dangling pointer.
///
/// Note: Prefer using clearGlobalAppState() which clears this automatically.
/// This function is kept for backward compatibility.
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
