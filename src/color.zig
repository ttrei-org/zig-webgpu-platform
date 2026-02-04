//! Color module - RGBA color type and utilities
//!
//! Provides the core Color type used throughout the application for vertex
//! coloring and general color representation. Extracted as a standalone module
//! so that application code needing colors does not depend on the renderer.

/// RGBA color type for vertex coloring and general color representation.
/// Values are normalized floats in range [0.0, 1.0].
/// The alpha channel enables future transparency support.
pub const Color = struct {
    /// Red component [0.0, 1.0].
    r: f32,
    /// Green component [0.0, 1.0].
    g: f32,
    /// Blue component [0.0, 1.0].
    b: f32,
    /// Alpha component [0.0, 1.0]. 1.0 = fully opaque, 0.0 = fully transparent.
    a: f32 = 1.0,

    // Named color constants (all fully opaque).
    pub const white: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const black: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const red: Color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const green: Color = .{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const blue: Color = .{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
    pub const yellow: Color = .{ .r = 1.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const cyan: Color = .{ .r = 0.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const magenta: Color = .{ .r = 1.0, .g = 0.0, .b = 1.0, .a = 1.0 };

    /// Convert to RGB array (legacy compatibility).
    /// Discards the alpha channel.
    pub fn toRgb(self: Color) [3]f32 {
        return .{ self.r, self.g, self.b };
    }

    /// Convert to RGBA array for vertex attribute compatibility.
    /// Includes the alpha channel for transparency support.
    pub fn toRgba(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    /// Create a Color from an RGB array (alpha defaults to 1.0).
    pub fn fromRgb(rgb_array: [3]f32) Color {
        return .{ .r = rgb_array[0], .g = rgb_array[1], .b = rgb_array[2], .a = 1.0 };
    }

    /// Create a Color from an RGBA array.
    pub fn fromRgba(rgba_array: [4]f32) Color {
        return .{ .r = rgba_array[0], .g = rgba_array[1], .b = rgba_array[2], .a = rgba_array[3] };
    }

    /// Create a Color from individual RGB values (alpha defaults to 1.0).
    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    /// Create a Color from individual RGBA values.
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Create a Color from u8 RGB values (0-255 range).
    /// Converts by dividing by 255.0. Alpha defaults to 1.0 (fully opaque).
    /// Convenient for using common RGB notation like (255, 128, 0).
    pub fn fromRgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = 1.0,
        };
    }

    /// Create a Color from u8 RGBA values (0-255 range).
    /// Converts by dividing by 255.0.
    /// Convenient for using common RGBA notation like (255, 128, 0, 255).
    pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// Create a Color from a 24-bit RGB hex value (e.g., 0xFF5500 for orange).
    /// Extracts channels using bit shifts. Alpha defaults to 1.0 (fully opaque).
    /// Common web color format support.
    pub fn fromHex(hex: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
            .a = 1.0,
        };
    }

    /// Create a Color from a 32-bit RGBA hex value (e.g., 0xFF550080 for semi-transparent orange).
    /// Extracts channels using bit shifts including alpha.
    /// Format: 0xRRGGBBAA.
    pub fn fromHexRgba(hex: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 24) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .a = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        };
    }
};
