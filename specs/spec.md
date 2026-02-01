# Zig WebGPU Cross-Platform Graphics Project

## Overview

A lightweight 2D vector graphics framework in Zig using WebGPU, targeting:
- **Desktop:** Linux, Windows (native via Dawn)
- **Web:** Browsers with WebGPU support (Chrome, Edge, Firefox nightly)
- **Mobile:** Android/iOS via web browser

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

### Project Structure

```
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig          # Entry point, platform dispatch
│   ├── app.zig           # Platform-agnostic game logic
│   ├── renderer.zig      # WebGPU 2D rendering primitives
│   └── platform/
│       ├── desktop.zig   # GLFW window + input handling
│       └── web.zig       # Emscripten bindings
├── shaders/
│   └── vector2d.wgsl     # Shader for 2D vector rendering
└── specs/
    └── spec.md
```

## Rendering Approach

### 2D Vector Primitives

The renderer will support drawing:
- Lines (with configurable width)
- Rectangles (filled, outlined)
- Circles/Ellipses (filled, outlined)
- Triangles/Polygons
- Bezier curves (optional, later)

### Implementation Strategy

1. **Immediate-mode batching:** Collect draw commands per frame, batch by primitive type
2. **Vertex buffer:** Dynamic buffer updated each frame with geometry
3. **Single shader:** WGSL shader handling all 2D primitives

### Coordinate System

- Origin at top-left (0, 0)
- Y increases downward (screen coordinates)
- Normalized device coordinates handled in shader
- Logical resolution independent of physical pixels

## Input Handling

| Input Type | Desktop | Web |
|------------|---------|-----|
| Keyboard | GLFW callbacks | Emscripten events |
| Mouse | GLFW callbacks | Emscripten events |
| Touch | N/A | Emscripten touch events |

## Game Loop

Fixed timestep with interpolated rendering:
- Logic updates at 60 Hz (configurable)
- Rendering at display refresh rate (vsync)
- Accumulator-based update loop

## Build Commands

### Desktop
```bash
zig build run
```

### Web
```bash
zig build -Dtarget=wasm32-emscripten
```

## Milestones

### Phase 1: Minimal Triangle
- [ ] Project setup with zgpu + zglfw
- [ ] Window creation (desktop)
- [ ] Clear screen to solid color
- [ ] Render single triangle via WebGPU

### Phase 2: 2D Primitives
- [ ] Basic vertex shader for 2D
- [ ] Draw lines, rectangles, circles
- [ ] Batched rendering

### Phase 3: Input & Game Loop
- [ ] Keyboard/mouse input abstraction
- [ ] Fixed timestep game loop
- [ ] Basic interactivity demo

### Phase 4: Web Build
- [ ] Emscripten build configuration
- [ ] Web-specific input handling
- [ ] Test in Chrome with WebGPU

### Phase 5: Polish
- [ ] Touch input (web)
- [ ] Performance profiling

## References

- [zgpu](https://github.com/zig-gamedev/zgpu)
- [zglfw](https://github.com/zig-gamedev/zglfw)
- [zig-gamedev samples](https://github.com/zig-gamedev/zig-gamedev/tree/main/samples)
- [WebGPU spec](https://www.w3.org/TR/webgpu/)
- [WGSL spec](https://www.w3.org/TR/WGSL/)
