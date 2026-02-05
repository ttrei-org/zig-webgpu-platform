# Design Specification: zig-webgpu-platform

A cross-platform, GPU-accelerated 2D graphics platform built on WebGPU with Zig.

**Ultimate goal:** A robust 2D graphics platform with a well-defined, documented API that application developers can build upon without touching rendering or platform internals.

---

## 1. System Overview

The platform provides a layered architecture where each layer has a single responsibility and a clean boundary. Application code interacts exclusively with the **Canvas API** — a resolution-independent, immediate-mode 2D drawing interface. Everything below Canvas (GPU pipeline, platform windowing, render targets) is an implementation detail.

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Code                        │
│              (uses Canvas + Color + Viewport)                │
├─────────────────────────────────────────────────────────────┤
│                      Canvas API                             │  ← Public API surface
│         fillRect · fillCircle · drawLine · ...              │
├─────────────────────────────────────────────────────────────┤
│                      Renderer                               │  ← Internal
│   Triangle batching · GPU pipeline · Frame lifecycle        │
├──────────────────────┬──────────────────────────────────────┤
│    Render Targets    │          Platform                    │  ← Internal
│  SwapChain/Offscreen │  Input · Windowing · Events          │
├──────────────────────┼──────────┬───────────┬───────────────┤
│      WebGPU          │  Desktop │  Web      │  Headless     │  ← Backends
│  (Dawn / Browser)    │  (GLFW)  │  (WASM)   │  (synthetic)  │
└──────────────────────┴──────────┴───────────┴───────────────┘
```

### Design Principles

1. **Canvas is the API.** Application code should never import `renderer.zig` or `platform.zig` directly. Canvas + Color + Viewport are the public contract.
2. **Resolution independence.** Applications draw in a logical coordinate space (e.g. 400×300). The platform scales to any physical resolution automatically.
3. **Immediate mode.** Each frame, the application issues draw commands from scratch. No retained scene graph, no widget state inside the platform.
4. **Backend transparency.** The same application code runs on desktop, web, and headless without `if (is_web)` branches.
5. **Single draw call.** All primitives decompose to triangles and are flushed in one batched GPU draw call per frame.

---

## 2. Layer Definitions

### 2.1 Canvas API (Public)

**Module:** `canvas.zig`
**Role:** The sole public drawing interface for application code.

The Canvas wraps a Renderer pointer and a Viewport, providing shape-drawing methods that decompose geometry into triangles internally. Applications receive a `*Canvas` each frame and draw onto it.

**Current API surface:**

| Method | Description |
|---|---|
| `fillTriangle(positions, colors)` | Filled triangle with per-vertex colors |
| `fillRect(x, y, w, h, color)` | Solid axis-aligned rectangle |
| `fillRectGradient(x, y, w, h, tl, tr, bl, br)` | Rectangle with per-corner color gradient |
| `fillCircle(cx, cy, radius, color, segments)` | Circle approximated as triangle fan |
| `drawLine(x1, y1, x2, y2, thickness, color)` | Line segment with thickness |
| `fillPolygon(points, color)` | Convex polygon via fan triangulation |

**Coordinate system:** Origin top-left, X-right, Y-down, in logical viewport units (not pixels).

**Supporting types (also public):**

| Type | Module | Description |
|---|---|---|
| `Color` | `renderer.zig` (re-exported via `canvas.zig`) | RGBA float color with named constants and factory methods (`fromHex`, `fromRgb8`, `rgb`, `rgba`) |
| `Viewport` | `canvas.zig` | Logical drawing area dimensions (`logical_width`, `logical_height`) |

**Gaps and future additions (planned):**
- `strokeRect` — outlined rectangle
- `strokeCircle` — outlined circle / arc
- `fillRoundedRect` — rounded corners
- `drawPolyline` — connected line strip
- `fillConcavePolygon` — ear-clipping or stencil-based concave fill
- Text rendering (separate subsystem)
- Alpha blending (requires pipeline state change)
- Z-ordering / draw layers

### 2.2 Renderer (Internal)

**Module:** `renderer.zig`
**Role:** Manages all WebGPU state and the per-frame render pipeline.

The Renderer owns the GPU device, pipeline, buffers, and command encoding. It exposes a narrow interface consumed by the frame orchestrator (`main.zig`):

| Operation | Description |
|---|---|
| `init` / `initHeadless` / `initWeb` | Backend-specific GPU initialization |
| `deinit` | Resource cleanup |
| `beginFrame(target)` → `FrameState` | Acquire texture view, create command encoder |
| `endFrame(frame_state, target)` | Submit command buffer, present |
| `setLogicalSize(w, h)` | Upload viewport dimensions to uniform buffer |
| `beginRenderPass` / `endRenderPass` | Render pass lifecycle |
| `queueTriangle(positions, colors)` | Enqueue one triangle (called by Canvas) |
| `flushBatch(render_pass)` | Upload all queued vertices, issue single draw |
| `screenshot(path)` | Capture current frame to PNG |

**Key internals:**
- **Vertex format:** 24 bytes per vertex — `position: [2]f32`, `color: [4]f32`
- **Batch capacity:** 10,000 vertices (3,333 triangles per frame)
- **Shader:** `triangle.wgsl` — transforms logical screen coords → NDC using uniform `screen_size`
- **Draw commands:** Accumulated in `ArrayList(DrawCommand)`, converted to vertices on flush
- **Single pipeline:** One render pipeline, one vertex buffer, one uniform bind group

**Current limitations:**
- No alpha blending (pipeline uses opaque blend state)
- No texture support (vertex color only)
- Single shader / single pipeline (no material system)
- Vertex buffer is rewritten every frame (no instancing or persistent geometry)

### 2.3 Render Targets (Internal)

**Module:** `render_target.zig`
**Role:** Abstracts where frames are rendered to.

Uses a vtable-based interface (`RenderTarget`) with two implementations:

| Implementation | Use Case |
|---|---|
| `SwapChainRenderTarget` | Windowed and web rendering — wraps the swap chain, supports resize |
| `OffscreenRenderTarget` | Headless rendering — BGRA8 texture + staging buffer for CPU readback |

The render target interface provides: `getTextureView`, `getDimensions`, `present`, `needsResize`, `resize`.

### 2.4 Platform (Internal)

**Module:** `platform.zig` + `platform/*.zig`
**Role:** Windowing, input, and event loop abstraction.

The `Platform` struct uses a function-pointer vtable for runtime polymorphism across three backends:

| Backend | Module | Description |
|---|---|---|
| Desktop | `platform/desktop.zig` | GLFW window, native input callbacks |
| Web | `platform/web.zig` | Emscripten bindings, browser canvas events, WebGPU async init |
| Headless | `platform/headless.zig` | Synthetic input, limited frame count, no display |

**Platform interface:**

| Method | Description |
|---|---|
| `pollEvents()` | Process pending input |
| `shouldQuit()` | Check for close request |
| `getMouseState()` | Position + 3-button state |
| `isKeyPressed(key)` | Keyboard polling |
| `getWindowSize()` / `getFramebufferSize()` | Dimensions (may differ on HiDPI) |
| `getWindow()` | Native window handle (desktop only) |

**Input types:**
- `MouseState` — position + buttons with `buttonJustPressed` / `buttonJustReleased` helpers
- `MouseButton` — `left`, `right`, `middle`
- `Key` — `escape`, `space`, `enter`, arrows
- `PlatformEvent` — tagged union: `none`, `quit`, `mouse_move`, `mouse_button`

### 2.5 Frame Orchestrator

**Module:** `main.zig`
**Role:** Wires everything together and owns the frame loop.

The `runFrame()` function is the single source of truth for the per-frame pipeline:

```
beginFrame → setLogicalSize → beginRenderPass → app.render(canvas) → flushBatch → endRenderPass → [pre-submit hook] → endFrame
```

Three entry paths call `runFrame`:
1. **`runWindowed`** — GLFW event loop with delta time and resize handling
2. **`runHeadless`** — Fixed frame count with staging buffer copy hook
3. **`wasm_main` + callback** — `emscripten_set_main_loop` + `requestAnimationFrame`

---

## 3. Data Flow

### 3.1 Per-Frame Rendering Pipeline

```
Application                Canvas              Renderer              GPU
    │                        │                     │                   │
    │  render(canvas) ──────►│                     │                   │
    │                        │  queueTriangle() ──►│ (appends to       │
    │                        │  queueTriangle() ──►│  draw_commands)   │
    │                        │  queueTriangle() ──►│                   │
    │                        │                     │                   │
    │                        │       flushBatch() ─┤                   │
    │                        │                     │  writeBuffer() ──►│ (vertex upload)
    │                        │                     │  draw(N) ────────►│ (single draw call)
    │                        │                     │                   │
```

### 3.2 Coordinate Transform Pipeline

```
Application draws at:     Logical coords (e.g. 200.0, 150.0 in a 400×300 viewport)
        │
        ▼
Vertex buffer contains:   Logical coords as-is (f32 pairs)
        │
        ▼
Vertex shader reads:      uniform screen_size = (400.0, 300.0) ← setLogicalSize()
                          ndc_x = (200.0 / 400.0) * 2.0 - 1.0 = 0.0
                          ndc_y = 1.0 - (150.0 / 300.0) * 2.0 = 0.0
        │
        ▼
Rasterizer maps:          NDC → physical framebuffer pixels (automatic)
```

The key insight: `setLogicalSize` sends the *logical* viewport dimensions (not physical pixel dimensions) to the shader uniform. This means the shader maps logical coordinates to NDC, and the GPU's viewport transform handles the final stretch to physical pixels. Applications never know about physical resolution.

### 3.3 Input Pipeline

```
OS/Browser Event → Platform Backend → MouseState / Key poll → App.update()
                                                                  │
                                                         prev vs current
                                                         (just-pressed detection)
```

Mouse coordinates from the platform are in logical viewport space (the web backend does CSS→canvas coordinate conversion; the desktop backend provides raw pixel coords which currently map 1:1 to logical if the window matches the viewport).

---

## 4. Cross-Platform Strategy

### 4.1 Build Targets

| Target | Windowing | WebGPU Provider | Entry Point |
|---|---|---|---|
| `x86_64-linux` | GLFW + X11 | Dawn (prebuilt) | `nativeMain()` |
| `x86_64-windows` | GLFW + Win32 | Dawn (prebuilt) | `nativeMain()` |
| `aarch64-macos` | GLFW + Cocoa | Dawn (prebuilt) | `nativeMain()` |
| `wasm32-emscripten` | Browser canvas | `navigator.gpu` | `wasm_main()` (JS calls) |

### 4.2 Web Architecture

The web build is notable for **not requiring the Emscripten SDK**. Instead:

- `platform/web.zig` declares `extern` Emscripten functions directly (bypassing `std.os.emscripten` and libc)
- `web/wasm_bindings.js` implements a complete WebGPU JavaScript bridge:
  - Handle registry mapping integer handles (WASM) ↔ JS WebGPU objects
  - All `wgpu*` functions (instance, adapter, device, pipeline, buffers, render pass)
  - Emscripten stubs (`emscripten_set_main_loop` → `requestAnimationFrame`)
  - Pre-initialization: creates adapter + device *before* WASM loads (solves async gap)

### 4.3 Headless Architecture

Headless mode enables CI/automated testing without a display:
- `HeadlessPlatform` provides synthetic input and a limited frame count
- `OffscreenRenderTarget` renders to a texture with a staging buffer for CPU readback
- A `PreSubmitHook` copies the rendered texture to the staging buffer before command submission
- `zigimg` encodes the pixel data to PNG
- Invoked via: `xvfb-run zig build run -- --headless --screenshot=/tmp/out.png`

---

## 5. Public API Contract (Current)

This section defines what application developers depend on. Everything else is an implementation detail that may change.

### 5.1 Types

```zig
// From canvas.zig
const Canvas = struct {
    viewport: Viewport,
    fn fillTriangle(self, positions: [3][2]f32, colors: [3]Color) void;
    fn fillRect(self, x: f32, y: f32, w: f32, h: f32, color: Color) void;
    fn fillRectGradient(self, x: f32, y: f32, w: f32, h: f32, tl: Color, tr: Color, bl: Color, br: Color) void;
    fn fillCircle(self, cx: f32, cy: f32, radius: f32, color: Color, segments: u16) void;
    fn drawLine(self, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: Color) void;
    fn fillPolygon(self, points: []const [2]f32, color: Color) void;
};

const Viewport = struct {
    logical_width: f32,
    logical_height: f32,
};

// From renderer.zig (re-exported through canvas.zig)
const Color = struct {
    r: f32, g: f32, b: f32, a: f32 = 1.0,

    // Named constants
    const white, black, red, green, blue, yellow, cyan, magenta;

    // Factories
    fn fromHex(hex: u24) Color;
    fn fromHexRgba(hex: u32) Color;
    fn fromRgb8(r: u8, g: u8, b: u8) Color;
    fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Color;
    fn rgb(r: f32, g: f32, b: f32) Color;
    fn rgba(r: f32, g: f32, b: f32, a: f32) Color;
    fn toRgb(self) [3]f32;
    fn toRgba(self) [4]f32;
};
```

### 5.2 Application Lifecycle

The platform interacts with the application through an `AppInterface` vtable (defined in `app_interface.zig`), enabling runtime polymorphism over application implementations. The concrete `App` in `app.zig` is one such implementation, which provides an `appInterface()` method returning the vtable. This decouples the platform from any specific application struct.

```zig
// The platform calls these on the application each frame (via AppInterface vtable):

fn update(delta_time: f32, mouse_state: MouseState) void;  // State update
fn render(canvas: *Canvas) void;                            // Draw commands
```

### 5.3 Input Types

```zig
const MouseState = struct {
    x: f32, y: f32,
    left_pressed: bool, right_pressed: bool, middle_pressed: bool,
    fn isPressed(self, button: MouseButton) bool;
    fn buttonJustPressed(current, prev, button) bool;
    fn buttonJustReleased(current, prev, button) bool;
};

const MouseButton = enum { left, right, middle };
const Key = enum { escape, space, enter, up, down, left, right };
```

---

## 6. Architectural Decisions and Rationale

### Why immediate mode?
Simplicity. No retained state to synchronize, no invalidation logic, no widget lifecycle. The application is the source of truth — it draws what it wants each frame. This is appropriate for a 2D graphics platform (as opposed to a UI toolkit).

### Why triangle-only primitives?
WebGPU's `triangle-list` topology is the most flexible and universally supported. All 2D shapes decompose cleanly to triangles. A single pipeline with one draw call per frame keeps the GPU state machine simple and fast.

### Why vtable-based polymorphism?
Zig has no interfaces or traits. Function-pointer vtables are the idiomatic approach for runtime polymorphism. The vtable cost is negligible (one indirect call per method per frame) and enables clean backend substitution.

### Why not use the Emscripten SDK for web?
Eliminating the Emscripten SDK dependency simplifies the toolchain (only `zig build` is needed) and reduces binary size. The JS bridge (`wasm_bindings.js`) is ~1500 lines but gives full control over WebGPU initialization and handle management.

### Why logical coordinates instead of pixels?
Resolution independence. Applications draw at a fixed logical size, and the platform handles DPI scaling. This avoids every application needing to handle HiDPI, window resize, and cross-platform resolution differences.

---

## 8. File Map

| File | Lines | Role | Layer |
|---|---|---|---|
| `src/canvas.zig` | 218 | Shape drawing API | **Public API** |
| `src/renderer.zig` | 2426 | WebGPU rendering | Internal |
| `src/render_target.zig` | 788 | Render target abstraction | Internal |
| `src/platform.zig` | 311 | Platform interface | Internal |
| `src/platform/desktop.zig` | 343 | GLFW backend | Internal |
| `src/platform/web.zig` | 1571 | Browser/WASM backend | Internal |
| `src/platform/headless.zig` | 222 | Headless backend | Internal |
| `src/main.zig` | 711 | Frame orchestration + entry | Internal |
| `src/app.zig` | 743 | Demo application | Example/Demo |
| `src/app_interface.zig` | 120 | Application interface (vtable) | Internal |
| `src/shaders/triangle.wgsl` | 69 | GPU shader | Internal |
| `web/index.html` | 198 | Web host page | Web infra |
| `web/wasm_bindings.js` | 1527 | JS WebGPU bridge | Web infra |
| `build.zig` | 203 | Build configuration | Build |
