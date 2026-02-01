//! Application state and logic module
//!
//! The App struct encapsulates all application-specific state and logic,
//! separated from platform and rendering concerns. This separation allows
//! the same app logic to work across different platforms (desktop, web, headless).
//!
//! Currently minimal - will be extended as application features are added.

const std = @import("std");

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
    pub fn update(self: *Self) void {
        self.frame_count += 1;
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

    app.update();
    try std.testing.expectEqual(@as(u64, 1), app.getFrameCount());

    app.update();
    app.update();
    try std.testing.expectEqual(@as(u64, 3), app.getFrameCount());
}

test "App requestQuit stops running" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.isRunning());
    app.requestQuit();
    try std.testing.expect(!app.isRunning());
}
