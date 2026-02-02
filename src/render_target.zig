//! RenderTarget abstraction interface
//!
//! Provides a unified interface for rendering to different target types:
//! - Swap chain (windowed mode): Presents frames to a window surface
//! - Offscreen texture (headless mode): Renders to an offscreen texture for testing
//!
//! This abstraction enables the same rendering code to work for both interactive
//! and automated testing scenarios without platform-specific branching.

const std = @import("std");
const zgpu = @import("zgpu");

const log = std.log.scoped(.render_target);

/// Dimensions of a render target in pixels.
pub const Dimensions = struct {
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
};

/// Error type for render target operations.
pub const RenderTargetError = error{
    /// Failed to acquire a texture view from the render target.
    /// This can happen when the swap chain is out of date or the window is minimized.
    TextureViewAcquisitionFailed,
    /// Failed to resize the render target.
    ResizeFailed,
};

/// RenderTarget interface for abstracting over different rendering destinations.
///
/// This interface provides a unified API for rendering to:
/// - Swap chain textures (windowed mode with presentation to display)
/// - Offscreen textures (headless mode for automated testing/screenshots)
///
/// The interface uses function pointers to enable runtime backend selection
/// while keeping the calling code simple and type-safe.
///
/// Usage pattern:
/// 1. Call `getTextureView()` at the start of each frame to get the render target
/// 2. Use the returned texture view as the color attachment for render passes
/// 3. Call `present()` at the end of each frame (no-op for offscreen targets)
pub const RenderTarget = struct {
    const Self = @This();

    /// Opaque pointer to backend-specific context (e.g., SwapChainTarget, OffscreenTarget).
    /// Cast back to the concrete type in the function pointer implementations.
    context: *anyopaque,

    // Function pointer vtable for polymorphic dispatch.
    // Each backend provides implementations for these operations.

    /// Get the texture view for the current frame.
    /// Returns null if the texture view cannot be acquired (e.g., window minimized).
    /// The caller must not release the returned texture view - it is owned by the target.
    getTextureViewFn: *const fn (self: *Self) RenderTargetError!zgpu.wgpu.TextureView,

    /// Get the current dimensions of the render target.
    getDimensionsFn: *const fn (self: *const Self) Dimensions,

    /// Present the rendered frame (swap chain only).
    /// For offscreen targets, this is a no-op.
    presentFn: *const fn (self: *Self) void,

    /// Check if the render target needs to be resized.
    /// Returns true if the current dimensions differ from the provided dimensions.
    needsResizeFn: *const fn (self: *const Self, width: u32, height: u32) bool,

    /// Resize the render target to new dimensions.
    /// For swap chain targets, this recreates the swap chain.
    /// For offscreen targets, this recreates the offscreen texture.
    resizeFn: *const fn (self: *Self, width: u32, height: u32) RenderTargetError!void,

    // Public API methods that delegate to the function pointers.
    // These provide a clean interface for callers.

    /// Get the texture view for the current frame.
    /// Returns the texture view to use as a render attachment.
    /// The texture view is valid until the next call to getTextureView() or present().
    ///
    /// Returns an error if the texture view cannot be acquired (e.g., window minimized,
    /// swap chain out of date). The caller should skip rendering for this frame.
    pub fn getTextureView(self: *Self) RenderTargetError!zgpu.wgpu.TextureView {
        return self.getTextureViewFn(self);
    }

    /// Get the current dimensions of the render target.
    /// Use this to set viewport size and update uniform buffers with screen dimensions.
    pub fn getDimensions(self: *const Self) Dimensions {
        return self.getDimensionsFn(self);
    }

    /// Present the rendered frame to the display.
    /// Call this at the end of each frame after submitting GPU commands.
    /// For swap chain targets, this presents the back buffer to the window.
    /// For offscreen targets, this is a no-op.
    pub fn present(self: *Self) void {
        self.presentFn(self);
    }

    /// Check if the render target needs to be resized.
    /// Call this at the start of each frame with the current window/framebuffer dimensions.
    /// Returns true if resize() should be called.
    pub fn needsResize(self: *const Self, width: u32, height: u32) bool {
        return self.needsResizeFn(self, width, height);
    }

    /// Resize the render target to new dimensions.
    /// Call this when needsResize() returns true.
    /// For swap chain targets, this recreates the swap chain with new dimensions.
    /// For offscreen targets, this recreates the offscreen texture.
    pub fn resize(self: *Self, width: u32, height: u32) RenderTargetError!void {
        return self.resizeFn(self, width, height);
    }
};

/// SwapChainRenderTarget wraps a WebGPU swap chain to implement the RenderTarget interface.
///
/// This enables the existing windowed rendering code to work with the RenderTarget abstraction
/// without modification. The swap chain provides texture views for each frame and handles
/// presentation to the window surface.
///
/// Lifecycle:
/// 1. Create with init() passing the swap chain and initial dimensions
/// 2. Each frame: getTextureView() → render → present()
/// 3. On window resize: call resize() to recreate the swap chain
pub const SwapChainRenderTarget = struct {
    const Self = @This();

    /// The underlying WebGPU swap chain.
    swapchain: zgpu.wgpu.SwapChain,
    /// WebGPU device needed for swap chain recreation on resize.
    device: zgpu.wgpu.Device,
    /// WebGPU surface needed for swap chain recreation on resize.
    surface: zgpu.wgpu.Surface,
    /// Current width in pixels.
    width: u32,
    /// Current height in pixels.
    height: u32,
    /// Current texture view from the swap chain (acquired each frame).
    /// Stored here so we can release it on present().
    current_texture_view: ?zgpu.wgpu.TextureView,
    /// The RenderTarget interface that delegates to this implementation.
    /// Initialized in init() with function pointers to our methods.
    render_target: RenderTarget,

    /// Initialize a SwapChainRenderTarget wrapping an existing swap chain.
    ///
    /// Parameters:
    /// - swapchain: The WebGPU swap chain to wrap
    /// - device: WebGPU device for swap chain recreation
    /// - surface: WebGPU surface for swap chain recreation
    /// - width: Initial width in pixels
    /// - height: Initial height in pixels
    pub fn init(
        swapchain: zgpu.wgpu.SwapChain,
        device: zgpu.wgpu.Device,
        surface: zgpu.wgpu.Surface,
        width: u32,
        height: u32,
    ) Self {
        var self: Self = .{
            .swapchain = swapchain,
            .device = device,
            .surface = surface,
            .width = width,
            .height = height,
            .current_texture_view = null,
            .render_target = undefined,
        };

        // Initialize the RenderTarget interface with our function pointers.
        // The context pointer points to this SwapChainRenderTarget instance.
        self.render_target = .{
            .context = @ptrCast(&self),
            .getTextureViewFn = &getTextureViewImpl,
            .getDimensionsFn = &getDimensionsImpl,
            .presentFn = &presentImpl,
            .needsResizeFn = &needsResizeImpl,
            .resizeFn = &resizeImpl,
        };

        return self;
    }

    /// Get the RenderTarget interface for this swap chain target.
    /// Returns a pointer to the embedded RenderTarget that can be used polymorphically.
    pub fn asRenderTarget(self: *Self) *RenderTarget {
        // Update the context pointer to ensure it points to the current location.
        // This is necessary because the struct may have been moved after init().
        self.render_target.context = @ptrCast(self);
        return &self.render_target;
    }

    // Implementation functions for the RenderTarget interface.
    // These are called through the function pointer vtable.

    fn getTextureViewImpl(render_target: *RenderTarget) RenderTargetError!zgpu.wgpu.TextureView {
        const self: *Self = @ptrCast(@alignCast(render_target.context));

        // Release any previous texture view before acquiring a new one.
        // The swap chain owns the texture, but we need to release the view.
        if (self.current_texture_view) |view| {
            view.release();
            self.current_texture_view = null;
        }

        // Get the current texture view from the swap chain.
        // Dawn's getCurrentTextureView can return null (as address 0) if the
        // swap chain is invalid (e.g., window minimized).
        const texture_view = self.swapchain.getCurrentTextureView();
        if (@intFromPtr(texture_view) == 0) {
            log.warn("swap chain returned null texture view", .{});
            return RenderTargetError.TextureViewAcquisitionFailed;
        }

        self.current_texture_view = texture_view;
        return texture_view;
    }

    fn getDimensionsImpl(render_target: *const RenderTarget) Dimensions {
        const self: *const Self = @ptrCast(@alignCast(render_target.context));
        return .{
            .width = self.width,
            .height = self.height,
        };
    }

    fn presentImpl(render_target: *RenderTarget) void {
        const self: *Self = @ptrCast(@alignCast(render_target.context));

        // Release the texture view before presenting.
        // The view is only valid until present() is called.
        if (self.current_texture_view) |view| {
            view.release();
            self.current_texture_view = null;
        }

        // Present the swap chain to display the rendered frame.
        self.swapchain.present();
    }

    fn needsResizeImpl(render_target: *const RenderTarget, width: u32, height: u32) bool {
        const self: *const Self = @ptrCast(@alignCast(render_target.context));
        return self.width != width or self.height != height;
    }

    fn resizeImpl(render_target: *RenderTarget, width: u32, height: u32) RenderTargetError!void {
        const self: *Self = @ptrCast(@alignCast(render_target.context));

        // Don't resize to zero dimensions (window minimized).
        if (width == 0 or height == 0) {
            log.debug("ignoring resize to zero dimensions", .{});
            return;
        }

        // Release any current texture view before recreating the swap chain.
        if (self.current_texture_view) |view| {
            view.release();
            self.current_texture_view = null;
        }

        // Release the old swap chain.
        self.swapchain.release();

        // Create a new swap chain with the updated dimensions.
        const new_swapchain = self.device.createSwapChain(
            self.surface,
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

        // Verify swap chain creation succeeded.
        if (@intFromPtr(new_swapchain) == 0) {
            log.err("failed to recreate swap chain", .{});
            return RenderTargetError.ResizeFailed;
        }

        self.swapchain = new_swapchain;
        self.width = width;
        self.height = height;

        log.info("swap chain resized to {}x{}", .{ width, height });
    }

    /// Release resources held by this target.
    /// Note: Does NOT release the swap chain itself, as that's typically
    /// owned by the Renderer. Only releases the current texture view if any.
    pub fn deinit(self: *Self) void {
        if (self.current_texture_view) |view| {
            view.release();
            self.current_texture_view = null;
        }
    }
};

test "Dimensions struct size and alignment" {
    // Dimensions should be 8 bytes (2 x u32)
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Dimensions));
}

/// OffscreenRenderTarget creates and manages a WebGPU texture for headless rendering.
///
/// This target renders to an offscreen texture instead of a swap chain, enabling:
/// - Headless rendering without a window
/// - Automated testing and screenshot generation
/// - Render-to-texture for post-processing
///
/// The texture is created with RENDER_ATTACHMENT | COPY_SRC usage:
/// - RENDER_ATTACHMENT: enables using the texture as a render target
/// - COPY_SRC: enables reading pixels back to CPU for screenshots
///
/// A staging buffer is created for GPU-to-CPU pixel readback with:
/// - COPY_DST: allows copying from the offscreen texture
/// - MAP_READ: allows CPU access to read pixel data
///
/// Lifecycle:
/// 1. Create with init() specifying device and dimensions
/// 2. Each frame: getTextureView() -> render -> present() (no-op for offscreen)
/// 3. On resize: call resize() to recreate the texture and staging buffer
/// 4. Call deinit() to release GPU resources
pub const OffscreenRenderTarget = struct {
    const Self = @This();

    /// Context for tracking the status of an async buffer map operation.
    /// Passed as userdata to mapAsync callback and updated when mapping completes.
    pub const MapCallbackContext = struct {
        /// The status returned by the mapping operation.
        status: zgpu.wgpu.BufferMapAsyncStatus = .success,
        /// Set to true when the callback has been invoked.
        completed: bool = false,
    };

    /// The offscreen texture for rendering.
    texture: zgpu.wgpu.Texture,
    /// Texture view for render pass attachment.
    texture_view: zgpu.wgpu.TextureView,
    /// Staging buffer for GPU-to-CPU pixel readback.
    /// Size = aligned_bytes_per_row * height.
    /// Usage: COPY_DST (receive copies from texture) | MAP_READ (CPU access).
    staging_buffer: zgpu.wgpu.Buffer,
    /// WebGPU device needed for texture recreation on resize.
    device: zgpu.wgpu.Device,
    /// Current width in pixels.
    width: u32,
    /// Current height in pixels.
    height: u32,
    /// The RenderTarget interface that delegates to this implementation.
    render_target: RenderTarget,

    /// WebGPU requires buffer row alignment of 256 bytes for texture copies.
    const copy_bytes_per_row_alignment: u32 = 256;

    /// Align a value up to a multiple of alignment.
    fn alignUp(value: u32, alignment: u32) u32 {
        return (value + alignment - 1) / alignment * alignment;
    }

    /// Calculate the aligned bytes per row for a given width (RGBA8 = 4 bytes per pixel).
    fn calcAlignedBytesPerRow(width: u32) u32 {
        const unaligned = width * 4;
        return alignUp(unaligned, copy_bytes_per_row_alignment);
    }

    /// Initialize an OffscreenRenderTarget with the specified dimensions.
    ///
    /// Creates a texture with:
    /// - Format: RGBA8Unorm (for easy PNG export)
    /// - Usage: RENDER_ATTACHMENT | COPY_SRC
    /// - Dimension: 2D
    ///
    /// Also creates a staging buffer for GPU readback with:
    /// - Size: aligned_bytes_per_row * height
    /// - Usage: COPY_DST | MAP_READ
    ///
    /// Parameters:
    /// - device: WebGPU device for resource creation
    /// - width: Texture width in pixels
    /// - height: Texture height in pixels
    pub fn init(device: zgpu.wgpu.Device, width: u32, height: u32) Self {
        const texture = createOffscreenTexture(device, width, height);
        const texture_view = createTextureView(texture);
        const staging_buffer = createStagingBuffer(device, width, height);

        var self: Self = .{
            .texture = texture,
            .texture_view = texture_view,
            .staging_buffer = staging_buffer,
            .device = device,
            .width = width,
            .height = height,
            .render_target = undefined,
        };

        // Initialize the RenderTarget interface with our function pointers.
        self.render_target = .{
            .context = @ptrCast(&self),
            .getTextureViewFn = &getTextureViewImpl,
            .getDimensionsFn = &getDimensionsImpl,
            .presentFn = &presentImpl,
            .needsResizeFn = &needsResizeImpl,
            .resizeFn = &resizeImpl,
        };

        const aligned_bytes_per_row = calcAlignedBytesPerRow(width);
        const buffer_size: u64 = @as(u64, aligned_bytes_per_row) * @as(u64, height);
        log.info("offscreen render target created: {}x{} (staging buffer: {} bytes)", .{ width, height, buffer_size });
        return self;
    }

    /// Release all GPU resources held by this target.
    /// Must be called before the device is released.
    pub fn deinit(self: *Self) void {
        self.staging_buffer.release();
        self.texture_view.release();
        self.texture.release();
        log.debug("offscreen render target resources released", .{});
    }

    /// Get the RenderTarget interface for this offscreen target.
    /// Returns a pointer to the embedded RenderTarget that can be used polymorphically.
    pub fn asRenderTarget(self: *Self) *RenderTarget {
        // Update the context pointer to ensure it points to the current location.
        // This is necessary because the struct may have been moved after init().
        self.render_target.context = @ptrCast(self);
        return &self.render_target;
    }

    /// Get the underlying texture for pixel readback operations.
    /// Use this with copyTextureToBuffer for screenshot capture.
    pub fn getTexture(self: *const Self) zgpu.wgpu.Texture {
        return self.texture;
    }

    /// Get the staging buffer for GPU-to-CPU pixel readback.
    /// Use this with copyTextureToBuffer and buffer mapping for screenshot capture.
    /// The buffer is sized for aligned row data: aligned_bytes_per_row * height.
    pub fn getStagingBuffer(self: *const Self) zgpu.wgpu.Buffer {
        return self.staging_buffer;
    }

    /// Get the aligned bytes per row for the staging buffer.
    /// WebGPU requires 256-byte alignment for texture copy operations.
    pub fn getAlignedBytesPerRow(self: *const Self) u32 {
        return calcAlignedBytesPerRow(self.width);
    }

    /// Get the total size of the staging buffer in bytes.
    pub fn getStagingBufferSize(self: *const Self) u64 {
        const aligned_bytes_per_row = calcAlignedBytesPerRow(self.width);
        return @as(u64, aligned_bytes_per_row) * @as(u64, self.height);
    }

    /// Copy the offscreen texture to the staging buffer for CPU readback.
    /// This should be called after rendering is complete, using the same command
    /// encoder that was used for rendering. The copy will be executed when the
    /// command buffer is submitted.
    ///
    /// After submission and device tick, the staging buffer can be mapped and read.
    ///
    /// Parameters:
    /// - encoder: The command encoder to record the copy operation to.
    ///   This should be the same encoder used for rendering the frame.
    pub fn copyToStagingBuffer(self: *const Self, encoder: zgpu.wgpu.CommandEncoder) void {
        const aligned_bytes_per_row = calcAlignedBytesPerRow(self.width);

        encoder.copyTextureToBuffer(
            .{
                .texture = self.texture,
                .mip_level = 0,
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .aspect = .all,
            },
            .{
                .buffer = self.staging_buffer,
                .layout = .{
                    .offset = 0,
                    .bytes_per_row = aligned_bytes_per_row,
                    .rows_per_image = self.height,
                },
            },
            .{
                .width = self.width,
                .height = self.height,
                .depth_or_array_layers = 1,
            },
        );

        log.debug("queued copy of offscreen texture ({}x{}) to staging buffer", .{ self.width, self.height });
    }

    /// Callback for buffer mapAsync operation.
    /// Sets the status and marks the operation as completed.
    fn mapCallback(
        status: zgpu.wgpu.BufferMapAsyncStatus,
        userdata: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *MapCallbackContext = @ptrCast(@alignCast(userdata));
        ctx.status = status;
        ctx.completed = true;
    }

    /// Map the staging buffer for CPU read access.
    /// This initiates an async mapping operation with MapMode.read.
    ///
    /// This must be called after:
    /// 1. copyToStagingBuffer() has been called to queue the copy
    /// 2. The command buffer has been submitted to the GPU queue
    ///
    /// The buffer cannot be used for GPU operations while mapped.
    /// After mapping completes, use getConstMappedRange() to access the data.
    ///
    /// Parameters:
    /// - ctx: A MapCallbackContext to track the async operation status.
    ///   The caller must keep this alive until ctx.completed becomes true.
    ///
    /// Usage:
    /// ```
    /// var map_ctx: MapCallbackContext = .{};
    /// offscreen_target.mapStagingBuffer(&map_ctx);
    /// // Poll device.tick() until map_ctx.completed is true
    /// // Then check map_ctx.status and access data via getConstMappedRange()
    /// ```
    pub fn mapStagingBuffer(self: *const Self, ctx: *MapCallbackContext) void {
        const buffer_size = self.getStagingBufferSize();

        self.staging_buffer.mapAsync(
            .{ .read = true },
            0,
            buffer_size,
            &mapCallback,
            @ptrCast(ctx),
        );

        log.debug("initiated async map of staging buffer ({} bytes) for CPU read", .{buffer_size});
    }

    /// Wait for an async buffer map operation to complete.
    /// Polls the device until the mapping callback has been invoked.
    ///
    /// Dawn (the WebGPU implementation used by zgpu) processes async operations
    /// synchronously during device.tick(), so we poll in a loop until the
    /// callback sets ctx.completed to true.
    ///
    /// Parameters:
    /// - ctx: The MapCallbackContext passed to mapStagingBuffer().
    ///   Must be the same context to track the correct operation.
    ///
    /// Returns:
    /// - true if mapping succeeded (ctx.status == .success)
    /// - false if mapping failed (check ctx.status for the error)
    ///
    /// Usage:
    /// ```
    /// var map_ctx: MapCallbackContext = .{};
    /// offscreen_target.mapStagingBuffer(&map_ctx);
    /// if (offscreen_target.waitForMap(&map_ctx)) {
    ///     // Access data via staging_buffer.getConstMappedRange()
    /// } else {
    ///     // Handle error based on map_ctx.status
    /// }
    /// ```
    pub fn waitForMap(self: *const Self, ctx: *MapCallbackContext) bool {
        // Poll the device until the mapping callback is invoked.
        // Dawn processes async operations during tick(), so we loop
        // until the callback sets completed to true.
        while (!ctx.completed) {
            self.device.tick();
        }

        if (ctx.status != .success) {
            log.err("buffer map failed with status: {}", .{ctx.status});
            return false;
        }

        log.debug("buffer map completed successfully", .{});
        return true;
    }

    // Implementation functions for the RenderTarget interface.

    fn getTextureViewImpl(render_target: *RenderTarget) RenderTargetError!zgpu.wgpu.TextureView {
        const self: *Self = @ptrCast(@alignCast(render_target.context));
        // For offscreen rendering, we always return the same texture view.
        // Unlike swap chain, the texture persists across frames.
        return self.texture_view;
    }

    fn getDimensionsImpl(render_target: *const RenderTarget) Dimensions {
        const self: *const Self = @ptrCast(@alignCast(render_target.context));
        return .{
            .width = self.width,
            .height = self.height,
        };
    }

    fn presentImpl(_: *RenderTarget) void {
        // No-op for offscreen rendering.
        // There's no display to present to - the texture contents persist
        // and can be read back via copyTextureToBuffer.
    }

    fn needsResizeImpl(render_target: *const RenderTarget, width: u32, height: u32) bool {
        const self: *const Self = @ptrCast(@alignCast(render_target.context));
        return self.width != width or self.height != height;
    }

    fn resizeImpl(render_target: *RenderTarget, width: u32, height: u32) RenderTargetError!void {
        const self: *Self = @ptrCast(@alignCast(render_target.context));

        // Don't resize to zero dimensions.
        if (width == 0 or height == 0) {
            log.debug("ignoring offscreen resize to zero dimensions", .{});
            return;
        }

        // Release old resources.
        self.staging_buffer.release();
        self.texture_view.release();
        self.texture.release();

        // Create new resources with updated dimensions.
        self.texture = createOffscreenTexture(self.device, width, height);
        self.texture_view = createTextureView(self.texture);
        self.staging_buffer = createStagingBuffer(self.device, width, height);
        self.width = width;
        self.height = height;

        const aligned_bytes_per_row = calcAlignedBytesPerRow(width);
        const buffer_size: u64 = @as(u64, aligned_bytes_per_row) * @as(u64, height);
        log.info("offscreen render target resized to {}x{} (staging buffer: {} bytes)", .{ width, height, buffer_size });
    }

    /// Create an offscreen texture with RENDER_ATTACHMENT | COPY_SRC usage.
    fn createOffscreenTexture(device: zgpu.wgpu.Device, width: u32, height: u32) zgpu.wgpu.Texture {
        return device.createTexture(.{
            .next_in_chain = null,
            .label = "Offscreen Render Target Texture",
            .usage = .{ .render_attachment = true, .copy_src = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm, // RGBA for easy PNG export
            .mip_level_count = 1,
            .sample_count = 1,
            .view_format_count = 0,
            .view_formats = null,
        });
    }

    /// Create a texture view for the offscreen texture.
    fn createTextureView(texture: zgpu.wgpu.Texture) zgpu.wgpu.TextureView {
        return texture.createView(.{
            .next_in_chain = null,
            .label = "Offscreen Render Target View",
            .format = .rgba8_unorm,
            .dimension = .tvdim_2d,
            .base_mip_level = 0,
            .mip_level_count = 1,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .aspect = .all,
        });
    }

    /// Create a staging buffer for GPU-to-CPU pixel readback.
    /// The buffer is configured with COPY_DST | MAP_READ usage:
    /// - COPY_DST: allows copying from the offscreen texture via copyTextureToBuffer
    /// - MAP_READ: allows CPU access to read pixel data via mapAsync/getMappedRange
    ///
    /// Size is calculated as aligned_bytes_per_row * height to satisfy WebGPU's
    /// 256-byte row alignment requirement for texture copies.
    fn createStagingBuffer(device: zgpu.wgpu.Device, width: u32, height: u32) zgpu.wgpu.Buffer {
        const aligned_bytes_per_row = calcAlignedBytesPerRow(width);
        const buffer_size: u64 = @as(u64, aligned_bytes_per_row) * @as(u64, height);

        return device.createBuffer(.{
            .next_in_chain = null,
            .label = "Offscreen Staging Buffer",
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = buffer_size,
            .mapped_at_creation = .false,
        });
    }
};

test "SwapChainRenderTarget interface consistency" {
    // Verify the RenderTarget function pointer types match SwapChainRenderTarget implementations.
    // This is a compile-time check that the signatures are correct.
    const rt_get_tex: @TypeOf(RenderTarget.getTextureViewFn) = &SwapChainRenderTarget.getTextureViewImpl;
    const rt_get_dim: @TypeOf(RenderTarget.getDimensionsFn) = &SwapChainRenderTarget.getDimensionsImpl;
    const rt_present: @TypeOf(RenderTarget.presentFn) = &SwapChainRenderTarget.presentImpl;
    const rt_needs_resize: @TypeOf(RenderTarget.needsResizeFn) = &SwapChainRenderTarget.needsResizeImpl;
    const rt_resize: @TypeOf(RenderTarget.resizeFn) = &SwapChainRenderTarget.resizeImpl;

    // Suppress unused variable warnings - we just need the assignments to compile.
    _ = rt_get_tex;
    _ = rt_get_dim;
    _ = rt_present;
    _ = rt_needs_resize;
    _ = rt_resize;
}

test "OffscreenRenderTarget interface consistency" {
    // Verify the RenderTarget function pointer types match OffscreenRenderTarget implementations.
    // This is a compile-time check that the signatures are correct.
    const rt_get_tex: @TypeOf(RenderTarget.getTextureViewFn) = &OffscreenRenderTarget.getTextureViewImpl;
    const rt_get_dim: @TypeOf(RenderTarget.getDimensionsFn) = &OffscreenRenderTarget.getDimensionsImpl;
    const rt_present: @TypeOf(RenderTarget.presentFn) = &OffscreenRenderTarget.presentImpl;
    const rt_needs_resize: @TypeOf(RenderTarget.needsResizeFn) = &OffscreenRenderTarget.needsResizeImpl;
    const rt_resize: @TypeOf(RenderTarget.resizeFn) = &OffscreenRenderTarget.resizeImpl;

    // Suppress unused variable warnings - we just need the assignments to compile.
    _ = rt_get_tex;
    _ = rt_get_dim;
    _ = rt_present;
    _ = rt_needs_resize;
    _ = rt_resize;
}
