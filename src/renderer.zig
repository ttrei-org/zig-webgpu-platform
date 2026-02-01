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
    /// Failed to compile shader module.
    ShaderCompilationFailed,
    /// Failed to create render pipeline.
    PipelineCreationFailed,
};

/// GPU vertex layout for triangle rendering.
/// Matches VertexInput in triangle.wgsl:
///   @location(0) position: vec2<f32>
///   @location(1) color: vec3<f32>
///
/// Memory layout (20 bytes total):
///   offset 0: position[0] (f32)
///   offset 4: position[1] (f32)
///   offset 8: color[0] (f32)
///   offset 12: color[1] (f32)
///   offset 16: color[2] (f32)
pub const Vertex = extern struct {
    position: [2]f32,
    color: [3]f32,

    // Compile-time size guarantee: 5 floats * 4 bytes = 20 bytes total.
    // This ensures the struct layout matches GPU vertex buffer expectations.
    comptime {
        if (@sizeOf(Vertex) != 20) {
            @compileError("Vertex struct must be exactly 20 bytes for GPU compatibility");
        }
    }
};

/// Hardcoded test triangle vertices in NDC (Normalized Device Coordinates).
/// Positions range from -1 to +1 on both axes, with (0,0) at center.
/// Each vertex has a distinct color (red, green, blue) to verify
/// that vertex attribute interpolation works correctly in the fragment shader.
pub const test_triangle_vertices = [_]Vertex{
    // Bottom-left: red
    .{ .position = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    // Bottom-right: green
    .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    // Top-center: blue
    .{ .position = .{ 0.0, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
};

/// Vertex attributes describing position and color shader inputs.
/// Position at location 0, color at location 1.
const vertex_attributes = [_]zgpu.wgpu.VertexAttribute{
    .{
        .format = .float32x2, // vec2<f32> for position
        .offset = 0,
        .shader_location = 0, // @location(0)
    },
    .{
        .format = .float32x3, // vec3<f32> for color
        .offset = @sizeOf([2]f32), // 8 bytes after position
        .shader_location = 1, // @location(1)
    },
};

/// Vertex buffer layout for the render pipeline.
/// Stride of 20 bytes (5 floats), per-vertex stepping.
pub const vertex_buffer_layout: zgpu.wgpu.VertexBufferLayout = .{
    .array_stride = @sizeOf(Vertex), // 20 bytes
    .step_mode = .vertex, // Per-vertex data
    .attribute_count = vertex_attributes.len,
    .attributes = &vertex_attributes,
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
    /// Compiled WGSL shader module for triangle rendering.
    shader_module: ?zgpu.wgpu.ShaderModule,
    /// Pipeline layout defining resource bindings for the render pipeline.
    /// Currently empty (no bind group layouts) - uniform buffer added later.
    pipeline_layout: ?zgpu.wgpu.PipelineLayout,
    /// Render pipeline for triangle rendering.
    /// Combines shader stages, vertex layout, and output format configuration.
    render_pipeline: ?zgpu.wgpu.RenderPipeline,
    /// Vertex buffer containing triangle vertex data.
    /// Holds 3 vertices (60 bytes) for the test triangle.
    vertex_buffer: ?zgpu.wgpu.Buffer,

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

        // Create shader module from embedded WGSL source
        const shader_module = createShaderModule(device) orelse {
            log.err("failed to create shader module", .{});
            queue.release();
            device.release();
            adapter.release();
            instance.release();
            return RendererError.ShaderCompilationFailed;
        };

        // Create empty pipeline layout (no bind group layouts yet).
        // This defines what resources the pipeline can access. An empty layout
        // means no external resources (uniforms, textures) - those will be added later.
        const pipeline_layout = device.createPipelineLayout(.{
            .next_in_chain = null,
            .label = "Empty Pipeline Layout",
            .bind_group_layout_count = 0,
            .bind_group_layouts = null,
        });
        log.debug("empty pipeline layout created", .{});

        // Create render pipeline for triangle rendering
        const render_pipeline = createRenderPipeline(device, pipeline_layout, shader_module) orelse {
            log.err("failed to create render pipeline", .{});
            pipeline_layout.release();
            shader_module.release();
            queue.release();
            device.release();
            adapter.release();
            instance.release();
            return RendererError.PipelineCreationFailed;
        };

        // Create vertex buffer with triangle data using mappedAtCreation for upload.
        // Size = 3 vertices * 20 bytes per vertex = 60 bytes.
        const vertex_buffer = createVertexBuffer(device);
        log.info("vertex buffer created with triangle data", .{});

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
            .shader_module = shader_module,
            .pipeline_layout = pipeline_layout,
            .render_pipeline = render_pipeline,
            .vertex_buffer = vertex_buffer,
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

    /// Cornflower blue - a pleasant default clear color (RGB: 0.39, 0.58, 0.93).
    pub const cornflower_blue: zgpu.wgpu.Color = .{ .r = 0.39, .g = 0.58, .b = 0.93, .a = 1.0 };

    /// Begin a render pass with a clear color.
    /// Configures the render pass descriptor with the swap chain texture view as
    /// the color attachment, load operation set to Clear, and store operation set
    /// to Store. This clears the screen to the specified color and prepares for drawing.
    /// Returns a RenderPassEncoder for recording draw commands.
    pub fn beginRenderPass(frame_state: FrameState, clear_color: zgpu.wgpu.Color) zgpu.wgpu.RenderPassEncoder {
        const color_attachment: zgpu.wgpu.RenderPassColorAttachment = .{
            .view = frame_state.texture_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear_color,
        };

        const render_pass = frame_state.command_encoder.beginRenderPass(.{
            .label = "Main Render Pass",
            .color_attachment_count = 1,
            .color_attachments = @ptrCast(&color_attachment),
        });

        log.debug("render pass begun with clear color", .{});
        return render_pass;
    }

    /// End a render pass.
    /// Completes the recording of render commands for this pass. After calling this,
    /// the render pass encoder is consumed and cannot be used again.
    /// Drawing commands should be recorded between beginRenderPass and endRenderPass.
    pub fn endRenderPass(render_pass: zgpu.wgpu.RenderPassEncoder) void {
        render_pass.end();
        log.debug("render pass ended", .{});
    }

    /// End the current frame and present it to the screen.
    /// Finishes the command encoder to create a command buffer, submits it to
    /// the GPU queue, releases the texture view, and presents the swap chain.
    /// Call this once at the end of each frame after all drawing is complete.
    pub fn endFrame(self: *Self, frame_state: FrameState) void {
        const queue = self.queue orelse {
            log.err("cannot end frame: queue not initialized", .{});
            return;
        };

        const swapchain = self.swapchain orelse {
            log.err("cannot end frame: swap chain not initialized", .{});
            return;
        };

        // Finish the command encoder to create a command buffer
        const command_buffer = frame_state.command_encoder.finish(.{
            .label = "Frame Command Buffer",
        });

        // Submit the command buffer to the GPU queue
        queue.submit(&[_]zgpu.wgpu.CommandBuffer{command_buffer});

        // Release the texture view (no longer needed after submission)
        frame_state.texture_view.release();

        // Present the swap chain to display the rendered frame
        swapchain.present();

        log.debug("frame ended and presented", .{});
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

    /// Embedded WGSL shader source (compiled into the binary at build time).
    const triangle_wgsl = @embedFile("shaders/triangle.wgsl");

    /// Create a shader module from the embedded WGSL source.
    /// Uses compile-time embedding to avoid runtime file I/O.
    /// Returns null if shader compilation fails.
    fn createShaderModule(device: zgpu.wgpu.Device) ?zgpu.wgpu.ShaderModule {
        // Create the WGSL descriptor with the embedded shader source
        var wgsl_desc: zgpu.wgpu.ShaderModuleWGSLDescriptor = .{
            .chain = .{
                .next = null,
                .struct_type = .shader_module_wgsl_descriptor,
            },
            .code = triangle_wgsl,
        };

        // Create the shader module using the chained WGSL descriptor
        const shader_module = device.createShaderModule(.{
            .next_in_chain = @ptrCast(&wgsl_desc.chain),
            .label = "Triangle Shader Module",
        });

        // Check if shader module creation succeeded
        // A null/zero pointer indicates compilation failure
        if (@intFromPtr(shader_module) == 0) {
            log.err("shader module creation returned null", .{});
            return null;
        }

        log.info("shader module created successfully", .{});
        return shader_module;
    }

    /// Create the render pipeline for triangle rendering.
    /// Configures vertex and fragment stages, primitive topology, and output format.
    /// Returns null if pipeline creation fails.
    fn createRenderPipeline(
        device: zgpu.wgpu.Device,
        pipeline_layout: zgpu.wgpu.PipelineLayout,
        shader_module: zgpu.wgpu.ShaderModule,
    ) ?zgpu.wgpu.RenderPipeline {
        // Color target state for BGRA8Unorm output (matches swap chain format)
        const color_target: zgpu.wgpu.ColorTargetState = .{
            .next_in_chain = null,
            .format = .bgra8_unorm,
            .blend = null, // No blending for opaque triangles
            .write_mask = .{ .red = true, .green = true, .blue = true, .alpha = true },
        };

        // Fragment state with fs_main entry point
        const fragment_state: zgpu.wgpu.FragmentState = .{
            .next_in_chain = null,
            .module = shader_module,
            .entry_point = "fs_main",
            .constant_count = 0,
            .constants = null,
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };

        // Create the render pipeline
        const pipeline = device.createRenderPipeline(.{
            .next_in_chain = null,
            .label = "Triangle Render Pipeline",
            .layout = pipeline_layout,
            .vertex = .{
                .next_in_chain = null,
                .module = shader_module,
                .entry_point = "vs_main",
                .constant_count = 0,
                .constants = null,
                .buffer_count = 1,
                .buffers = @ptrCast(&vertex_buffer_layout),
            },
            .primitive = .{
                .next_in_chain = null,
                .topology = .triangle_list,
                .strip_index_format = .undef,
                .front_face = .ccw,
                .cull_mode = .none, // No culling for 2D rendering
            },
            .depth_stencil = null, // No depth testing for 2D
            .multisample = .{
                .next_in_chain = null,
                .count = 1, // No multisampling
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = false,
            },
            .fragment = &fragment_state,
        });

        // Check if pipeline creation succeeded
        if (@intFromPtr(pipeline) == 0) {
            log.err("render pipeline creation returned null", .{});
            return null;
        }

        log.info("render pipeline created successfully", .{});
        return pipeline;
    }

    /// Create a vertex buffer containing the test triangle data.
    /// Uses mappedAtCreation for efficient data upload at buffer creation time.
    /// The buffer is unmapped after copying data, making it ready for GPU use.
    fn createVertexBuffer(device: zgpu.wgpu.Device) zgpu.wgpu.Buffer {
        const vertex_data = &test_triangle_vertices;
        const buffer_size: u64 = @sizeOf(@TypeOf(vertex_data.*));

        // Create buffer with mappedAtCreation for immediate data upload.
        // Usage: VERTEX (for binding as vertex buffer) | COPY_DST (for potential future updates).
        const buffer = device.createBuffer(.{
            .next_in_chain = null,
            .label = "Triangle Vertex Buffer",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = buffer_size,
            .mapped_at_creation = .true,
        });

        // Get the mapped memory range and copy vertex data into it.
        // getMappedRange returns a slice we can directly write to.
        const mapped = buffer.getMappedRange(Vertex, 0, vertex_data.len);
        if (mapped) |dst| {
            @memcpy(dst, vertex_data);
        } else {
            log.err("failed to get mapped range for vertex buffer", .{});
        }

        // Unmap the buffer - data is now on the GPU and buffer is ready for rendering.
        buffer.unmap();

        return buffer;
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

        // Release shader module before device (it depends on the device)
        if (self.shader_module) |shader| {
            shader.release();
            self.shader_module = null;
        }

        // Release render pipeline before pipeline layout (it depends on the layout)
        if (self.render_pipeline) |pipeline| {
            pipeline.release();
            self.render_pipeline = null;
        }

        // Release vertex buffer before device (it depends on the device)
        if (self.vertex_buffer) |buffer| {
            buffer.release();
            self.vertex_buffer = null;
        }

        // Release pipeline layout before device (it depends on the device)
        if (self.pipeline_layout) |layout| {
            layout.release();
            self.pipeline_layout = null;
        }

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
    _ = RendererError.ShaderCompilationFailed;
    _ = RendererError.PipelineCreationFailed;
}
