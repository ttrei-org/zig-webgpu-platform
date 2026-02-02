//! Zig GUI Experiment - Main entry point
//!
//! A GPU-accelerated terminal emulator experiment using zgpu and zglfw.
//!
//! Controls:
//! - Escape: Close the window
//!
//! Command-line options:
//! - --screenshot=<filename>: Take a screenshot after startup and exit

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
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;

const log = std.log.scoped(.main);

/// Configure logging level.
/// Set to .debug for verbose output, .info for normal, .warn or .err for quieter output.
pub const std_options: std.Options = .{
    .log_level = .info,
};

// Export zgpu types for use in other modules
pub const GraphicsContext = zgpu.GraphicsContext;

/// Command-line options parsed from arguments.
const Options = struct {
    /// If set, take a screenshot to this filename and exit.
    screenshot_filename: ?[]const u8 = null,
};

/// Parse command-line arguments.
/// Uses argsWithAllocator for cross-platform compatibility, then deallocates
/// the iterator's internal buffers after parsing is complete.
fn parseArgs(allocator: std.mem.Allocator) Options {
    var opts: Options = .{};
    var args = std.process.argsWithAllocator(allocator) catch |err| {
        log.warn("failed to get command line arguments: {}", .{err});
        return opts;
    };
    defer args.deinit();

    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--screenshot=")) {
            opts.screenshot_filename = arg["--screenshot=".len..];
        }
    }

    return opts;
}

pub fn main() void {
    log.info("zig-gui-experiment starting", .{});

    // Parse command-line arguments using page_allocator for cross-platform compatibility
    const opts = parseArgs(std.heap.page_allocator);

    // Initialize platform
    var platform = desktop.DesktopPlatform.init(std.heap.page_allocator) catch |err| {
        log.err("failed to initialize platform: {}", .{err});
        return;
    };
    defer platform.deinit();

    // Create window
    platform.createWindow(400, 300, "Zig GUI Experiment") catch |err| {
        log.err("failed to create window: {}", .{err});
        return;
    };

    // Initialize WebGPU renderer with the window.
    // The renderer creates the surface before requesting the adapter to ensure
    // the adapter is compatible with the window surface (required for X11).
    const fb_size = platform.getFramebufferSize();
    var renderer = Renderer.init(std.heap.page_allocator, platform.window.?, fb_size.width, fb_size.height) catch |err| {
        log.err("failed to initialize renderer: {}", .{err});
        return;
    };
    defer renderer.deinit();

    log.info("WebGPU initialization complete - adapter, device, and swap chain configured", .{});

    // Initialize application state
    var app = App.init(std.heap.page_allocator);
    defer app.deinit();

    // Get the platform abstraction interface for platform-agnostic main loop.
    // The Platform interface provides shouldQuit(), pollEvents(), getMouseState(),
    // and isKeyPressed() methods that work across desktop, web, and headless backends.
    var plat = platform.platform();

    log.info("entering main loop", .{});

    // Track if this is the first frame (for --screenshot mode)
    var first_frame_rendered = false;

    // Track time for delta calculation
    var last_time: f64 = zglfw.getTime();

    // Main loop: poll events and render until platform requests quit or app stops.
    // Uses the Platform abstraction for portable event handling across backends.
    while (!plat.shouldQuit() and app.isRunning()) {
        // Poll platform events (input, window events, etc.)
        plat.pollEvents();

        // Calculate delta time
        const current_time = zglfw.getTime();
        var delta_time: f32 = @floatCast(current_time - last_time);
        last_time = current_time;

        // Cap delta time to prevent large jumps after pauses
        if (delta_time > MAX_DELTA_TIME) {
            delta_time = MAX_DELTA_TIME;
        }

        // Exit on Escape key (using platform-agnostic key check)
        if (plat.isKeyPressed(.escape)) {
            app.requestQuit();
            continue;
        }

        // Get mouse state for input handling
        const mouse_state = plat.getMouseState();

        // Update application state with delta time and input
        app.update(delta_time, mouse_state);

        // Begin frame - get swap chain texture and command encoder
        const frame_state = renderer.beginFrame() catch |err| {
            // Skip this frame on error (e.g., window minimized)
            if (err != renderer_mod.RendererError.BeginFrameFailed) {
                log.warn("beginFrame failed: {}", .{err});
            }
            continue;
        };

        // Begin render pass with cornflower blue clear color
        const render_pass = Renderer.beginRenderPass(frame_state, Renderer.cornflower_blue);

        // Let the app queue draw commands
        app.render(&renderer);

        // Flush all queued triangles in a single batched draw call
        renderer.flushBatch(render_pass);

        // End render pass
        Renderer.endRenderPass(render_pass);

        // End frame: submit command buffer and present swap chain
        renderer.endFrame(frame_state);

        // Handle --screenshot option: take screenshot after first frame and exit
        if (!first_frame_rendered) {
            first_frame_rendered = true;
            if (opts.screenshot_filename) |filename| {
                renderer.takeScreenshot(filename) catch |err| {
                    log.err("failed to take startup screenshot: {}", .{err});
                };
                log.info("screenshot mode: exiting after capturing {s}", .{filename});
                break;
            }
        }
    }

    log.info("zig-gui-experiment exiting", .{});
}
