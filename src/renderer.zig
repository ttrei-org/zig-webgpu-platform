//! Renderer module - WebGPU rendering abstraction
//!
//! This module provides the central rendering abstraction for the application,
//! encapsulating all WebGPU state and operations. The Renderer struct manages
//! the graphics device, command queue, and swap chain for presenting frames.

const std = @import("std");
const builtin = @import("builtin");
const zgpu = @import("zgpu");
const zigimg = @import("zigimg");

/// True if building for native desktop (not emscripten/web)
const is_native = builtin.os.tag != .emscripten;

/// zglfw is only available on native desktop builds.
/// On emscripten, we provide an opaque type stub since the renderer
/// doesn't use GLFW window handles on web (browser provides WebGPU surface).
const zglfw = if (is_native) @import("zglfw") else struct {
    pub const Window = opaque {};
};
const render_target = @import("render_target.zig");

pub const RenderTarget = render_target.RenderTarget;
pub const SwapChainRenderTarget = render_target.SwapChainRenderTarget;
pub const OffscreenRenderTarget = render_target.OffscreenRenderTarget;

const log = std.log.scoped(.renderer);

// Dawn native instance - opaque pointer to C++ dawn::native::Instance
// These types and externs are only available on native (non-WASM) builds.
// On web, WebGPU is provided by the browser's navigator.gpu API.
const DawnNativeInstance = if (is_native) ?*opaque {} else void;
const DawnProcsTable = if (is_native) ?*anyopaque else void;

// External C functions from dawn.cpp and dawn_proc.c (native only)
// On WASM builds, these are stubbed out as unreachable since browser provides WebGPU.
const dniCreate = if (is_native) struct {
    extern fn dniCreate() DawnNativeInstance;
}.dniCreate else struct {
    fn dniCreate() void {
        unreachable;
    }
}.dniCreate;

const dniDestroy = if (is_native) struct {
    extern fn dniDestroy(dni: DawnNativeInstance) void;
}.dniDestroy else struct {
    fn dniDestroy(_: void) void {}
}.dniDestroy;

const dniGetWgpuInstance = if (is_native) struct {
    extern fn dniGetWgpuInstance(dni: DawnNativeInstance) ?zgpu.wgpu.Instance;
}.dniGetWgpuInstance else struct {
    fn dniGetWgpuInstance(_: void) ?zgpu.wgpu.Instance {
        unreachable;
    }
}.dniGetWgpuInstance;

const dnGetProcs = if (is_native) struct {
    extern fn dnGetProcs() DawnProcsTable;
}.dnGetProcs else struct {
    fn dnGetProcs() void {
        unreachable;
    }
}.dnGetProcs;

const dawnProcSetProcs = if (is_native) struct {
    extern fn dawnProcSetProcs(procs: DawnProcsTable) void;
}.dawnProcSetProcs else struct {
    fn dawnProcSetProcs(_: void) void {}
}.dawnProcSetProcs;

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
///   @location(1) color: vec4<f32>
///
/// Memory layout (24 bytes total):
///   offset 0: position[0] (f32)
///   offset 4: position[1] (f32)
///   offset 8: color[0] (f32) - red
///   offset 12: color[1] (f32) - green
///   offset 16: color[2] (f32) - blue
///   offset 20: color[3] (f32) - alpha
pub const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,

    // Compile-time size guarantee: 6 floats * 4 bytes = 24 bytes total.
    // This ensures the struct layout matches GPU vertex buffer expectations.
    comptime {
        if (@sizeOf(Vertex) != 24) {
            @compileError("Vertex struct must be exactly 24 bytes for GPU compatibility");
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

    /// Convert to RGB array (legacy compatibility).
    /// Discards the alpha channel.
    pub fn toRgb(self: Color) [3]f32 {
        return .{ self.r, self.g, self.b };
    }

    /// Convert to RGBA array for vertex attribute compatibility.
    /// Includes the alpha channel for transparency support.
    pub fn toRgba(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    /// Create a Color from an RGB array (alpha defaults to 1.0).
    pub fn fromRgb(rgb_array: [3]f32) Color {
        return .{ .r = rgb_array[0], .g = rgb_array[1], .b = rgb_array[2], .a = 1.0 };
    }

    /// Create a Color from an RGBA array.
    pub fn fromRgba(rgba_array: [4]f32) Color {
        return .{ .r = rgba_array[0], .g = rgba_array[1], .b = rgba_array[2], .a = rgba_array[3] };
    }

    /// Create a Color from individual RGB values (alpha defaults to 1.0).
    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    /// Create a Color from individual RGBA values.
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Create a Color from u8 RGB values (0-255 range).
    /// Converts by dividing by 255.0. Alpha defaults to 1.0 (fully opaque).
    /// Convenient for using common RGB notation like (255, 128, 0).
    pub fn fromRgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = 1.0,
        };
    }

    /// Create a Color from u8 RGBA values (0-255 range).
    /// Converts by dividing by 255.0.
    /// Convenient for using common RGBA notation like (255, 128, 0, 255).
    pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// Create a Color from a 24-bit RGB hex value (e.g., 0xFF5500 for orange).
    /// Extracts channels using bit shifts. Alpha defaults to 1.0 (fully opaque).
    /// Common web color format support.
    pub fn fromHex(hex: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
            .a = 1.0,
        };
    }

    /// Create a Color from a 32-bit RGBA hex value (e.g., 0xFF550080 for semi-transparent orange).
    /// Extracts channels using bit shifts including alpha.
    /// Format: 0xRRGGBBAA.
    pub fn fromHexRgba(hex: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 24) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .a = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        };
    }
};

/// RGBA vertex color type for GPU vertex attributes.
/// This is the low-level format matching the vertex buffer layout (vec4<f32> in WGSL).
/// For high-level color operations, use the Color struct instead.
pub const VertexColor = [4]f32;

/// A triangle draw command containing three vertices with positions and colors.
/// Positions are in screen coordinates (pixels), origin at top-left.
/// Colors are interpolated across the triangle surface by the GPU.
///
/// This struct is used as a variant in DrawCommand and captures all data
/// needed to render a single triangle.
pub const Triangle = struct {
    /// Three vertex positions in screen coordinates (x, y in pixels).
    positions: [3][2]f32,
    /// Color at each vertex for gradient interpolation.
    /// Uses the Color type for richer color manipulation; alpha is included
    /// in GPU upload for transparency support.
    colors: [3]Color,

    /// Create a Triangle from an array of Vertex structs.
    /// Convenience function for converting between representations.
    /// Note: Converts from VertexColor (RGBA array) to Color (preserves all channels).
    pub fn fromVertices(vertices: [3]Vertex) Triangle {
        return .{
            .positions = .{
                vertices[0].position,
                vertices[1].position,
                vertices[2].position,
            },
            .colors = .{
                Color.fromRgba(vertices[0].color),
                Color.fromRgba(vertices[1].color),
                Color.fromRgba(vertices[2].color),
            },
        };
    }

    /// Convert back to an array of Vertex structs for GPU rendering.
    /// Extracts RGBA components from Color for full transparency support.
    pub fn toVertices(self: Triangle) [3]Vertex {
        return .{
            .{ .position = self.positions[0], .color = self.colors[0].toRgba() },
            .{ .position = self.positions[1], .color = self.colors[1].toRgba() },
            .{ .position = self.positions[2], .color = self.colors[2].toRgba() },
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
    .{ .position = .{ 100.0, 225.0 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } },
    // Bottom-right: green (300px from left, 225px from top)
    .{ .position = .{ 300.0, 225.0 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } },
    // Top-center: blue (200px from left, 75px from top)
    .{ .position = .{ 200.0, 75.0 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } },
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
        .format = .float32x4, // vec4<f32> for color (RGBA with alpha)
        .offset = @sizeOf([2]f32), // 8 bytes after position
        .shader_location = 1, // @location(1)
    },
};

/// Vertex buffer layout for the render pipeline.
/// Stride of 24 bytes (6 floats), per-vertex stepping.
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
    /// Only present on native builds; web builds use browser-provided WebGPU.
    native_instance: DawnNativeInstance = if (is_native) null else {},
    /// WebGPU instance handle - entry point for the WebGPU API.
    instance: zgpu.wgpu.Instance,
    /// WebGPU adapter representing a physical GPU.
    adapter: zgpu.wgpu.Adapter,
    /// WebGPU device handle for creating GPU resources.
    device: zgpu.wgpu.Device,
    /// Command queue for submitting work to the GPU.
    queue: zgpu.wgpu.Queue,
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
    shader_module: zgpu.wgpu.ShaderModule,
    /// Bind group layout describing the uniform buffer binding.
    /// Defines the interface between Zig code and shader for screen dimensions.
    /// Layout: binding 0, visibility VERTEX, buffer type Uniform.
    bind_group_layout: zgpu.wgpu.BindGroupLayout,
    /// Pipeline layout defining resource bindings for the render pipeline.
    /// Contains bind_group_layout for uniform buffer access in shaders.
    pipeline_layout: zgpu.wgpu.PipelineLayout,
    /// Render pipeline for triangle rendering.
    /// Combines shader stages, vertex layout, and output format configuration.
    render_pipeline: zgpu.wgpu.RenderPipeline,
    /// Dynamic vertex buffer for triangle rendering.
    /// Holds up to max_vertex_capacity vertices, reused each frame via queue.writeBuffer().
    /// Size = max_vertex_capacity * @sizeOf(Vertex) = 10000 * 20 = 200KB.
    vertex_buffer: zgpu.wgpu.Buffer,
    /// Maximum number of vertices the buffer can hold.
    /// Set to 10,000 vertices (~200KB) for efficient batched rendering.
    vertex_buffer_capacity: u32,
    /// Uniform buffer for screen dimensions.
    /// Holds the Uniforms struct (8 bytes data, 16 bytes allocated for GPU alignment).
    /// Updated each frame or on resize via queue.writeBuffer().
    uniform_buffer: zgpu.wgpu.Buffer,
    /// Bind group containing the uniform buffer binding.
    /// Makes the uniform data (screen dimensions) available to the shader during rendering.
    /// Set during render pass to connect the uniform buffer to shader binding 0.
    bind_group: zgpu.wgpu.BindGroup,
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

    /// Initialize the renderer with a GLFW window (native desktop only).
    /// Creates a WebGPU instance, surface, adapter (compatible with surface), device,
    /// and swap chain. The surface must be created before the adapter to ensure
    /// the adapter can present to the surface on all platforms (especially X11).
    ///
    /// This function is only available on native builds. For web/WASM builds,
    /// use initWeb() instead.
    pub const init = if (is_native) initNativeImpl else struct {
        fn init(_: std.mem.Allocator, _: *zglfw.Window, _: u32, _: u32) RendererError!Self {
            @compileError("Renderer.init() is only available on native builds; use initWeb() for WASM");
        }
    }.init;

    /// Shared GPU resources returned by initSharedResources.
    /// All fields are always valid after successful initialization.
    const SharedResources = struct {
        shader_module: zgpu.wgpu.ShaderModule,
        bind_group_layout: zgpu.wgpu.BindGroupLayout,
        pipeline_layout: zgpu.wgpu.PipelineLayout,
        render_pipeline: zgpu.wgpu.RenderPipeline,
        vertex_buffer: zgpu.wgpu.Buffer,
        vertex_buffer_capacity: u32,
        uniform_buffer: zgpu.wgpu.Buffer,
        bind_group: zgpu.wgpu.BindGroup,
    };

    /// Initialize shared GPU resources (shader, pipeline, buffers, bind group).
    /// Called by all three init paths after they obtain a device and queue.
    /// On error, releases any resources created so far within this function.
    fn initSharedResources(
        device: zgpu.wgpu.Device,
        queue: zgpu.wgpu.Queue,
        width: u32,
        height: u32,
    ) RendererError!SharedResources {
        // Create shader module from embedded WGSL source
        const shader_module = createShaderModule(device) orelse {
            log.err("failed to create shader module", .{});
            return RendererError.ShaderCompilationFailed;
        };
        errdefer shader_module.release();

        // Create bind group layout for uniform buffer (screen dimensions)
        const bind_group_layout = createBindGroupLayout(device);
        errdefer bind_group_layout.release();
        log.debug("bind group layout created for uniforms", .{});

        // Create pipeline layout with the bind group layout in slot 0
        const bind_group_layouts = [_]zgpu.wgpu.BindGroupLayout{bind_group_layout};
        const pipeline_layout = device.createPipelineLayout(.{
            .next_in_chain = null,
            .label = "Main Pipeline Layout",
            .bind_group_layout_count = bind_group_layouts.len,
            .bind_group_layouts = &bind_group_layouts,
        });
        errdefer pipeline_layout.release();
        log.debug("pipeline layout created with bind group layout in slot 0", .{});

        // Create render pipeline for triangle rendering
        const render_pipeline = createRenderPipeline(device, pipeline_layout, shader_module) orelse {
            log.err("failed to create render pipeline", .{});
            return RendererError.PipelineCreationFailed;
        };
        // No errdefer needed for render_pipeline - it's the last failable operation,
        // and remaining operations below are infallible.

        // Create dynamic vertex buffer
        const vertex_result = createVertexBuffer(device);
        log.info("dynamic vertex buffer created: {} vertices capacity ({} bytes)", .{
            vertex_result.capacity,
            @as(u64, vertex_result.capacity) * @sizeOf(Vertex),
        });

        // Create uniform buffer for screen dimensions
        const uniform_buffer = createUniformBuffer(device);
        log.info("uniform buffer created for screen dimensions", .{});

        // Initialize uniform buffer with current screen dimensions
        const initial_uniforms: Uniforms = .{
            .screen_size = .{ @floatFromInt(width), @floatFromInt(height) },
        };
        queue.writeBuffer(uniform_buffer, 0, Uniforms, &.{initial_uniforms});
        log.info("uniform buffer initialized with screen size: {}x{}", .{ width, height });

        // Create bind group containing the uniform buffer
        const bind_group = createBindGroup(device, bind_group_layout, uniform_buffer);
        log.info("bind group created with uniform buffer", .{});

        return .{
            .shader_module = shader_module,
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .render_pipeline = render_pipeline,
            .vertex_buffer = vertex_result.buffer,
            .vertex_buffer_capacity = vertex_result.capacity,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
        };
    }

    fn initNativeImpl(allocator: std.mem.Allocator, window: *zglfw.Window, width: u32, height: u32) RendererError!Self {
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

        // Initialize shared GPU resources (shader, pipeline, buffers, bind group).
        const shared = initSharedResources(device, queue, width, height) catch |err| {
            // Release backend-specific resources on shared init failure
            swapchain.release();
            queue.release();
            device.release();
            adapter.release();
            surface.release();
            instance.release();
            dniDestroy(native_instance);
            return err;
        };

        return .{
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
            .shader_module = shared.shader_module,
            .bind_group_layout = shared.bind_group_layout,
            .pipeline_layout = shared.pipeline_layout,
            .render_pipeline = shared.render_pipeline,
            .vertex_buffer = shared.vertex_buffer,
            .vertex_buffer_capacity = shared.vertex_buffer_capacity,
            .uniform_buffer = shared.uniform_buffer,
            .bind_group = shared.bind_group,
            // Screenshot resources are created lazily on first capture
            .screenshot_texture = null,
            .screenshot_staging_buffer = null,
            .screenshot_width = 0,
            .screenshot_height = 0,
        };
    }

    /// Initialize the renderer for headless (offscreen) rendering (native only).
    /// Creates a WebGPU instance, adapter (without surface), and device.
    /// No swap chain is created - use createOffscreenRenderTarget() instead.
    ///
    /// This enables GPU rendering without a window or display, which is useful for:
    /// - Automated testing
    /// - Screenshot generation in CI environments
    /// - Server-side rendering
    ///
    /// This function is only available on native builds.
    pub const initHeadless = if (is_native) initHeadlessImpl else struct {
        fn initHeadless(_: std.mem.Allocator, _: u32, _: u32) RendererError!Self {
            @compileError("Renderer.initHeadless() is only available on native builds");
        }
    }.initHeadless;

    fn initHeadlessImpl(allocator: std.mem.Allocator, width: u32, height: u32) RendererError!Self {
        log.info("initializing headless renderer (no window/surface)", .{});

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

        // Request adapter WITHOUT a compatible surface.
        // This allows headless operation - we render to an offscreen texture.
        const adapter = requestAdapterHeadless(instance) orelse {
            log.err("failed to obtain WebGPU adapter for headless rendering", .{});
            instance.release();
            return RendererError.AdapterRequestFailed;
        };

        // Log adapter properties for debugging
        var props: zgpu.wgpu.AdapterProperties = undefined;
        props.next_in_chain = null;
        adapter.getProperties(&props);
        log.info("WebGPU adapter (headless): {s} ({s})", .{ props.name, props.driver_description });
        log.info("  Backend: {}, Type: {}", .{ props.backend_type, props.adapter_type });
        log.info("  Vendor: {s} (0x{x}), Device ID: 0x{x}", .{ props.vendor_name, props.vendor_id, props.device_id });

        // Request device with default limits
        const device = requestDevice(adapter) orelse {
            log.err("failed to obtain WebGPU device", .{});
            adapter.release();
            instance.release();
            return RendererError.DeviceRequestFailed;
        };
        log.info("WebGPU device obtained (headless)", .{});

        // Set up error callback to catch validation errors
        device.setUncapturedErrorCallback(&deviceErrorCallback, null);

        // Get the command queue from the device
        const queue = device.getQueue();
        log.debug("WebGPU queue obtained", .{});

        // Initialize shared GPU resources (shader, pipeline, buffers, bind group).
        const shared = initSharedResources(device, queue, width, height) catch |err| {
            // Release backend-specific resources on shared init failure
            queue.release();
            device.release();
            adapter.release();
            instance.release();
            dniDestroy(native_instance);
            return err;
        };

        log.info("headless renderer initialization complete", .{});

        return .{
            .allocator = allocator,
            .command_buffer = .empty,
            .native_instance = native_instance,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = null, // No surface in headless mode
            .swapchain = null, // No swap chain in headless mode
            .window = null, // No window in headless mode
            .swapchain_width = width,
            .swapchain_height = height,
            .shader_module = shared.shader_module,
            .bind_group_layout = shared.bind_group_layout,
            .pipeline_layout = shared.pipeline_layout,
            .render_pipeline = shared.render_pipeline,
            .vertex_buffer = shared.vertex_buffer,
            .vertex_buffer_capacity = shared.vertex_buffer_capacity,
            .uniform_buffer = shared.uniform_buffer,
            .bind_group = shared.bind_group,
            .screenshot_texture = null,
            .screenshot_staging_buffer = null,
            .screenshot_width = 0,
            .screenshot_height = 0,
        };
    }

    /// Initialize the renderer for web/WASM builds using browser WebGPU.
    ///
    /// This function is the web counterpart to init() (desktop) and initHeadless().
    /// It uses browser-provided WebGPU APIs instead of Dawn:
    /// - Creates a surface from the HTML canvas element
    /// - Requests adapter and device via browser's navigator.gpu API
    /// - Creates a swap chain bound to the canvas for presentation
    ///
    /// The browser WebGPU context must be available (navigator.gpu must exist).
    /// On browsers without WebGPU support, this will fail with appropriate errors.
    ///
    /// Parameters:
    /// - allocator: Memory allocator for internal buffers
    /// - width: Canvas width in pixels
    /// - height: Canvas height in pixels
    ///
    /// Returns:
    /// - Initialized Renderer for web rendering, or error on failure
    ///
    /// Note: This function is only available on WASM builds. On native builds,
    /// use init() for windowed rendering or initHeadless() for offscreen rendering.
    pub const initWeb = if (!is_native) initWebImpl else struct {
        fn initWebImpl(_: std.mem.Allocator, _: u32, _: u32) RendererError!Self {
            @compileError("initWeb is only available on WASM builds");
        }
    }.initWebImpl;

    fn initWebImpl(allocator: std.mem.Allocator, width: u32, height: u32) RendererError!Self {
        const web = @import("platform/web.zig");

        log.info("initializing web renderer (browser WebGPU)", .{});

        // On web, WebGPU is provided by the browser. We don't need Dawn.
        // The browser's navigator.gpu API provides the WebGPU implementation.

        // Create WebGPU instance - on web this is obtained from the browser
        // zgpu provides a platform-agnostic way to create instances
        const instance = zgpu.wgpu.createInstance(.{
            .next_in_chain = null,
        });
        // Check if instance creation succeeded (null pointer indicates failure)
        if (@intFromPtr(instance) == 0) {
            log.err("failed to create WebGPU instance (browser may not support WebGPU)", .{});
            return RendererError.InstanceCreationFailed;
        }
        log.debug("WebGPU instance created from browser", .{});

        // Create surface from the HTML canvas element
        // The default canvas selector "#canvas" matches Emscripten's default
        const surface = web.createSurfaceFromCanvas(instance, "#canvas") orelse {
            log.err("failed to create WebGPU surface from canvas", .{});
            instance.release();
            return RendererError.SurfaceCreationFailed;
        };
        log.debug("WebGPU surface created from canvas", .{});

        // Request adapter with high-performance preference and compatible surface
        // On web, this calls navigator.gpu.requestAdapter() via zgpu
        const adapter = web.requestAdapterSync(instance, surface) orelse {
            log.err("failed to obtain WebGPU adapter from browser", .{});
            surface.release();
            instance.release();
            return RendererError.AdapterRequestFailed;
        };

        // Log adapter properties for debugging
        var props: zgpu.wgpu.AdapterProperties = undefined;
        props.next_in_chain = null;
        adapter.getProperties(&props);
        log.info("WebGPU adapter (web): {s} ({s})", .{ props.name, props.driver_description });
        log.info("  Backend: {}, Type: {}", .{ props.backend_type, props.adapter_type });

        // Request device with default limits
        const device = web.requestDeviceSync(adapter) orelse {
            log.err("failed to obtain WebGPU device from browser", .{});
            adapter.release();
            surface.release();
            instance.release();
            return RendererError.DeviceRequestFailed;
        };
        log.info("WebGPU device obtained (web)", .{});

        // Set up error callback to catch validation errors
        device.setUncapturedErrorCallback(&deviceErrorCallback, null);

        // Get the command queue from the device
        const queue = device.getQueue();
        log.debug("WebGPU queue obtained", .{});

        // Create swap chain for the canvas
        const swapchain = web.createSwapChain(device, surface, width, height) orelse {
            log.err("failed to create swap chain for canvas", .{});
            queue.release();
            device.release();
            adapter.release();
            surface.release();
            instance.release();
            return RendererError.SwapChainCreationFailed;
        };
        log.info("WebGPU swap chain created: {}x{}", .{ width, height });

        // Initialize shared GPU resources (shader, pipeline, buffers, bind group).
        const shared = initSharedResources(device, queue, width, height) catch |err| {
            // Release backend-specific resources on shared init failure
            swapchain.release();
            queue.release();
            device.release();
            adapter.release();
            surface.release();
            instance.release();
            return err;
        };

        log.info("web renderer initialization complete", .{});

        return .{
            .allocator = allocator,
            .command_buffer = .empty,
            // No native_instance on web - browser provides WebGPU
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = surface,
            .swapchain = swapchain,
            .window = null, // No GLFW window on web
            .swapchain_width = width,
            .swapchain_height = height,
            .shader_module = shared.shader_module,
            .bind_group_layout = shared.bind_group_layout,
            .pipeline_layout = shared.pipeline_layout,
            .render_pipeline = shared.render_pipeline,
            .vertex_buffer = shared.vertex_buffer,
            .vertex_buffer_capacity = shared.vertex_buffer_capacity,
            .uniform_buffer = shared.uniform_buffer,
            .bind_group = shared.bind_group,
            .screenshot_texture = null,
            .screenshot_staging_buffer = null,
            .screenshot_width = 0,
            .screenshot_height = 0,
        };
    }

    /// Create an OffscreenRenderTarget for headless rendering.
    /// Use this instead of createSwapChainRenderTarget() in headless mode.
    pub fn createOffscreenRenderTarget(self: *Self, width: u32, height: u32) OffscreenRenderTarget {
        return OffscreenRenderTarget.init(self.device, width, height);
    }

    /// Create a SwapChainRenderTarget from this renderer's swap chain.
    /// The returned target wraps the renderer's swap chain and can be used with beginFrame().
    /// This enables the RenderTarget abstraction for windowed rendering.
    ///
    /// Note: The returned SwapChainRenderTarget holds references to the renderer's resources.
    /// It should be reinitialized if the renderer's swap chain is recreated.
    pub fn createSwapChainRenderTarget(self: *Self) SwapChainRenderTarget {
        return SwapChainRenderTarget.init(
            self.swapchain.?,
            self.device,
            self.surface.?,
            self.swapchain_width,
            self.swapchain_height,
        );
    }

    /// Begin a new frame for rendering.
    /// Gets the current texture view from the render target and creates a command encoder.
    /// Call this once at the start of each frame before recording render commands.
    /// Returns FrameState containing the texture view and command encoder.
    ///
    /// Parameters:
    /// - target: The render target to render to. Can be a swap chain (windowed) or
    ///   offscreen texture (headless). The target provides the texture view for rendering.
    ///
    /// Note: The caller is responsible for handling resize by calling target.needsResize()
    /// and target.resize() before calling beginFrame().
    pub fn beginFrame(self: *Self, target: *RenderTarget) RendererError!FrameState {
        // Clear previous frame's commands while keeping allocated memory for efficiency.
        // Each frame starts fresh with an empty command list.
        self.command_buffer.clearRetainingCapacity();

        // Get the texture view from the render target.
        // This abstracts over swap chain vs offscreen texture - both provide a texture view.
        const texture_view = target.getTextureView() catch |err| {
            log.warn("failed to get texture view from render target: {}", .{err});
            return RendererError.BeginFrameFailed;
        };

        // Update uniform buffer with current screen dimensions from the render target.
        // This ensures shaders use correct NDC transform after any resize.
        const dimensions = target.getDimensions();
        if (dimensions.width != self.swapchain_width or dimensions.height != self.swapchain_height) {
            self.swapchain_width = dimensions.width;
            self.swapchain_height = dimensions.height;
            const new_uniforms: Uniforms = .{
                .screen_size = .{ @floatFromInt(dimensions.width), @floatFromInt(dimensions.height) },
            };
            self.queue.writeBuffer(self.uniform_buffer, 0, Uniforms, &.{new_uniforms});
            log.debug("uniform buffer updated with screen size: {}x{}", .{ dimensions.width, dimensions.height });
        }

        // Create a command encoder for recording GPU commands this frame
        const command_encoder = self.device.createCommandEncoder(.{
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
    /// - colors: Color at each vertex for gradient interpolation.
    ///   Alpha channel is stored but currently ignored during rendering.
    ///
    /// Note: The command buffer must be processed during endFrame to render the queued triangles.
    pub fn queueTriangle(self: *Self, positions: [3][2]f32, colors: [3]Color) void {
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
        // Update vertex buffer with the provided vertices.
        // This allows the app to specify different triangles each frame.
        self.queue.writeBuffer(self.vertex_buffer, 0, Vertex, vertices);

        // Set render pipeline - configures GPU to use our shader and vertex layout
        render_pass.setPipeline(self.render_pipeline);

        // Set bind group 0 (uniforms) - required by the pipeline layout
        render_pass.setBindGroup(0, self.bind_group, &.{});

        // Bind vertex buffer (slot 0, full buffer)
        const vertex_buffer_size: u64 = @sizeOf([3]Vertex);
        render_pass.setVertexBuffer(0, self.vertex_buffer, 0, vertex_buffer_size);

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

        // Set render pipeline - configures GPU to use our shader and vertex layout
        render_pass.setPipeline(self.render_pipeline);

        // Set bind group 0 (uniforms) - required by the pipeline layout
        render_pass.setBindGroup(0, self.bind_group, &.{});

        // Bind vertex buffer with the exact size needed for all vertices
        const vertex_buffer_size: u64 = @as(u64, vertex_count) * @sizeOf(Vertex);
        render_pass.setVertexBuffer(0, self.vertex_buffer, 0, vertex_buffer_size);

        // Issue a single draw call for all triangles in the batch.
        // vertex_count = total_triangles * 3.
        render_pass.draw(vertex_count, 1, 0, 0);

        log.debug("batched draw: {} vertices ({} triangles)", .{ vertex_count, vertex_count / 3 });
    }

    /// End the current frame and present it to the screen.
    /// Finishes the command encoder to create a command buffer, submits it
    /// to the GPU queue, and presents via the render target.
    /// Call this once at the end of each frame after all drawing is complete.
    ///
    /// Parameters:
    /// - frame_state: The FrameState returned by beginFrame().
    /// - target: The same render target passed to beginFrame(). Used for presentation.
    ///
    /// Note: flushBatch() should be called before endRenderPass() to render
    /// any queued triangles. This function only handles frame submission.
    pub fn endFrame(self: *Self, frame_state: FrameState, target: *RenderTarget) void {
        // Finish the command encoder to create a command buffer
        const command_buffer = frame_state.command_encoder.finish(.{
            .label = "Frame Command Buffer",
        });

        // Submit the command buffer to the GPU queue
        self.queue.submit(&[_]zgpu.wgpu.CommandBuffer{command_buffer});

        // Present the frame via the render target.
        // This handles texture view release and swap chain presentation.
        // For offscreen targets, this is a no-op.
        target.present();

        // Tick the device to process internal Dawn work.
        // Required on some platforms (especially Linux/Vulkan) for the
        // compositor to receive and display the presented frame.
        self.device.tick();

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
        // Upload vertices to GPU buffer at offset 0.
        // Size = vertex_count * @sizeOf(Vertex).
        const vertex_slice = vertices[0..vertex_count];
        self.queue.writeBuffer(self.vertex_buffer, 0, Vertex, vertex_slice);

        log.debug("uploaded {} vertices ({} triangles) to GPU buffer", .{ vertex_count, current_triangle });

        return vertex_count;
    }

    /// Recreate the swap chain with new dimensions.
    /// Called internally when window resize is detected.
    fn recreateSwapChain(self: *Self, width: u32, height: u32) RendererError!void {
        const surface = self.surface orelse {
            return RendererError.SwapChainCreationFailed;
        };

        // Release old swap chain
        if (self.swapchain) |old_swapchain| {
            old_swapchain.release();
        }

        // Create new swap chain with updated dimensions
        const swapchain = self.device.createSwapChain(
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
        const new_uniforms: Uniforms = .{
            .screen_size = .{ @floatFromInt(width), @floatFromInt(height) },
        };
        self.queue.writeBuffer(self.uniform_buffer, 0, Uniforms, &.{new_uniforms});

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

    /// Alpha blending state for transparency support.
    /// Uses standard alpha blending: result = src * src_alpha + dst * (1 - src_alpha)
    const alpha_blend_state: zgpu.wgpu.BlendState = .{
        .color = .{
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
            .operation = .add,
        },
        .alpha = .{
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
            .operation = .add,
        },
    };

    /// Create the render pipeline for triangle rendering.
    /// Configures vertex and fragment stages, primitive topology, and output format.
    /// Returns null if pipeline creation fails.
    fn createRenderPipeline(
        device: zgpu.wgpu.Device,
        pipeline_layout: zgpu.wgpu.PipelineLayout,
        shader_module: zgpu.wgpu.ShaderModule,
    ) ?zgpu.wgpu.RenderPipeline {
        // Color target state for BGRA8Unorm output (matches swap chain format)
        // Alpha blending enabled for transparency support.
        const color_target: zgpu.wgpu.ColorTargetState = .{
            .next_in_chain = null,
            .format = .bgra8_unorm,
            .blend = &alpha_blend_state,
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

    /// Request a WebGPU adapter for headless rendering (no surface required).
    /// Prefers high-performance GPU and uses the default backend.
    /// Returns null if no suitable adapter is available.
    fn requestAdapterHeadless(instance: zgpu.wgpu.Instance) ?zgpu.wgpu.Adapter {
        const Response = struct {
            adapter: ?zgpu.wgpu.Adapter = null,
            status: zgpu.wgpu.RequestAdapterStatus = .unknown,
        };

        var response: Response = .{};

        // Request adapter without a compatible surface for headless rendering.
        // This allows GPU compute and offscreen rendering without a window.
        instance.requestAdapter(
            .{
                .next_in_chain = null,
                .compatible_surface = null, // No surface needed for headless
                .power_preference = .high_performance,
                .backend_type = .undef, // Let Dawn choose the best backend
                .force_fallback_adapter = false,
                .compatibility_mode = false,
            },
            &adapterCallback,
            @ptrCast(&response),
        );

        if (response.status != .success) {
            log.warn("headless adapter request failed with status: {}", .{response.status});
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
        self.screenshot_texture = self.device.createTexture(.{
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

        self.screenshot_staging_buffer = self.device.createBuffer(.{
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

    /// Save the current frame to a PNG file at the specified path.
    /// This is the public API for screenshot capture in windowed mode.
    ///
    /// The method:
    /// 1. Triggers GPU readback by re-rendering to a screenshot texture
    /// 2. Waits for the GPU copy to staging buffer to complete
    /// 3. Converts pixel data to PNG format (BGRA to RGBA)
    /// 4. Writes the PNG file to the specified path
    ///
    /// For headless mode, use `takeScreenshotFromOffscreen` instead which
    /// captures from an existing offscreen render target without re-rendering.
    ///
    /// Errors are returned as `RendererError.ScreenshotFailed` which covers:
    /// - Device/queue not initialized
    /// - Buffer mapping failure
    /// - File I/O errors (directory doesn't exist, permission denied, disk full)
    pub fn screenshot(self: *Self, path: []const u8) RendererError!void {
        return self.takeScreenshot(path);
    }

    /// Take a screenshot of the current frame and save it to a PNG file.
    /// This re-renders the current scene to a separate texture and copies to CPU memory.
    ///
    /// This function:
    /// 1. Creates a render pass targeting the screenshot texture
    /// 2. Re-renders the scene (triangle) to capture pixels
    /// 3. Copies the texture to a staging buffer
    /// 4. Maps the buffer and writes to a PNG file
    fn takeScreenshot(self: *Self, filename: []const u8) RendererError!void {

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
        const encoder = self.device.createCommandEncoder(.{
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
        self.queue.submit(&[_]zgpu.wgpu.CommandBuffer{commands});

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
            self.device.tick();
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

    /// Take a screenshot from an offscreen render target and save to PNG.
    /// This is used for headless rendering where we already have a texture.
    /// The offscreen texture is in RGBA format (not BGRA like swap chain).
    pub fn takeScreenshotFromOffscreen(
        self: *Self,
        offscreen_target: *OffscreenRenderTarget,
        filename: []const u8,
    ) RendererError!void {
        const width = offscreen_target.width;
        const height = offscreen_target.height;
        const aligned_bytes_per_row = calcAlignedBytesPerRow(width);
        const buffer_size: u64 = @as(u64, aligned_bytes_per_row) * @as(u64, height);

        // Create a staging buffer for CPU readback
        const staging_buffer = self.device.createBuffer(.{
            .next_in_chain = null,
            .label = "Offscreen Screenshot Staging Buffer",
            .usage = .{ .map_read = true, .copy_dst = true },
            .size = buffer_size,
            .mapped_at_creation = .false,
        });
        defer staging_buffer.release();

        // Create a command encoder for copy operations
        const encoder = self.device.createCommandEncoder(.{
            .next_in_chain = null,
            .label = "Offscreen Screenshot Encoder",
        });

        // Copy from offscreen texture to staging buffer
        encoder.copyTextureToBuffer(
            .{
                .texture = offscreen_target.getTexture(),
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
            .label = "Offscreen Screenshot Commands",
        });
        self.queue.submit(&[_]zgpu.wgpu.CommandBuffer{commands});

        // Map the staging buffer for CPU read
        var map_ctx: MapCallbackContext = .{};

        staging_buffer.mapAsync(
            .{ .read = true },
            0,
            buffer_size,
            &mapCallback,
            @ptrCast(&map_ctx),
        );

        // Poll the device until mapping is complete
        while (!map_ctx.completed) {
            self.device.tick();
        }

        if (map_ctx.status != .success) {
            log.err("offscreen buffer mapping failed with status: {}", .{map_ctx.status});
            return RendererError.ScreenshotFailed;
        }

        // Get the mapped data
        const mapped_data = staging_buffer.getConstMappedRange(u8, 0, buffer_size) orelse {
            log.err("failed to get mapped range for offscreen screenshot", .{});
            staging_buffer.unmap();
            return RendererError.ScreenshotFailed;
        };

        // Verify pixel data is accessible from CPU (bd-3m2).
        // This confirms the GPU->CPU data path works correctly.
        verifyPixelData(mapped_data, width, height, aligned_bytes_per_row);

        // Write to PNG file - offscreen now uses BGRA format (same as all backends)
        self.writePngFile(filename, mapped_data, width, height, aligned_bytes_per_row) catch |err| {
            log.err("failed to write offscreen PNG file: {}", .{err});
            staging_buffer.unmap();
            return RendererError.ScreenshotFailed;
        };

        // Unmap the buffer
        staging_buffer.unmap();

        log.info("offscreen screenshot saved to: {s}", .{filename});
    }

    /// Verify that pixel data from GPU readback is accessible and valid.
    /// Reads pixels at specific locations and logs their RGBA values.
    /// Verifies: background matches expected clear color, rendered areas have content.
    ///
    /// This function confirms the GPU->CPU data path works correctly (bd-3m2).
    fn verifyPixelData(data: []const u8, width: u32, height: u32, aligned_bytes_per_row: u32) void {
        log.info("=== Pixel Data Verification (GPU->CPU readback) ===", .{});
        log.info("image dimensions: {}x{}, row stride: {} bytes", .{ width, height, aligned_bytes_per_row });
        log.info("total buffer size: {} bytes", .{data.len});

        // Helper to read a pixel at (x, y) - returns RGBA tuple from BGRA layout
        // All backends now use BGRA format: byte 0=B, 1=G, 2=R, 3=A
        const getPixel = struct {
            fn get(pixel_data: []const u8, x: u32, y: u32, stride: u32) struct { r: u8, g: u8, b: u8, a: u8 } {
                const offset = @as(usize, y) * @as(usize, stride) + @as(usize, x) * 4;
                if (offset + 3 >= pixel_data.len) {
                    return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                }
                return .{
                    .r = pixel_data[offset + 2], // R is at BGRA offset 2
                    .g = pixel_data[offset + 1], // G is at BGRA offset 1
                    .b = pixel_data[offset + 0], // B is at BGRA offset 0
                    .a = pixel_data[offset + 3], // A is at BGRA offset 3
                };
            }
        }.get;

        // Expected cornflower blue clear color: (0.39, 0.58, 0.93, 1.0) as RGBA8
        // R: 0.39 * 255 = 99.45 -> 99
        // G: 0.58 * 255 = 147.9 -> 148
        // B: 0.93 * 255 = 237.15 -> 237
        // A: 255
        const expected_bg = struct {
            const r: u8 = 99;
            const g: u8 = 148;
            const b: u8 = 237;
            const a: u8 = 255;
        };

        // Sample locations to verify:
        // 1. Corners - should be background (cornflower blue)
        // 2. Center area (200, 150 in the app's 400x300 coordinate space) - should have rendered content
        // We'll check at (0,0), (width-1, 0), (0, height-1), (width-1, height-1) for background
        // And check around center for rendered content (starburst pattern)

        log.info("--- Background verification (corners should be cornflower blue) ---", .{});

        const corners = [_]struct { x: u32, y: u32, name: []const u8 }{
            .{ .x = 0, .y = 0, .name = "top-left" },
            .{ .x = width - 1, .y = 0, .name = "top-right" },
            .{ .x = 0, .y = height - 1, .name = "bottom-left" },
            .{ .x = width - 1, .y = height - 1, .name = "bottom-right" },
        };

        var bg_matches: u32 = 0;
        for (corners) |corner| {
            const px = getPixel(data, corner.x, corner.y, aligned_bytes_per_row);
            const is_bg = (absDiff(px.r, expected_bg.r) <= 2) and
                (absDiff(px.g, expected_bg.g) <= 2) and
                (absDiff(px.b, expected_bg.b) <= 2) and
                (px.a == expected_bg.a);

            log.info("  {s} ({}, {}): RGBA({}, {}, {}, {}) {s}", .{
                corner.name,
                corner.x,
                corner.y,
                px.r,
                px.g,
                px.b,
                px.a,
                if (is_bg) "[OK: matches background]" else "[UNEXPECTED]",
            });
            if (is_bg) bg_matches += 1;
        }

        log.info("--- Center area verification (should have rendered content) ---", .{});

        // Check center of the starburst (around 200, 150)
        // Also check a few points within the starburst radius
        const center_points = [_]struct { x: u32, y: u32, name: []const u8 }{
            .{ .x = 200, .y = 150, .name = "center" },
            .{ .x = 200, .y = 100, .name = "above-center" },
            .{ .x = 250, .y = 150, .name = "right-of-center" },
            .{ .x = 200, .y = 200, .name = "below-center" },
            .{ .x = 150, .y = 150, .name = "left-of-center" },
        };

        var non_bg_count: u32 = 0;
        for (center_points) |point| {
            if (point.x >= width or point.y >= height) continue;

            const px = getPixel(data, point.x, point.y, aligned_bytes_per_row);
            const is_bg = (absDiff(px.r, expected_bg.r) <= 2) and
                (absDiff(px.g, expected_bg.g) <= 2) and
                (absDiff(px.b, expected_bg.b) <= 2);
            const is_nonzero = (px.r != 0 or px.g != 0 or px.b != 0);

            log.info("  {s} ({}, {}): RGBA({}, {}, {}, {}) {s}", .{
                point.name,
                point.x,
                point.y,
                px.r,
                px.g,
                px.b,
                px.a,
                if (!is_bg and is_nonzero) "[OK: rendered content]" else if (is_bg) "[background]" else "[zero]",
            });
            if (!is_bg and is_nonzero) non_bg_count += 1;
        }

        log.info("--- Verification Summary ---", .{});
        log.info("  background corners matching: {}/4", .{bg_matches});
        log.info("  center points with rendered content: {}/{}", .{ non_bg_count, center_points.len });

        if (bg_matches == 4 and non_bg_count > 0) {
            log.info("  RESULT: GPU->CPU pixel readback VERIFIED - data is valid!", .{});
        } else if (bg_matches == 0 and non_bg_count == 0) {
            log.warn("  RESULT: All pixels appear zero or unexpected - readback may have failed", .{});
        } else {
            log.info("  RESULT: Partial verification - some expected patterns found", .{});
        }

        log.info("=== End Pixel Data Verification ===", .{});
    }

    /// Helper: compute absolute difference between two u8 values
    fn absDiff(a: u8, b: u8) u8 {
        return if (a > b) a - b else b - a;
    }

    /// Write pixel data to a PNG file using zigimg.
    /// Converts BGRA to RGBA and writes to PNG format.
    ///
    /// Handles common file I/O errors with user-friendly messages:
    /// - Directory doesn't exist (FileNotFound)
    /// - Permission denied (AccessDenied, PermissionDenied)
    /// - Disk full (NoSpaceLeft, DiskQuota)
    ///
    /// Logs success with file path and size.
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

        // Write PNG file to disk with error handling
        var write_buffer: [1024 * 1024]u8 = undefined;
        image.writeToFilePath(allocator, filename, &write_buffer, .{ .png = .{} }) catch |err| {
            logPngWriteError(err, filename);
            return err;
        };

        // Log success with file path and size
        const file_size = getFileSize(filename);
        log.info("PNG file written: {s} ({} bytes, {}x{} pixels)", .{ filename, file_size, width, height });
    }

    /// Log user-friendly error messages for PNG file write failures.
    /// Maps low-level errors to actionable messages.
    fn logPngWriteError(err: anyerror, filename: []const u8) void {
        switch (err) {
            error.FileNotFound => log.err("failed to write PNG: directory does not exist for path '{s}'", .{filename}),
            error.AccessDenied => log.err("failed to write PNG: permission denied for '{s}'", .{filename}),
            error.PermissionDenied => log.err("failed to write PNG: permission denied for '{s}'", .{filename}),
            error.NoSpaceLeft => log.err("failed to write PNG: disk full, cannot write '{s}'", .{filename}),
            error.DiskQuota => log.err("failed to write PNG: disk quota exceeded for '{s}'", .{filename}),
            else => log.err("failed to write PNG file '{s}': {}", .{ filename, err }),
        }
    }

    /// Get file size in bytes, returns 0 if file cannot be accessed.
    fn getFileSize(filename: []const u8) u64 {
        const stat = std.fs.cwd().statFile(filename) catch return 0;
        return stat.size;
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

        // Release shader module before device (it depends on the device)
        self.shader_module.release();

        // Release render pipeline before pipeline layout (it depends on the layout)
        self.render_pipeline.release();

        // Release vertex buffer before device (it depends on the device)
        self.vertex_buffer.release();

        // Release uniform buffer before device (it depends on the device)
        self.uniform_buffer.release();

        // Release bind group before bind group layout (it depends on the layout)
        self.bind_group.release();

        // Release pipeline layout before device (it depends on the device)
        self.pipeline_layout.release();

        // Release bind group layout before device (it depends on the device)
        self.bind_group_layout.release();

        // Release screenshot resources before device (these are legitimately optional)
        if (self.screenshot_texture) |texture| {
            texture.release();
        }
        if (self.screenshot_staging_buffer) |buffer| {
            buffer.release();
        }

        // Release the device
        self.device.release();

        // Release the adapter
        self.adapter.release();

        // Queue is owned by the device, no separate release needed

        // Release the instance last
        self.instance.release();

        // Destroy Dawn native instance (C++ cleanup) - native builds only
        // On web, there's no Dawn native instance to destroy.
        if (is_native) {
            if (self.native_instance) |ni| {
                dniDestroy(ni);
                self.native_instance = null;
            }
        }

        log.info("renderer resources released", .{});
    }
};

test "Renderer error types are defined" {
    // Renderer.init() requires actual WebGPU hardware, which may not
    // be available in all test environments. We verify that the error
    // set contains the expected members by converting to anyerror.
    const expected_errors = [_]anyerror{
        RendererError.InstanceCreationFailed,
        RendererError.AdapterRequestFailed,
        RendererError.DeviceRequestFailed,
        RendererError.SurfaceCreationFailed,
        RendererError.SwapChainCreationFailed,
        RendererError.ShaderCompilationFailed,
        RendererError.PipelineCreationFailed,
    };
    try std.testing.expectEqual(@as(usize, 7), expected_errors.len);
}
