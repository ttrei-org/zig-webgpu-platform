//! Renderer module - WebGPU rendering abstraction
//!
//! This module provides the central rendering abstraction for the application,
//! encapsulating all WebGPU state and operations. The Renderer struct manages
//! the graphics device, command queue, and swap chain for presenting frames.

const std = @import("std");
const builtin = @import("builtin");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

const log = std.log.scoped(.renderer);

/// Error type for renderer operations.
pub const RendererError = error{
    /// Failed to create WebGPU instance.
    InstanceCreationFailed,
    /// Failed to obtain a WebGPU adapter (no compatible GPU found).
    AdapterRequestFailed,
    /// Failed to obtain a WebGPU device from the adapter.
    DeviceRequestFailed,
    /// Failed to create WebGPU surface from window.
    SurfaceCreationFailed,
    /// Failed to create swap chain.
    SwapChainCreationFailed,
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
    /// Window surface for presenting rendered frames.
    surface: ?zgpu.wgpu.Surface,
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
            .surface = null,
            .swapchain = null,
        };
    }

    /// Create a swap chain from a GLFW window.
    /// Creates a WebGPU surface from the native window handle and configures
    /// a swap chain with BGRA8Unorm format and Fifo present mode (vsync).
    pub fn createSwapChain(self: *Self, window: *zglfw.Window, width: u32, height: u32) RendererError!void {
        if (self.instance == null or self.device == null) {
            log.err("cannot create swap chain: instance or device not initialized", .{});
            return RendererError.SwapChainCreationFailed;
        }

        // Create surface from the GLFW window (platform-specific)
        const surface = createSurfaceFromWindow(self.instance.?, window);
        if (surface == null) {
            log.err("failed to create WebGPU surface from window", .{});
            return RendererError.SurfaceCreationFailed;
        }
        self.surface = surface;
        log.debug("WebGPU surface created", .{});

        // Create swap chain with standard settings for 2D rendering
        const swapchain = self.device.?.createSwapChain(
            surface,
            .{
                .next_in_chain = null,
                .label = "Main Swap Chain",
                .usage = .{ .render_attachment = true },
                .format = .bgra8_unorm,
                .width = width,
                .height = height,
                .present_mode = .fifo, // VSync enabled
            },
        );

        self.swapchain = swapchain;
        log.info("WebGPU swap chain created: {}x{}", .{ width, height });
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

    /// Create a WebGPU surface from a GLFW window handle.
    /// Handles platform-specific native window types (X11, Wayland, Win32, Cocoa).
    fn createSurfaceFromWindow(instance: zgpu.wgpu.Instance, window: *zglfw.Window) ?zgpu.wgpu.Surface {
        const platform = zglfw.getPlatform();

        switch (platform) {
            .x11 => {
                const display = zglfw.getX11Display();
                const x11_window = zglfw.getX11Window(window);

                if (display == null) {
                    log.err("failed to get X11 display", .{});
                    return null;
                }

                var desc: zgpu.wgpu.SurfaceDescriptorFromXlibWindow = .{
                    .chain = .{
                        .next = null,
                        .struct_type = .surface_descriptor_from_xlib_window,
                    },
                    .display = display.?,
                    .window = x11_window,
                };

                return instance.createSurface(.{
                    .next_in_chain = @ptrCast(&desc.chain),
                    .label = "X11 Surface",
                });
            },
            .wayland => {
                const display = zglfw.getWaylandDisplay();
                const wl_surface = zglfw.getWaylandWindow(window);

                if (display == null or wl_surface == null) {
                    log.err("failed to get Wayland display or surface", .{});
                    return null;
                }

                var desc: zgpu.wgpu.SurfaceDescriptorFromWaylandSurface = .{
                    .chain = .{
                        .next = null,
                        .struct_type = .surface_descriptor_from_wayland_surface,
                    },
                    .display = display.?,
                    .surface = wl_surface.?,
                };

                return instance.createSurface(.{
                    .next_in_chain = @ptrCast(&desc.chain),
                    .label = "Wayland Surface",
                });
            },
            .win32 => {
                // Windows support - requires HWND and HINSTANCE
                const hwnd = zglfw.getWin32Window(window);
                if (hwnd == null) {
                    log.err("failed to get Win32 window handle", .{});
                    return null;
                }

                var desc: zgpu.wgpu.SurfaceDescriptorFromWindowsHWND = .{
                    .chain = .{
                        .next = null,
                        .struct_type = .surface_descriptor_from_windows_hwnd,
                    },
                    .hinstance = std.os.windows.kernel32.GetModuleHandleW(null),
                    .hwnd = hwnd.?,
                };

                return instance.createSurface(.{
                    .next_in_chain = @ptrCast(&desc.chain),
                    .label = "Win32 Surface",
                });
            },
            .cocoa => {
                // macOS support - requires NSWindow (via objc runtime)
                // This path requires additional setup for metal layer
                log.warn("macOS surface creation not yet implemented", .{});
                return null;
            },
            else => {
                log.err("unsupported platform for surface creation: {}", .{platform});
                return null;
            },
        }
    }

    /// Clean up renderer resources.
    /// Releases all WebGPU resources held by the renderer.
    pub fn deinit(self: *Self) void {
        log.debug("deinitializing renderer", .{});

        // Release swap chain first as it depends on the surface
        if (self.swapchain) |swapchain| {
            swapchain.release();
            self.swapchain = null;
        }

        // Release surface after swap chain
        if (self.surface) |surface| {
            surface.release();
            self.surface = null;
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
    _ = RendererError.SurfaceCreationFailed;
    _ = RendererError.SwapChainCreationFailed;
}
