# Zig WebGPU Cross-Platform Graphics Project

## Overview

A lightweight 2D graphics framework in Zig using WebGPU, targeting:
- **Desktop:** Linux, Windows (native via Dawn)
- **Web:** Browsers with WebGPU support (Chrome, Edge, Firefox nightly)

## Architecture

### Target Platforms & Backends

| Platform | Build Target | Graphics Backend | Windowing |
|----------|--------------|------------------|-----------|
| Linux | native | Dawn (Vulkan) | GLFW |
| Windows | native | Dawn (D3D12) | GLFW |
| Web | wasm32-emscripten | Browser WebGPU | Emscripten/Canvas |

### Dependencies

- **zgpu** - WebGPU bindings + Dawn integration
- **zglfw** - Window creation and input (desktop only)
- **zigimg** or **stb_image_write** - PNG export for headless mode

### Project Structure

```
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig          # Entry point, CLI parsing, platform dispatch
│   ├── app.zig           # Platform-agnostic application logic
│   ├── renderer.zig      # WebGPU rendering, draw commands, screenshot API
│   ├── platform.zig      # Platform interface definition
│   └── platform/
│       ├── desktop.zig   # GLFW window + mouse input
│       ├── web.zig       # Emscripten bindings
│       └── headless.zig  # Offscreen rendering without window
├── shaders/
│   └── triangle.wgsl     # Shader for triangle rendering
├── web/
│   └── index.html        # HTML shell for web build
└── specs/
    ├── spec.md
    └── implementation-plan.md
```

## Rendering Approach

### Primitives

Initial implementation supports:
- **Triangles** (filled, with per-vertex color)

Additional primitives (lines, rectangles, circles, polygons) deferred to future work.

### Implementation Strategy

1. **Immediate-mode batching:** Collect draw commands per frame
2. **Vertex buffer:** Dynamic buffer updated each frame with geometry
3. **Single shader:** WGSL shader for triangle rendering

### Coordinate System

- Origin at top-left (0, 0)
- Y increases downward (screen coordinates)
- Normalized device coordinates handled in shader via uniforms
- Logical resolution independent of physical pixels

## Input Handling

| Input Type | Desktop | Web |
|------------|---------|-----|
| Mouse position | GLFW callbacks | Emscripten events |
| Mouse buttons | GLFW callbacks | Emscripten events |

Keyboard and touch input deferred to future work.

## Render Loop

Simple render loop with vsync:
- Poll events each frame
- Call App.update with delta time and mouse state
- Call App.render
- Present frame

Fixed timestep game loop deferred to future work.

## Headless Mode

For automated testing and AI agent verification:

- **CLI flag:** `--headless` enables headless mode
- **Offscreen rendering:** Render to texture instead of window
- **Screenshot API:** `Renderer.screenshot(path)` saves PNG to disk
- **Resolution:** Configurable in application code

Usage:
```bash
zig build run -- --headless
```

## Build Commands

### Desktop
```bash
zig build run
```

### Desktop (Headless)
```bash
zig build run -- --headless
```

### Web
```bash
zig build -Dtarget=wasm32-emscripten
```

## Milestones

### Phase 1: Minimal Triangle
- Project setup with zgpu + zglfw
- Window creation (desktop)
- Clear screen to solid color
- Render single triangle via WebGPU
- Uniforms for screen-space coordinates

### Phase 2: Triangle Primitive API
- App structure separating logic from rendering
- Draw command buffer for batched rendering
- Color API with named constants and helpers
- Static test pattern demonstrating triangles

### Phase 3: Input & Simple Loop
- Platform abstraction layer
- Mouse input (position + left/right/middle buttons)
- Simple render loop with delta time
- Interactive demo (triangle follows mouse click)

### Phase 4: Headless Mode
- CLI argument parsing
- Render target abstraction
- Offscreen rendering to texture
- GPU readback to CPU memory
- PNG export via screenshot API
- Headless platform implementation

### Phase 5: Web Build
- Emscripten build configuration
- Web platform with canvas integration
- Emscripten main loop (requestAnimationFrame)
- Browser WebGPU initialization
- Mouse input via Emscripten events
- HTML shell with WebGPU feature detection

## Future Work

- Additional primitives: lines, rectangles, circles, ellipses, polygons, bezier curves
- Keyboard input
- Touch input (web)
- Fixed timestep game loop

## References

- [zgpu](https://github.com/zig-gamedev/zgpu)
- [zglfw](https://github.com/zig-gamedev/zglfw)
- [zig-gamedev samples](https://github.com/zig-gamedev/zig-gamedev/tree/main/samples)
- [WebGPU spec](https://www.w3.org/TR/webgpu/)
- [WGSL spec](https://www.w3.org/TR/WGSL/)
