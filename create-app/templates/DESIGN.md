# Design Specification: {{PROJECT_NAME}}

A 2D graphical application built on [zig-webgpu-platform](https://github.com/ttrei-org/zig-webgpu-platform).

---

## 1. Project Overview

<!-- Describe what your application does and who it is for. -->

---

## 2. Goals & Non-Goals

**Goals:**
- <!-- e.g. Interactive 2D visualization of ... -->
- <!-- e.g. Cross-platform: runs on desktop and web -->

**Non-Goals:**
- <!-- e.g. 3D rendering -->
- <!-- e.g. Networked multiplayer -->

---

## 3. Architecture

This project uses **zig-webgpu-platform** as a library dependency. The platform provides a layered graphics stack:

```
┌─────────────────────────────────────────┐
│           Your Application Code          │
│        (uses Canvas + Color + Input)     │
├─────────────────────────────────────────┤
│     zig-webgpu-platform (library)        │
│  Canvas API → Renderer → WebGPU backend  │
└─────────────────────────────────────────┘
```

Your code interacts only with the **Canvas API** — a resolution-independent, immediate-mode 2D drawing interface. See the platform's [API.md](https://github.com/ttrei-org/zig-webgpu-platform/blob/master/API.md) for the full reference.

---

## 4. Application Structure

The application implements the `AppInterface` vtable pattern:

```zig
pub const App = struct {
    // Application state fields go here

    pub fn init() App { ... }

    // Called each frame with delta time and input state
    fn update(delta_time: f32, mouse: MouseState) void { ... }

    // Called each frame — draw onto the canvas
    fn render(canvas: *Canvas) void { ... }
};
```

**Lifecycle:** `platform.run()` drives the main loop, calling `update` then `render` each frame.

---

## 5. Data Flow

```
Platform polls input
       │
       ▼
App.update(delta_time, mouse_state)   ← Update state
       │
       ▼
App.render(canvas)                     ← Draw commands
       │
       ▼
Platform submits to GPU (one batched draw call)
```

All drawing uses logical coordinates (e.g. 400×300). The platform handles resolution scaling.

---

## 6. Build Targets

| Target | Command | Notes |
|---|---|---|
| Native desktop | `zig build run` | Dawn/GLFW, X11 on Linux |
| WASM/web | `zig build -Dtarget=wasm32-emscripten` | Browser WebGPU, serve with `python3 serve.py` |

Both targets are configured in `build.zig`. The same `src/main.zig` runs on both platforms.

---

## 7. File Map

| File | Role |
|---|---|
| `src/main.zig` | Application entry point and logic |
| `build.zig` | Build configuration |
| `build.zig.zon` | Package manifest (declares platform dependency) |
| `web/index.html` | HTML host page for web build |
| `serve.py` | Development HTTP server for web builds |
| `scripts/web_screenshot.sh` | Automated web screenshot capture |

<!-- Add new files as your project grows -->

---

## 8. Key Design Decisions

<!-- Document important choices and their rationale here. -->
<!-- Example: Why immediate mode? Why this data structure? Why this coordinate system? -->
