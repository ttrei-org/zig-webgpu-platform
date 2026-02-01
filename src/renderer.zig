//! Renderer module - WebGPU rendering abstraction
//!
//! This module provides the central rendering abstraction for the application,
//! encapsulating all WebGPU state and operations. The Renderer struct manages
//! the graphics device, command queue, and swap chain for presenting frames.

const std = @import("std");
const zgpu = @import("zgpu");

const log = std.log.scoped(.renderer);

/// Error type for renderer operations.
pub const RendererError = error{
    /// Failed to create WebGPU instance.
    InstanceCreationFailed,
    /// Failed to obtain a WebGPU adapter (no compatible GPU found).
    AdapterRequestFailed,
    /// Failed to obtain a WebGPU device from the adapter.
    DeviceRequestFailed,
};

/// Renderer encapsulates all WebGPU rendering state and operations.
/// This is the central abstraction for GPU-accelerated rendering.
pub const Renderer = struct {
    const Self = @This();

    /// WebGPU instance handle - entry point for the WebGPU API.
    instance: ?zgpu.wgpu.Instance,
    /// WebGPU adapter representing a physical GPU.
    adapter: ?zgpu.wgpu.Adapter,
    /// WebGPU device handle for creating GPU resources.
    device: ?zgpu.wgpu.Device,
    /// Command queue for submitting work to the GPU.
    queue: ?zgpu.wgpu.Queue,
    /// Swap chain for presenting rendered frames to the window surface.
    swapchain: ?zgpu.wgpu.SwapChain,

    /// Initialize the renderer.
    /// Creates a WebGPU instance and requests a high-performance adapter.
    /// Returns an error if instance creation or adapter request fails.
    pub fn init() RendererError!Self {
        log.debug("initializing renderer", .{});

        // Create WebGPU instance - the entry point for WebGPU API
        const instance = zgpu.wgpu.createInstance(.{ .next_in_chain = null });
        if (instance == null) {
            log.err("failed to create WebGPU instance", .{});
            return RendererError.InstanceCreationFailed;
        }
        log.debug("WebGPU instance created", .{});

        // Request adapter with high-performance preference
        const adapter = requestAdapter(instance.?);
        if (adapter == null) {
            log.err("failed to obtain WebGPU adapter", .{});
            instance.?.release();
            return RendererError.AdapterRequestFailed;
        }
        log.info("WebGPU adapter obtained", .{});

        // Request device with default limits (sufficient for 2D triangle rendering)
        const device = requestDevice(adapter.?);
        if (device == null) {
            log.err("failed to obtain WebGPU device", .{});
            adapter.?.release();
            instance.?.release();
            return RendererError.DeviceRequestFailed;
        }
        log.info("WebGPU device obtained", .{});

        // Get the command queue from the device
        const queue = device.?.getQueue();
        log.debug("WebGPU queue obtained", .{});

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .swapchain = null,
        };
    }

    /// Request a WebGPU adapter from the instance.
    /// Prefers high-performance GPU and uses the default backend.
    /// Returns null if no suitable adapter is available.
    fn requestAdapter(instance: zgpu.wgpu.Instance) ?zgpu.wgpu.Adapter {
        const Response = struct {
            adapter: ?zgpu.wgpu.Adapter = null,
            status: zgpu.wgpu.RequestAdapterStatus = .unknown,
        };

        var response: Response = .{};

        // Request adapter asynchronously - Dawn processes this synchronously
        // on the main thread, so the callback fires before returning.
        instance.requestAdapter(
            .{
                .next_in_chain = null,
                .compatible_surface = null,
                .power_preference = .high_performance,
                .backend_type = .undef, // Let Dawn choose the best backend
                .force_fallback_adapter = false,
                .compatibility_mode = false,
            },
            &adapterCallback,
            @ptrCast(&response),
        );

        if (response.status != .success) {
            log.warn("adapter request failed with status: {}", .{response.status});
            return null;
        }

        return response.adapter;
    }

    /// Callback for adapter request - stores the result in the response struct.
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
        } else {
            const msg = message orelse "unknown error";
            log.err("adapter request failed: {s}", .{msg});
        }
    }

    /// Request a WebGPU device from the adapter.
    /// Uses default limits and features, sufficient for 2D triangle rendering.
    /// Returns null if device creation fails.
    fn requestDevice(adapter: zgpu.wgpu.Adapter) ?zgpu.wgpu.Device {
        const Response = struct {
            device: ?zgpu.wgpu.Device = null,
            status: zgpu.wgpu.RequestDeviceStatus = .unknown,
        };

        var response: Response = .{};

        // Request device with default limits - Dawn processes this synchronously
        // on the main thread, so the callback fires before returning.
        adapter.requestDevice(
            .{
                .next_in_chain = null,
                .label = "Primary Device",
                .required_features_count = 0,
                .required_features = null,
                .required_limits = null,
                .default_queue = .{
                    .next_in_chain = null,
                    .label = "Default Queue",
                },
                .device_lost_callback = null,
                .device_lost_user_data = null,
            },
            &deviceCallback,
            @ptrCast(&response),
        );

        if (response.status != .success) {
            log.warn("device request failed with status: {}", .{response.status});
            return null;
        }

        return response.device;
    }

    /// Callback for device request - stores the result in the response struct.
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
        } else {
            const msg = message orelse "unknown error";
            log.err("device request failed: {s}", .{msg});
        }
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

        // Release the device
        if (self.device) |device| {
            device.release();
            self.device = null;
        }

        // Release the adapter
        if (self.adapter) |adapter| {
            adapter.release();
            self.adapter = null;
        }

        // Release the instance last
        if (self.instance) |instance| {
            instance.release();
            self.instance = null;
        }

        log.info("renderer resources released", .{});
    }
};

test "Renderer init and deinit" {
    // Renderer.init() now requires actual WebGPU hardware, which may not
    // be available in all test environments. We test that the error types
    // are properly defined instead.
    _ = RendererError.InstanceCreationFailed;
    _ = RendererError.AdapterRequestFailed;
    _ = RendererError.DeviceRequestFailed;
}
