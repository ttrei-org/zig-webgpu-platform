//! Zig WebGPU Platform - Main entry point
//!
//! This is the demo application that showcases the platform's capabilities.
//! For native builds, it uses lib.run() to handle all platform initialization.
//! For WASM builds, it exports wasm_main to be called from JavaScript.
//!
//! Controls:
//! - Escape: Close the window
//! - Left click: Move the interactive triangle
//!
//! Command-line options (handled by lib.run):
//! - --screenshot=<filename>: Take a screenshot after startup and exit
//! - --headless: Run in headless mode for automated testing

const std = @import("std");
const builtin = @import("builtin");

const lib = @import("lib.zig");
const App = @import("app.zig").App;

/// True if building for WASM (web) target
const is_wasm = builtin.cpu.arch.isWasm();

/// Configure logging level and custom log function for WASM.
/// Set to .debug for verbose output, .info for normal, .warn or .err for quieter output.
pub const std_options: std.Options = .{
    .log_level = .info,
    // On WASM, use a custom log function that doesn't require Thread.getCurrentId().
    // The default std.log.defaultLog uses Thread.getCurrentId() for thread-safe stderr
    // access, but emscripten doesn't support threads.
    .logFn = if (is_wasm) wasmLogFn else std.log.defaultLog,
};

/// Custom log function for WASM builds.
/// Uses emscripten's console output instead of std.debug which requires threads.
fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // For WASM, we skip logging to avoid complexity - browser DevTools can be used
    // for debugging via JavaScript console.log() calls.
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

/// Custom panic namespace for WASM builds.
/// The default panic handler uses Thread.getCurrentId() and stderr which are not supported
/// on emscripten. This provides a minimal panic namespace that works in the browser.
pub const panic = if (is_wasm) WasmPanic else std.debug.FullPanic(std.debug.defaultPanic);

/// Minimal panic namespace for WASM that just traps without trying to use
/// stderr or Thread (which don't work on wasm32-emscripten).
const WasmPanic = struct {
    pub fn call(_: []const u8, _: ?usize) noreturn {
        @trap();
    }

    pub fn sentinelMismatch(expected: anytype, _: @TypeOf(expected)) noreturn {
        @trap();
    }

    pub fn unwrapError(_: anyerror) noreturn {
        @trap();
    }

    pub fn outOfBounds(_: usize, _: usize) noreturn {
        @trap();
    }

    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
        @trap();
    }

    pub fn inactiveUnionField(active: anytype, _: @TypeOf(active)) noreturn {
        @trap();
    }

    pub fn sliceCastLenRemainder(_: usize) noreturn {
        @trap();
    }

    pub fn reachedUnreachable() noreturn {
        @trap();
    }

    pub fn unwrapNull() noreturn {
        @trap();
    }

    pub fn castToNull() noreturn {
        @trap();
    }

    pub fn incorrectAlignment() noreturn {
        @trap();
    }

    pub fn invalidErrorCode() noreturn {
        @trap();
    }

    pub fn integerOutOfBounds() noreturn {
        @trap();
    }

    pub fn integerOverflow() noreturn {
        @trap();
    }

    pub fn shlOverflow() noreturn {
        @trap();
    }

    pub fn shrOverflow() noreturn {
        @trap();
    }

    pub fn divideByZero() noreturn {
        @trap();
    }

    pub fn exactDivisionRemainder() noreturn {
        @trap();
    }

    pub fn integerPartOutOfBounds() noreturn {
        @trap();
    }

    pub fn corruptSwitch() noreturn {
        @trap();
    }

    pub fn shiftRhsTooBig() noreturn {
        @trap();
    }

    pub fn invalidEnumValue() noreturn {
        @trap();
    }

    pub fn forLenMismatch() noreturn {
        @trap();
    }

    pub fn copyLenMismatch() noreturn {
        @trap();
    }

    pub fn memcpyAlias() noreturn {
        @trap();
    }

    pub fn noreturnReturned() noreturn {
        @trap();
    }
};

const log = std.log.scoped(.main);

/// Main entry point for the application.
/// For WASM builds, we provide a _start stub to satisfy std.start checks, but the
/// actual entry point is the exported wasm_main function called from JavaScript.
pub const main = if (!is_wasm) nativeMain else struct {};

/// Main implementation for native desktop builds.
/// Creates the demo App and uses lib.run() for all platform handling.
fn nativeMain() void {
    log.info("zig-webgpu-platform demo starting", .{});

    // Create the demo app
    var app = App.init(std.heap.page_allocator);
    var iface = app.appInterface();
    defer iface.deinit();

    // Run using the library's platform runner
    // lib.run() handles command-line parsing (--screenshot, --headless, etc.),
    // platform initialization, main loop, and cleanup.
    lib.run(&iface, .{
        .viewport = lib.DEFAULT_VIEWPORT,
        .window_title = "Zig WebGPU Platform Demo",
    });

    log.info("zig-webgpu-platform demo exiting", .{});
}

/// WASM-specific exports and implementations.
/// These are only compiled for WASM targets to avoid importing web.zig on native builds.
const wasm_exports = if (is_wasm) struct {
    const zgpu = @import("zgpu");

    /// Web platform module. Also provides emscripten bindings without libc dependency.
    const web = @import("platform/web.zig");

    /// Internal modules needed for WASM rendering.
    const renderer_mod = @import("renderer.zig");
    const Renderer = renderer_mod.Renderer;
    const render_target_mod = @import("render_target.zig");
    const SwapChainRenderTarget = render_target_mod.SwapChainRenderTarget;
    const RenderTarget = render_target_mod.RenderTarget;
    const Canvas = lib.Canvas;
    const Viewport = lib.Viewport;
    const AppInterface = lib.AppInterface;

    /// Frames per second cap for delta time calculation.
    const MAX_DELTA_TIME: f32 = 0.25;

    /// Static storage for global app state.
    /// Using static variables because emscripten_set_main_loop with simulate_infinite_loop=1
    /// doesn't return, so stack-allocated variables would be invalid when the callback runs.
    var static_platform: web.WebPlatform = undefined;
    var static_app: App = undefined;
    var static_app_interface: AppInterface = undefined;
    var static_app_state: web.GlobalAppState = undefined;

    /// Static storage for renderer and render target.
    var static_renderer: Renderer = undefined;
    var static_swap_chain_target: SwapChainRenderTarget = undefined;
    var static_render_target: RenderTarget = undefined;

    /// Execute one frame of the update/render/present pipeline (web version).
    fn runFrame(
        app: *AppInterface,
        renderer: *Renderer,
        render_target: *RenderTarget,
        viewport: Viewport,
    ) void {
        const frame_state = renderer.beginFrame(render_target) catch |err| {
            if (err == renderer_mod.RendererError.DeviceLost) {
                return;
            }
            if (err != renderer_mod.RendererError.BeginFrameFailed) {
                log.warn("beginFrame failed: {}", .{err});
            }
            return;
        };

        renderer.setLogicalSize(viewport.logical_width, viewport.logical_height);

        const render_pass = Renderer.beginRenderPass(frame_state, Renderer.cornflower_blue);
        var canvas = Canvas.init(renderer, viewport);
        app.render(&canvas);
        renderer.flushBatch(render_pass);
        Renderer.endRenderPass(render_pass);

        renderer.endFrame(frame_state, render_target);
    }

    /// Convert mouse coordinates from physical canvas space to logical viewport space.
    fn toLogicalCoordinates(mouse: lib.MouseState, window_size: @import("platform.zig").Size, viewport: Viewport) lib.MouseState {
        const win_w: f32 = @floatFromInt(window_size.width);
        const win_h: f32 = @floatFromInt(window_size.height);

        if (win_w <= 0 or win_h <= 0) return mouse;

        var result = mouse;
        result.x = mouse.x * (viewport.logical_width / win_w);
        result.y = mouse.y * (viewport.logical_height / win_h);
        return result;
    }

    /// Main loop callback for web platform.
    fn mainLoopCallback() callconv(.c) void {
        const state = web.global_app_state orelse {
            log.warn("web main loop callback: app state not initialized", .{});
            return;
        };

        // Calculate delta time from last frame
        const current_time = web.emscripten.emscripten_get_now();
        var delta_time: f32 = @floatCast((current_time - state.last_frame_time) / 1000.0);
        state.last_frame_time = current_time;

        // Cap delta time to prevent large jumps
        if (delta_time > MAX_DELTA_TIME) {
            delta_time = MAX_DELTA_TIME;
        }

        // Poll for events
        state.platform.pollEvents();

        // Convert mouse from canvas-pixel space to logical viewport space
        const raw_mouse = state.platform.getMouseState();
        const mouse_state = toLogicalCoordinates(raw_mouse, state.platform.getWindowSize(), lib.DEFAULT_VIEWPORT);

        // Update application state
        state.app_interface.update(delta_time, mouse_state);

        // Log frame callback invocations
        const frame = state.platform.frame_count;
        if (frame == 1) {
            log.info("web main loop started", .{});
        } else if (frame % 60 == 0) {
            log.info("web frame {} (dt={d:.3}s)", .{ frame, delta_time });
        }

        // Render frame if renderer and render target are available
        if (state.renderer) |renderer| {
            if (renderer.isDeviceLost()) {
                log.err("GPU device lost on web - requires page reload", .{});
                web.emscripten.emscripten_cancel_main_loop();
                return;
            }
            if (state.render_target) |rt| {
                runFrame(state.app_interface, renderer, rt, lib.DEFAULT_VIEWPORT);
            }
        }

        // Check if quit was requested
        if (state.platform.shouldClose() or !state.app_interface.isRunning()) {
            log.info("quit requested, cancelling main loop", .{});
            web.emscripten.emscripten_cancel_main_loop();
        }
    }

    /// Entry point called from JavaScript.
    pub fn wasm_main() callconv(.c) void {
        log.info("wasm_main: initializing web platform", .{});

        // Initialize web platform in static storage
        static_platform = web.WebPlatform.init(std.heap.page_allocator);

        // Get canvas dimensions for renderer initialization
        const fb_size = static_platform.getFramebufferSize();
        log.info("wasm_main: canvas size {}x{}", .{ fb_size.width, fb_size.height });

        // Initialize WebGPU renderer for web platform
        log.info("wasm_main: initializing WebGPU renderer", .{});
        static_renderer = Renderer.initWeb(std.heap.page_allocator, fb_size.width, fb_size.height) catch |err| {
            log.err("wasm_main: failed to initialize renderer: {}", .{err});
            return;
        };
        log.info("wasm_main: WebGPU renderer initialized successfully", .{});

        // Create SwapChainRenderTarget from the renderer's swap chain
        static_swap_chain_target = static_renderer.createSwapChainRenderTarget();
        static_render_target = static_swap_chain_target.render_target;
        static_render_target.context = @ptrCast(&static_swap_chain_target);
        log.info("wasm_main: swap chain render target created", .{});

        // Initialize application state in static storage
        static_app = App.init(std.heap.page_allocator);

        // Create the AppInterface vtable in static storage
        static_app_interface = static_app.appInterface();

        // Initialize global app state struct
        static_app_state = .{
            .platform = &static_platform,
            .app_interface = &static_app_interface,
            .renderer = &static_renderer,
            .last_frame_time = web.emscripten.emscripten_get_now(),
            .render_target = &static_render_target,
        };

        // Set the global state pointer for callback access
        web.initGlobalAppState(&static_app_state);
        web.setGlobalRenderer(&static_renderer);
        web.setGlobalRenderTarget(&static_render_target);

        log.info("wasm_main: platform and app initialized, starting main loop", .{});

        // Start the main loop using emscripten_set_main_loop
        web.emscripten.emscripten_set_main_loop(mainLoopCallback, 0, 1);

        log.info("wasm_main: main loop exited (unexpected)", .{});
    }
} else struct {};

// Export wasm_main for WASM builds.
comptime {
    if (is_wasm) {
        @export(&wasm_exports.wasm_main, .{ .name = "wasm_main" });
    }
}

// For WASM builds, provide a _start symbol to prevent std.start issues.
pub const _start = if (is_wasm) wasmStart else {};

fn wasmStart() callconv(.c) void {
    // No-op stub. Browser calls wasm_main directly via JavaScript.
}

// Pull in tests from modules that aren't transitively imported by the main code paths.
test {
    _ = @import("canvas.zig");
    _ = @import("app_interface.zig");
    _ = @import("lib.zig");
}
