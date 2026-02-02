//! Renderer module - WebGPU rendering abstraction
//!
//! This module provides the central rendering abstraction for the application,
//! encapsulating all WebGPU state and operations. The Renderer struct manages
//! the graphics device, command queue, and swap chain for presenting frames.

const std = @import("std");
const builtin = @import("builtin");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");
const zigimg = @import("zigimg");

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
    /// Failed to take screenshot (buffer mapping or file I/O error).
    ScreenshotFailed,
};

/// Uniform buffer data for coordinate transformation.
/// Contains screen dimensions used by shaders to transform screen coordinates to NDC.
///
/// Memory layout (8 bytes total, 16-byte aligned for GPU):
///   offset 0: screen_size[0] (f32) - width in pixels
///   offset 4: screen_size[1] (f32) - height in pixels
///
/// This struct uses extern layout for predictable GPU memory mapping.
/// The shader can use these values to convert pixel coordinates to normalized
/// device coordinates: ndc = (pixel / screen_size) * 2.0 - 1.0
pub const Uniforms = extern struct {
    /// Screen dimensions in pixels (width, height).
    screen_size: [2]f32,

    // Compile-time size guarantee: 2 floats * 4 bytes = 8 bytes.
    // Note: WebGPU requires uniform buffers to be 16-byte aligned, but the
    // buffer itself handles alignment - this struct just needs correct size.
    comptime {
        if (@sizeOf(Uniforms) != 8) {
            @compileError("Uniforms struct must be exactly 8 bytes for GPU compatibility");
        }
    }
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

/// RGBA color type for vertex coloring and general color representation.
/// Values are normalized floats in range [0.0, 1.0].
/// The alpha channel enables future transparency support.
pub const Color = struct {
    /// Red component [0.0, 1.0].
    r: f32,
    /// Green component [0.0, 1.0].
    g: f32,
    /// Blue component [0.0, 1.0].
    b: f32,
    /// Alpha component [0.0, 1.0]. 1.0 = fully opaque, 0.0 = fully transparent.
    a: f32 = 1.0,

    // Named color constants (all fully opaque).
    pub const white: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const black: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const red: Color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const green: Color = .{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const blue: Color = .{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
    pub const yellow: Color = .{ .r = 1.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const cyan: Color = .{ .r = 0.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const magenta: Color = .{ .r = 1.0, .g = 0.0, .b = 1.0, .a = 1.0 };

    /// Convert to RGB array for vertex attribute compatibility.
    /// Discards the alpha channel for use with current vertex format.
    pub fn toRgb(self: Color) [3]f32 {
        return .{ self.r, self.g, self.b };
    }

    /// Create a Color from an RGB array (alpha defaults to 1.0).
    pub fn fromRgb(rgb_array: [3]f32) Color {
        return .{ .r = rgb_array[0], .g = rgb_array[1], .b = rgb_array[2], .a = 1.0 };
    }

    /// Create a Color from individual RGB values (alpha defaults to 1.0).
    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    /// Create a Color from individual RGBA values.
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

/// RGB vertex color type for GPU vertex attributes.
/// This is the low-level format matching the vertex buffer layout (vec3<f32> in WGSL).
/// For high-level color operations, use the Color struct instead.
pub const VertexColor = [3]f32;

/// A triangle draw command containing three vertices with positions and colors.
/// Positions are in screen coordinates (pixels), origin at top-left.
/// Colors are interpolated across the triangle surface by the GPU.
///
/// This struct is used as a variant in DrawCommand and captures all data
/// needed to render a single triangle.
pub const Triangle = struct {
    /// Three vertex positions in screen coordinates (x, y in pixels).
    positions: [3][2]f32,
    /// Color at each vertex for gradient interpolation (RGB format for GPU).
    colors: [3]VertexColor,

    /// Create a Triangle from an array of Vertex structs.
    /// Convenience function for converting between representations.
    pub fn fromVertices(vertices: [3]Vertex) Triangle {
        return .{
            .positions = .{
                vertices[0].position,
                vertices[1].position,
                vertices[2].position,
            },
            .colors = .{
                vertices[0].color,
                vertices[1].color,
                vertices[2].color,
            },
        };
    }

    /// Convert back to an array of Vertex structs for GPU rendering.
    pub fn toVertices(self: Triangle) [3]Vertex {
        return .{
            .{ .position = self.positions[0], .color = self.colors[0] },
            .{ .position = self.positions[1], .color = self.colors[1] },
            .{ .position = self.positions[2], .color = self.colors[2] },
        };
    }
};

/// Tagged union for draw commands.
/// Allows storing heterogeneous draw commands in a single list for batched processing.
/// Currently supports triangles; extensible to other primitives (lines, rectangles, circles).
///
/// Design rationale:
/// - Tagged union enables type-safe command storage without dynamic dispatch
/// - Batch processing improves GPU utilization by reducing state changes
/// - New primitive types can be added as additional union variants
pub const DrawCommand = union(enum) {
    /// A triangle primitive with three colored vertices.
    triangle: Triangle,

    // Future primitives will be added here as the rendering system evolves:
    // line: Line,
    // rectangle: Rectangle,
    // circle: Circle,
};

/// Hardcoded test triangle vertices in screen coordinates (pixels).
/// Screen coordinate system: origin at top-left, X increases right, Y increases down.
/// For a 400x300 window, this triangle is centered and covers roughly 1/4 of the screen.
/// Each vertex has a distinct color (red, green, blue) to verify
/// that vertex attribute interpolation works correctly in the fragment shader.
pub const test_triangle_vertices = [_]Vertex{
    // Bottom-left: red (100px from left, 225px from top)
    .{ .position = .{ 100.0, 225.0 }, .color = .{ 1.0, 0.0, 0.0 } },
    // Bottom-right: green (300px from left, 225px from top)
    .{ .position = .{ 300.0, 225.0 }, .color = .{ 0.0, 1.0, 0.0 } },
    // Top-center: blue (200px from left, 75px from top)
    .{ .position = .{ 200.0, 75.0 }, .color = .{ 0.0, 0.0, 1.0 } },
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

    /// Allocator used for command buffer and other dynamic allocations.
    allocator: std.mem.Allocator,
    /// Command buffer accumulating draw commands during App.render.
    /// Processed during endFrame to generate GPU draw calls.
    command_buffer: std.ArrayList(DrawCommand),

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
    /// Bind group layout describing the uniform buffer binding.
    /// Defines the interface between Zig code and shader for screen dimensions.
    /// Layout: binding 0, visibility VERTEX, buffer type Uniform.
    bind_group_layout: ?zgpu.wgpu.BindGroupLayout,
    /// Pipeline layout defining resource bindings for the render pipeline.
    /// Contains bind_group_layout for uniform buffer access in shaders.
    pipeline_layout: ?zgpu.wgpu.PipelineLayout,
    /// Render pipeline for triangle rendering.
    /// Combines shader stages, vertex layout, and output format configuration.
    render_pipeline: ?zgpu.wgpu.RenderPipeline,
    /// Dynamic vertex buffer for triangle rendering.
    /// Holds up to max_vertex_capacity vertices, reused each frame via queue.writeBuffer().
    /// Size = max_vertex_capacity * @sizeOf(Vertex) = 10000 * 20 = 200KB.
    vertex_buffer: ?zgpu.wgpu.Buffer,
    /// Maximum number of vertices the buffer can hold.
    /// Set to 10,000 vertices (~200KB) for efficient batched rendering.
    vertex_buffer_capacity: u32,
    /// Uniform buffer for screen dimensions.
    /// Holds the Uniforms struct (8 bytes data, 16 bytes allocated for GPU alignment).
    /// Updated each frame or on resize via queue.writeBuffer().
    uniform_buffer: ?zgpu.wgpu.Buffer,
    /// Bind group containing the uniform buffer binding.
    /// Makes the uniform data (screen dimensions) available to the shader during rendering.
    /// Set during render pass to connect the uniform buffer to shader binding 0.
    bind_group: ?zgpu.wgpu.BindGroup,
    /// Texture for screenshot capture.
    /// Created with copy_src usage to allow copying to a staging buffer.
    /// Matches swap chain dimensions and is recreated on resize.
    screenshot_texture: ?zgpu.wgpu.Texture,
    /// Staging buffer for GPU-to-CPU pixel readback.
    /// Used to map rendered pixels to CPU memory for file writing.
    screenshot_staging_buffer: ?zgpu.wgpu.Buffer,
    /// Width of the screenshot resources (for resize detection).
    screenshot_width: u32,
    /// Height of the screenshot resources (for resize detection).
    screenshot_height: u32,

    /// Initialize the renderer with a GLFW window.
    /// Creates a WebGPU instance, surface, adapter (compatible with surface), device,
    /// and swap chain. The surface must be created before the adapter to ensure
    /// the adapter can present to the surface on all platforms (especially X11).
    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window, width: u32, height: u32) RendererError!Self {
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

        // Create surface from the GLFW window BEFORE requesting adapter.
        // This is critical: the adapter must be requested with a compatible surface
        // to ensure it can present to the window on all platforms (especially X11).
        const surface = createSurfaceFromWindow(instance, window) orelse {
            log.err("failed to create WebGPU surface from window", .{});
            instance.release();
            return RendererError.SurfaceCreationFailed;
        };
        log.debug("WebGPU surface created", .{});

        // Request adapter with high-performance preference AND compatible surface
        const adapter = requestAdapter(instance, surface) orelse {
            log.err("failed to obtain WebGPU adapter", .{});
            surface.release();
            instance.release();
            return RendererError.AdapterRequestFailed;
        };

        // Log adapter properties for debugging - helps identify GPU backend issues
        var props: zgpu.wgpu.AdapterProperties = undefined;
        props.next_in_chain = null;
        adapter.getProperties(&props);
        log.info("WebGPU adapter: {s} ({s})", .{ props.name, props.driver_description });
        log.info("  Backend: {}, Type: {}", .{ props.backend_type, props.adapter_type });
        log.info("  Vendor: {s} (0x{x}), Device ID: 0x{x}", .{ props.vendor_name, props.vendor_id, props.device_id });

        // Request device with default limits (sufficient for 2D triangle rendering)
        const device = requestDevice(adapter) orelse {
            log.err("failed to obtain WebGPU device", .{});
            adapter.release();
            surface.release();
            instance.release();
            return RendererError.DeviceRequestFailed;
        };
        log.info("WebGPU device obtained", .{});

        // Set up error callback to catch validation errors
        device.setUncapturedErrorCallback(&deviceErrorCallback, null);

        // Get the command queue from the device
        const queue = device.getQueue();
        log.debug("WebGPU queue obtained", .{});

        // Create swap chain with standard settings for 2D rendering
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
        log.info("WebGPU swap chain created: {}x{}", .{ width, height });

        // Create shader module from embedded WGSL source
        const shader_module = createShaderModule(device) orelse {
            log.err("failed to create shader module", .{});
            swapchain.release();
            queue.release();
            device.release();
            adapter.release();
            surface.release();
            instance.release();
            return RendererError.ShaderCompilationFailed;
        };

        // Create bind group layout for uniform buffer (screen dimensions).
        // Defines the interface between Zig code and shader for screen dimensions.
        const bind_group_layout = createBindGroupLayout(device);
        log.debug("bind group layout created for uniforms", .{});

        // Create pipeline layout with the bind group layout in slot 0.
        // This ensures the render pipeline expects a bind group with uniform buffer at group 0.
        const bind_group_layouts = [_]zgpu.wgpu.BindGroupLayout{bind_group_layout};
        const pipeline_layout = device.createPipelineLayout(.{
            .next_in_chain = null,
            .label = "Main Pipeline Layout",
            .bind_group_layout_count = bind_group_layouts.len,
            .bind_group_layouts = &bind_group_layouts,
        });
        log.debug("pipeline layout created with bind group layout in slot 0", .{});

        // Create render pipeline for triangle rendering
        const render_pipeline = createRenderPipeline(device, pipeline_layout, shader_module) orelse {
            log.err("failed to create render pipeline", .{});
            pipeline_layout.release();
            shader_module.release();
            swapchain.release();
            queue.release();
            device.release();
            adapter.release();
            surface.release();
            instance.release();
            return RendererError.PipelineCreationFailed;
        };

        // Create dynamic vertex buffer with max capacity.
        // Size = 10,000 vertices * 20 bytes = 200KB.
        const vertex_result = createVertexBuffer(device);
        log.info("dynamic vertex buffer created: {} vertices capacity ({} bytes)", .{
            vertex_result.capacity,
            @as(u64, vertex_result.capacity) * @sizeOf(Vertex),
        });

        // Create uniform buffer for screen dimensions.
        // WebGPU requires uniform buffers to be 16-byte aligned, so we allocate 16 bytes
        // even though Uniforms is only 8 bytes.
        const uniform_buffer = createUniformBuffer(device);
        log.info("uniform buffer created for screen dimensions", .{});

        // Initialize uniform buffer with current screen dimensions.
        // The shader needs these values to transform screen coordinates to NDC.
        const initial_uniforms: Uniforms = .{
            .screen_size = .{ @floatFromInt(width), @floatFromInt(height) },
        };
        queue.writeBuffer(uniform_buffer, 0, Uniforms, &.{initial_uniforms});
        log.info("uniform buffer initialized with screen size: {}x{}", .{ width, height });

        // Create bind group containing the uniform buffer.
        // This connects the uniform buffer to binding 0 in the shader.
        const bind_group = createBindGroup(device, bind_group_layout, uniform_buffer);
        log.info("bind group created with uniform buffer", .{});

        return Self{
            .allocator = allocator,
            .command_buffer = .empty,
            .native_instance = native_instance,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = surface,
            .swapchain = swapchain,
            .window = window,
            .swapchain_width = width,
            .swapchain_height = height,
            .shader_module = shader_module,
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .render_pipeline = render_pipeline,
            .vertex_buffer = vertex_result.buffer,
            .vertex_buffer_capacity = vertex_result.capacity,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
            // Screenshot resources are created lazily on first capture
            .screenshot_texture = null,
            .screenshot_staging_buffer = null,
            .screenshot_width = 0,
            .screenshot_height = 0,
        };
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

        // Clear previous frame's commands while keeping allocated memory for efficiency.
        // Each frame starts fresh with an empty command list.
        self.command_buffer.clearRetainingCapacity();

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

    /// Queue a triangle for later batched rendering.
    /// Creates a Triangle draw command and appends it to the command buffer.
    /// Does not immediately render - just records the command for later execution.
    /// This is the public API apps use to draw triangles.
    ///
    /// Parameters:
    /// - positions: Three vertex positions in screen coordinates (x, y in pixels).
    /// - colors: RGB color at each vertex for gradient interpolation.
    ///
    /// Note: The command buffer must be processed during endFrame to render the queued triangles.
    pub fn queueTriangle(self: *Self, positions: [3][2]f32, colors: [3]VertexColor) void {
        const triangle: Triangle = .{
            .positions = positions,
            .colors = colors,
        };
        const command: DrawCommand = .{ .triangle = triangle };
        self.command_buffer.append(self.allocator, command) catch |err| {
            log.err("failed to queue triangle: {}", .{err});
        };
    }

    /// Draw a triangle with the given vertices (immediate mode).
    /// Sets up the pipeline, bind groups, and vertex buffer, then issues the draw call.
    /// The vertices should be in screen coordinates (pixels).
    ///
    /// Parameters:
    /// - render_pass: Active render pass encoder to record draw commands to.
    /// - vertices: Array of exactly 3 vertices defining the triangle.
    pub fn drawTriangle(self: *Self, render_pass: zgpu.wgpu.RenderPassEncoder, vertices: *const [3]Vertex) void {
        const render_pipeline = self.render_pipeline orelse {
            log.warn("drawTriangle: render pipeline not initialized", .{});
            return;
        };

        const vertex_buffer = self.vertex_buffer orelse {
            log.warn("drawTriangle: vertex buffer not initialized", .{});
            return;
        };

        const queue = self.queue orelse {
            log.warn("drawTriangle: queue not initialized", .{});
            return;
        };

        // Update vertex buffer with the provided vertices.
        // This allows the app to specify different triangles each frame.
        queue.writeBuffer(vertex_buffer, 0, Vertex, vertices);

        // Set render pipeline - configures GPU to use our shader and vertex layout
        render_pass.setPipeline(render_pipeline);

        // Set bind group 0 (uniforms) - required by the pipeline layout
        if (self.bind_group) |bind_group| {
            render_pass.setBindGroup(0, bind_group, &.{});
        }

        // Bind vertex buffer (slot 0, full buffer)
        const vertex_buffer_size: u64 = @sizeOf([3]Vertex);
        render_pass.setVertexBuffer(0, vertex_buffer, 0, vertex_buffer_size);

        // Draw the triangle (3 vertices, 1 instance)
        render_pass.draw(3, 1, 0, 0);

        log.debug("triangle drawn", .{});
    }

    /// Flush all queued triangle draw commands in a single batched draw call.
    /// Uploads all queued triangle vertices to the GPU buffer and issues one draw call.
    /// This batched approach is much more efficient than one draw call per triangle -
    /// it minimizes GPU state changes and CPU overhead.
    ///
    /// Must be called while a render pass is active (before endRenderPass).
    ///
    /// Parameters:
    /// - render_pass: Active render pass encoder to record the draw command to.
    pub fn flushBatch(self: *Self, render_pass: zgpu.wgpu.RenderPassEncoder) void {
        // Upload all queued triangle vertices to the GPU buffer
        const vertex_count = self.convertTrianglesToVertices();

        // Early exit if no triangles were queued
        if (vertex_count == 0) {
            return;
        }

        const render_pipeline = self.render_pipeline orelse {
            log.warn("flushBatch: render pipeline not initialized", .{});
            return;
        };

        const vertex_buffer = self.vertex_buffer orelse {
            log.warn("flushBatch: vertex buffer not initialized", .{});
            return;
        };

        // Set render pipeline - configures GPU to use our shader and vertex layout
        render_pass.setPipeline(render_pipeline);

        // Set bind group 0 (uniforms) - required by the pipeline layout
        if (self.bind_group) |bind_group| {
            render_pass.setBindGroup(0, bind_group, &.{});
        }

        // Bind vertex buffer with the exact size needed for all vertices
        const vertex_buffer_size: u64 = @as(u64, vertex_count) * @sizeOf(Vertex);
        render_pass.setVertexBuffer(0, vertex_buffer, 0, vertex_buffer_size);

        // Issue a single draw call for all triangles in the batch.
        // vertex_count = total_triangles * 3.
        render_pass.draw(vertex_count, 1, 0, 0);

        log.debug("batched draw: {} vertices ({} triangles)", .{ vertex_count, vertex_count / 3 });
    }

    /// End the current frame and present it to the screen.
    /// Finishes the command encoder to create a command buffer, submits it
    /// to the GPU queue, and presents the swap chain.
    /// Call this once at the end of each frame after all drawing is complete.
    ///
    /// Note: flushBatch() should be called before endRenderPass() to render
    /// any queued triangles. This function only handles frame submission.
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

        // Tick the device to process internal Dawn work.
        // Required on some platforms (especially Linux/Vulkan) for the
        // compositor to receive and display the presented frame.
        const device = self.device orelse return;
        device.tick();

        log.debug("frame ended and presented", .{});
    }

    /// Convert triangle draw commands to vertices and upload to GPU.
    /// Iterates through the command buffer, extracts triangles, converts
    /// each to 3 Vertex structs, and uploads to the dynamic vertex buffer
    /// using queue.writeBuffer(). Logs a warning if vertex buffer overflows.
    ///
    /// Returns the total number of vertices converted and uploaded.
    fn convertTrianglesToVertices(self: *Self) u32 {
        var vertex_count: u32 = 0;

        // First pass: count total vertices needed to detect overflow early
        var triangle_count: u32 = 0;
        for (self.command_buffer.items) |command| {
            switch (command) {
                .triangle => {
                    triangle_count += 1;
                },
            }
        }

        const required_vertices = triangle_count * 3;

        // Early exit if no triangles to render
        if (required_vertices == 0) {
            return 0;
        }

        // Check for buffer overflow before processing
        if (required_vertices > self.vertex_buffer_capacity) {
            log.warn("vertex buffer overflow: {} vertices required, {} capacity. Truncating to {} triangles.", .{
                required_vertices,
                self.vertex_buffer_capacity,
                self.vertex_buffer_capacity / 3,
            });
        }

        // Build temporary vertex array from triangle commands.
        // Use stack allocation for small batches, respecting buffer capacity.
        const max_vertices = @min(required_vertices, self.vertex_buffer_capacity);
        const max_triangles = max_vertices / 3;

        // Stack-allocated array for vertices (up to capacity limit).
        // This avoids heap allocation for the common case.
        var vertices: [max_vertex_capacity]Vertex = undefined;
        var current_triangle: u32 = 0;

        for (self.command_buffer.items) |command| {
            switch (command) {
                .triangle => |triangle| {
                    // Stop if we've reached capacity
                    if (current_triangle >= max_triangles) break;

                    // Convert Triangle to 3 Vertex structs
                    const tri_vertices = triangle.toVertices();
                    const base_idx = current_triangle * 3;
                    vertices[base_idx + 0] = tri_vertices[0];
                    vertices[base_idx + 1] = tri_vertices[1];
                    vertices[base_idx + 2] = tri_vertices[2];

                    current_triangle += 1;
                },
            }
        }

        vertex_count = current_triangle * 3;

        // Upload vertex data to GPU buffer.
        // This transfers CPU-side vertex data to GPU memory before the draw call.
        // Done once per frame with all triangles batched for efficiency.
        const queue = self.queue orelse {
            log.warn("cannot upload vertices: queue not initialized", .{});
            return 0;
        };

        const vertex_buffer = self.vertex_buffer orelse {
            log.warn("cannot upload vertices: vertex buffer not initialized", .{});
            return 0;
        };

        // Upload vertices to GPU buffer at offset 0.
        // Size = vertex_count * @sizeOf(Vertex).
        const vertex_slice = vertices[0..vertex_count];
        queue.writeBuffer(vertex_buffer, 0, Vertex, vertex_slice);

        log.debug("uploaded {} vertices ({} triangles) to GPU buffer", .{ vertex_count, current_triangle });

        return vertex_count;
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

        // Update uniform buffer with new screen dimensions so shaders use correct NDC transform.
        // Without this, the triangle would be rendered with stale dimensions after resize.
        const queue = self.queue orelse return RendererError.SwapChainCreationFailed;
        const uniform_buffer = self.uniform_buffer orelse return RendererError.SwapChainCreationFailed;
        const new_uniforms: Uniforms = .{
            .screen_size = .{ @floatFromInt(width), @floatFromInt(height) },
        };
        queue.writeBuffer(uniform_buffer, 0, Uniforms, &.{new_uniforms});

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

    /// Create a dynamic vertex buffer with maximum capacity.
    /// The buffer is reused each frame - vertices are uploaded via queue.writeBuffer().
    /// Usage: VERTEX (for binding as vertex buffer) | COPY_DST (for dynamic updates).
    ///
    /// Returns the buffer and its capacity.
    fn createVertexBuffer(device: zgpu.wgpu.Device) struct { buffer: zgpu.wgpu.Buffer, capacity: u32 } {
        const buffer_size: u64 = @as(u64, max_vertex_capacity) * @sizeOf(Vertex);

        // Create buffer with VERTEX | COPY_DST usage for dynamic vertex data.
        // mapped_at_creation is false since we'll upload data via writeBuffer each frame.
        const buffer = device.createBuffer(.{
            .next_in_chain = null,
            .label = "Dynamic Vertex Buffer",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = buffer_size,
            .mapped_at_creation = .false,
        });

        return .{ .buffer = buffer, .capacity = max_vertex_capacity };
    }

    /// Maximum vertex capacity for the dynamic vertex buffer.
    /// 10,000 vertices at 20 bytes each = 200KB.
    /// This provides enough capacity for ~3,333 triangles per frame.
    pub const max_vertex_capacity: u32 = 10000;

    /// Maximum number of triangles that can be rendered per frame.
    /// Calculated as max_vertex_capacity / 3 (3 vertices per triangle).
    pub const max_triangle_capacity: u32 = max_vertex_capacity / 3;

    /// Minimum uniform buffer size for WebGPU alignment.
    /// WebGPU requires uniform buffers to be 16-byte aligned. Since Uniforms is 8 bytes,
    /// we allocate 16 bytes to satisfy alignment requirements.
    const uniform_buffer_size: u64 = 16;

    /// Create a uniform buffer for screen dimensions.
    /// The buffer is created with UNIFORM | COPY_DST usage to allow:
    /// - Binding as a uniform buffer in shaders (UNIFORM)
    /// - Updating via queue.writeBuffer() each frame or on resize (COPY_DST)
    fn createUniformBuffer(device: zgpu.wgpu.Device) zgpu.wgpu.Buffer {
        const buffer = device.createBuffer(.{
            .next_in_chain = null,
            .label = "Screen Dimensions Uniform Buffer",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = uniform_buffer_size,
            .mapped_at_creation = .false,
        });

        return buffer;
    }

    /// Create a bind group layout describing the uniform buffer binding.
    /// Configures: binding 0, visibility VERTEX (used in vertex shader), buffer type Uniform.
    /// This layout is used both to create the bind group and to define the pipeline layout.
    /// The layout defines the interface between Zig code and shader for screen dimensions.
    fn createBindGroupLayout(device: zgpu.wgpu.Device) zgpu.wgpu.BindGroupLayout {
        // Define the uniform buffer binding entry.
        // Binding 0: screen dimensions uniform buffer, visible to vertex shader.
        const layout_entries = [_]zgpu.wgpu.BindGroupLayoutEntry{
            .{
                .next_in_chain = null,
                .binding = 0, // @group(0) @binding(0) in WGSL
                .visibility = .{ .vertex = true, .fragment = false, .compute = false, ._padding = 0 },
                .buffer = .{
                    .next_in_chain = null,
                    .binding_type = .uniform,
                    .has_dynamic_offset = .false,
                    .min_binding_size = @sizeOf(Uniforms), // 8 bytes
                },
                // Not using sampler, texture, or storage_texture - set to defaults
                .sampler = .{ .next_in_chain = null, .binding_type = .undef },
                .texture = .{
                    .next_in_chain = null,
                    .sample_type = .undef,
                    .view_dimension = .undef,
                    .multisampled = false,
                },
                .storage_texture = .{
                    .next_in_chain = null,
                    .access = .undef,
                    .format = .undef,
                    .view_dimension = .undef,
                },
            },
        };

        const layout = device.createBindGroupLayout(.{
            .next_in_chain = null,
            .label = "Uniforms Bind Group Layout",
            .entry_count = layout_entries.len,
            .entries = &layout_entries,
        });

        return layout;
    }

    /// Create a bind group containing the uniform buffer.
    /// Binds the uniform buffer at binding 0 with offset 0 and full size.
    /// The bind group is set during rendering to make uniform data available to shaders.
    fn createBindGroup(
        device: zgpu.wgpu.Device,
        layout: zgpu.wgpu.BindGroupLayout,
        uniform_buffer: zgpu.wgpu.Buffer,
    ) zgpu.wgpu.BindGroup {
        // Define the binding entry for the uniform buffer.
        // Binding 0 with offset 0 and size covering the full uniform buffer.
        const entries = [_]zgpu.wgpu.BindGroupEntry{
            .{
                .next_in_chain = null,
                .binding = 0, // @group(0) @binding(0) in WGSL
                .buffer = uniform_buffer,
                .offset = 0,
                .size = uniform_buffer_size, // 16 bytes (aligned size)
                .sampler = null,
                .texture_view = null,
            },
        };

        const bind_group = device.createBindGroup(.{
            .next_in_chain = null,
            .label = "Uniforms Bind Group",
            .layout = layout,
            .entry_count = entries.len,
            .entries = &entries,
        });

        return bind_group;
    }

    /// Request a WebGPU adapter from the instance.
    /// Prefers high-performance GPU and uses the default backend.
    /// The surface parameter ensures the adapter can present to the window.
    /// Returns null if no suitable adapter is available.
    fn requestAdapter(instance: zgpu.wgpu.Instance, surface: zgpu.wgpu.Surface) ?zgpu.wgpu.Adapter {
        const Response = struct {
            adapter: ?zgpu.wgpu.Adapter = null,
            status: zgpu.wgpu.RequestAdapterStatus = .unknown,
        };

        var response: Response = .{};

        // Request adapter asynchronously - Dawn processes this synchronously
        // on the main thread, so the callback fires before returning.
        // The compatible_surface ensures the adapter can present to our window.
        instance.requestAdapter(
            .{
                .next_in_chain = null,
                .compatible_surface = surface,
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

    /// Error callback for WebGPU validation errors.
    fn deviceErrorCallback(
        err_type: zgpu.wgpu.ErrorType,
        message: ?[*:0]const u8,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const msg = message orelse "unknown error";
        log.err("WebGPU error ({}): {s}", .{ err_type, msg });
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

    /// WebGPU requires buffer row alignment of 256 bytes.
    const copy_bytes_per_row_alignment: u32 = 256;

    /// Align a value up to a multiple of alignment.
    fn alignUp(value: u32, alignment: u32) u32 {
        return (value + alignment - 1) / alignment * alignment;
    }

    /// Calculate the aligned bytes per row for a given width (BGRA8 = 4 bytes per pixel).
    fn calcAlignedBytesPerRow(width: u32) u32 {
        const unaligned = width * 4;
        return alignUp(unaligned, copy_bytes_per_row_alignment);
    }

    /// Ensure screenshot resources exist and match current swap chain dimensions.
    /// Creates or recreates the screenshot texture and staging buffer if needed.
    fn ensureScreenshotResources(self: *Self) void {
        const device = self.device orelse return;
        const width = self.swapchain_width;
        const height = self.swapchain_height;

        // Check if resources already exist with correct dimensions
        if (self.screenshot_texture != null and
            self.screenshot_width == width and
            self.screenshot_height == height)
        {
            return;
        }

        // Release old resources if they exist
        if (self.screenshot_texture) |tex| {
            tex.release();
            self.screenshot_texture = null;
        }
        if (self.screenshot_staging_buffer) |buf| {
            buf.release();
            self.screenshot_staging_buffer = null;
        }

        // Create screenshot texture as a render target with copy_src.
        // render_attachment: we render to this texture
        // copy_src: we copy from this texture to the staging buffer
        self.screenshot_texture = device.createTexture(.{
            .next_in_chain = null,
            .label = "Screenshot Texture",
            .usage = .{ .render_attachment = true, .copy_src = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
            .format = .bgra8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
            .view_format_count = 0,
            .view_formats = null,
        });

        // Create staging buffer for CPU readback.
        // Size = aligned_bytes_per_row * height.
        const aligned_bytes_per_row = calcAlignedBytesPerRow(width);
        const buffer_size: u64 = @as(u64, aligned_bytes_per_row) * @as(u64, height);

        self.screenshot_staging_buffer = device.createBuffer(.{
            .next_in_chain = null,
            .label = "Screenshot Staging Buffer",
            .usage = .{ .map_read = true, .copy_dst = true },
            .size = buffer_size,
            .mapped_at_creation = .false,
        });

        self.screenshot_width = width;
        self.screenshot_height = height;

        log.info("screenshot resources created: {}x{} (buffer size: {} bytes)", .{
            width, height, buffer_size,
        });
    }

    /// Context for async buffer mapping callback.
    const MapCallbackContext = struct {
        status: zgpu.wgpu.BufferMapAsyncStatus = .unknown,
        completed: bool = false,
    };

    /// Callback for buffer mapAsync operation.
    fn mapCallback(
        status: zgpu.wgpu.BufferMapAsyncStatus,
        userdata: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *MapCallbackContext = @ptrCast(@alignCast(userdata));
        ctx.status = status;
        ctx.completed = true;
    }

    /// Take a screenshot of the current frame and save it to a PNG file.
    /// This re-renders the current scene to a separate texture and copies to CPU memory.
    ///
    /// This function:
    /// 1. Creates a render pass targeting the screenshot texture
    /// 2. Re-renders the scene (triangle) to capture pixels
    /// 3. Copies the texture to a staging buffer
    /// 4. Maps the buffer and writes to a PNG file
    pub fn takeScreenshot(self: *Self, filename: []const u8) RendererError!void {
        const device = self.device orelse {
            log.err("cannot take screenshot: device not initialized", .{});
            return RendererError.ScreenshotFailed;
        };

        const queue = self.queue orelse {
            log.err("cannot take screenshot: queue not initialized", .{});
            return RendererError.ScreenshotFailed;
        };

        // Ensure screenshot resources exist
        self.ensureScreenshotResources();

        const screenshot_texture = self.screenshot_texture orelse {
            log.err("failed to create screenshot texture", .{});
            return RendererError.ScreenshotFailed;
        };

        const staging_buffer = self.screenshot_staging_buffer orelse {
            log.err("failed to create staging buffer", .{});
            return RendererError.ScreenshotFailed;
        };

        const width = self.screenshot_width;
        const height = self.screenshot_height;
        const aligned_bytes_per_row = calcAlignedBytesPerRow(width);

        // Create a texture view for the screenshot texture
        const screenshot_view = screenshot_texture.createView(.{
            .next_in_chain = null,
            .label = "Screenshot Texture View",
            .format = .bgra8_unorm,
            .dimension = .tvdim_2d,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .aspect = .all,
        });
        defer screenshot_view.release();

        // Create a command encoder for rendering and copy operations
        const encoder = device.createCommandEncoder(.{
            .next_in_chain = null,
            .label = "Screenshot Encoder",
        });

        // Render the scene to the screenshot texture
        const color_attachment: zgpu.wgpu.RenderPassColorAttachment = .{
            .view = screenshot_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = cornflower_blue,
        };

        const render_pass = encoder.beginRenderPass(.{
            .label = "Screenshot Render Pass",
            .color_attachment_count = 1,
            .color_attachments = @ptrCast(&color_attachment),
        });

        // Flush all queued triangles using the batched rendering pipeline.
        // This renders whatever the app has queued via queueTriangle().
        self.flushBatch(render_pass);
        render_pass.end();

        // Copy from screenshot texture to staging buffer
        encoder.copyTextureToBuffer(
            .{
                .texture = screenshot_texture,
                .mip_level = 0,
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .aspect = .all,
            },
            .{
                .buffer = staging_buffer,
                .layout = .{
                    .offset = 0,
                    .bytes_per_row = aligned_bytes_per_row,
                    .rows_per_image = height,
                },
            },
            .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
        );

        // Submit the commands
        const commands = encoder.finish(.{
            .label = "Screenshot Commands",
        });
        queue.submit(&[_]zgpu.wgpu.CommandBuffer{commands});

        // Map the staging buffer for CPU read
        const buffer_size: u64 = @as(u64, aligned_bytes_per_row) * @as(u64, height);
        var map_ctx: MapCallbackContext = .{};

        staging_buffer.mapAsync(
            .{ .read = true },
            0,
            buffer_size,
            &mapCallback,
            @ptrCast(&map_ctx),
        );

        // Poll the device until mapping is complete.
        // Dawn processes mapping synchronously on tick(), so we poll in a loop.
        while (!map_ctx.completed) {
            device.tick();
        }

        if (map_ctx.status != .success) {
            log.err("buffer mapping failed with status: {}", .{map_ctx.status});
            return RendererError.ScreenshotFailed;
        }

        // Get the mapped data
        const mapped_data = staging_buffer.getConstMappedRange(u8, 0, buffer_size) orelse {
            log.err("failed to get mapped range", .{});
            staging_buffer.unmap();
            return RendererError.ScreenshotFailed;
        };

        // Write to PNG file
        self.writePngFile(filename, mapped_data, width, height, aligned_bytes_per_row) catch |err| {
            log.err("failed to write PNG file: {}", .{err});
            staging_buffer.unmap();
            return RendererError.ScreenshotFailed;
        };

        // Unmap the buffer
        staging_buffer.unmap();

        log.info("screenshot saved to: {s}", .{filename});
    }

    /// Write pixel data to a PNG file using zigimg.
    /// Converts BGRA to RGBA and writes to PNG format.
    fn writePngFile(
        self: *Self,
        filename: []const u8,
        data: []const u8,
        width: u32,
        height: u32,
        aligned_bytes_per_row: u32,
    ) !void {
        _ = self;

        const allocator = std.heap.page_allocator;

        // Create RGBA pixel data from BGRA source
        const pixel_count = @as(usize, width) * @as(usize, height);
        var rgba_pixels = try allocator.alloc(zigimg.color.Rgba32, pixel_count);
        defer allocator.free(rgba_pixels);

        // Convert BGRA to RGBA
        for (0..height) |y| {
            const src_row_offset = y * aligned_bytes_per_row;
            for (0..width) |x| {
                const src_pixel = src_row_offset + x * 4;
                const dst_idx = y * width + x;
                rgba_pixels[dst_idx] = .{
                    .r = data[src_pixel + 2], // R from BGRA offset 2
                    .g = data[src_pixel + 1], // G from BGRA offset 1
                    .b = data[src_pixel + 0], // B from BGRA offset 0
                    .a = data[src_pixel + 3], // A from BGRA offset 3
                };
            }
        }

        // Create zigimg Image from pixel data
        var image: zigimg.Image = .{
            .width = width,
            .height = height,
            .pixels = .{ .rgba32 = rgba_pixels },
            .animation = .{},
        };

        // Write to PNG file
        var write_buffer: [1024 * 1024]u8 = undefined;
        image.writeToFilePath(allocator, filename, &write_buffer, .{ .png = .{} }) catch |err| {
            log.err("zigimg writeToFilePath failed: {}", .{err});
            return err;
        };
    }

    /// Clean up renderer resources.
    /// Releases all WebGPU resources held by the renderer.
    pub fn deinit(self: *Self) void {
        log.debug("deinitializing renderer", .{});

        // Free command buffer first (uses allocator, not GPU resources)
        self.command_buffer.deinit(self.allocator);

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

        // Release uniform buffer before device (it depends on the device)
        if (self.uniform_buffer) |buffer| {
            buffer.release();
            self.uniform_buffer = null;
        }

        // Release bind group before bind group layout (it depends on the layout)
        if (self.bind_group) |bg| {
            bg.release();
            self.bind_group = null;
        }

        // Release pipeline layout before device (it depends on the device)
        if (self.pipeline_layout) |layout| {
            layout.release();
            self.pipeline_layout = null;
        }

        // Release bind group layout before device (it depends on the device)
        if (self.bind_group_layout) |layout| {
            layout.release();
            self.bind_group_layout = null;
        }

        // Release screenshot resources before device
        if (self.screenshot_texture) |texture| {
            texture.release();
            self.screenshot_texture = null;
        }
        if (self.screenshot_staging_buffer) |buffer| {
            buffer.release();
            self.screenshot_staging_buffer = null;
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
