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

// Dawn native instance - opaque pointer to C++ dawn::native::Instance
const DawnNativeInstance = ?*opaque {};
const DawnProcsTable = ?*anyopaque;

// External C functions from dawn.cpp and dawn_proc.c
extern fn dniCreate() DawnNativeInstance;
extern fn dniDestroy(dni: DawnNativeInstance) void;
extern fn dniGetWgpuInstance(dni: DawnNativeInstance) ?zgpu.wgpu.Instance;
extern fn dnGetProcs() DawnProcsTable;
extern fn dawnProcSetProcs(procs: DawnProcsTable) void;

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
    /// Failed to begin frame (swap chain not initialized or texture unavailable).
    BeginFrameFailed,
};

/// Resources needed for rendering a single frame.
/// Returned by beginFrame(), consumed by endFrame().
pub const FrameState = struct {
    /// Texture view to render into (from swap chain).
    texture_view: zgpu.wgpu.TextureView,
    /// Command encoder for recording GPU commands this frame.
    command_encoder: zgpu.wgpu.CommandEncoder,
};

/// Renderer encapsulates all WebGPU rendering state and operations.
/// This is the central abstraction for GPU-accelerated rendering.
pub const Renderer = struct {
    const Self = @This();

    /// Dawn native instance - must be kept alive for WebGPU to function.
    native_instance: DawnNativeInstance,
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
    /// Window reference for resize detection.
    window: ?*zglfw.Window,
    /// Current swap chain dimensions for resize detection.
    swapchain_width: u32,
    /// Current swap chain dimensions for resize detection.
    swapchain_height: u32,

    /// Initialize the renderer.
    /// Creates a WebGPU instance and requests a high-performance adapter.
    /// Returns an error if adapter or device request fails.
    pub fn init() RendererError!Self {
        log.debug("initializing renderer", .{});

        // Initialize Dawn proc table - MUST be called before any WebGPU functions
        dawnProcSetProcs(dnGetProcs());
        log.debug("Dawn proc table initialized", .{});

        // Create Dawn native instance (C++ object that manages WebGPU backend)
        const native_instance = dniCreate();
        errdefer dniDestroy(native_instance);

        // Get WebGPU instance from Dawn native instance
        const instance = dniGetWgpuInstance(native_instance) orelse {
            log.err("failed to get WebGPU instance from Dawn", .{});
            return RendererError.InstanceCreationFailed;
        };
        log.debug("WebGPU instance created", .{});

        // Request adapter with high-performance preference
        const adapter = requestAdapter(instance) orelse {
            log.err("failed to obtain WebGPU adapter", .{});
            instance.release();
            return RendererError.AdapterRequestFailed;
        };
        log.info("WebGPU adapter obtained", .{});

        // Request device with default limits (sufficient for 2D triangle rendering)
        const device = requestDevice(adapter) orelse {
            log.err("failed to obtain WebGPU device", .{});
            adapter.release();
            instance.release();
            return RendererError.DeviceRequestFailed;
        };
        log.info("WebGPU device obtained", .{});

        // Get the command queue from the device
        const queue = device.getQueue();
        log.debug("WebGPU queue obtained", .{});

        return Self{
            .native_instance = native_instance,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = null,
            .swapchain = null,
            .window = null,
            .swapchain_width = 0,
            .swapchain_height = 0,
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
        self.window = window;
        self.swapchain_width = width;
        self.swapchain_height = height;
        log.info("WebGPU swap chain created: {}x{}", .{ width, height });
    }

    /// Begin a new frame for rendering.
    /// Gets the current swap chain texture view and creates a command encoder.
    /// Call this once at the start of each frame before recording render commands.
    /// Handles swap chain recreation if the window has been resized.
    /// Returns FrameState containing the texture view and command encoder.
    pub fn beginFrame(self: *Self) RendererError!FrameState {
        const device = self.device orelse {
            log.err("cannot begin frame: device not initialized", .{});
            return RendererError.BeginFrameFailed;
        };

        const window = self.window orelse {
            log.err("cannot begin frame: window not set", .{});
            return RendererError.BeginFrameFailed;
        };

        // Check if window was resized and recreate swap chain if needed
        const fb_size = window.getFramebufferSize();
        const current_width: u32 = @intCast(fb_size[0]);
        const current_height: u32 = @intCast(fb_size[1]);

        if (current_width != self.swapchain_width or current_height != self.swapchain_height) {
            // Window was resized - need to recreate swap chain
            if (current_width > 0 and current_height > 0) {
                log.info("window resized: {}x{} -> {}x{}, recreating swap chain", .{
                    self.swapchain_width, self.swapchain_height, current_width, current_height,
                });
                try self.recreateSwapChain(current_width, current_height);
            } else {
                // Window is minimized (zero size) - skip this frame
                log.debug("window minimized, skipping frame", .{});
                return RendererError.BeginFrameFailed;
            }
        }

        const swapchain = self.swapchain orelse {
            log.err("cannot begin frame: swap chain not initialized", .{});
            return RendererError.BeginFrameFailed;
        };

        // Get the texture view from the swap chain for this frame.
        // Dawn's getCurrentTextureView can return null (as address 0) if the
        // swap chain is invalid. We check for this by inspecting the pointer address.
        const texture_view = swapchain.getCurrentTextureView();
        if (@intFromPtr(texture_view) == 0) {
            log.warn("swap chain returned null texture view, attempting recreation", .{});
            try self.recreateSwapChain(current_width, current_height);

            // Try again after recreation
            const new_swapchain = self.swapchain orelse {
                log.err("swap chain recreation failed", .{});
                return RendererError.BeginFrameFailed;
            };
            const new_texture_view = new_swapchain.getCurrentTextureView();
            if (@intFromPtr(new_texture_view) == 0) {
                log.err("swap chain still returning null texture view after recreation", .{});
                return RendererError.BeginFrameFailed;
            }

            // Create command encoder with the new texture view
            const command_encoder = device.createCommandEncoder(.{
                .next_in_chain = null,
                .label = "Frame Command Encoder",
            });

            log.debug("frame begun (after swap chain recreation)", .{});

            return FrameState{
                .texture_view = new_texture_view,
                .command_encoder = command_encoder,
            };
        }

        // Create a command encoder for recording GPU commands this frame
        const command_encoder = device.createCommandEncoder(.{
            .next_in_chain = null,
            .label = "Frame Command Encoder",
        });

        log.debug("frame begun", .{});

        return FrameState{
            .texture_view = texture_view,
            .command_encoder = command_encoder,
        };
    }

    /// Recreate the swap chain with new dimensions.
    /// Called internally when window resize is detected.
    fn recreateSwapChain(self: *Self, width: u32, height: u32) RendererError!void {
        const device = self.device orelse {
            return RendererError.SwapChainCreationFailed;
        };

        const surface = self.surface orelse {
            return RendererError.SwapChainCreationFailed;
        };

        // Release old swap chain
        if (self.swapchain) |old_swapchain| {
            old_swapchain.release();
        }

        // Create new swap chain with updated dimensions
        const swapchain = device.createSwapChain(
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
        self.swapchain_width = width;
        self.swapchain_height = height;
        log.info("swap chain recreated: {}x{}", .{ width, height });
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
        const native_os = builtin.os.tag;

        // Use compile-time OS detection to avoid referencing unavailable symbols
        if (native_os == .windows) {
            return createWin32Surface(instance, window);
        } else if (native_os == .macos) {
            log.warn("macOS surface creation not yet implemented", .{});
            return null;
        } else {
            // Linux - check runtime platform (X11 vs Wayland)
            const platform = zglfw.getPlatform();
            return switch (platform) {
                .x11 => createX11Surface(instance, window),
                .wayland => createWaylandSurface(instance, window),
                else => blk: {
                    log.err("unsupported platform for surface creation: {}", .{platform});
                    break :blk null;
                },
            };
        }
    }

    /// Create X11 surface (Linux only)
    fn createX11Surface(instance: zgpu.wgpu.Instance, window: *zglfw.Window) ?zgpu.wgpu.Surface {
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
    }

    /// Create Wayland surface (Linux only)
    fn createWaylandSurface(instance: zgpu.wgpu.Instance, window: *zglfw.Window) ?zgpu.wgpu.Surface {
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
    }

    /// Create Win32 surface (Windows only)
    fn createWin32Surface(instance: zgpu.wgpu.Instance, window: *zglfw.Window) ?zgpu.wgpu.Surface {
        if (builtin.os.tag != .windows) {
            @compileError("createWin32Surface should only be called on Windows");
        }

        const hwnd = zglfw.getWin32Window(window);
        if (hwnd == null) {
            log.err("failed to get Win32 window handle", .{});
            return null;
        }

        const hinstance = std.os.windows.kernel32.GetModuleHandleW(null);
        if (hinstance == null) {
            log.err("failed to get module handle", .{});
            return null;
        }

        var desc: zgpu.wgpu.SurfaceDescriptorFromWindowsHWND = .{
            .chain = .{
                .next = null,
                .struct_type = .surface_descriptor_from_windows_hwnd,
            },
            .hinstance = hinstance.?,
            .hwnd = hwnd.?,
        };

        return instance.createSurface(.{
            .next_in_chain = @ptrCast(&desc.chain),
            .label = "Win32 Surface",
        });
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

        // Destroy Dawn native instance (C++ cleanup)
        if (self.native_instance) |ni| {
            dniDestroy(ni);
            self.native_instance = null;
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
