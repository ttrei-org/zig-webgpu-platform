# API Reference: zig-webgpu-platform

Comprehensive reference for application developers building graphical Zig programs on this platform.

---

## Using as a Library

zig-webgpu-platform can be used as a dependency in your own Zig projects.

### Adding the Dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_webgpu_platform = .{
        .url = "git+https://github.com/ttrei-org/zig-webgpu-platform.git#master",
        .hash = "...", // Use `zig fetch --save <url>` to compute the hash
    },
}
```

### Configuring build.zig

```zig
const platform_dep = b.dependency("zig_webgpu_platform", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("platform", platform_dep.module("zig-webgpu-platform"));

// For native (desktop) builds, link Dawn, GLFW, and system SDK dependencies:
const platform_build = @import("zig_webgpu_platform");
platform_build.linkNativeDeps(platform_dep, exe);
```

`linkNativeDeps` resolves all transitive native dependencies (Dawn prebuilt libraries, GLFW, system SDKs, C++ sources) through the platform's own builder, so consumer projects don't need to list them in their `build.zig.zon`. Only call it for native targets — WASM builds don't need it.

### Library Import Pattern

```zig
const platform = @import("platform");

// Drawing types
const Canvas = platform.Canvas;
const Viewport = platform.Viewport;
const Color = platform.Color;

// Application interface
const AppInterface = platform.AppInterface;

// Input types
const MouseState = platform.MouseState;
const MouseButton = platform.MouseButton;
const Key = platform.Key;

// Platform runner
const run = platform.run;
const RunOptions = platform.RunOptions;
```

### Minimal Example (Native)

`platform.run()` works on both native and WASM targets. On native it creates a GLFW window and runs the render loop directly. On WASM it creates a WebPlatform, initializes the WebGPU renderer, sets up the swap chain, and starts the emscripten main loop. Consumer code calls `platform.run(&iface, options)` in both cases.

```zig
const std = @import("std");
const platform = @import("platform");

const Canvas = platform.Canvas;
const Color = platform.Color;
const AppInterface = platform.AppInterface;
const MouseState = platform.MouseState;

pub const MyApp = struct {
    running: bool = true,

    pub fn init() MyApp {
        return .{};
    }

    pub fn appInterface(self: *MyApp) AppInterface {
        return .{
            .context = @ptrCast(self),
            .updateFn = &updateImpl,
            .renderFn = &renderImpl,
            .isRunningFn = &isRunningImpl,
            .requestQuitFn = &requestQuitImpl,
            .deinitFn = &deinitImpl,
            .shouldTakeScreenshotFn = null,
            .onScreenshotCompleteFn = null,
        };
    }

    fn updateImpl(iface: *AppInterface, delta_time: f32, mouse: MouseState) void {
        _ = delta_time;
        _ = mouse;
        _ = iface;
    }

    fn renderImpl(iface: *AppInterface, canvas: *Canvas) void {
        _ = iface;
        // Draw a blue background
        canvas.fillRect(0, 0, canvas.viewport.logical_width, canvas.viewport.logical_height, Color.fromHex(0x87CEEB));
        // Draw a red circle in the center
        canvas.fillCircle(200, 150, 30, Color.red, 32);
    }

    fn isRunningImpl(iface: *const AppInterface) bool {
        const self: *const MyApp = @ptrCast(@alignCast(iface.context));
        return self.running;
    }

    fn requestQuitImpl(iface: *AppInterface) void {
        const self: *MyApp = @ptrCast(@alignCast(iface.context));
        self.running = false;
    }

    fn deinitImpl(iface: *AppInterface) void {
        _ = iface;
    }
};

pub fn main() void {
    var app = MyApp.init();
    var iface = app.appInterface();
    defer iface.deinit();

    platform.run(&iface, .{
        .viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },
        .width = 800,
        .height = 600,
        .window_title = "My App",
    });
}
```

---

### WASM Entry Point

WASM targets require additional boilerplate in `src/main.zig` because emscripten doesn't support threads or stderr. The key requirements:

1. **`std_options`** — custom no-op `logFn` (default uses `Thread.getCurrentId()`, unavailable on emscripten)
2. **`panic`** — custom panic namespace using `@trap()` (no stderr on emscripten)
3. **`main`** — conditional: native uses `nativeMain`, WASM uses an empty struct
4. **`wasm_main`** — exported entry using static storage (emscripten main loop doesn't return)
5. **`_start`** — no-op stub to satisfy `std.start` checks on WASM

```zig
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");

const Canvas = platform.Canvas;
const Color = platform.Color;
const AppInterface = platform.AppInterface;
const MouseState = platform.MouseState;

const is_wasm = builtin.cpu.arch.isWasm();

// WASM overrides: the default std.log and panic handlers use threads/stderr
// which are not supported on wasm32-emscripten.
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = if (is_wasm) wasmLogFn else std.log.defaultLog,
};

fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

pub const panic = if (is_wasm) WasmPanic else std.debug.FullPanic(std.debug.defaultPanic);

const WasmPanic = struct {
    pub fn call(_: []const u8, _: ?usize) noreturn { @trap(); }
    pub fn sentinelMismatch(_: anytype, _: anytype) noreturn { @trap(); }
    pub fn unwrapError(_: anyerror) noreturn { @trap(); }
    pub fn outOfBounds(_: usize, _: usize) noreturn { @trap(); }
    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn { @trap(); }
    pub fn inactiveUnionField(_: anytype, _: anytype) noreturn { @trap(); }
    pub fn sliceCastLenRemainder(_: usize) noreturn { @trap(); }
    pub fn reachedUnreachable() noreturn { @trap(); }
    pub fn unwrapNull() noreturn { @trap(); }
    pub fn castToNull() noreturn { @trap(); }
    pub fn incorrectAlignment() noreturn { @trap(); }
    pub fn invalidErrorCode() noreturn { @trap(); }
    pub fn integerOutOfBounds() noreturn { @trap(); }
    pub fn integerOverflow() noreturn { @trap(); }
    pub fn shlOverflow() noreturn { @trap(); }
    pub fn shrOverflow() noreturn { @trap(); }
    pub fn divideByZero() noreturn { @trap(); }
    pub fn exactDivisionRemainder() noreturn { @trap(); }
    pub fn integerPartOutOfBounds() noreturn { @trap(); }
    pub fn corruptSwitch() noreturn { @trap(); }
    pub fn shiftRhsTooBig() noreturn { @trap(); }
    pub fn invalidEnumValue() noreturn { @trap(); }
    pub fn forLenMismatch() noreturn { @trap(); }
    pub fn copyLenMismatch() noreturn { @trap(); }
    pub fn memcpyAlias() noreturn { @trap(); }
    pub fn noreturnReturned() noreturn { @trap(); }
};

pub const MyApp = struct {
    // ... (same App struct as native example above)
};

// For WASM builds, we need a custom entry point.
pub const main = if (!is_wasm) nativeMain else struct {};

fn nativeMain() void {
    var app = MyApp.init();
    var iface = app.appInterface();
    defer iface.deinit();

    platform.run(&iface, .{
        .viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },
        .width = 800,
        .height = 600,
        .window_title = "My App",
    });
}

// WASM entry point: static storage because emscripten_set_main_loop doesn't return.
const wasm_entry = if (is_wasm) struct {
    var static_app: MyApp = undefined;
    var static_iface: AppInterface = undefined;

    pub fn wasm_main() callconv(.c) void {
        static_app = MyApp.init();
        static_iface = static_app.appInterface();
        platform.run(&static_iface, .{
            .viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },
        });
    }
} else struct {};

comptime {
    if (is_wasm) {
        @export(&wasm_entry.wasm_main, .{ .name = "wasm_main" });
    }
}

pub const _start = if (is_wasm) struct {
    fn entry() callconv(.c) void {}
}.entry else {};
```

The build.zig must also export the `wasm_main` symbol and disable the default entry for WASM:

```zig
if (is_wasm) {
    exe.root_module.export_symbol_names = &.{"wasm_main"};
    exe.entry = .disabled;
}
```

---

## Overview

For internal development or direct source imports, applications interact with the platform through these modules:

| Module | Purpose |
|--------|---------|
| `lib.zig` | **Public API surface** - re-exports all public types |
| `canvas.zig` | 2D shape drawing API (Canvas, Viewport) |
| `color.zig` | Color type with factory methods and constants |
| `app_interface.zig` | Application lifecycle interface |
| `platform.zig` | Input types (MouseState, MouseButton, Key) |

Direct import pattern (internal use):
```zig
const lib = @import("lib.zig");
const Canvas = lib.Canvas;
const Color = lib.Color;
const Viewport = lib.Viewport;
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

A more complete native-only example showing mouse-following behavior (see [WASM Entry Point](#wasm-entry-point) above for cross-platform boilerplate):

```zig
const std = @import("std");
const platform = @import("platform");

const Canvas = platform.Canvas;
const Color = platform.Color;
const AppInterface = platform.AppInterface;
const MouseState = platform.MouseState;

pub const App = struct {
    running: bool = true,
    ball_x: f32 = 200.0,
    ball_y: f32 = 150.0,

    pub fn init() App {
        return .{};
    }

    pub fn appInterface(self: *App) AppInterface {
        return .{
            .context = @ptrCast(self),
            .updateFn = &updateImpl,
            .renderFn = &renderImpl,
            .isRunningFn = &isRunningImpl,
            .requestQuitFn = &requestQuitImpl,
            .deinitFn = &deinitImpl,
            .shouldTakeScreenshotFn = null,
            .onScreenshotCompleteFn = null,
        };
    }

    fn updateImpl(iface: *AppInterface, delta_time: f32, mouse: MouseState) void {
        const self: *App = @ptrCast(@alignCast(iface.context));
        // Move ball toward mouse
        self.ball_x += (mouse.x - self.ball_x) * delta_time * 5.0;
        self.ball_y += (mouse.y - self.ball_y) * delta_time * 5.0;
    }

    fn renderImpl(iface: *AppInterface, canvas: *Canvas) void {
        _ = iface;
        // Sky background
        canvas.fillRect(0, 0, canvas.viewport.logical_width, canvas.viewport.logical_height, Color.fromHex(0x87CEEB));

        // Ball following mouse
        canvas.fillCircle(200, 150, 20.0, Color.red, 32);

        // Border
        canvas.strokeRect(10, 10, canvas.viewport.logical_width - 20, canvas.viewport.logical_height - 20, 2.0, Color.black);
    }

    fn isRunningImpl(iface: *const AppInterface) bool {
        const self: *const App = @ptrCast(@alignCast(iface.context));
        return self.running;
    }

    fn requestQuitImpl(iface: *AppInterface) void {
        const self: *App = @ptrCast(@alignCast(iface.context));
        self.running = false;
    }

    fn deinitImpl(iface: *AppInterface) void {
        _ = iface;
    }
};

pub fn main() void {
    var app = App.init();
    var iface = app.appInterface();
    defer iface.deinit();

    platform.run(&iface, .{
        .viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },
        .width = 800,
        .height = 600,
        .window_title = "Ball Demo",
    });
}
```

---

## Performance Notes

- **Single draw call:** All primitives are batched and rendered in one GPU draw call per frame
- **Batch capacity:** 10,000 vertices (3,333 triangles) per frame
- **Vertex format:** 24 bytes per vertex (position + RGBA color)
- **Immediate mode:** No scene graph; redraw everything each frame

---

## RunOptions

Configuration for `platform.run()`. On native, it creates a GLFW window, initializes Dawn WebGPU, and runs the render loop. On WASM, it creates a WebPlatform, initializes the WebGPU renderer, sets up the swap chain, and starts the emscripten main loop. The same `RunOptions` struct is used on both targets.

```zig
pub const RunOptions = struct {
    /// Logical viewport dimensions for drawing (default: 400x300)
    viewport: Viewport = .{ .logical_width = 400.0, .logical_height = 300.0 },

    /// If set, take a screenshot to this filename and exit
    screenshot_filename: ?[]const u8 = null,

    /// Run in headless mode (no window display)
    headless: bool = false,

    /// Window/framebuffer width in pixels (default: 800)
    width: u32 = 800,

    /// Window/framebuffer height in pixels (default: 600)
    height: u32 = 600,

    /// Window title (desktop only)
    window_title: [:0]const u8 = "Zig WebGPU Application",
};
```

**Command-line overrides (native only):** The runner accepts these CLI arguments:
- `--screenshot=<path>` - Take screenshot and exit
- `--headless` - Run without a window
- `--width=N` - Set window width
- `--height=N` - Set window height

---

## Limitations

- **No alpha blending:** Pipeline uses opaque blend state (alpha channel stored but not composited)
- **No textures:** Vertex color only
- **Convex polygons only:** `fillPolygon` uses fan triangulation
- **No text rendering:** Not yet implemented
