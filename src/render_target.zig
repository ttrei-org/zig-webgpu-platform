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

test "Dimensions struct size and alignment" {
    // Dimensions should be 8 bytes (2 x u32)
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Dimensions));
}
