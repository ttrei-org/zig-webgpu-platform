//! Application state and logic module
//!
//! The App struct encapsulates all application-specific state and logic,
//! separated from platform and rendering concerns. This separation allows
//! the same app logic to work across different platforms (desktop, web, headless).
//!
//! Currently minimal - will be extended as application features are added.

const std = @import("std");

const platform_mod = @import("platform.zig");
const MouseState = platform_mod.MouseState;

const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;
const Color = renderer_mod.Color;

const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;

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

    /// Current mouse state including position and button states.
    mouse_state: MouseState,

    /// Previous frame's mouse state for detecting state changes.
    /// Enables detecting: button just pressed (current.left && !prev.left),
    /// button just released (!current.left && prev.left), position delta.
    prev_mouse_state: MouseState,

    /// Position of the interactive triangle (x, y in screen coordinates).
    /// Updated when the user clicks the left mouse button.
    /// Initially centered in the window (200, 150 for 400x300 window).
    triangle_position: [2]f32,

    /// Rotation angle for animated triangles (radians).
    /// Incremented each frame using delta time to demonstrate smooth vsync rendering.
    /// A full rotation takes ~4 seconds (tau/4 radians per second).
    rotation_angle: f32,

    /// Reference to the renderer for screenshot capability.
    /// Set via setRenderer() after renderer initialization.
    /// Optional because App may be created before Renderer in some initialization orders.
    renderer: ?*Renderer,

    /// Path for screenshot output. If set, a screenshot will be taken after the first frame.
    /// Set via setScreenshotPath() or during initialization.
    screenshot_path: ?[]const u8,

    /// Whether a screenshot is pending (should be taken after next render).
    /// Set to true when screenshot_path is configured, cleared after screenshot is taken.
    screenshot_pending: bool,

    /// Whether the app should quit after taking a screenshot.
    /// Used for automated testing workflows where we render, capture, and exit.
    quit_after_screenshot: bool,

    /// Application configuration options.
    /// Passed to init() to configure app behavior.
    pub const Options = struct {
        /// Path for screenshot output. If set, a screenshot will be taken after the first frame.
        screenshot_path: ?[]const u8 = null,
        /// Whether to quit after taking a screenshot.
        quit_after_screenshot: bool = true,
    };

    /// Initialize the application with the given allocator.
    /// The allocator is stored for any dynamic allocations the app may need.
    /// Renderer reference is initially null; call setRenderer() to enable screenshot capability.
    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithOptions(allocator, .{});
    }

    /// Initialize the application with the given allocator and options.
    /// Use this to configure screenshot behavior and other app settings.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Self {
        log.debug("initializing app", .{});
        if (options.screenshot_path) |path| {
            log.info("screenshot configured: {s} (quit_after={})", .{ path, options.quit_after_screenshot });
        }
        const initial_mouse_state: MouseState = .{
            .x = 0,
            .y = 0,
            .left_pressed = false,
            .right_pressed = false,
            .middle_pressed = false,
        };
        return Self{
            .allocator = allocator,
            .running = true,
            .frame_count = 0,
            .mouse_state = initial_mouse_state,
            .prev_mouse_state = initial_mouse_state,
            .triangle_position = .{ 200.0, 150.0 }, // Center of 400x300 window
            .rotation_angle = 0.0,
            .renderer = null,
            .screenshot_path = options.screenshot_path,
            .screenshot_pending = options.screenshot_path != null,
            .quit_after_screenshot = options.quit_after_screenshot,
        };
    }

    /// Set the renderer reference for screenshot capability.
    /// Must be called after renderer initialization to enable takeScreenshot().
    /// This decouples App initialization from Renderer initialization order.
    pub fn setRenderer(self: *Self, renderer: *Renderer) void {
        self.renderer = renderer;
        log.debug("renderer reference set for screenshot capability", .{});
    }

    /// Schedule a screenshot to be taken after the next frame.
    /// The screenshot will be saved to the specified path.
    ///
    /// Parameters:
    /// - path: File path where the PNG screenshot will be saved
    /// - quit_after: If true, the app will request quit after the screenshot is taken
    pub fn scheduleScreenshot(self: *Self, path: []const u8, quit_after: bool) void {
        self.screenshot_path = path;
        self.screenshot_pending = true;
        self.quit_after_screenshot = quit_after;
        log.info("screenshot scheduled: {s} (quit_after={})", .{ path, quit_after });
    }

    /// Check if a screenshot should be taken after the current frame.
    /// Returns the screenshot path if pending, null otherwise.
    pub fn shouldTakeScreenshot(self: *const Self) ?[]const u8 {
        if (self.screenshot_pending) {
            return self.screenshot_path;
        }
        return null;
    }

    /// Called after a screenshot has been successfully taken.
    /// Clears the pending flag and optionally requests quit.
    pub fn onScreenshotComplete(self: *Self) void {
        self.screenshot_pending = false;
        if (self.quit_after_screenshot) {
            log.info("screenshot complete, requesting quit", .{});
            self.requestQuit();
        }
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
    /// - mouse_state: Current mouse state including position and button states.
    pub fn update(self: *Self, delta_time: f32, mouse_state: MouseState) void {
        self.frame_count += 1;

        // Update rotation angle for animated triangles.
        // Rotate at tau/4 radians per second (~1.57 rad/s, ~90 degrees/s).
        // This creates a smooth, visible rotation to verify vsync rendering.
        const rotation_speed: f32 = std.math.tau / 4.0;
        self.rotation_angle += rotation_speed * delta_time;

        // Wrap angle to prevent floating-point precision issues over long runtimes.
        if (self.rotation_angle > std.math.tau) {
            self.rotation_angle -= std.math.tau;
        }

        // Log mouse position changes for debug verification.
        // Only log when position changes significantly to avoid spam.
        // Log every 60 frames (~1 second at 60 FPS) if position changed
        if (self.frame_count % 60 == 0) {
            if (@abs(mouse_state.x - self.prev_mouse_state.x) > 0.1 or @abs(mouse_state.y - self.prev_mouse_state.y) > 0.1) {
                log.info("mouse position: ({d:.1}, {d:.1})", .{ mouse_state.x, mouse_state.y });
            }
        }

        // Log button state changes for debug verification.
        // Each press/release is logged immediately for testing.
        if (mouse_state.left_pressed != self.prev_mouse_state.left_pressed) {
            const action = if (mouse_state.left_pressed) "pressed" else "released";
            log.info("left button {s}", .{action});
        }
        if (mouse_state.right_pressed != self.prev_mouse_state.right_pressed) {
            const action = if (mouse_state.right_pressed) "pressed" else "released";
            log.info("right button {s}", .{action});
        }
        if (mouse_state.middle_pressed != self.prev_mouse_state.middle_pressed) {
            const action = if (mouse_state.middle_pressed) "pressed" else "released";
            log.info("middle button {s}", .{action});
        }

        // Move the interactive triangle to click position.
        // Detects left button "just pressed" (transition from released to pressed).
        if (MouseState.buttonJustPressed(mouse_state, self.prev_mouse_state, .left)) {
            self.triangle_position = .{ mouse_state.x, mouse_state.y };
            log.info("triangle moved to ({d:.1}, {d:.1})", .{ mouse_state.x, mouse_state.y });
        }

        // Store current state for next frame comparison
        self.mouse_state = mouse_state;
        self.prev_mouse_state = mouse_state;
    }

    /// Called once per frame after update to queue draw commands.
    /// The application uses the Canvas to draw shapes for batched rendering.
    /// Draw commands are accumulated and rendered in a single batched draw call
    /// when flushBatch() is called.
    ///
    /// Parameters:
    /// - canvas: Pointer to the Canvas for drawing shapes.
    pub fn render(self: *const Self, canvas: *Canvas) void {
        // Static test pattern demonstrating the Canvas shape API.
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

            canvas.fillTriangle(
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
        canvas.fillTriangle(
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
        canvas.fillTriangle(
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
        canvas.fillTriangle(
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
        canvas.fillTriangle(
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
        canvas.fillTriangle(
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
        canvas.fillTriangle(
            .{
                .{ 0.0, 0.0 }, // Exact corner
                .{ marker_size, 0.0 }, // Along top edge
                .{ 0.0, marker_size }, // Along left edge
            },
            .{ Color.red, Color.red, Color.red },
        );

        // Top-right corner (width,0): green marker pointing into corner
        canvas.fillTriangle(
            .{
                .{ width, 0.0 }, // Exact corner
                .{ width - marker_size, 0.0 }, // Along top edge
                .{ width, marker_size }, // Along right edge
            },
            .{ Color.green, Color.green, Color.green },
        );

        // Bottom-left corner (0,height): blue marker pointing into corner
        canvas.fillTriangle(
            .{
                .{ 0.0, height }, // Exact corner
                .{ marker_size, height }, // Along bottom edge
                .{ 0.0, height - marker_size }, // Along left edge
            },
            .{ Color.blue, Color.blue, Color.blue },
        );

        // Bottom-right corner (width,height): white marker pointing into corner
        canvas.fillTriangle(
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
        canvas.fillTriangle(
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
        canvas.fillTriangle(
            .{
                .{ width / 2.0, height }, // Apex at bottom edge center
                .{ width / 2.0 - edge_marker_half, height - edge_depth }, // Base left
                .{ width / 2.0 + edge_marker_half, height - edge_depth }, // Base right
            },
            .{ Color.cyan, Color.cyan, Color.cyan },
        );

        // Left edge center: yellow marker pointing right
        canvas.fillTriangle(
            .{
                .{ 0.0, height / 2.0 }, // Apex at left edge center
                .{ edge_depth, height / 2.0 - edge_marker_half }, // Base top
                .{ edge_depth, height / 2.0 + edge_marker_half }, // Base bottom
            },
            .{ Color.yellow, Color.yellow, Color.yellow },
        );

        // Right edge center: magenta marker pointing left
        canvas.fillTriangle(
            .{
                .{ width, height / 2.0 }, // Apex at right edge center
                .{ width - edge_depth, height / 2.0 - edge_marker_half }, // Base top
                .{ width - edge_depth, height / 2.0 + edge_marker_half }, // Base bottom
            },
            .{ Color.magenta, Color.magenta, Color.magenta },
        );

        // Mouse position debug display - visual crosshair at current mouse location.
        // Uses fillRect for the two bars instead of manual triangle pairs.
        const mouse_x = self.mouse_state.x;
        const mouse_y = self.mouse_state.y;
        const crosshair_size: f32 = 8.0;
        const crosshair_thickness: f32 = 2.0;

        // Horizontal bar of crosshair
        canvas.fillRect(
            mouse_x - crosshair_size,
            mouse_y - crosshair_thickness,
            crosshair_size * 2.0,
            crosshair_thickness * 2.0,
            Color.white,
        );

        // Vertical bar of crosshair
        canvas.fillRect(
            mouse_x - crosshair_thickness,
            mouse_y - crosshair_size,
            crosshair_thickness * 2.0,
            crosshair_size * 2.0,
            Color.white,
        );

        // Mouse button state indicators - three squares in bottom-left area.
        // Each square represents a button: Left, Right, Middle (from left to right).
        // Bright color = pressed, dim color = released.
        // This provides visual feedback for verifying button press/release detection.
        const btn_base_x: f32 = 60.0;
        const btn_base_y: f32 = 200.0;
        const btn_size: f32 = 20.0;
        const btn_spacing: f32 = 25.0;

        const btn_colors = [3]struct { pressed: Color, released: Color }{
            .{ .pressed = Color.red, .released = Color.rgb(0.3, 0.0, 0.0) }, // Left: Red
            .{ .pressed = Color.green, .released = Color.rgb(0.0, 0.3, 0.0) }, // Right: Green
            .{ .pressed = Color.blue, .released = Color.rgb(0.0, 0.0, 0.3) }, // Middle: Blue
        };
        const btn_states = [3]bool{
            self.mouse_state.left_pressed,
            self.mouse_state.right_pressed,
            self.mouse_state.middle_pressed,
        };

        for (0..3) |i| {
            const x = btn_base_x + @as(f32, @floatFromInt(i)) * btn_spacing;
            const color = if (btn_states[i]) btn_colors[i].pressed else btn_colors[i].released;

            canvas.fillRect(x, btn_base_y, btn_size, btn_size, color);
        }

        // Z-order test: Overlapping triangles to verify painter's algorithm.
        // Since there is no depth buffer, draw order = depth order.
        // Later-drawn triangles should appear on top of earlier ones.
        // We draw three overlapping triangles with contrasting colors.
        //
        // Layout: Three triangles in upper-right quadrant, each partially
        // overlapping the previous one. Draw order: Red -> Green -> Blue.
        // Expected result: Blue on top, then Green, then Red at bottom.

        const overlap_base_x: f32 = 280.0;
        const overlap_base_y: f32 = 50.0;
        const overlap_size: f32 = 50.0;
        const overlap_offset: f32 = 20.0; // Horizontal offset between triangles

        // First triangle (Red) - drawn first, should be at the bottom
        canvas.fillTriangle(
            .{
                .{ overlap_base_x, overlap_base_y + overlap_size }, // Bottom-left
                .{ overlap_base_x + overlap_size, overlap_base_y + overlap_size }, // Bottom-right
                .{ overlap_base_x + overlap_size / 2.0, overlap_base_y }, // Top
            },
            .{ Color.red, Color.red, Color.red },
        );

        // Second triangle (Green) - drawn second, should be in the middle
        canvas.fillTriangle(
            .{
                .{ overlap_base_x + overlap_offset, overlap_base_y + overlap_size }, // Bottom-left
                .{ overlap_base_x + overlap_offset + overlap_size, overlap_base_y + overlap_size }, // Bottom-right
                .{ overlap_base_x + overlap_offset + overlap_size / 2.0, overlap_base_y }, // Top
            },
            .{ Color.green, Color.green, Color.green },
        );

        // Third triangle (Blue) - drawn last, should be on top
        canvas.fillTriangle(
            .{
                .{ overlap_base_x + 2.0 * overlap_offset, overlap_base_y + overlap_size }, // Bottom-left
                .{ overlap_base_x + 2.0 * overlap_offset + overlap_size, overlap_base_y + overlap_size }, // Bottom-right
                .{ overlap_base_x + 2.0 * overlap_offset + overlap_size / 2.0, overlap_base_y }, // Top
            },
            .{ Color.blue, Color.blue, Color.blue },
        );

        // Animated rotating triangle - demonstrates smooth vsync rendering.
        // Uses delta_time-based rotation to verify frame-rate independent animation.
        // Positioned in the upper-left area to avoid overlap with other elements.
        const rotating_center_x: f32 = 80.0;
        const rotating_center_y: f32 = 100.0;
        const rotating_radius: f32 = 35.0;

        // Calculate vertices for an equilateral triangle rotated by rotation_angle.
        // Each vertex is 120 degrees (2*pi/3) apart on a circle centered at (rotating_center_x, rotating_center_y).
        var rotating_vertices: [3][2]f32 = undefined;
        for (0..3) |i| {
            const vertex_angle = self.rotation_angle + @as(f32, @floatFromInt(i)) * (std.math.tau / 3.0);
            rotating_vertices[i] = .{
                rotating_center_x + rotating_radius * @cos(vertex_angle),
                rotating_center_y + rotating_radius * @sin(vertex_angle),
            };
        }

        canvas.fillTriangle(
            rotating_vertices,
            .{
                Color.fromHex(0x00FF88), // Bright green
                Color.fromHex(0x00AAFF), // Bright cyan
                Color.fromHex(0xFF00AA), // Bright magenta
            },
        );

        // Interactive triangle - moves to click position.
        // Demonstrates input handling: left-click moves this triangle to the cursor location.
        // Drawn last so it appears on top of other elements.
        const tri_x = self.triangle_position[0];
        const tri_y = self.triangle_position[1];
        const tri_size: f32 = 30.0; // Half-width of the triangle base

        // Equilateral-ish triangle centered at the stored position.
        // Apex points upward, base at the bottom.
        canvas.fillTriangle(
            .{
                .{ tri_x, tri_y - tri_size }, // Top apex
                .{ tri_x - tri_size, tri_y + tri_size * 0.6 }, // Bottom-left
                .{ tri_x + tri_size, tri_y + tri_size * 0.6 }, // Bottom-right
            },
            .{
                Color.fromHex(0xFFD700), // Gold apex
                Color.fromHex(0xFF8C00), // Dark orange bottom-left
                Color.fromHex(0xFF8C00), // Dark orange bottom-right
            },
        );
    }

    /// Get the current frame count.
    /// Useful for timing, animations, and diagnostics.
    pub fn getFrameCount(self: *const Self) u64 {
        return self.frame_count;
    }

    /// Screenshot error type for App-level screenshot operations.
    pub const ScreenshotError = error{
        /// Renderer not set. Call setRenderer() before takeScreenshot().
        RendererNotSet,
        /// Screenshot capture failed (underlying renderer error).
        CaptureFailed,
    };

    /// Take a screenshot of the current frame and save to a PNG file.
    /// Delegates to the renderer's screenshot method.
    ///
    /// Prerequisites:
    /// - setRenderer() must be called first to provide renderer reference
    /// - Should be called after render() to capture the current frame's content
    ///
    /// Parameters:
    /// - path: File path where the PNG screenshot will be saved
    ///
    /// Returns:
    /// - ScreenshotError.RendererNotSet if setRenderer() was not called
    /// - ScreenshotError.CaptureFailed if the renderer fails to capture
    pub fn takeScreenshot(self: *Self, path: []const u8) ScreenshotError!void {
        const renderer = self.renderer orelse {
            log.err("cannot take screenshot: renderer not set. Call setRenderer() first.", .{});
            return ScreenshotError.RendererNotSet;
        };

        renderer.screenshot(path) catch |err| {
            log.err("screenshot capture failed: {}", .{err});
            return ScreenshotError.CaptureFailed;
        };

        log.info("screenshot saved to: {s} (frame {})", .{ path, self.frame_count });
    }
};

test "App init and deinit" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.isRunning());
    try std.testing.expectEqual(@as(u64, 0), app.getFrameCount());
    try std.testing.expectEqual(@as(f32, 0.0), app.rotation_angle);
}

test "App update increments frame count" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const mouse_state: MouseState = .{
        .x = 100.0,
        .y = 50.0,
        .left_pressed = false,
        .right_pressed = false,
        .middle_pressed = false,
    };

    app.update(0.016, mouse_state); // ~60 FPS with mouse at (100, 50)
    try std.testing.expectEqual(@as(u64, 1), app.getFrameCount());

    app.update(0.016, .{ .x = 110.0, .y = 60.0, .left_pressed = false, .right_pressed = false, .middle_pressed = false });
    app.update(0.016, .{ .x = 120.0, .y = 70.0, .left_pressed = false, .right_pressed = false, .middle_pressed = false });
    try std.testing.expectEqual(@as(u64, 3), app.getFrameCount());
}

test "App requestQuit stops running" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.isRunning());
    app.requestQuit();
    try std.testing.expect(!app.isRunning());
}

test "Triangle moves to click position on left button press" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // Initial triangle position should be at center (200, 150)
    try std.testing.expectEqual(@as(f32, 200.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 150.0), app.triangle_position[1]);

    // First frame: mouse at (50, 75), no buttons pressed
    app.update(0.016, .{ .x = 50.0, .y = 75.0, .left_pressed = false, .right_pressed = false, .middle_pressed = false });

    // Triangle should still be at center (no click yet)
    try std.testing.expectEqual(@as(f32, 200.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 150.0), app.triangle_position[1]);

    // Second frame: left button just pressed at (50, 75)
    app.update(0.016, .{ .x = 50.0, .y = 75.0, .left_pressed = true, .right_pressed = false, .middle_pressed = false });

    // Triangle should now be at click position (50, 75)
    try std.testing.expectEqual(@as(f32, 50.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 75.0), app.triangle_position[1]);

    // Third frame: left button held, mouse moved to (100, 200)
    app.update(0.016, .{ .x = 100.0, .y = 200.0, .left_pressed = true, .right_pressed = false, .middle_pressed = false });

    // Triangle should NOT move while button is held (only on "just pressed")
    try std.testing.expectEqual(@as(f32, 50.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 75.0), app.triangle_position[1]);

    // Fourth frame: button released
    app.update(0.016, .{ .x = 100.0, .y = 200.0, .left_pressed = false, .right_pressed = false, .middle_pressed = false });

    // Triangle should still be at (50, 75) after release
    try std.testing.expectEqual(@as(f32, 50.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 75.0), app.triangle_position[1]);

    // Fifth frame: new click at (300, 250)
    app.update(0.016, .{ .x = 300.0, .y = 250.0, .left_pressed = true, .right_pressed = false, .middle_pressed = false });

    // Triangle should move to new click position
    try std.testing.expectEqual(@as(f32, 300.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 250.0), app.triangle_position[1]);
}

test "Triangle does not move on right or middle button press" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // Initial triangle position at center
    try std.testing.expectEqual(@as(f32, 200.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 150.0), app.triangle_position[1]);

    // First frame: no buttons pressed
    app.update(0.016, .{ .x = 50.0, .y = 75.0, .left_pressed = false, .right_pressed = false, .middle_pressed = false });

    // Right button press should not move triangle
    app.update(0.016, .{ .x = 50.0, .y = 75.0, .left_pressed = false, .right_pressed = true, .middle_pressed = false });
    try std.testing.expectEqual(@as(f32, 200.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 150.0), app.triangle_position[1]);

    // Release right button
    app.update(0.016, .{ .x = 100.0, .y = 100.0, .left_pressed = false, .right_pressed = false, .middle_pressed = false });

    // Middle button press should not move triangle
    app.update(0.016, .{ .x = 100.0, .y = 100.0, .left_pressed = false, .right_pressed = false, .middle_pressed = true });
    try std.testing.expectEqual(@as(f32, 200.0), app.triangle_position[0]);
    try std.testing.expectEqual(@as(f32, 150.0), app.triangle_position[1]);
}

test "Rotation angle updates with delta time" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // Initial rotation should be 0
    try std.testing.expectEqual(@as(f32, 0.0), app.rotation_angle);

    const mouse_state: MouseState = .{
        .x = 0.0,
        .y = 0.0,
        .left_pressed = false,
        .right_pressed = false,
        .middle_pressed = false,
    };

    // After 1 second at rotation_speed = tau/4, angle should be ~1.57 radians (90 degrees)
    app.update(1.0, mouse_state);
    const expected_angle = std.math.tau / 4.0;
    try std.testing.expectApproxEqAbs(expected_angle, app.rotation_angle, 0.001);

    // After another 3 seconds (total 4 seconds), should have wrapped around
    // 4 seconds * tau/4 = tau radians = one full rotation, wraps to ~0
    app.update(1.0, mouse_state);
    app.update(1.0, mouse_state);
    app.update(1.0, mouse_state);
    // Should be close to tau, which then wraps to ~0
    try std.testing.expect(app.rotation_angle < std.math.tau);
}

test "takeScreenshot returns error when renderer not set" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // Renderer is null by default, so takeScreenshot should fail
    try std.testing.expectEqual(@as(?*Renderer, null), app.renderer);

    const result = app.takeScreenshot("/tmp/test.png");
    try std.testing.expectError(App.ScreenshotError.RendererNotSet, result);
}

test "App init has null renderer by default" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // Verify renderer is null on init
    try std.testing.expectEqual(@as(?*Renderer, null), app.renderer);
}

test "App initWithOptions configures screenshot" {
    const options: App.Options = .{
        .screenshot_path = "/tmp/test.png",
        .quit_after_screenshot = true,
    };
    var app = App.initWithOptions(std.testing.allocator, options);
    defer app.deinit();

    // Verify screenshot is pending with correct path
    try std.testing.expect(app.screenshot_pending);
    try std.testing.expectEqualStrings("/tmp/test.png", app.screenshot_path.?);
    try std.testing.expect(app.quit_after_screenshot);
}

test "App shouldTakeScreenshot returns path when pending" {
    const options: App.Options = .{
        .screenshot_path = "/tmp/screenshot.png",
        .quit_after_screenshot = false,
    };
    var app = App.initWithOptions(std.testing.allocator, options);
    defer app.deinit();

    // Should return the path when screenshot is pending
    const path = app.shouldTakeScreenshot();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/tmp/screenshot.png", path.?);
}

test "App onScreenshotComplete clears pending and optionally quits" {
    const options: App.Options = .{
        .screenshot_path = "/tmp/test.png",
        .quit_after_screenshot = true,
    };
    var app = App.initWithOptions(std.testing.allocator, options);
    defer app.deinit();

    try std.testing.expect(app.isRunning());
    try std.testing.expect(app.screenshot_pending);

    // After screenshot complete, should no longer be pending
    app.onScreenshotComplete();

    try std.testing.expect(!app.screenshot_pending);
    // Since quit_after_screenshot is true, app should no longer be running
    try std.testing.expect(!app.isRunning());
}

test "App scheduleScreenshot sets up screenshot" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // Initially no screenshot pending
    try std.testing.expect(app.shouldTakeScreenshot() == null);

    // Schedule a screenshot
    app.scheduleScreenshot("/tmp/dynamic.png", false);

    // Now it should be pending
    const path = app.shouldTakeScreenshot();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/tmp/dynamic.png", path.?);
    try std.testing.expect(!app.quit_after_screenshot);
}
