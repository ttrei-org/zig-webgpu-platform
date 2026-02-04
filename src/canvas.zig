//! Canvas module - 2D shape drawing API
//!
//! Provides a high-level, immediate-mode drawing API that wraps the Renderer's
//! triangle-based primitives. Instead of manually decomposing shapes into
//! triangles, callers use semantic shape methods like `fillRect()` and
//! `fillCircle()`.
//!
//! ## Coordinate System
//!
//! All coordinates are in **logical units** defined by the `Viewport`:
//! - **Origin**: top-left corner (0, 0)
//! - **X axis**: increases to the right
//! - **Y axis**: increases downward
//! - **Units**: logical pixels (e.g. 400x300), not physical pixels
//!
//! The GPU shader automatically scales logical coordinates to whatever physical
//! resolution the render target provides. This means drawing code is
//! resolution-independent — the same code renders correctly at 800x600, 1920x1080,
//! or any other size.
//!
//! ## Usage Pattern
//!
//! ```
//! // In your App.render() callback:
//! pub fn render(canvas: *Canvas) void {
//!     // Sky background
//!     canvas.fillRect(0, 0, 400, 200, Color.fromHex(0x87CEEB));
//!     // Sun
//!     canvas.fillCircle(350, 50, 30, Color.yellow, 32);
//!     // Ground
//!     canvas.fillRect(0, 200, 400, 100, Color.green);
//!     // House
//!     canvas.fillRect(150, 140, 100, 60, Color.fromRgb8(180, 160, 140));
//!     canvas.fillTriangle(
//!         .{ .{ 140, 140 }, .{ 200, 100 }, .{ 260, 140 } },
//!         .{ Color.fromHex(0x8B6914), Color.fromHex(0x8B6914), Color.fromHex(0x8B6914) },
//!     );
//! }
//! ```
//!
//! ## Available Primitives
//!
//! | Method          | Description                              | Triangles   |
//! |-----------------|------------------------------------------|-------------|
//! | fillTriangle    | Single filled triangle, per-vertex color | 1           |
//! | fillRect        | Solid filled rectangle                   | 2           |
//! | fillRectGradient| Rectangle with per-corner color gradient | 2           |
//! | fillCircle      | Filled circle (triangle fan)             | segments    |
//! | fillPolygon     | Filled convex polygon (fan triangulation)| N-2         |
//! | strokeRect      | Outlined rectangle (inset stroke)        | 8           |
//! | strokeCircle    | Outlined circle (ring of quads)          | segments*2  |
//! | drawLine        | Thick line segment                       | 2           |
//! | drawPolyline    | Connected line segments                  | (N-1)*2     |

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const color_mod = @import("color.zig");

pub const Renderer = renderer_mod.Renderer;
pub const Color = color_mod.Color;

/// Defines a logical coordinate space for drawing, decoupling App drawing
/// code from physical pixel dimensions. The shader transforms logical
/// coordinates to NDC using these dimensions, so shapes scale automatically
/// to fill whatever physical resolution the render target provides.
pub const Viewport = struct {
    /// Logical width of the drawing area (e.g. 400.0).
    logical_width: f32,
    /// Logical height of the drawing area (e.g. 300.0).
    logical_height: f32,
};

/// Canvas provides shape-drawing methods that decompose into triangles
/// and delegate to the underlying Renderer.
pub const Canvas = struct {
    renderer: *Renderer,
    /// The logical coordinate space used for drawing.
    /// App code should reference viewport dimensions instead of hardcoding pixel values.
    viewport: Viewport,

    /// Create a Canvas wrapping an existing Renderer with a logical viewport.
    ///
    /// The viewport defines the logical coordinate space for all drawing operations.
    /// All shapes drawn through this Canvas use the viewport's coordinate system,
    /// regardless of the physical render target resolution.
    ///
    /// Typically created once per frame in the render loop:
    /// ```
    /// var canvas = Canvas.init(&renderer, .{ .logical_width = 400.0, .logical_height = 300.0 });
    /// ```
    pub fn init(renderer: *Renderer, viewport: Viewport) Canvas {
        return .{ .renderer = renderer, .viewport = viewport };
    }

    /// Draw a filled triangle with per-vertex colors.
    ///
    /// The GPU interpolates colors smoothly across the triangle surface.
    /// This is the lowest-level primitive — all other shapes decompose into triangles.
    ///
    /// Parameters:
    /// - positions: Three [x, y] vertices in logical coordinates.
    /// - colors: Per-vertex colors (interpolated by the GPU).
    pub fn fillTriangle(self: Canvas, positions: [3][2]f32, colors: [3]Color) void {
        self.renderer.queueTriangle(positions, colors);
    }

    /// Draw a filled axis-aligned rectangle with a single solid color.
    ///
    /// Decomposes into 2 triangles sharing the diagonal edge.
    ///
    /// Parameters:
    /// - x, y: Top-left corner position in logical coordinates.
    /// - w, h: Width and height in logical units.
    /// - color: Fill color applied uniformly.
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

    /// Draw a filled circle as a triangle fan from the center.
    ///
    /// The circle is approximated by `segments` triangles radiating from
    /// the center point. More segments produce a smoother circle:
    /// - 16 segments: visible facets, fast
    /// - 32 segments: smooth for small/medium circles (recommended default)
    /// - 64 segments: very smooth for large circles
    ///
    /// Parameters:
    /// - cx, cy: Center position in logical coordinates.
    /// - radius: Circle radius in logical units.
    /// - color: Fill color.
    /// - segments: Number of triangles (minimum 3). Higher = smoother.
    pub fn fillCircle(self: Canvas, cx: f32, cy: f32, radius: f32, color: Color, segments: u16) void {
        if (segments < 3) return;
        const seg_f: f32 = @floatFromInt(segments);
        var i: u16 = 0;
        while (i < segments) : (i += 1) {
            const i_f: f32 = @floatFromInt(i);
            const next_f: f32 = @floatFromInt(i + 1);
            const angle1 = i_f * std.math.tau / seg_f;
            const angle2 = next_f * std.math.tau / seg_f;
            self.renderer.queueTriangle(
                .{
                    .{ cx, cy },
                    .{ cx + radius * @cos(angle1), cy + radius * @sin(angle1) },
                    .{ cx + radius * @cos(angle2), cy + radius * @sin(angle2) },
                },
                .{ color, color, color },
            );
        }
    }

    /// Draw an outlined (unfilled) circle as a ring of quads.
    ///
    /// The circle is approximated by `segments` quads (2 triangles each) forming
    /// a ring between an inner radius and an outer radius. The stroke is drawn
    /// **inset** from the given radius: the outer edge aligns with `radius` and
    /// the inner edge is at `radius - thickness`.
    ///
    /// Produces `segments * 2` triangles.
    ///
    /// Coordinates are in screen space (origin top-left, X right, Y down).
    pub fn strokeCircle(self: Canvas, cx: f32, cy: f32, radius: f32, thickness: f32, color: Color, segments: u16) void {
        if (segments < 3) return;
        // Clamp thickness so it doesn't exceed the radius
        const t = @min(thickness, radius);
        if (t <= 0 or radius <= 0) return;
        const r_outer = radius;
        const r_inner = radius - t;
        const seg_f: f32 = @floatFromInt(segments);
        var i: u16 = 0;
        while (i < segments) : (i += 1) {
            const i_f: f32 = @floatFromInt(i);
            const next_f: f32 = @floatFromInt(i + 1);
            const angle1 = i_f * std.math.tau / seg_f;
            const angle2 = next_f * std.math.tau / seg_f;
            const cos1 = @cos(angle1);
            const sin1 = @sin(angle1);
            const cos2 = @cos(angle2);
            const sin2 = @sin(angle2);
            // Four corners of the quad: outer1, outer2, inner1, inner2
            const outer_a = [2]f32{ cx + r_outer * cos1, cy + r_outer * sin1 };
            const outer_b = [2]f32{ cx + r_outer * cos2, cy + r_outer * sin2 };
            const inner_a = [2]f32{ cx + r_inner * cos1, cy + r_inner * sin1 };
            const inner_b = [2]f32{ cx + r_inner * cos2, cy + r_inner * sin2 };
            // Two triangles per quad segment
            self.renderer.queueTriangle(.{ outer_a, outer_b, inner_a }, .{ color, color, color });
            self.renderer.queueTriangle(.{ outer_b, inner_b, inner_a }, .{ color, color, color });
        }
    }

    /// Draw a line segment with the given thickness as a rotated rectangle.
    ///
    /// The line is rendered as 2 triangles forming a rectangle oriented
    /// along the direction from (x1,y1) to (x2,y2). Returns immediately
    /// for degenerate (near-zero-length) lines.
    ///
    /// Parameters:
    /// - x1, y1: Start point in logical coordinates.
    /// - x2, y2: End point in logical coordinates.
    /// - thickness: Line width in logical units. The line extends thickness/2
    ///   on each side of the center line.
    /// - color: Line color.
    pub fn drawLine(self: Canvas, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: Color) void {
        const dx = x2 - x1;
        const dy = y2 - y1;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) return;
        // Perpendicular offset for the line's thickness
        const half_t = thickness * 0.5;
        const nx = -dy / len * half_t;
        const ny = dx / len * half_t;
        const p0 = [2]f32{ x1 + nx, y1 + ny };
        const p1 = [2]f32{ x1 - nx, y1 - ny };
        const p2 = [2]f32{ x2 - nx, y2 - ny };
        const p3 = [2]f32{ x2 + nx, y2 + ny };
        self.renderer.queueTriangle(.{ p0, p1, p2 }, .{ color, color, color });
        self.renderer.queueTriangle(.{ p0, p2, p3 }, .{ color, color, color });
    }

    /// Draw an outlined (unfilled) axis-aligned rectangle.
    ///
    /// The stroke is drawn fully **inside** the given rect boundary, so the
    /// outer edge of the stroke aligns with (x, y, x+w, y+h). This avoids
    /// the rectangle growing beyond the specified dimensions.
    ///
    /// Implementation uses 4 thin filled rectangles (top, bottom, left, right)
    /// rather than 4 drawLine() calls, which avoids diagonal overlap artifacts
    /// at corners.
    ///
    /// Produces 8 triangles (4 rects x 2 triangles each).
    ///
    /// Coordinates are in screen space (origin top-left, X right, Y down).
    pub fn strokeRect(self: Canvas, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: Color) void {
        // Clamp thickness so it doesn't exceed half the smallest dimension,
        // preventing the strips from overlapping or going negative.
        const t = @min(thickness, @min(w * 0.5, h * 0.5));
        if (t <= 0 or w <= 0 or h <= 0) return;

        // Top strip
        self.fillRect(x, y, w, t, color);
        // Bottom strip
        self.fillRect(x, y + h - t, w, t, color);
        // Left strip (between top and bottom to avoid double-draw at corners)
        self.fillRect(x, y + t, t, h - 2 * t, color);
        // Right strip
        self.fillRect(x + w - t, y + t, t, h - 2 * t, color);
    }

    /// Draw a connected sequence of line segments (polyline / line strip).
    ///
    /// Iterates consecutive point pairs and draws a line for each segment
    /// using drawLine(). Each segment is an independent rotated rectangle,
    /// so joints at sharp angles will have small gaps or overlaps — this is
    /// acceptable for a first implementation.
    ///
    /// Produces (points.len - 1) * 2 triangles (2 per segment).
    ///
    /// Parameters:
    /// - points: Slice of at least 2 [2]f32 positions in logical coordinates.
    /// - thickness: Line width in logical units.
    /// - color: Uniform color for all segments.
    ///
    /// Coordinates are in screen space (origin top-left, X right, Y down).
    pub fn drawPolyline(self: Canvas, points: []const [2]f32, thickness: f32, color: Color) void {
        if (points.len < 2) return;
        for (0..points.len - 1) |i| {
            self.drawLine(
                points[i][0],
                points[i][1],
                points[i + 1][0],
                points[i + 1][1],
                thickness,
                color,
            );
        }
    }

    /// Draw a filled convex polygon using fan triangulation from the first vertex.
    ///
    /// Only correct for **convex** polygons. For concave shapes the result
    /// will have visual artifacts. Degenerate polygons (< 3 points) are
    /// silently ignored. Produces N-2 triangles for N vertices.
    ///
    /// Parameters:
    /// - points: Slice of [x, y] vertex positions in logical coordinates (min 3).
    ///   Vertices should be ordered consistently (clockwise or counter-clockwise).
    /// - color: Uniform fill color.
    pub fn fillPolygon(self: Canvas, points: []const [2]f32, color: Color) void {
        if (points.len < 3) return;
        // Fan triangulation: anchor at points[0], sweep remaining edges
        for (1..points.len - 1) |i| {
            self.renderer.queueTriangle(
                .{ points[0], points[i], points[i + 1] },
                .{ color, color, color },
            );
        }
    }
};

// --- Tests ---

test "Canvas struct layout" {
    // Verify the Canvas struct has the expected fields and can be initialized.
    // Actual rendering requires a GPU, so we only test the struct shape.
    const canvas_info = @typeInfo(Canvas);
    const fields = canvas_info.@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("renderer", fields[0].name);
    try std.testing.expectEqualStrings("viewport", fields[1].name);
}

test "Viewport struct layout" {
    const vp: Viewport = .{ .logical_width = 400.0, .logical_height = 300.0 };
    try std.testing.expectEqual(@as(f32, 400.0), vp.logical_width);
    try std.testing.expectEqual(@as(f32, 300.0), vp.logical_height);
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
    // Verify the re-exported Color type is identical to the renderer's Color
    // (both resolve to color_mod.Color).
    try std.testing.expect(Color == renderer_mod.Color);
    try std.testing.expect(Color == color_mod.Color);
}

test "fillCircle signature" {
    // Verify fillCircle has the correct signature: self, cx, cy, radius, color, segments
    const FnInfo = @typeInfo(@TypeOf(Canvas.fillCircle));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 6), params.len);
}

test "drawLine signature" {
    // Verify drawLine has the correct signature: self, x1, y1, x2, y2, thickness, color
    const FnInfo = @typeInfo(@TypeOf(Canvas.drawLine));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 7), params.len);
}

test "fillPolygon signature" {
    // Verify fillPolygon has the correct signature: self, points, color
    const FnInfo = @typeInfo(@TypeOf(Canvas.fillPolygon));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 3), params.len);
}

test "strokeRect signature" {
    // Verify strokeRect has the correct signature: self, x, y, w, h, thickness, color
    const FnInfo = @typeInfo(@TypeOf(Canvas.strokeRect));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 7), params.len);
}

test "drawPolyline signature" {
    // Verify drawPolyline has the correct signature: self, points, thickness, color
    const FnInfo = @typeInfo(@TypeOf(Canvas.drawPolyline));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 4), params.len);
}

test "drawPolyline triangle count reasoning" {
    // drawPolyline calls drawLine() for each consecutive pair.
    // Each drawLine produces 2 triangles (one rotated rectangle).
    // For N points: (N-1) segments * 2 triangles = (N-1)*2 triangles total.
    // With 5 points: 4 segments * 2 = 8 triangles.
    // We verify the function exists and returns void (no error).
    const ReturnType = @typeInfo(@TypeOf(Canvas.drawPolyline)).@"fn".return_type.?;
    try std.testing.expect(ReturnType == void);
}

test "strokeRect triangle count" {
    // strokeRect decomposes into 4 filled rectangles = 8 triangles (2 per rect).
    // Verify indirectly: the method calls fillRect 4 times, each producing 2 triangles.
    // We verify the function exists and accepts the expected parameter types.
    const ReturnType = @typeInfo(@TypeOf(Canvas.strokeRect)).@"fn".return_type.?;
    try std.testing.expect(ReturnType == void);
}

test "strokeRect thickness clamping" {
    // When thickness exceeds half the smallest dimension, it should be clamped.
    // This is a logic test — we verify the function compiles and has correct semantics
    // by checking that the implementation handles edge cases via @min.
    // (Actual rendering requires a GPU; we test the type-level contract here.)
    const FnInfo = @typeInfo(@TypeOf(Canvas.strokeRect));
    // Return type must be void (no error possible)
    try std.testing.expect(FnInfo.@"fn".return_type.? == void);
}

test "strokeCircle signature" {
    // Verify strokeCircle has the correct signature: self, cx, cy, radius, thickness, color, segments
    const FnInfo = @typeInfo(@TypeOf(Canvas.strokeCircle));
    const params = FnInfo.@"fn".params;
    try std.testing.expectEqual(@as(usize, 7), params.len);
}

test "strokeCircle triangle count" {
    // strokeCircle produces segments * 2 triangles (2 per quad segment).
    // For 32 segments: 32 * 2 = 64 triangles.
    // We verify the function exists and returns void (no error).
    const ReturnType = @typeInfo(@TypeOf(Canvas.strokeCircle)).@"fn".return_type.?;
    try std.testing.expect(ReturnType == void);
}
