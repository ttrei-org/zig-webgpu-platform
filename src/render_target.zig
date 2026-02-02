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
