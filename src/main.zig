//! Zig GUI Experiment - Main entry point
//!
//! A GPU-accelerated terminal emulator experiment using zgpu and zglfw.

const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

const desktop = @import("platform/desktop.zig");
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;

const log = std.log.scoped(.main);

// Export zgpu types for use in other modules
pub const GraphicsContext = zgpu.GraphicsContext;

pub fn main() void {
    log.info("zig-gui-experiment starting", .{});

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

    // Initialize WebGPU renderer
    var renderer = Renderer.init() catch |err| {
        log.err("failed to initialize renderer: {}", .{err});
        return;
    };
    defer renderer.deinit();

    // Create swap chain from the platform window
    const fb_size = platform.getFramebufferSize();
    renderer.createSwapChain(platform.window.?, fb_size.width, fb_size.height) catch |err| {
        log.err("failed to create swap chain: {}", .{err});
        return;
    };

    log.info("WebGPU initialization complete - adapter, device, and swap chain configured", .{});
    log.info("entering main loop", .{});

    // Main loop: poll events and render until window close is requested
    while (!platform.shouldClose()) {
        platform.pollEvents();

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

        // End render pass (no draw commands yet - just clearing)
        Renderer.endRenderPass(render_pass);

        // Submit command buffer and present frame
        const command_buffer = frame_state.command_encoder.finish(null);
        renderer.queue.?.submit(&[_]@TypeOf(command_buffer){command_buffer});
        renderer.swapchain.?.present();

        // Release resources for this frame
        frame_state.texture_view.release();
    }

    log.info("zig-gui-experiment exiting", .{});
}
