//! Zig GUI Experiment - Main entry point
//!
//! A GPU-accelerated terminal emulator experiment using zgpu and zglfw.

const std = @import("std");

const log = std.log.scoped(.main);

pub fn main() void {
    log.info("zig-gui-experiment starting", .{});
    log.info("zig-gui-experiment exiting", .{});
}
