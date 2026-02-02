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
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

const App = @import("app.zig").App;
const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;

/// Frames per second cap for delta time calculation.
/// If a frame takes longer than this, delta_time is capped to prevent
/// large jumps in game state (e.g., when window is dragged or minimized).
const MAX_DELTA_TIME: f32 = 0.25; // 4 FPS minimum
const desktop = @import("platform/desktop.zig");
const headless = @import("platform/headless.zig");
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const OffscreenRenderTarget = renderer_mod.OffscreenRenderTarget;

const log = std.log.scoped(.main);

/// Configure logging level.
/// Set to .debug for verbose output, .info for normal, .warn or .err for quieter output.
pub const std_options: std.Options = .{
    .log_level = .info,
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

pub fn main() void {
    log.info("zig-gui-experiment starting", .{});

    // Parse command-line arguments using page_allocator for cross-platform compatibility
    const config = parseArgs(std.heap.page_allocator);
    log.info("config: headless={}, {}x{}", .{ config.headless, config.width, config.height });

    if (config.headless) {
        runHeadless(config);
    } else {
        runWindowed(config);
    }

    log.info("zig-gui-experiment exiting", .{});
}

/// Run in windowed mode with GLFW and swap chain rendering.
fn runWindowed(config: Config) void {
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

    // Initialize application state
    var app = App.init(std.heap.page_allocator);
    defer app.deinit();

    // Get the platform abstraction interface
    var plat = platform.platform();

    log.info("entering main loop", .{});

    var first_frame_rendered = false;
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

        if (!first_frame_rendered) {
            first_frame_rendered = true;
            if (config.screenshot_filename) |filename| {
                renderer.takeScreenshot(filename) catch |err| {
                    log.err("failed to take startup screenshot: {}", .{err});
                };
                log.info("screenshot mode: exiting after capturing {s}", .{filename});
                break;
            }
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

    // Initialize application state
    var app = App.init(std.heap.page_allocator);
    defer app.deinit();

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
        renderer.endFrame(frame_state, render_target);

        frame_count += 1;
        log.info("headless frame {} rendered successfully", .{frame_count});

        // Handle screenshot option - take screenshot and exit
        if (config.screenshot_filename) |filename| {
            log.info("taking headless screenshot to {s}", .{filename});
            renderer.takeScreenshotFromOffscreen(&offscreen_target, filename) catch |err| {
                log.err("failed to take headless screenshot: {}", .{err});
            };
            log.info("headless screenshot complete, exiting", .{});
            break;
        }
    }

    log.info("headless rendering complete after {} frames", .{frame_count});
}
