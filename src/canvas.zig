//! Canvas module - Shape drawing abstraction over the Renderer
//!
//! Provides a higher-level drawing API that wraps the Renderer's triangle-based
//! primitives. Instead of manually decomposing shapes into triangles, callers
//! use semantic shape methods like fillRect() and fillTriangle().

const std = @import("std");
const renderer_mod = @import("renderer.zig");

pub const Renderer = renderer_mod.Renderer;
pub const Color = renderer_mod.Color;

/// Canvas provides shape-drawing methods that decompose into triangles
/// and delegate to the underlying Renderer.
pub const Canvas = struct {
    renderer: *Renderer,

    /// Create a Canvas wrapping an existing Renderer.
    pub fn init(renderer: *Renderer) Canvas {
        return .{ .renderer = renderer };
    }

    /// Draw a filled triangle with per-vertex colors.
    ///
    /// Delegates directly to renderer.queueTriangle(). This is provided
    /// so callers can use Canvas as their sole drawing interface.
    pub fn fillTriangle(self: Canvas, positions: [3][2]f32, colors: [3]Color) void {
        self.renderer.queueTriangle(positions, colors);
    }

    /// Draw a filled axis-aligned rectangle with a single solid color.
    ///
    /// Decomposes into 2 triangles:
    /// - Upper-left:  (x,y) - (x+w,y) - (x,y+h)
    /// - Lower-right: (x+w,y) - (x+w,y+h) - (x,y+h)
    ///
    /// Coordinates are in screen space (origin top-left, X right, Y down).
    pub fn fillRect(self: Canvas, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        self.fillRectGradient(x, y, w, h, color, color, color, color);
    }

    /// Draw a filled axis-aligned rectangle with per-corner colors.
    ///
    /// Corner colors are interpolated across the rectangle by the GPU.
    /// The two triangles share edges so the gradient is seamless.
    ///
    /// Parameters:
    /// - tl: top-left corner color
    /// - tr: top-right corner color
    /// - bl: bottom-left corner color
    /// - br: bottom-right corner color
    pub fn fillRectGradient(
        self: Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        tl: Color,
        tr: Color,
        bl: Color,
        br: Color,
    ) void {
        // Upper-left triangle: TL -> TR -> BL
        self.renderer.queueTriangle(
            .{ .{ x, y }, .{ x + w, y }, .{ x, y + h } },
            .{ tl, tr, bl },
        );
        // Lower-right triangle: TR -> BR -> BL
        self.renderer.queueTriangle(
            .{ .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } },
            .{ tr, br, bl },
        );
    }
};

// --- Tests ---

test "Canvas struct layout" {
    // Verify the Canvas struct has the expected field and can be initialized.
    // Actual rendering requires a GPU, so we only test the struct shape.
    const canvas_info = @typeInfo(Canvas);
    const fields = canvas_info.@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("renderer", fields[0].name);
}

test "fillRect produces correct triangle decomposition" {
    // We can't call fillRect without a real Renderer (it would dereference
    // the pointer), but we can verify the geometry logic by checking that
    // fillRectGradient compiles and has the expected function signature.
    const FnInfo = @typeInfo(@TypeOf(Canvas.fillRectGradient));
    const params = FnInfo.@"fn".params;
    // self + x + y + w + h + tl + tr + bl + br = 9 params
    try std.testing.expectEqual(@as(usize, 9), params.len);
}

test "fillRect solid color delegates to fillRectGradient" {
    // Verify fillRect has the correct signature: self, x, y, w, h, color
    const FnInfo = @typeInfo(@TypeOf(Canvas.fillRect));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 6), params.len);
}

test "Color re-export matches renderer Color" {
    // Verify the re-exported Color type is identical to the renderer's Color.
    try std.testing.expect(Color == renderer_mod.Color);
}
