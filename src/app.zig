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
        // Demo scene showcasing all Canvas primitives: fillRect, fillRectGradient,
        // fillCircle, strokeCircle, fillTriangle, drawLine, fillPolygon.
        // All positions use viewport dimensions for resolution independence.

        const vp_w = canvas.viewport.logical_width;
        const vp_h = canvas.viewport.logical_height;

        // -- Sky background gradient (light blue at top -> deeper blue at horizon) --
        canvas.fillRectGradient(
            0.0,
            0.0,
            vp_w,
            vp_h * 0.7,
            Color.fromHex(0x87CEEB), // Sky blue (top-left)
            Color.fromHex(0x87CEEB), // Sky blue (top-right)
            Color.fromHex(0x4A90D9), // Deeper blue (bottom-left, at horizon)
            Color.fromHex(0x4A90D9), // Deeper blue (bottom-right, at horizon)
        );

        // -- Ground (green rectangle covering lower portion) --
        const ground_y = vp_h * 0.7;
        canvas.fillRectGradient(
            0.0,
            ground_y,
            vp_w,
            vp_h * 0.3,
            Color.fromHex(0x4CAF50), // Grass green (top)
            Color.fromHex(0x4CAF50),
            Color.fromHex(0x2E7D32), // Darker green (bottom)
            Color.fromHex(0x2E7D32),
        );

        // -- Sun (fillCircle with warm yellow) --
        canvas.fillCircle(vp_w * 0.82, vp_h * 0.12, 28.0, Color.fromHex(0xFFD54F), 24);
        // Outer glow ring (slightly larger, more transparent orange)
        canvas.fillCircle(vp_w * 0.82, vp_h * 0.12, 34.0, Color.rgba(1.0, 0.85, 0.3, 0.25), 24);
        // Solar ring (strokeCircle demo — crisp outline around the sun)
        canvas.strokeCircle(vp_w * 0.82, vp_h * 0.12, 42.0, 2.0, Color.fromHex(0xFFA000), 32);

        // -- House --
        const house_x = vp_w * 0.22;
        const house_y = ground_y - 70.0;
        const house_w: f32 = 80.0;
        const house_h: f32 = 70.0;

        // House body
        canvas.fillRect(house_x, house_y, house_w, house_h, Color.fromHex(0xBCAAA4));

        // Roof (triangle above the house body)
        canvas.fillTriangle(
            .{
                .{ house_x - 8.0, house_y }, // Left overhang
                .{ house_x + house_w + 8.0, house_y }, // Right overhang
                .{ house_x + house_w / 2.0, house_y - 40.0 }, // Peak
            },
            .{
                Color.fromHex(0x8D6E63), // Brown
                Color.fromHex(0x8D6E63),
                Color.fromHex(0x6D4C41), // Darker brown at peak
            },
        );

        // Door
        canvas.fillRect(house_x + house_w / 2.0 - 8.0, house_y + house_h - 30.0, 16.0, 30.0, Color.fromHex(0x5D4037));

        // Windows (two small squares)
        canvas.fillRect(house_x + 10.0, house_y + 15.0, 18.0, 18.0, Color.fromHex(0xBBDEFB));
        canvas.fillRect(house_x + house_w - 28.0, house_y + 15.0, 18.0, 18.0, Color.fromHex(0xBBDEFB));

        // Window cross-bars (drawLine)
        // Left window
        canvas.drawLine(house_x + 10.0, house_y + 24.0, house_x + 28.0, house_y + 24.0, 1.0, Color.fromHex(0x795548));
        canvas.drawLine(house_x + 19.0, house_y + 15.0, house_x + 19.0, house_y + 33.0, 1.0, Color.fromHex(0x795548));
        // Right window
        canvas.drawLine(house_x + house_w - 28.0, house_y + 24.0, house_x + house_w - 10.0, house_y + 24.0, 1.0, Color.fromHex(0x795548));
        canvas.drawLine(house_x + house_w - 19.0, house_y + 15.0, house_x + house_w - 19.0, house_y + 33.0, 1.0, Color.fromHex(0x795548));

        // -- Tree (left side) --
        drawTree(canvas, vp_w * 0.08, ground_y);

        // -- Tree (right side, slightly larger) --
        drawTree(canvas, vp_w * 0.62, ground_y);

        // -- Fence (drawLine calls for posts and rails) --
        const fence_start_x = house_x + house_w + 15.0;
        const fence_y = ground_y - 25.0;
        const post_spacing: f32 = 18.0;
        const num_posts: usize = 5;

        for (0..num_posts) |i| {
            const px = fence_start_x + @as(f32, @floatFromInt(i)) * post_spacing;
            // Vertical post
            canvas.drawLine(px, fence_y, px, ground_y, 2.0, Color.fromHex(0x8D6E63));
        }
        // Horizontal rails
        const fence_end_x = fence_start_x + @as(f32, @floatFromInt(num_posts - 1)) * post_spacing;
        canvas.drawLine(fence_start_x, fence_y + 5.0, fence_end_x, fence_y + 5.0, 2.0, Color.fromHex(0xA1887F));
        canvas.drawLine(fence_start_x, fence_y + 15.0, fence_end_x, fence_y + 15.0, 2.0, Color.fromHex(0xA1887F));

        // -- Path / stepping stones (small fillRects on the ground) --
        // A gravel path leading from the house door to the right.
        const path_y = ground_y + 5.0;
        const stone_w: f32 = 8.0;
        const stone_h: f32 = 4.0;
        var si: usize = 0;
        while (si < 4) : (si += 1) {
            const sx = house_x + house_w / 2.0 + 15.0 + @as(f32, @floatFromInt(si)) * 18.0;
            canvas.fillRect(sx, path_y, stone_w, stone_h, Color.fromHex(0x9E9E9E));
        }

        // -- Hexagon (fillPolygon) -- decorative element in the sky
        const hex_cx = vp_w * 0.55;
        const hex_cy = vp_h * 0.18;
        const hex_r: f32 = 14.0;
        var hex_points: [6][2]f32 = undefined;
        for (0..6) |i| {
            const angle = @as(f32, @floatFromInt(i)) * (std.math.tau / 6.0) - std.math.pi / 6.0;
            hex_points[i] = .{
                hex_cx + hex_r * @cos(angle),
                hex_cy + hex_r * @sin(angle),
            };
        }
        canvas.fillPolygon(&hex_points, Color.fromHex(0xFFAB40));

        // -- Animated rotating shape (pentagon) demonstrating animation --
        // Uses self.rotation_angle for frame-rate independent rotation.
        const rot_cx = vp_w * 0.82;
        const rot_cy = vp_h * 0.55;
        const rot_r: f32 = 18.0;
        const rot_sides: usize = 5;
        var rot_points: [rot_sides][2]f32 = undefined;
        for (0..rot_sides) |i| {
            const angle = self.rotation_angle + @as(f32, @floatFromInt(i)) * (std.math.tau / @as(f32, @floatFromInt(rot_sides)));
            rot_points[i] = .{
                rot_cx + rot_r * @cos(angle),
                rot_cy + rot_r * @sin(angle),
            };
        }
        canvas.fillPolygon(&rot_points, Color.fromHex(0xE040FB));

        // -- Interactive triangle -- moves to left-click position.
        // Drawn near the end so it appears on top.
        const tri_x = self.triangle_position[0];
        const tri_y = self.triangle_position[1];
        const tri_size: f32 = 20.0;

        canvas.fillTriangle(
            .{
                .{ tri_x, tri_y - tri_size }, // Top apex
                .{ tri_x - tri_size, tri_y + tri_size * 0.6 }, // Bottom-left
                .{ tri_x + tri_size, tri_y + tri_size * 0.6 }, // Bottom-right
            },
            .{
                Color.fromHex(0xFFD700), // Gold apex
                Color.fromHex(0xFF8C00), // Dark orange
                Color.fromHex(0xFF8C00),
            },
        );

        // -- Stroke rectangles (showcasing strokeRect) --
        // Picture frame around the hexagon
        canvas.strokeRect(hex_cx - 22.0, hex_cy - 22.0, 44.0, 44.0, 2.0, Color.fromHex(0xFFD700));

        // Window frames using strokeRect (outline around each window)
        canvas.strokeRect(house_x + 10.0, house_y + 15.0, 18.0, 18.0, 1.0, Color.fromHex(0x5D4037));
        canvas.strokeRect(house_x + house_w - 28.0, house_y + 15.0, 18.0, 18.0, 1.0, Color.fromHex(0x5D4037));

        // -- Zigzag path on the ground (drawPolyline demo) --
        // A winding trail from left to right across the ground.
        const zigzag_y = ground_y + 15.0;
        const zigzag_points = [_][2]f32{
            .{ vp_w * 0.35, zigzag_y },
            .{ vp_w * 0.40, zigzag_y - 8.0 },
            .{ vp_w * 0.45, zigzag_y + 4.0 },
            .{ vp_w * 0.50, zigzag_y - 6.0 },
            .{ vp_w * 0.55, zigzag_y + 2.0 },
            .{ vp_w * 0.58, zigzag_y - 4.0 },
        };
        canvas.drawPolyline(&zigzag_points, 2.0, Color.fromHex(0xD7CCC8));

        // -- Star outline in the sky (drawPolyline demo) --
        // A 5-pointed star drawn as a closed polyline.
        const star_cx = vp_w * 0.38;
        const star_cy = vp_h * 0.12;
        const star_outer: f32 = 12.0;
        const star_inner: f32 = 5.0;
        var star_points: [11][2]f32 = undefined;
        for (0..10) |i| {
            const angle = @as(f32, @floatFromInt(i)) * (std.math.tau / 10.0) - std.math.pi / 2.0;
            const r = if (i % 2 == 0) star_outer else star_inner;
            star_points[i] = .{
                star_cx + r * @cos(angle),
                star_cy + r * @sin(angle),
            };
        }
        // Close the star by repeating the first point
        star_points[10] = star_points[0];
        canvas.drawPolyline(&star_points, 1.5, Color.fromHex(0xFFEB3B));

        // -- Mouse crosshair --
        const mouse_x = self.mouse_state.x;
        const mouse_y = self.mouse_state.y;
        const crosshair_size: f32 = 8.0;
        const crosshair_thickness: f32 = 1.5;

        canvas.fillRect(
            mouse_x - crosshair_size,
            mouse_y - crosshair_thickness,
            crosshair_size * 2.0,
            crosshair_thickness * 2.0,
            Color.white,
        );
        canvas.fillRect(
            mouse_x - crosshair_thickness,
            mouse_y - crosshair_size,
            crosshair_thickness * 2.0,
            crosshair_size * 2.0,
            Color.white,
        );

        // -- Mouse button state indicators (bottom-left corner) --
        const btn_base_x: f32 = 10.0;
        const btn_base_y: f32 = vp_h - 20.0;
        const btn_size: f32 = 12.0;
        const btn_spacing: f32 = 16.0;

        const btn_colors = [3]struct { pressed: Color, released: Color }{
            .{ .pressed = Color.red, .released = Color.rgb(0.3, 0.0, 0.0) },
            .{ .pressed = Color.green, .released = Color.rgb(0.0, 0.3, 0.0) },
            .{ .pressed = Color.blue, .released = Color.rgb(0.0, 0.0, 0.3) },
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
    }

    /// Draw a tree at the given ground position. Trunk is a fillRect,
    /// foliage is three stacked fillTriangles for a layered look.
    fn drawTree(canvas: *Canvas, base_x: f32, ground_y: f32) void {
        const trunk_w: f32 = 10.0;
        const trunk_h: f32 = 35.0;
        // Trunk
        canvas.fillRect(base_x - trunk_w / 2.0, ground_y - trunk_h, trunk_w, trunk_h, Color.fromHex(0x6D4C41));

        // Three stacked triangle layers for foliage (widest at bottom, narrow at top)
        const layers = [_]struct { w: f32, y_offset: f32, h: f32 }{
            .{ .w = 40.0, .y_offset = 25.0, .h = 30.0 }, // Bottom layer
            .{ .w = 32.0, .y_offset = 40.0, .h = 28.0 }, // Middle layer
            .{ .w = 24.0, .y_offset = 55.0, .h = 26.0 }, // Top layer
        };

        for (layers) |layer| {
            const ly = ground_y - layer.y_offset;
            canvas.fillTriangle(
                .{
                    .{ base_x - layer.w / 2.0, ly },
                    .{ base_x + layer.w / 2.0, ly },
                    .{ base_x, ly - layer.h },
                },
                .{
                    Color.fromHex(0x388E3C),
                    Color.fromHex(0x388E3C),
                    Color.fromHex(0x1B5E20), // Darker at top
                },
            );
        }
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
