//! zig-webgpu-platform - Public Library Interface
//!
//! This module provides the public API surface for applications using zig-webgpu-platform
//! as a library. Import this module to access all types needed for building graphical
//! applications.
//!
//! ## Quick Start
//!
//! ```zig
//! const platform = @import("zig-webgpu-platform");
//! const Canvas = platform.Canvas;
//! const Color = platform.Color;
//! const AppInterface = platform.AppInterface;
//!
//! // Create your app implementing the AppInterface pattern
//! var app = MyApp.init(allocator);
//! var iface = app.appInterface();
//!
//! // Run the platform (handles all backend initialization and main loop)
//! platform.run(&iface, .{});
//! ```
//!
//! ## Exported Types
//!
//! - `Canvas` - 2D shape drawing API
//! - `Viewport` - Logical coordinate space definition
//! - `Color` - RGBA color type with factory methods
//! - `AppInterface` - Application lifecycle interface (vtable pattern)
//! - `MouseState` - Mouse position and button state
//! - `MouseButton` - Mouse button identifiers
//! - `Key` - Keyboard key identifiers

const std = @import("std");
const builtin = @import("builtin");

// --- Public Types from canvas.zig ---
const canvas_mod = @import("canvas.zig");
pub const Canvas = canvas_mod.Canvas;
pub const Viewport = canvas_mod.Viewport;

// --- Public Types from color.zig ---
const color_mod = @import("color.zig");
pub const Color = color_mod.Color;

// --- Public Types from app_interface.zig ---
const app_interface_mod = @import("app_interface.zig");
pub const AppInterface = app_interface_mod.AppInterface;

// --- Public Types from platform.zig ---
const platform_mod = @import("platform.zig");
pub const MouseState = platform_mod.MouseState;
pub const MouseButton = platform_mod.MouseButton;
pub const Key = platform_mod.Key;

// --- Internal modules (not exported, but needed for run()) ---
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;

/// True if building for native desktop (not WASM/web)
pub const is_native = platform_mod.is_native;

/// True if building for WASM (web) target
pub const is_wasm = builtin.cpu.arch.isWasm();

/// zglfw is only available on native desktop builds
const zglfw = if (is_native) @import("zglfw") else struct {};

/// Desktop platform is only available for native builds
const desktop = if (is_native) @import("platform/desktop.zig") else struct {};
const headless = @import("platform/headless.zig");

const log = std.log.scoped(.lib);

/// Logical viewport dimensions for the application's drawing coordinate space.
/// All drawing code uses this fixed coordinate space; the GPU scales it to
/// whatever physical resolution the render target provides.
pub const DEFAULT_VIEWPORT: Viewport = .{ .logical_width = 400.0, .logical_height = 300.0 };

/// Frames per second cap for delta time calculation.
/// If a frame takes longer than this, delta_time is capped to prevent
/// large jumps in game state (e.g., when window is dragged or minimized).
const MAX_DELTA_TIME: f32 = 0.25; // 4 FPS minimum

/// Configuration options for the platform runner.
pub const RunOptions = struct {
    /// Logical viewport dimensions for drawing.
    /// Applications draw in this coordinate space regardless of window size.
    viewport: Viewport = DEFAULT_VIEWPORT,

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

    /// Window title (desktop only).
    window_title: [:0]const u8 = "Zig WebGPU Application",
};

/// Convert mouse coordinates from physical window/canvas space to logical viewport space.
fn toLogicalCoordinates(mouse: MouseState, window_size: platform_mod.Size, viewport: Viewport) MouseState {
    const win_w: f32 = @floatFromInt(window_size.width);
    const win_h: f32 = @floatFromInt(window_size.height);

    // Guard against division by zero (minimized window or uninitialized state)
    if (win_w <= 0 or win_h <= 0) return mouse;

    var result = mouse;
    result.x = mouse.x * (viewport.logical_width / win_w);
    result.y = mouse.y * (viewport.logical_height / win_h);
    return result;
}

/// Run the platform with the provided application interface.
///
/// This function initializes the appropriate platform backend (desktop, web, or headless),
/// creates the renderer, and runs the main loop until the application requests quit.
///
/// For native builds, this function returns when the application exits.
/// For WASM builds, this function sets up the browser's requestAnimationFrame callback
/// and returns immediately (the loop continues asynchronously).
///
/// Parameters:
/// - `app`: Pointer to an AppInterface that will receive update/render callbacks
/// - `options`: Platform configuration (viewport, window size, headless mode, etc.)
///
/// Example:
/// ```zig
/// var app = MyApp.init(allocator);
/// var iface = app.appInterface();
/// defer iface.deinit();
///
/// platform.run(&iface, .{
///     .viewport = .{ .logical_width = 800.0, .logical_height = 600.0 },
///     .width = 1280,
///     .height = 720,
/// });
/// ```
pub fn run(app: *AppInterface, options: RunOptions) void {
    if (is_wasm) {
        // WASM builds use the existing wasm_main infrastructure in main.zig.
        // The run() function is not the primary entry point for WASM.
        // Instead, JavaScript calls wasm_main which sets up the main loop.
        log.warn("run() called on WASM - use wasm_main instead", .{});
        return;
    }

    // Native builds: parse command-line args to override options
    const config = parseArgsWithDefaults(std.heap.page_allocator, options);

    if (config.headless) {
        runHeadless(app, config);
    } else {
        runWindowed(app, config);
    }
}

/// Internal configuration combining RunOptions with CLI overrides.
const InternalConfig = struct {
    viewport: Viewport,
    screenshot_filename: ?[]const u8,
    headless: bool,
    width: u32,
    height: u32,
    window_title: [:0]const u8,
};

/// Parse command-line arguments, using RunOptions as defaults.
fn parseArgsWithDefaults(allocator: std.mem.Allocator, defaults: RunOptions) InternalConfig {
    var config: InternalConfig = .{
        .viewport = defaults.viewport,
        .screenshot_filename = defaults.screenshot_filename,
        .headless = defaults.headless,
        .width = defaults.width,
        .height = defaults.height,
        .window_title = defaults.window_title,
    };

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
                log.warn("invalid --width value '{s}', using default", .{width_str});
                continue;
            };
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            const height_str = arg["--height=".len..];
            config.height = std.fmt.parseInt(u32, height_str, 10) catch {
                log.warn("invalid --height value '{s}', using default", .{height_str});
                continue;
            };
        }
    }

    return config;
}

/// Run the application in windowed mode with GLFW.
fn runWindowed(app: *AppInterface, config: InternalConfig) void {
    if (!is_native) {
        log.err("windowed mode not available on this platform", .{});
        return;
    }

    log.info("starting windowed mode", .{});

    // Build a Config struct for DesktopPlatform
    const platform_config = .{
        .screenshot_filename = config.screenshot_filename,
        .headless = false,
        .width = config.width,
        .height = config.height,
    };

    // Initialize desktop platform with GLFW
    var platform = desktop.DesktopPlatform.init(std.heap.page_allocator, platform_config) catch |err| {
        log.err("failed to initialize platform: {}", .{err});
        return;
    };
    defer platform.deinit();

    // Create window using config dimensions
    platform.createWindow(config.width, config.height, config.window_title) catch |err| {
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

    log.info("WebGPU initialization complete", .{});

    // Create a SwapChainRenderTarget for windowed rendering
    var swap_chain_target = renderer.createSwapChainRenderTarget();
    var render_target = swap_chain_target.asRenderTarget();

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

        // Convert mouse from window-pixel space to logical viewport space.
        const raw_mouse = plat.getMouseState();
        const mouse_state = toLogicalCoordinates(raw_mouse, plat.getWindowSize(), config.viewport);
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

        // Detect device loss and attempt recovery by reinitializing the renderer.
        if (renderer.isDeviceLost()) {
            log.warn("GPU device lost - attempting recovery", .{});
            renderer.deinit();

            const fb = platform.getFramebufferSize();
            renderer = Renderer.init(std.heap.page_allocator, platform.window.?, fb.width, fb.height) catch |reinit_err| {
                log.err("device recovery failed: {} - exiting", .{reinit_err});
                return;
            };
            swap_chain_target = renderer.createSwapChainRenderTarget();
            render_target = swap_chain_target.asRenderTarget();

            log.info("GPU device recovered successfully", .{});
            continue;
        }

        runFrame(app, &renderer, &render_target, config.viewport, null);

        // Check if App wants to take a screenshot after this frame
        if (app.shouldTakeScreenshot()) |filename| {
            renderer.screenshot(filename) catch |err| {
                log.err("failed to take screenshot: {}", .{err});
            };
            app.onScreenshotComplete();
        }
    }
}

/// Run the application in headless mode (no window).
fn runHeadless(app: *AppInterface, config: InternalConfig) void {
    const zgpu = @import("zgpu");

    log.info("starting headless mode", .{});

    // Build a Config struct for HeadlessPlatform
    const platform_config = .{
        .screenshot_filename = config.screenshot_filename,
        .headless = true,
        .width = config.width,
        .height = config.height,
    };

    // Initialize headless platform (no GLFW, no display required)
    var platform = headless.HeadlessPlatform.init(std.heap.page_allocator, platform_config);
    defer platform.deinit();

    // Initialize WebGPU renderer in headless mode (no surface/swap chain)
    var renderer = Renderer.initHeadless(std.heap.page_allocator, config.width, config.height) catch |err| {
        log.err("failed to initialize headless renderer: {}", .{err});
        return;
    };
    defer renderer.deinit();

    log.info("WebGPU headless initialization complete", .{});

    // Create an OffscreenRenderTarget for headless rendering
    var offscreen_target = renderer.createOffscreenRenderTarget(config.width, config.height) catch |err| {
        log.err("failed to create offscreen render target: {}", .{err});
        return;
    };
    defer offscreen_target.deinit();
    const render_target = offscreen_target.asRenderTarget();

    // Get the platform abstraction interface
    var plat = platform.platform();

    log.info("entering headless main loop", .{});

    var frame_count: u64 = 0;

    // Headless main loop - runs for a limited number of frames or until screenshot is taken
    while (!plat.shouldQuit() and app.isRunning()) {
        plat.pollEvents();

        // Use synthetic delta time (60 FPS simulation)
        const delta_time: f32 = 1.0 / 60.0;

        // Convert mouse from physical pixel space to logical viewport space.
        const raw_mouse = plat.getMouseState();
        const mouse_state = toLogicalCoordinates(raw_mouse, plat.getWindowSize(), config.viewport);
        app.update(delta_time, mouse_state);

        // Use pre-submit hook to copy rendered texture to staging buffer
        const OffscreenRenderTarget = renderer_mod.OffscreenRenderTarget;
        const hook: PreSubmitHook = .{
            .context = @ptrCast(&offscreen_target),
            .callback = &struct {
                fn cb(ctx: *anyopaque, encoder: zgpu.wgpu.CommandEncoder) void {
                    const target: *OffscreenRenderTarget = @ptrCast(@alignCast(ctx));
                    target.copyToStagingBuffer(encoder);
                }
            }.cb,
        };
        runFrame(app, &renderer, render_target, config.viewport, hook);

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

/// Hook called between endRenderPass and endFrame.
const PreSubmitHook = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, encoder: @import("zgpu").wgpu.CommandEncoder) void,

    fn call(self: PreSubmitHook, encoder: @import("zgpu").wgpu.CommandEncoder) void {
        self.callback(self.context, encoder);
    }
};

/// Execute one frame of the update/render/present pipeline.
fn runFrame(
    app: *AppInterface,
    renderer: *Renderer,
    render_target: *renderer_mod.RenderTarget,
    viewport: Viewport,
    pre_submit_hook: ?PreSubmitHook,
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

    // Set logical viewport dimensions so the shader maps logical coords to NDC.
    renderer.setLogicalSize(viewport.logical_width, viewport.logical_height);

    const render_pass = Renderer.beginRenderPass(frame_state, Renderer.cornflower_blue);
    var canvas = Canvas.init(renderer, viewport);
    app.render(&canvas);
    renderer.flushBatch(render_pass);
    Renderer.endRenderPass(render_pass);

    // Allow caller to record commands before the command buffer is submitted
    if (pre_submit_hook) |hook| {
        hook.call(frame_state.command_encoder);
    }

    renderer.endFrame(frame_state, render_target);
}

// --- Tests ---

test "lib exports Canvas type" {
    const canvas_type = Canvas;
    try std.testing.expect(@TypeOf(canvas_type) != void);
}

test "lib exports Color type" {
    const color = Color.red;
    try std.testing.expectEqual(@as(f32, 1.0), color.r);
}

test "lib exports Viewport type" {
    const vp: Viewport = .{ .logical_width = 400.0, .logical_height = 300.0 };
    try std.testing.expectEqual(@as(f32, 400.0), vp.logical_width);
}

test "lib exports AppInterface type" {
    const iface_type = @typeInfo(AppInterface);
    try std.testing.expect(iface_type == .@"struct");
}

test "lib exports MouseState type" {
    const mouse: MouseState = .{
        .x = 100.0,
        .y = 200.0,
        .left_pressed = true,
        .right_pressed = false,
        .middle_pressed = false,
    };
    try std.testing.expectEqual(@as(f32, 100.0), mouse.x);
}

test "lib exports MouseButton type" {
    const btn: MouseButton = .left;
    try std.testing.expect(btn == .left);
}

test "lib exports Key type" {
    const key: Key = .escape;
    try std.testing.expect(key == .escape);
}

test "DEFAULT_VIEWPORT has expected dimensions" {
    try std.testing.expectEqual(@as(f32, 400.0), DEFAULT_VIEWPORT.logical_width);
    try std.testing.expectEqual(@as(f32, 300.0), DEFAULT_VIEWPORT.logical_height);
}

test "toLogicalCoordinates handles zero dimensions" {
    const mouse: MouseState = .{
        .x = 100.0,
        .y = 100.0,
        .left_pressed = false,
        .right_pressed = false,
        .middle_pressed = false,
    };
    const zero_size: platform_mod.Size = .{ .width = 0, .height = 0 };
    const viewport: Viewport = .{ .logical_width = 400.0, .logical_height = 300.0 };

    // Should return original coordinates when window size is zero
    const result = toLogicalCoordinates(mouse, zero_size, viewport);
    try std.testing.expectEqual(@as(f32, 100.0), result.x);
    try std.testing.expectEqual(@as(f32, 100.0), result.y);
}

test "toLogicalCoordinates scales correctly" {
    const mouse: MouseState = .{
        .x = 400.0,
        .y = 300.0,
        .left_pressed = false,
        .right_pressed = false,
        .middle_pressed = false,
    };
    const window_size: platform_mod.Size = .{ .width = 800, .height = 600 };
    const viewport: Viewport = .{ .logical_width = 400.0, .logical_height = 300.0 };

    const result = toLogicalCoordinates(mouse, window_size, viewport);
    // 400 * (400/800) = 200
    try std.testing.expectEqual(@as(f32, 200.0), result.x);
    // 300 * (300/600) = 150
    try std.testing.expectEqual(@as(f32, 150.0), result.y);
}
