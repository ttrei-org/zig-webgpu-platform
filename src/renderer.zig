//! Renderer module - WebGPU rendering abstraction
//!
//! This module provides the central rendering abstraction for the application,
//! encapsulating all WebGPU state and operations. The Renderer struct manages
//! the graphics device, command queue, and swap chain for presenting frames.

const std = @import("std");
const zgpu = @import("zgpu");

const log = std.log.scoped(.renderer);

/// Renderer encapsulates all WebGPU rendering state and operations.
/// This is the central abstraction for GPU-accelerated rendering.
pub const Renderer = struct {
    const Self = @This();

    /// WebGPU device handle for creating GPU resources.
    device: ?zgpu.wgpu.Device,
    /// Command queue for submitting work to the GPU.
    queue: ?zgpu.wgpu.Queue,
    /// Swap chain for presenting rendered frames to the window surface.
    swapchain: ?zgpu.wgpu.SwapChain,

    /// Initialize the renderer.
    /// Creates a renderer with uninitialized WebGPU state. The actual GPU
    /// resources will be acquired later when the adapter/device are requested.
    pub fn init() Self {
        log.debug("initializing renderer", .{});
        return Self{
            .device = null,
            .queue = null,
            .swapchain = null,
        };
    }

    /// Clean up renderer resources.
    /// Releases all WebGPU resources held by the renderer.
    pub fn deinit(self: *Self) void {
        log.debug("deinitializing renderer", .{});

        // Release swap chain first as it depends on the device
        if (self.swapchain) |swapchain| {
            swapchain.release();
            self.swapchain = null;
        }

        // Queue is owned by the device, no separate release needed
        self.queue = null;

        // Release the device last
        if (self.device) |device| {
            device.release();
            self.device = null;
        }

        log.info("renderer resources released", .{});
    }
};

test "Renderer init and deinit" {
    var renderer = Renderer.init();
    defer renderer.deinit();

    // Verify initial state - all handles should be null
    try std.testing.expect(renderer.device == null);
    try std.testing.expect(renderer.queue == null);
    try std.testing.expect(renderer.swapchain == null);
}
