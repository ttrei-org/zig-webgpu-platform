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
fn parseArgs() Options {
    var opts: Options = .{};
    var args = std.process.args();
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

    // Parse command-line arguments
    const opts = parseArgs();

    // Initialize platform
    var platform = desktop.DesktopPlatform.init(std.heap.page_allocator) catch |err| {
        log.err("failed to initialize platform: {}", .{err});
        return;
    };
    defer platform.deinit();

    // Create window
    platform.createWindow(800, 600, "Zig GUI Experiment") catch |err| {
        log.err("failed to create window: {}", .{err});
        return;
    };

    // Initialize WebGPU renderer with the window.
    // The renderer creates the surface before requesting the adapter to ensure
    // the adapter is compatible with the window surface (required for X11).
    const fb_size = platform.getFramebufferSize();
    var renderer = Renderer.init(platform.window.?, fb_size.width, fb_size.height) catch |err| {
        log.err("failed to initialize renderer: {}", .{err});
        return;
    };
    defer renderer.deinit();

    log.info("WebGPU initialization complete - adapter, device, and swap chain configured", .{});
    log.info("entering main loop", .{});

    // Track if this is the first frame (for --screenshot mode)
    var first_frame_rendered = false;

    // Main loop: poll events and render until window close is requested
    while (!platform.shouldClose()) {
        platform.pollEvents();

        // Exit on Escape key
        if (platform.isKeyPressed(desktop.DesktopPlatform.Key.escape)) {
            break;
        }

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

        // Set render pipeline - configures GPU to use our shader and vertex layout
        render_pass.setPipeline(renderer.render_pipeline.?);

        // Set bind group 0 (uniforms) - required by the pipeline layout
        render_pass.setBindGroup(0, renderer.bind_group.?, &.{});

        // Bind vertex buffer (slot 0, full buffer)
        const vertex_buffer_size: u64 = @sizeOf(@TypeOf(renderer_mod.test_triangle_vertices));
        render_pass.setVertexBuffer(0, renderer.vertex_buffer.?, 0, vertex_buffer_size);

        // Draw the triangle (3 vertices, 1 instance)
        render_pass.draw(3, 1, 0, 0);

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
