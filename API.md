# API Reference: zig-webgpu-platform

Comprehensive reference for application developers building graphical Zig programs on this platform.

---

## Overview

Applications interact with the platform through three main modules:

| Module | Purpose |
|--------|---------|
| `canvas.zig` | 2D shape drawing API (Canvas, Viewport) |
| `color.zig` | Color type with factory methods and constants |
| `app_interface.zig` | Application lifecycle interface |

Import pattern:
```zig
const canvas = @import("canvas.zig");
const Canvas = canvas.Canvas;
const Color = canvas.Color;
const Viewport = canvas.Viewport;
```

---

## Canvas Module

### Canvas

The main drawing interface. Applications receive a `*Canvas` in their `render()` callback and issue draw commands.

```zig
pub const Canvas = struct {
    renderer: *Renderer,    // Internal - do not access directly
    viewport: Viewport,     // Read-only: logical drawing area
    
    pub fn init(renderer: *Renderer, viewport: Viewport) Canvas;
};
```

**Coordinate System:**
- Origin: top-left corner (0, 0)
- X axis: increases to the right
- Y axis: increases downward
- Units: logical pixels (not physical), as defined by Viewport

All drawing is resolution-independent. The GPU automatically scales logical coordinates to the physical render target.

---

### Drawing Methods

#### fillTriangle
```zig
pub fn fillTriangle(self: Canvas, positions: [3][2]f32, colors: [3]Color) void
```
Draw a filled triangle with per-vertex colors. The GPU interpolates colors across the surface.

**Parameters:**
- `positions`: Three `[x, y]` vertices in logical coordinates
- `colors`: Per-vertex colors (GPU-interpolated)

**Triangles produced:** 1

---

#### fillRect
```zig
pub fn fillRect(self: Canvas, x: f32, y: f32, w: f32, h: f32, color: Color) void
```
Draw a filled axis-aligned rectangle with a solid color.

**Parameters:**
- `x, y`: Top-left corner position
- `w, h`: Width and height
- `color`: Fill color

**Triangles produced:** 2

---

#### fillRectGradient
```zig
pub fn fillRectGradient(
    self: Canvas,
    x: f32, y: f32, w: f32, h: f32,
    tl: Color, tr: Color, bl: Color, br: Color,
) void
```
Draw a filled rectangle with per-corner color gradient.

**Parameters:**
- `x, y`: Top-left corner position
- `w, h`: Width and height
- `tl, tr, bl, br`: Top-left, top-right, bottom-left, bottom-right corner colors

**Triangles produced:** 2

---

#### fillCircle
```zig
pub fn fillCircle(self: Canvas, cx: f32, cy: f32, radius: f32, color: Color, segments: u16) void
```
Draw a filled circle as a triangle fan.

**Parameters:**
- `cx, cy`: Center position
- `radius`: Circle radius
- `color`: Fill color
- `segments`: Number of segments (minimum 3). Higher = smoother
  - 16: visible facets, fast
  - 32: smooth for small/medium circles (recommended)
  - 64: very smooth for large circles

**Triangles produced:** `segments`

---

#### strokeCircle
```zig
pub fn strokeCircle(self: Canvas, cx: f32, cy: f32, radius: f32, thickness: f32, color: Color, segments: u16) void
```
Draw an outlined (unfilled) circle as a ring of quads.

The stroke is **inset**: outer edge aligns with `radius`, inner edge at `radius - thickness`.

**Parameters:**
- `cx, cy`: Center position
- `radius`: Circle radius (outer edge)
- `thickness`: Stroke width (clamped to radius)
- `color`: Stroke color
- `segments`: Number of segments (minimum 3)

**Triangles produced:** `segments * 2`

---

#### drawLine
```zig
pub fn drawLine(self: Canvas, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: Color) void
```
Draw a line segment with thickness as a rotated rectangle.

**Parameters:**
- `x1, y1`: Start point
- `x2, y2`: End point
- `thickness`: Line width (extends `thickness/2` on each side)
- `color`: Line color

**Triangles produced:** 2

**Note:** Degenerate lines (near-zero length) are silently skipped.

---

#### drawPolyline
```zig
pub fn drawPolyline(self: Canvas, points: []const [2]f32, thickness: f32, color: Color) void
```
Draw connected line segments (polyline / line strip).

**Parameters:**
- `points`: Slice of `[x, y]` positions (minimum 2)
- `thickness`: Line width
- `color`: Uniform color

**Triangles produced:** `(points.len - 1) * 2`

**Note:** Joints at sharp angles may have small gaps/overlaps.

---

#### strokeRect
```zig
pub fn strokeRect(self: Canvas, x: f32, y: f32, w: f32, h: f32, thickness: f32, color: Color) void
```
Draw an outlined (unfilled) axis-aligned rectangle.

The stroke is **inset**: outer edge aligns with the rect boundary.

**Parameters:**
- `x, y`: Top-left corner position
- `w, h`: Width and height
- `thickness`: Stroke width (clamped to half smallest dimension)
- `color`: Stroke color

**Triangles produced:** 8

---

#### fillPolygon
```zig
pub fn fillPolygon(self: Canvas, points: []const [2]f32, color: Color) void
```
Draw a filled convex polygon using fan triangulation.

**Parameters:**
- `points`: Slice of `[x, y]` vertices (minimum 3, ordered consistently)
- `color`: Fill color

**Triangles produced:** `points.len - 2`

**Warning:** Only correct for convex polygons. Concave shapes produce visual artifacts.

---

### Viewport

Defines the logical coordinate space, decoupling drawing from physical pixels.

```zig
pub const Viewport = struct {
    logical_width: f32,   // e.g., 400.0
    logical_height: f32,  // e.g., 300.0
};
```

Access via `canvas.viewport` to get dimensions for layout calculations.

---

## Color Module

### Color

RGBA color with normalized float components `[0.0, 1.0]`.

```zig
pub const Color = struct {
    r: f32,          // Red component
    g: f32,          // Green component
    b: f32,          // Blue component
    a: f32 = 1.0,    // Alpha (1.0 = opaque, 0.0 = transparent)
};
```

---

### Named Constants

All fully opaque (alpha = 1.0):

```zig
Color.white    // (1.0, 1.0, 1.0)
Color.black    // (0.0, 0.0, 0.0)
Color.red      // (1.0, 0.0, 0.0)
Color.green    // (0.0, 1.0, 0.0)
Color.blue     // (0.0, 0.0, 1.0)
Color.yellow   // (1.0, 1.0, 0.0)
Color.cyan     // (0.0, 1.0, 1.0)
Color.magenta  // (1.0, 0.0, 1.0)
```

---

### Factory Methods

#### From float values
```zig
pub fn rgb(r: f32, g: f32, b: f32) Color           // Alpha = 1.0
pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color
pub fn fromRgb(rgb_array: [3]f32) Color            // Alpha = 1.0
pub fn fromRgba(rgba_array: [4]f32) Color
```

#### From 8-bit integers (0-255)
```zig
pub fn fromRgb8(r: u8, g: u8, b: u8) Color         // Alpha = 1.0
pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Color
```

#### From hex values
```zig
pub fn fromHex(hex: u24) Color      // 0xRRGGBB, alpha = 1.0
pub fn fromHexRgba(hex: u32) Color  // 0xRRGGBBAA
```

**Examples:**
```zig
const orange = Color.fromHex(0xFF5500);
const semi_transparent = Color.fromHexRgba(0xFF550080);
const sky_blue = Color.fromRgb8(135, 206, 235);
```

---

### Conversion Methods

```zig
pub fn toRgb(self: Color) [3]f32   // Discards alpha
pub fn toRgba(self: Color) [4]f32
```

---

## Input Types

Input types are defined in `platform.zig` and passed to `AppInterface.update()`.

### MouseState

Current mouse position and button states.

```zig
pub const MouseState = struct {
    x: f32,              // X position in logical coordinates
    y: f32,              // Y position in logical coordinates
    left_pressed: bool,
    right_pressed: bool,
    middle_pressed: bool,
    
    pub fn isPressed(self: MouseState, button: MouseButton) bool;
    pub fn buttonJustPressed(current: MouseState, prev: MouseState, button: MouseButton) bool;
    pub fn buttonJustReleased(current: MouseState, prev: MouseState, button: MouseButton) bool;
};
```

**Edge detection helpers:**
- `buttonJustPressed`: Returns `true` on the frame a button transitions from released to pressed
- `buttonJustReleased`: Returns `true` on the frame a button transitions from pressed to released

---

### MouseButton

```zig
pub const MouseButton = enum {
    left,
    right,
    middle,
};
```

---

### Key

Keyboard key identifiers for polling.

```zig
pub const Key = enum {
    escape,
    space,
    enter,
    up,
    down,
    left,
    right,
};
```

---

## Application Interface

### AppInterface

The platform calls these methods each frame via the vtable pattern.

```zig
pub const AppInterface = struct {
    // Required methods
    pub fn update(self: *Self, delta_time: f32, mouse_state: MouseState) void;
    pub fn render(self: *Self, canvas: *Canvas) void;
    pub fn isRunning(self: *const Self) bool;
    pub fn requestQuit(self: *Self) void;
    pub fn deinit(self: *Self) void;
    
    // Optional methods (for screenshot workflow)
    pub fn shouldTakeScreenshot(self: *const Self) ?[]const u8;
    pub fn onScreenshotComplete(self: *Self) void;
};
```

**Frame lifecycle:**
1. `update(delta_time, mouse_state)` - Advance application state
2. `render(canvas)` - Issue draw commands
3. `isRunning()` - Check if app wants to continue

---

## Example Application

```zig
const std = @import("std");
const canvas = @import("canvas.zig");
const Canvas = canvas.Canvas;
const Color = canvas.Color;

pub const App = struct {
    running: bool = true,
    ball_x: f32 = 200.0,
    ball_y: f32 = 150.0,
    
    pub fn update(self: *App, delta_time: f32, mouse: MouseState) void {
        // Move ball toward mouse
        self.ball_x += (mouse.x - self.ball_x) * delta_time * 5.0;
        self.ball_y += (mouse.y - self.ball_y) * delta_time * 5.0;
    }
    
    pub fn render(self: *App, c: *Canvas) void {
        // Sky background
        c.fillRect(0, 0, c.viewport.logical_width, c.viewport.logical_height, Color.fromHex(0x87CEEB));
        
        // Ball following mouse
        c.fillCircle(self.ball_x, self.ball_y, 20.0, Color.red, 32);
        
        // Border
        c.strokeRect(10, 10, c.viewport.logical_width - 20, c.viewport.logical_height - 20, 2.0, Color.black);
    }
    
    pub fn isRunning(self: *const App) bool {
        return self.running;
    }
    
    pub fn requestQuit(self: *App) void {
        self.running = false;
    }
};
```

---

## Performance Notes

- **Single draw call:** All primitives are batched and rendered in one GPU draw call per frame
- **Batch capacity:** 10,000 vertices (3,333 triangles) per frame
- **Vertex format:** 24 bytes per vertex (position + RGBA color)
- **Immediate mode:** No scene graph; redraw everything each frame

---

## Limitations

- **No alpha blending:** Pipeline uses opaque blend state (alpha channel stored but not composited)
- **No textures:** Vertex color only
- **Convex polygons only:** `fillPolygon` uses fan triangulation
- **No text rendering:** Not yet implemented
