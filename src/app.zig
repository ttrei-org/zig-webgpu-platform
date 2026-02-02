//! Application state and logic module
//!
//! The App struct encapsulates all application-specific state and logic,
//! separated from platform and rendering concerns. This separation allows
//! the same app logic to work across different platforms (desktop, web, headless).
//!
//! Currently minimal - will be extended as application features are added.

const std = @import("std");

const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const Color = renderer_mod.Color;

const log = std.log.scoped(.app);

/// Application state container.
/// Encapsulates all application-specific state and logic, independent of
/// platform and rendering implementation.
///
/// Design rationale:
/// - Separation of concerns: app logic vs platform vs rendering
/// - Portability: same App can run on desktop, web, or headless
/// - Testability: app logic can be tested without GPU or window
pub const App = struct {
    const Self = @This();

    /// Memory allocator for dynamic allocations.
    allocator: std.mem.Allocator,

    /// Whether the application should continue running.
    /// Set to false to request graceful shutdown.
    running: bool,

    /// Frame counter for diagnostics and timing.
    frame_count: u64,

    /// Initialize the application with the given allocator.
    /// The allocator is stored for any dynamic allocations the app may need.
    pub fn init(allocator: std.mem.Allocator) Self {
        log.debug("initializing app", .{});
        return Self{
            .allocator = allocator,
            .running = true,
            .frame_count = 0,
        };
    }

    /// Clean up application resources.
    /// Currently minimal, but provided for consistency and future expansion.
    pub fn deinit(self: *Self) void {
        log.debug("deinitializing app (frame_count={})", .{self.frame_count});
        self.running = false;
    }

    /// Check if the application should continue running.
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Request the application to stop.
    /// This sets the running flag to false, signaling a graceful shutdown.
    pub fn requestQuit(self: *Self) void {
        log.info("quit requested", .{});
        self.running = false;
    }

    /// Called once per frame to update application state.
    /// This is where game logic, animations, and state updates would occur.
    /// Currently increments the frame counter for diagnostics.
    ///
    /// Parameters:
    /// - delta_time: Time elapsed since last frame in seconds.
    ///   Used for frame-rate independent movement and animations.
    pub fn update(self: *Self, delta_time: f32) void {
        _ = delta_time; // Currently unused, will be used for animations
        self.frame_count += 1;
    }

    /// Called once per frame after update to queue draw commands.
    /// The application uses the renderer to queue shapes for batched rendering.
    /// Draw commands are accumulated and rendered in a single batched draw call
    /// when flushBatch() is called.
    ///
    /// Parameters:
    /// - renderer: Pointer to the Renderer for queuing draw commands.
    pub fn render(self: *const Self, renderer: *Renderer) void {
        _ = self;

        // Queue multiple triangles to verify batched rendering works correctly.
        // Coordinates are in pixels, origin at top-left.
        // For a 400x300 window, triangles are positioned across the viewport.

        // Triangle 1: Large centered RGB triangle (classic test pattern)
        // Uses Color constants for primary colors.
        renderer.queueTriangle(
            .{
                .{ 100.0, 225.0 }, // Bottom-left
                .{ 300.0, 225.0 }, // Bottom-right
                .{ 200.0, 75.0 }, // Top-center
            },
            .{
                Color.red,
                Color.green,
                Color.blue,
            },
        );

        // Triangle 2: Small yellow triangle (top-left corner)
        // Uses Color.rgb() helper for custom colors.
        renderer.queueTriangle(
            .{
                .{ 20.0, 80.0 }, // Bottom-left
                .{ 80.0, 80.0 }, // Bottom-right
                .{ 50.0, 20.0 }, // Top-center
            },
            .{
                Color.yellow, // Yellow constant
                Color.rgb(1.0, 0.8, 0.0), // Orange-yellow
                Color.rgb(1.0, 1.0, 0.2), // Light yellow
            },
        );

        // Triangle 3: Small cyan triangle (top-right corner)
        // Uses Color constant and Color.rgb() helper.
        renderer.queueTriangle(
            .{
                .{ 320.0, 80.0 }, // Bottom-left
                .{ 380.0, 80.0 }, // Bottom-right
                .{ 350.0, 20.0 }, // Top-center
            },
            .{
                Color.cyan,
                Color.rgb(0.0, 0.8, 1.0), // Light blue
                Color.rgb(0.2, 1.0, 1.0), // Bright cyan
            },
        );

        // Triangle 4: Small magenta triangle (bottom-left corner)
        // Uses Color constant and Color.rgb() helper.
        renderer.queueTriangle(
            .{
                .{ 20.0, 280.0 }, // Bottom-left
                .{ 80.0, 280.0 }, // Bottom-right
                .{ 50.0, 240.0 }, // Top-center
            },
            .{
                Color.magenta,
                Color.rgb(0.8, 0.0, 1.0), // Purple
                Color.rgb(1.0, 0.2, 1.0), // Light magenta
            },
        );

        // Triangle 5: Small white/gray triangle (bottom-right corner)
        // Uses Color.rgb() helper for grayscale tones.
        renderer.queueTriangle(
            .{
                .{ 320.0, 280.0 }, // Bottom-left
                .{ 380.0, 280.0 }, // Bottom-right
                .{ 350.0, 240.0 }, // Top-center
            },
            .{
                Color.rgb(0.8, 0.8, 0.8), // Light gray
                Color.white,
                Color.rgb(0.6, 0.6, 0.6), // Medium gray
            },
        );
    }

    /// Get the current frame count.
    /// Useful for timing, animations, and diagnostics.
    pub fn getFrameCount(self: *const Self) u64 {
        return self.frame_count;
    }
};

test "App init and deinit" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.isRunning());
    try std.testing.expectEqual(@as(u64, 0), app.getFrameCount());
}

test "App update increments frame count" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    app.update(0.016); // ~60 FPS
    try std.testing.expectEqual(@as(u64, 1), app.getFrameCount());

    app.update(0.016);
    app.update(0.016);
    try std.testing.expectEqual(@as(u64, 3), app.getFrameCount());
}

test "App requestQuit stops running" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.isRunning());
    app.requestQuit();
    try std.testing.expect(!app.isRunning());
}
