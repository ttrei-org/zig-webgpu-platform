//! Zig GUI Experiment - Main entry point
//!
//! A GPU-accelerated terminal emulator experiment using zgpu and zglfw.
//!
//! Controls:
//! - Escape: Close the window
//!
//! Command-line options:
//! - --screenshot=<filename>: Take a screenshot after startup and exit
//! - --headless: Run in headless mode for automated testing and screenshot generation

const std = @import("std");
const builtin = @import("builtin");
const zgpu = @import("zgpu");

const App = @import("app.zig").App;
const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;

/// True if building for native desktop (not emscripten/web)
const is_native = platform_mod.is_native;

/// zglfw is only available on native desktop builds
const zglfw = if (is_native) @import("zglfw") else struct {};

/// Frames per second cap for delta time calculation.
/// If a frame takes longer than this, delta_time is capped to prevent
/// large jumps in game state (e.g., when window is dragged or minimized).
const MAX_DELTA_TIME: f32 = 0.25; // 4 FPS minimum

/// Desktop platform is only available for native builds
const desktop = if (is_native) @import("platform/desktop.zig") else struct {};
const headless = @import("platform/headless.zig");
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const OffscreenRenderTarget = renderer_mod.OffscreenRenderTarget;

const log = std.log.scoped(.main);

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
/// This avoids the "Unsupported operating system emscripten" error from Thread.getCurrentId().
fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // For WASM, we use emscripten's console logging via EM_ASM or just skip logging.
    // Currently we skip logging to avoid complexity - browser DevTools can be used
    // for debugging via JavaScript console.log() calls.
    //
    // A future enhancement could use emscripten_console_log() or EM_ASM to output
    // to the browser console, but for now we suppress WASM logging to fix the build.
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

/// Custom panic namespace for WASM builds.
/// The default panic handler uses Thread.getCurrentId() and stderr which are not supported
/// on emscripten. This provides a minimal panic namespace that works in the browser.
///
/// When a panic occurs, this handler will:
/// 1. Trap (abort execution via unreachable)
/// The browser's developer tools can catch this and show a stack trace.
///
/// In the future, this could be enhanced to call a JavaScript console.error() function
/// via an imported JS function to display the panic message before aborting.
///
/// This is a panic namespace (type) not a function, following the modern Zig API.
/// The namespace provides all the panic entry points that the compiler expects.
pub const panic = if (is_wasm) WasmPanic else std.debug.FullPanic(std.debug.defaultPanic);

/// Minimal panic namespace for WASM that just traps without trying to use
/// stderr or Thread (which don't work on wasm32-emscripten).
/// Function signatures match std/debug/simple_panic.zig exactly.
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

// Export zgpu types for use in other modules
pub const GraphicsContext = zgpu.GraphicsContext;

/// Application configuration parsed from command-line arguments.
/// Holds all settings needed for application initialization.
pub const Config = struct {
    /// If set, take a screenshot to this filename and exit.
    screenshot_filename: ?[]const u8 = null,
    /// If true, run in headless mode (no window display).
    /// Used for automated testing and screenshot generation.
    headless: bool = false,
    /// Window/framebuffer width in pixels.
    /// For headless mode, this is the render target resolution.
    width: u32 = 800,
    /// Window/framebuffer height in pixels.
    /// For headless mode, this is the render target resolution.
    height: u32 = 600,
};

/// Parse command-line arguments into a Config struct.
/// Uses argsWithAllocator for cross-platform compatibility, then deallocates
/// the iterator's internal buffers after parsing is complete.
/// Supports: --screenshot=<file>, --headless, --width=N, --height=N
fn parseArgs(allocator: std.mem.Allocator) Config {
    var config: Config = .{};
    var args = std.process.argsWithAllocator(allocator) catch |err| {
        log.warn("failed to get command line arguments: {}", .{err});
        return config;
    };
    defer args.deinit();

    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--screenshot=")) {
            config.screenshot_filename = arg["--screenshot=".len..];
        } else if (std.mem.eql(u8, arg, "--headless")) {
            config.headless = true;
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            const width_str = arg["--width=".len..];
            config.width = std.fmt.parseInt(u32, width_str, 10) catch {
                log.warn("invalid --width value '{s}', using default 800", .{width_str});
                continue;
            };
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            const height_str = arg["--height=".len..];
            config.height = std.fmt.parseInt(u32, height_str, 10) catch {
                log.warn("invalid --height value '{s}', using default 600", .{height_str});
                continue;
            };
        }
    }

    return config;
}

/// True if building for WASM (web) target
const is_wasm = builtin.cpu.arch.isWasm();

/// Main entry point for the application.
/// For WASM builds, we provide a _start stub to satisfy std.start checks, but the
/// actual entry point is the exported wasm_main function called from JavaScript.
/// This prevents std.start from trying to generate entry code for wasm32-emscripten
/// which doesn't have proper start.zig support (no _start symbol for wasm arch).
pub const main = if (!is_wasm) nativeMain else struct {};

/// Main implementation for native desktop builds.
fn nativeMain() void {
    log.info("zig-gui-experiment starting", .{});

    // Parse command-line arguments using page_allocator for cross-platform compatibility
    const config = parseArgs(std.heap.page_allocator);
    log.info("config: headless={}, {}x{}", .{ config.headless, config.width, config.height });

    if (config.headless) {
        runHeadless(config);
    } else {
        // Windowed mode is only available on native desktop builds
        runWindowed(config);
    }

    log.info("zig-gui-experiment exiting", .{});
}

/// Run in windowed mode with GLFW and swap chain rendering.
/// Only available on native desktop builds (not emscripten).
const runWindowed = if (is_native) runWindowedImpl else unreachable;

fn runWindowedImpl(config: Config) void {
    log.info("starting windowed mode", .{});

    // Initialize desktop platform with GLFW
    var platform = desktop.DesktopPlatform.init(std.heap.page_allocator, config) catch |err| {
        log.err("failed to initialize platform: {}", .{err});
        return;
    };
    defer platform.deinit();

    // Create window using config dimensions
    platform.createWindow(config.width, config.height, "Zig GUI Experiment") catch |err| {
        log.err("failed to create window: {}", .{err});
        return;
    };

    // Initialize WebGPU renderer with the window
    const fb_size = platform.getFramebufferSize();
    var renderer = Renderer.init(std.heap.page_allocator, platform.window.?, fb_size.width, fb_size.height) catch |err| {
        log.err("failed to initialize renderer: {}", .{err});
        return;
    };
    defer renderer.deinit();

    log.info("WebGPU initialization complete - adapter, device, and swap chain configured", .{});

    // Create a SwapChainRenderTarget for windowed rendering
    var swap_chain_target = renderer.createSwapChainRenderTarget();
    var render_target = swap_chain_target.asRenderTarget();

    // Initialize application state with screenshot config
    const app_options: App.Options = .{
        .screenshot_path = config.screenshot_filename,
        .quit_after_screenshot = true,
    };
    var app = App.initWithOptions(std.heap.page_allocator, app_options);
    defer app.deinit();

    // Set renderer reference for screenshot capability
    app.setRenderer(&renderer);

    // Get the platform abstraction interface
    var plat = platform.platform();

    log.info("entering main loop", .{});

    var last_time: f64 = zglfw.getTime();

    // Main loop
    while (!plat.shouldQuit() and app.isRunning()) {
        plat.pollEvents();

        const current_time = zglfw.getTime();
        var delta_time: f32 = @floatCast(current_time - last_time);
        last_time = current_time;

        if (delta_time > MAX_DELTA_TIME) {
            delta_time = MAX_DELTA_TIME;
        }

        if (plat.isKeyPressed(.escape)) {
            app.requestQuit();
            continue;
        }

        const mouse_state = plat.getMouseState();
        app.update(delta_time, mouse_state);

        // Check if render target needs resize
        const current_fb = platform.getFramebufferSize();
        if (current_fb.width > 0 and current_fb.height > 0) {
            if (render_target.needsResize(current_fb.width, current_fb.height)) {
                log.info("window resized to {}x{}, resizing render target", .{ current_fb.width, current_fb.height });
                render_target.resize(current_fb.width, current_fb.height) catch |err| {
                    log.warn("failed to resize render target: {}", .{err});
                    continue;
                };
            }
        } else {
            log.debug("window minimized, skipping frame", .{});
            continue;
        }

        const frame_state = renderer.beginFrame(render_target) catch |err| {
            if (err != renderer_mod.RendererError.BeginFrameFailed) {
                log.warn("beginFrame failed: {}", .{err});
            }
            continue;
        };

        const render_pass = Renderer.beginRenderPass(frame_state, Renderer.cornflower_blue);
        app.render(&renderer);
        renderer.flushBatch(render_pass);
        Renderer.endRenderPass(render_pass);
        renderer.endFrame(frame_state, render_target);

        // Check if App wants to take a screenshot after this frame
        if (app.shouldTakeScreenshot()) |filename| {
            renderer.screenshot(filename) catch |err| {
                log.err("failed to take screenshot: {}", .{err});
            };
            app.onScreenshotComplete();
        }
    }
}

/// Run in headless mode without a window.
/// Uses offscreen rendering for automated testing and screenshot generation.
fn runHeadless(config: Config) void {
    log.info("starting headless mode (no window will be created)", .{});

    // Initialize headless platform (no GLFW, no display required)
    var platform = headless.HeadlessPlatform.init(std.heap.page_allocator, config);
    defer platform.deinit();

    // Initialize WebGPU renderer in headless mode (no surface/swap chain)
    var renderer = Renderer.initHeadless(std.heap.page_allocator, config.width, config.height) catch |err| {
        log.err("failed to initialize headless renderer: {}", .{err});
        return;
    };
    defer renderer.deinit();

    log.info("WebGPU headless initialization complete - rendering to offscreen texture", .{});

    // Create an OffscreenRenderTarget for headless rendering
    var offscreen_target = renderer.createOffscreenRenderTarget(config.width, config.height);
    defer offscreen_target.deinit();
    const render_target = offscreen_target.asRenderTarget();

    // Initialize application state with screenshot config
    const app_options: App.Options = .{
        .screenshot_path = config.screenshot_filename,
        .quit_after_screenshot = true,
    };
    var app = App.initWithOptions(std.heap.page_allocator, app_options);
    defer app.deinit();

    // Set renderer reference for screenshot capability
    app.setRenderer(&renderer);

    // Get the platform abstraction interface
    var plat = platform.platform();

    log.info("entering headless main loop", .{});

    var frame_count: u64 = 0;

    // Headless main loop - runs for a limited number of frames or until screenshot is taken
    while (!plat.shouldQuit() and app.isRunning()) {
        plat.pollEvents();

        // Use synthetic delta time (60 FPS simulation)
        const delta_time: f32 = 1.0 / 60.0;

        const mouse_state = plat.getMouseState();
        app.update(delta_time, mouse_state);

        const frame_state = renderer.beginFrame(render_target) catch |err| {
            log.err("headless beginFrame failed: {}", .{err});
            return;
        };

        const render_pass = Renderer.beginRenderPass(frame_state, Renderer.cornflower_blue);
        app.render(&renderer);
        renderer.flushBatch(render_pass);
        Renderer.endRenderPass(render_pass);

        // Copy rendered texture to staging buffer for CPU readback.
        // This must be done after rendering but before the command buffer is submitted.
        offscreen_target.copyToStagingBuffer(frame_state.command_encoder);

        renderer.endFrame(frame_state, render_target);

        frame_count += 1;
        log.info("headless frame {} rendered successfully", .{frame_count});

        // Check if App wants to take a screenshot after this frame
        if (app.shouldTakeScreenshot()) |filename| {
            log.info("taking headless screenshot to {s}", .{filename});
            renderer.takeScreenshotFromOffscreen(&offscreen_target, filename) catch |err| {
                log.err("failed to take headless screenshot: {}", .{err});
            };
            app.onScreenshotComplete();
        }
    }

    log.info("headless rendering complete after {} frames", .{frame_count});
}

/// WASM-specific exports and implementations.
/// These are only compiled for WASM targets to avoid importing web.zig on native builds.
const wasm_exports = if (is_wasm) struct {
    /// Web platform module.
    /// Also provides emscripten bindings without libc dependency.
    const web = @import("platform/web.zig");

    /// Render target module for SwapChainRenderTarget.
    const render_target_mod = @import("render_target.zig");
    const SwapChainRenderTarget = render_target_mod.SwapChainRenderTarget;
    const RenderTarget = render_target_mod.RenderTarget;

    /// Static storage for global app state.
    /// Using static variables because emscripten_set_main_loop with simulate_infinite_loop=1
    /// doesn't return, so stack-allocated variables would be invalid when the callback runs.
    /// The callback accesses these via web.global_app_state pointer.
    var static_platform: web.WebPlatform = undefined;
    var static_app: App = undefined;
    var static_app_state: web.GlobalAppState = undefined;

    /// Static storage for renderer and render target.
    /// These must persist across frames since the main loop callback accesses them.
    var static_renderer: Renderer = undefined;
    var static_swap_chain_target: SwapChainRenderTarget = undefined;
    var static_render_target: RenderTarget = undefined;

    /// Main loop callback for web platform.
    /// Called by the browser each frame via emscripten_set_main_loop.
    /// This function executes one iteration of the update/render loop.
    ///
    /// Accesses App, Renderer, and Platform via the global_app_state pointer
    /// since C function pointers cannot capture context.
    ///
    /// Currently handles update logic. Rendering requires WebGPU context
    /// from the browser (to be added in follow-up tasks: bd-3bja).
    fn mainLoopCallback() callconv(.c) void {
        const state = web.global_app_state orelse {
            log.warn("web main loop callback: app state not initialized", .{});
            return;
        };

        // Calculate delta time from last frame
        const current_time = web.emscripten.emscripten_get_now();
        var delta_time: f32 = @floatCast((current_time - state.last_frame_time) / 1000.0);
        state.last_frame_time = current_time;

        // Cap delta time to prevent large jumps (e.g., when tab is backgrounded)
        if (delta_time > MAX_DELTA_TIME) {
            delta_time = MAX_DELTA_TIME;
        }

        // Poll for events (updates frame counter and processes browser events)
        state.platform.pollEvents();

        // Get mouse state from platform
        const mouse_state = state.platform.getMouseState();

        // Update application state
        state.app.update(delta_time, mouse_state);

        // Log frame callback invocations for browser console debugging.
        // First frame logs to confirm main loop started; then every 60 frames (~1s at 60 FPS).
        const frame = state.platform.frame_count;
        if (frame == 1) {
            log.info("web main loop started - frame callback running", .{});
        } else if (frame % 60 == 0) {
            log.info("web frame {} (dt={d:.3}s) - loop running", .{ frame, delta_time });
        }

        // Render frame if renderer and render target are available.
        // On web, WebGPU initialization is asynchronous so renderer may be null initially.
        if (state.renderer) |renderer| {
            if (state.render_target) |render_target| {
                // Begin frame
                const frame_state = renderer.beginFrame(render_target) catch |err| {
                    if (err != renderer_mod.RendererError.BeginFrameFailed) {
                        log.warn("web beginFrame failed: {}", .{err});
                    }
                    return;
                };

                // Render: clear, draw app content, flush batch
                const render_pass = Renderer.beginRenderPass(frame_state, Renderer.cornflower_blue);
                state.app.render(renderer);
                renderer.flushBatch(render_pass);
                Renderer.endRenderPass(render_pass);

                // End frame and present
                renderer.endFrame(frame_state, render_target);
            }
        }

        // Check if quit was requested or app stopped running
        if (state.platform.shouldClose() or !state.app.isRunning()) {
            log.info("quit requested, cancelling main loop", .{});
            web.emscripten.emscripten_cancel_main_loop();
        }
    }

    /// Entry point called from JavaScript.
    /// Exported as 'wasm_main' and called from JavaScript after WASM module instantiation.
    /// Uses emscripten_set_main_loop to integrate with the browser's requestAnimationFrame.
    ///
    /// Initializes:
    /// 1. WebPlatform - for input and canvas management
    /// 2. Renderer - WebGPU rendering context via initWeb()
    /// 3. SwapChainRenderTarget - render target for the canvas
    /// 4. App - application state and logic
    /// 5. GlobalAppState - ties platform, app, renderer, and render target together
    ///
    /// The global state is stored in static variables to survive across callback invocations.
    pub fn wasm_main() callconv(.c) void {
        log.info("wasm_main: initializing web platform", .{});

        // Initialize web platform in static storage
        static_platform = web.WebPlatform.init(std.heap.page_allocator);

        // Get canvas dimensions for renderer initialization
        const fb_size = static_platform.getFramebufferSize();
        log.info("wasm_main: canvas size {}x{}", .{ fb_size.width, fb_size.height });

        // Initialize WebGPU renderer for web platform.
        // This creates the WebGPU instance, surface, adapter, device, and swap chain.
        log.info("wasm_main: initializing WebGPU renderer", .{});
        static_renderer = Renderer.initWeb(std.heap.page_allocator, fb_size.width, fb_size.height) catch |err| {
            log.err("wasm_main: failed to initialize renderer: {}", .{err});
            return;
        };
        log.info("wasm_main: WebGPU renderer initialized successfully", .{});

        // Create SwapChainRenderTarget from the renderer's swap chain.
        // This wraps the swap chain to implement the RenderTarget interface.
        static_swap_chain_target = static_renderer.createSwapChainRenderTarget();
        static_render_target = static_swap_chain_target.render_target;
        // Update context pointer after struct is in final location
        static_render_target.context = @ptrCast(&static_swap_chain_target);
        log.info("wasm_main: swap chain render target created", .{});

        // Initialize application state in static storage
        static_app = App.init(std.heap.page_allocator);

        // Set renderer reference for the app (for screenshot capability)
        static_app.setRenderer(&static_renderer);

        // Initialize global app state struct with platform, app, renderer, and render target.
        // All pointers are now valid and ready for the main loop callback.
        static_app_state = .{
            .platform = &static_platform,
            .app = &static_app,
            .renderer = &static_renderer,
            .last_frame_time = web.emscripten.emscripten_get_now(),
            .render_target = &static_render_target,
        };

        // Set the global state pointer for callback access
        web.initGlobalAppState(&static_app_state);

        // Also set global renderer and render target via web module helpers
        web.setGlobalRenderer(&static_renderer);
        web.setGlobalRenderTarget(&static_render_target);

        log.info("wasm_main: platform, renderer, and app initialized, starting main loop", .{});

        // Start the main loop using emscripten_set_main_loop.
        // Parameters:
        // - callback: Function to call each frame
        // - fps: 0 means use requestAnimationFrame (vsync)
        // - simulate_infinite_loop: 1 means the function doesn't return (required for WASM)
        //
        // This integrates with the browser's animation frame system. The callback
        // will be called each frame by the browser, typically at 60 FPS.
        //
        // Note: With simulate_infinite_loop=1, this function never returns.
        // The platform and app state are stored in static variables and accessed
        // via global_app_state pointer from the callback.
        web.emscripten.emscripten_set_main_loop(mainLoopCallback, 0, 1);

        // This line is never reached because simulate_infinite_loop=1
        log.info("wasm_main: main loop exited (unexpected)", .{});
    }
} else struct {};

// Export wasm_main for WASM builds.
// The comptime export ensures the symbol is only created for WASM targets.
comptime {
    if (is_wasm) {
        @export(&wasm_exports.wasm_main, .{ .name = "wasm_main" });
    }
}

// For WASM builds targeting emscripten, we need to provide a _start symbol to prevent
// std.start from trying to export its own _start (which uses arch-specific assembly
// that doesn't support wasm32-emscripten). This is a no-op since we use wasm_main
// as the actual entry point called from JavaScript.
//
// The pub declaration satisfies the @hasDecl(root, "_start") check in std/start.zig.
pub const _start = if (is_wasm) wasmStart else {};

fn wasmStart() callconv(.c) void {
    // No-op stub. Browser calls wasm_main directly via JavaScript.
}
