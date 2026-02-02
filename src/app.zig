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

        // Static test pattern demonstrating the triangle API.
        // Creates a radial "starburst" pattern with triangles emanating from center,
        // plus corner accent triangles. Showcases Color constants and helpers.
        //
        // Window is 400x300. Center at (200, 150).

        const center_x: f32 = 200.0;
        const center_y: f32 = 150.0;

        // Radial triangles forming a starburst pattern around the center.
        // Each triangle has its apex at the center and base on an outer arc.
        // Colors cycle through the spectrum for a rainbow effect.
        const radial_colors = [_]Color{
            Color.red,
            Color.fromHex(0xFF8000), // Orange
            Color.yellow,
            Color.green,
            Color.cyan,
            Color.blue,
            Color.fromHex(0x8000FF), // Purple
            Color.magenta,
        };

        const num_spokes: usize = 8;
        const inner_radius: f32 = 20.0; // Small gap at center
        const outer_radius: f32 = 110.0;

        for (0..num_spokes) |i| {
            // Angle for this spoke (evenly distributed around circle)
            const angle: f32 = @as(f32, @floatFromInt(i)) * (std.math.tau / @as(f32, @floatFromInt(num_spokes)));
            const next_angle: f32 = angle + std.math.tau / @as(f32, @floatFromInt(num_spokes));
            const mid_angle: f32 = (angle + next_angle) / 2.0;

            // Calculate spoke triangle vertices
            // Apex at inner radius, base at outer radius
            const apex_x = center_x + inner_radius * @cos(mid_angle);
            const apex_y = center_y + inner_radius * @sin(mid_angle);

            // Base vertices at outer radius, offset by half-width perpendicular to spoke
            const base_left_x = center_x + outer_radius * @cos(angle);
            const base_left_y = center_y + outer_radius * @sin(angle);
            const base_right_x = center_x + outer_radius * @cos(next_angle);
            const base_right_y = center_y + outer_radius * @sin(next_angle);

            const base_color = radial_colors[i];
            // Create gradient by darkening the base color at the apex
            const apex_color = Color.rgb(base_color.r * 0.3, base_color.g * 0.3, base_color.b * 0.3);

            renderer.queueTriangle(
                .{
                    .{ apex_x, apex_y },
                    .{ base_left_x, base_left_y },
                    .{ base_right_x, base_right_y },
                },
                .{
                    apex_color, // Dark at center
                    base_color, // Bright at edge
                    base_color, // Bright at edge
                },
            );
        }

        // Central triangle using classic RGB gradient (demonstrates color interpolation)
        renderer.queueTriangle(
            .{
                .{ center_x, center_y - 15.0 }, // Top
                .{ center_x - 13.0, center_y + 8.0 }, // Bottom-left
                .{ center_x + 13.0, center_y + 8.0 }, // Bottom-right
            },
            .{
                Color.red,
                Color.green,
                Color.blue,
            },
        );

        // Corner accent triangles demonstrating various Color API methods

        // Top-left: Yellow tones using Color constant and rgb() helper
        renderer.queueTriangle(
            .{
                .{ 10.0, 50.0 },
                .{ 50.0, 50.0 },
                .{ 30.0, 10.0 },
            },
            .{
                Color.yellow,
                Color.rgb(1.0, 0.8, 0.0), // Orange-yellow
                Color.rgb(1.0, 1.0, 0.5), // Light yellow
            },
        );

        // Top-right: Cyan tones using Color constant and rgb() helper
        renderer.queueTriangle(
            .{
                .{ 350.0, 50.0 },
                .{ 390.0, 50.0 },
                .{ 370.0, 10.0 },
            },
            .{
                Color.cyan,
                Color.rgb(0.0, 0.8, 1.0), // Sky blue
                Color.rgb(0.5, 1.0, 1.0), // Light cyan
            },
        );

        // Bottom-left: Magenta tones using Color constant and fromHex() helper
        renderer.queueTriangle(
            .{
                .{ 10.0, 250.0 },
                .{ 50.0, 250.0 },
                .{ 30.0, 290.0 },
            },
            .{
                Color.magenta,
                Color.fromHex(0xFF00AA), // Pink-magenta
                Color.fromHex(0xAA00FF), // Purple
            },
        );

        // Bottom-right: Grayscale using rgb() for precise control
        renderer.queueTriangle(
            .{
                .{ 350.0, 250.0 },
                .{ 390.0, 250.0 },
                .{ 370.0, 290.0 },
            },
            .{
                Color.white,
                Color.rgb(0.7, 0.7, 0.7), // Light gray
                Color.rgb(0.4, 0.4, 0.4), // Medium gray
            },
        );

        // Position test triangles - verify screen coordinate system works at boundaries.
        // These small markers at exact screen positions confirm coordinate transform is correct.
        // Window dimensions: 400x300. Valid pixel range: x=[0,399], y=[0,299].
        const width: f32 = 400.0;
        const height: f32 = 300.0;
        const marker_size: f32 = 12.0;

        // Corner markers: small triangles pointing into each corner.
        // Tests coordinate system at extreme positions (0,0), (width,0), (0,height), (width,height).

        // Top-left corner (0,0): red marker pointing into corner
        renderer.queueTriangle(
            .{
                .{ 0.0, 0.0 }, // Exact corner
                .{ marker_size, 0.0 }, // Along top edge
                .{ 0.0, marker_size }, // Along left edge
            },
            .{ Color.red, Color.red, Color.red },
        );

        // Top-right corner (width,0): green marker pointing into corner
        renderer.queueTriangle(
            .{
                .{ width, 0.0 }, // Exact corner
                .{ width - marker_size, 0.0 }, // Along top edge
                .{ width, marker_size }, // Along right edge
            },
            .{ Color.green, Color.green, Color.green },
        );

        // Bottom-left corner (0,height): blue marker pointing into corner
        renderer.queueTriangle(
            .{
                .{ 0.0, height }, // Exact corner
                .{ marker_size, height }, // Along bottom edge
                .{ 0.0, height - marker_size }, // Along left edge
            },
            .{ Color.blue, Color.blue, Color.blue },
        );

        // Bottom-right corner (width,height): white marker pointing into corner
        renderer.queueTriangle(
            .{
                .{ width, height }, // Exact corner
                .{ width - marker_size, height }, // Along bottom edge
                .{ width, height - marker_size }, // Along right edge
            },
            .{ Color.white, Color.white, Color.white },
        );

        // Edge center markers: triangles at midpoint of each edge.
        // Verifies coordinate system works along screen boundaries.
        const edge_marker_half: f32 = 8.0;
        const edge_depth: f32 = 10.0;

        // Top edge center: orange marker pointing down
        renderer.queueTriangle(
            .{
                .{ width / 2.0, 0.0 }, // Apex at top edge center
                .{ width / 2.0 - edge_marker_half, edge_depth }, // Base left
                .{ width / 2.0 + edge_marker_half, edge_depth }, // Base right
            },
            .{
                Color.fromHex(0xFF8000), // Orange
                Color.fromHex(0xFF8000),
                Color.fromHex(0xFF8000),
            },
        );

        // Bottom edge center: cyan marker pointing up
        renderer.queueTriangle(
            .{
                .{ width / 2.0, height }, // Apex at bottom edge center
                .{ width / 2.0 - edge_marker_half, height - edge_depth }, // Base left
                .{ width / 2.0 + edge_marker_half, height - edge_depth }, // Base right
            },
            .{ Color.cyan, Color.cyan, Color.cyan },
        );

        // Left edge center: yellow marker pointing right
        renderer.queueTriangle(
            .{
                .{ 0.0, height / 2.0 }, // Apex at left edge center
                .{ edge_depth, height / 2.0 - edge_marker_half }, // Base top
                .{ edge_depth, height / 2.0 + edge_marker_half }, // Base bottom
            },
            .{ Color.yellow, Color.yellow, Color.yellow },
        );

        // Right edge center: magenta marker pointing left
        renderer.queueTriangle(
            .{
                .{ width, height / 2.0 }, // Apex at right edge center
                .{ width - edge_depth, height / 2.0 - edge_marker_half }, // Base top
                .{ width - edge_depth, height / 2.0 + edge_marker_half }, // Base bottom
            },
            .{ Color.magenta, Color.magenta, Color.magenta },
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
