//! Zig GUI Experiment - Main entry point
//!
//! A GPU-accelerated terminal emulator experiment using zgpu and zglfw.

const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

const log = std.log.scoped(.main);

// Export zgpu types for use in other modules
pub const GraphicsContext = zgpu.GraphicsContext;

pub fn main() void {
    log.info("zig-gui-experiment starting", .{});
    log.info("zig-gui-experiment exiting", .{});
}
