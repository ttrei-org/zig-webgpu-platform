# Implementation Plan

Based on [spec.md](./spec.md) with scoped-down requirements.

## Scope Summary

- **Primitives:** Triangles only (other primitives deferred)
- **Input:** Mouse only (position + buttons), unified across desktop/web
- **Game loop:** Simple render loop (no fixed timestep)
- **Headless mode:** CLI flag, explicit screenshot API, PNG output
- **Platforms:** Desktop (Linux/Windows) + Web (WASM/Emscripten)
- **Omitted:** Touch input, performance profiling, bezier curves

---

## Phase 1: Project Setup & Minimal Triangle

### 1.1 Project Initialization

- [ ] **1.1.1** Create `build.zig.zon` with project metadata
- [ ] **1.1.2** Add zgpu dependency to `build.zig.zon`
- [ ] **1.1.3** Add zglfw dependency to `build.zig.zon`
- [ ] **1.1.4** Create `build.zig` with basic executable target
- [ ] **1.1.5** Configure zgpu module in build
- [ ] **1.1.6** Configure zglfw module in build (desktop only)
- [ ] **1.1.7** Create `src/main.zig` stub that compiles
- [ ] **1.1.8** Verify `zig build` succeeds

**Dependencies:** None

### 1.2 Window Creation (Desktop)

- [ ] **1.2.1** Create `src/platform/desktop.zig`
- [ ] **1.2.2** Initialize GLFW
- [ ] **1.2.3** Create window with title and dimensions
- [ ] **1.2.4** Implement window close detection
- [ ] **1.2.5** Create main loop that polls events
- [ ] **1.2.6** Implement graceful shutdown (destroy window, terminate GLFW)
- [ ] **1.2.7** Verify window opens and closes cleanly

**Dependencies:** 1.1

### 1.3 WebGPU Initialization

- [ ] **1.3.1** Create `src/renderer.zig` with Renderer struct
- [ ] **1.3.2** Request WebGPU adapter from zgpu
- [ ] **1.3.3** Request WebGPU device from adapter
- [ ] **1.3.4** Create swap chain from GLFW window surface
- [ ] **1.3.5** Store device, queue, swap chain in Renderer
- [ ] **1.3.6** Implement Renderer.deinit for cleanup
- [ ] **1.3.7** Verify WebGPU initializes without errors

**Dependencies:** 1.2

### 1.4 Clear Screen

- [ ] **1.4.1** Create Renderer.beginFrame method
- [ ] **1.4.2** Get current swap chain texture view
- [ ] **1.4.3** Create command encoder
- [ ] **1.4.4** Begin render pass with clear color
- [ ] **1.4.5** End render pass (empty for now)
- [ ] **1.4.6** Create Renderer.endFrame method
- [ ] **1.4.7** Submit command buffer to queue
- [ ] **1.4.8** Present swap chain
- [ ] **1.4.9** Verify window shows solid color

**Dependencies:** 1.3

### 1.5 Triangle Shader

- [ ] **1.5.1** Create `shaders/triangle.wgsl`
- [ ] **1.5.2** Define vertex input struct (position: vec2, color: vec3)
- [ ] **1.5.3** Write vertex shader (pass through position, output color)
- [ ] **1.5.4** Write fragment shader (output interpolated color)
- [ ] **1.5.5** Add screen-space to clip-space transform in vertex shader

**Dependencies:** 1.4

### 1.6 Triangle Pipeline

- [ ] **1.6.1** Load shader module from WGSL file
- [ ] **1.6.2** Define vertex buffer layout (position + color attributes)
- [ ] **1.6.3** Create pipeline layout (empty for now)
- [ ] **1.6.4** Create render pipeline with shader and vertex layout
- [ ] **1.6.5** Store pipeline in Renderer
- [ ] **1.6.6** Verify pipeline creation succeeds

**Dependencies:** 1.5

### 1.7 Triangle Rendering

- [ ] **1.7.1** Define Vertex struct in Zig (position: [2]f32, color: [3]f32)
- [ ] **1.7.2** Create hardcoded triangle vertex data (3 vertices)
- [ ] **1.7.3** Create vertex buffer with triangle data
- [ ] **1.7.4** In render pass, set pipeline
- [ ] **1.7.5** In render pass, set vertex buffer
- [ ] **1.7.6** In render pass, draw 3 vertices
- [ ] **1.7.7** Verify colored triangle renders on screen

**Dependencies:** 1.6

### 1.8 Uniforms for Coordinate Transform

- [ ] **1.8.1** Define Uniforms struct (screen_size: vec2)
- [ ] **1.8.2** Create uniform buffer
- [ ] **1.8.3** Create bind group layout for uniforms
- [ ] **1.8.4** Create bind group with uniform buffer
- [ ] **1.8.5** Update pipeline layout to include bind group
- [ ] **1.8.6** Update shader to use uniforms for NDC transform
- [ ] **1.8.7** Update uniform buffer on window resize
- [ ] **1.8.8** Verify triangle uses screen coordinates (0,0 = top-left)

**Dependencies:** 1.7

---

## Phase 2: Triangle Primitive API

### 2.1 App Structure

- [ ] **2.1.1** Create `src/app.zig` with App struct
- [ ] **2.1.2** Define App.init method
- [ ] **2.1.3** Define App.deinit method
- [ ] **2.1.4** Define App.update method (empty for now)
- [ ] **2.1.5** Define App.render method receiving Renderer pointer
- [ ] **2.1.6** Move hardcoded triangle draw into App.render
- [ ] **2.1.7** Update main.zig to create App and call its methods

**Dependencies:** 1.8

### 2.2 Draw Command Buffer

- [ ] **2.2.1** Define DrawCommand union (triangle, etc.)
- [ ] **2.2.2** Define Triangle struct (3 positions, 3 colors)
- [ ] **2.2.3** Add command buffer (ArrayList) to Renderer
- [ ] **2.2.4** Implement Renderer.drawTriangle method (appends command)
- [ ] **2.2.5** Clear command buffer at frame start

**Dependencies:** 2.1

### 2.3 Batched Rendering

- [ ] **2.3.1** Create dynamic vertex buffer with max capacity
- [ ] **2.3.2** In endFrame, iterate draw commands
- [ ] **2.3.3** Convert triangle commands to vertices
- [ ] **2.3.4** Upload vertices to GPU buffer
- [ ] **2.3.5** Issue single draw call for all triangles
- [ ] **2.3.6** Verify multiple triangles render correctly

**Dependencies:** 2.2

### 2.4 Color API

- [ ] **2.4.1** Define Color struct (r, g, b, a as f32)
- [ ] **2.4.2** Add named color constants (red, green, blue, white, black)
- [ ] **2.4.3** Add Color.fromRgb helper (u8 inputs)
- [ ] **2.4.4** Add Color.fromHex helper
- [ ] **2.4.5** Update Triangle to use Color type
- [ ] **2.4.6** Update shader for alpha support

**Dependencies:** 2.3

### 2.5 Static Test Pattern

- [ ] **2.5.1** Create test pattern in App.render
- [ ] **2.5.2** Draw triangles in different positions
- [ ] **2.5.3** Draw triangles with different colors
- [ ] **2.5.4** Draw overlapping triangles (test z-order)
- [ ] **2.5.5** Verify test pattern renders correctly

**Dependencies:** 2.4

---

## Phase 3: Input & Simple Loop

### 3.1 Platform Abstraction

- [ ] **3.1.1** Define Platform interface/struct in `src/platform.zig`
- [ ] **3.1.2** Define PlatformEvent union (none, quit, mouse_move, mouse_button)
- [ ] **3.1.3** Define MouseButton enum (left, right, middle)
- [ ] **3.1.4** Define MouseState struct (x, y, buttons pressed)
- [ ] **3.1.5** Define Platform.pollEvents method signature
- [ ] **3.1.6** Define Platform.getMouseState method signature

**Dependencies:** 2.5

### 3.2 Desktop Input Implementation

- [ ] **3.2.1** Store mouse state in desktop platform struct
- [ ] **3.2.2** Register GLFW cursor position callback
- [ ] **3.2.3** Update mouse x/y in callback
- [ ] **3.2.4** Register GLFW mouse button callback
- [ ] **3.2.5** Update button state in callback
- [ ] **3.2.6** Implement pollEvents using GLFW poll
- [ ] **3.2.7** Implement getMouseState returning stored state
- [ ] **3.2.8** Verify mouse position updates correctly
- [ ] **3.2.9** Verify button press/release detected

**Dependencies:** 3.1

### 3.3 Input in App

- [ ] **3.3.1** Pass MouseState to App.update
- [ ] **3.3.2** Store previous mouse state for change detection
- [ ] **3.3.3** Add helper to detect button just pressed
- [ ] **3.3.4** Add helper to detect button just released
- [ ] **3.3.5** Demo: move triangle to mouse position on click
- [ ] **3.3.6** Verify interactive behavior works

**Dependencies:** 3.2

### 3.4 Simple Render Loop

- [ ] **3.4.1** Create main loop structure in platform
- [ ] **3.4.2** Poll events each iteration
- [ ] **3.4.3** Call App.update with delta time
- [ ] **3.4.4** Call App.render
- [ ] **3.4.5** Present frame
- [ ] **3.4.6** Exit loop on quit event
- [ ] **3.4.7** Calculate delta time between frames
- [ ] **3.4.8** Verify smooth rendering with vsync

**Dependencies:** 3.3

---

## Phase 4: Headless Mode

### 4.1 CLI Argument Parsing

- [ ] **4.1.1** Parse command line arguments in main.zig
- [ ] **4.1.2** Detect `--headless` flag
- [ ] **4.1.3** Store headless mode in config struct
- [ ] **4.1.4** Pass config to platform initialization

**Dependencies:** 3.4

### 4.2 Render Target Abstraction

- [ ] **4.2.1** Define RenderTarget interface (texture view + dimensions)
- [ ] **4.2.2** Refactor swap chain to implement RenderTarget
- [ ] **4.2.3** Update Renderer.beginFrame to accept RenderTarget
- [ ] **4.2.4** Verify windowed rendering still works

**Dependencies:** 4.1

### 4.3 Offscreen Render Target

- [ ] **4.3.1** Create texture for offscreen rendering
- [ ] **4.3.2** Configure texture with COPY_SRC usage
- [ ] **4.3.3** Create texture view for rendering
- [ ] **4.3.4** Implement OffscreenTarget struct
- [ ] **4.3.5** Allow setting dimensions via API
- [ ] **4.3.6** Verify offscreen rendering executes without window

**Dependencies:** 4.2

### 4.4 GPU Readback

- [ ] **4.4.1** Create staging buffer for readback (COPY_DST + MAP_READ)
- [ ] **4.4.2** After render, copy texture to staging buffer
- [ ] **4.4.3** Map staging buffer for CPU read
- [ ] **4.4.4** Wait for map to complete
- [ ] **4.4.5** Read pixel data from mapped buffer
- [ ] **4.4.6** Unmap buffer after read
- [ ] **4.4.7** Verify pixel data is accessible

**Dependencies:** 4.3

### 4.5 PNG Export

- [ ] **4.5.1** Add zigimg or stb_image_write dependency
- [ ] **4.5.2** Convert BGRA/RGBA pixel data to PNG format
- [ ] **4.5.3** Implement Renderer.screenshot(path) method
- [ ] **4.5.4** Write PNG file to disk
- [ ] **4.5.5** Verify PNG opens in image viewer correctly

**Dependencies:** 4.4

### 4.6 Headless Platform

- [ ] **4.6.1** Create `src/platform/headless.zig`
- [ ] **4.6.2** Initialize WebGPU without window/surface
- [ ] **4.6.3** Implement dummy pollEvents (returns quit after N frames)
- [ ] **4.6.4** Implement dummy getMouseState (fixed position)
- [ ] **4.6.5** Update main.zig to select platform based on --headless
- [ ] **4.6.6** Verify headless mode runs and exits cleanly

**Dependencies:** 4.5

### 4.7 Headless Integration

- [ ] **4.7.1** In headless mode, use offscreen render target
- [ ] **4.7.2** Expose screenshot API to App
- [ ] **4.7.3** App calls screenshot at appropriate time
- [ ] **4.7.4** Test: run headless, verify PNG contains test pattern
- [ ] **4.7.5** Verify PNG matches windowed rendering

**Dependencies:** 4.6

---

## Phase 5: Web Build

### 5.1 Build Configuration

- [ ] **5.1.1** Add wasm32-emscripten target to build.zig
- [ ] **5.1.2** Configure Emscripten-specific settings
- [ ] **5.1.3** Disable zglfw for web target
- [ ] **5.1.4** Output .wasm and .js files
- [ ] **5.1.5** Verify `zig build -Dtarget=wasm32-emscripten` compiles

**Dependencies:** 4.7

### 5.2 Web Platform Stub

- [ ] **5.2.1** Create `src/platform/web.zig`
- [ ] **5.2.2** Define Emscripten external function imports
- [ ] **5.2.3** Implement platform init (get canvas, request adapter)
- [ ] **5.2.4** Implement platform deinit
- [ ] **5.2.5** Verify web platform compiles

**Dependencies:** 5.1

### 5.3 Emscripten Main Loop

- [ ] **5.3.1** Use emscripten_set_main_loop for render loop
- [ ] **5.3.2** Store app state in global for callback access
- [ ] **5.3.3** Implement frame callback calling update/render
- [ ] **5.3.4** Handle requestAnimationFrame timing
- [ ] **5.3.5** Verify loop runs in browser

**Dependencies:** 5.2

### 5.4 Web WebGPU Integration

- [ ] **5.4.1** Get WebGPU context from canvas
- [ ] **5.4.2** Request adapter via browser API
- [ ] **5.4.3** Request device from adapter
- [ ] **5.4.4** Create swap chain from canvas context
- [ ] **5.4.5** Verify clear color shows in browser

**Dependencies:** 5.3

### 5.5 Web Mouse Input

- [ ] **5.5.1** Register mousemove event listener via Emscripten
- [ ] **5.5.2** Convert page coordinates to canvas coordinates
- [ ] **5.5.3** Update mouse state x/y
- [ ] **5.5.4** Register mousedown event listener
- [ ] **5.5.5** Register mouseup event listener
- [ ] **5.5.6** Update button state on events
- [ ] **5.5.7** Verify mouse position matches desktop behavior
- [ ] **5.5.8** Verify button clicks work correctly

**Dependencies:** 5.4

### 5.6 HTML Shell

- [ ] **5.6.1** Create `web/index.html` template
- [ ] **5.6.2** Add canvas element with id
- [ ] **5.6.3** Add script tag loading generated .js
- [ ] **5.6.4** Add basic CSS for fullscreen canvas
- [ ] **5.6.5** Add WebGPU feature detection with error message
- [ ] **5.6.6** Verify page loads and runs app

**Dependencies:** 5.5

### 5.7 Web Testing

- [ ] **5.7.1** Create simple local server script (Python http.server)
- [ ] **5.7.2** Document HTTPS requirement for WebGPU
- [ ] **5.7.3** Test in Chrome with WebGPU enabled
- [ ] **5.7.4** Verify triangle renders correctly
- [ ] **5.7.5** Verify mouse input works
- [ ] **5.7.6** Compare output to desktop version

**Dependencies:** 5.6

---

## Task Dependency Graph

```
Phase 1: Setup & Triangle
1.1 → 1.2 → 1.3 → 1.4 → 1.5 → 1.6 → 1.7 → 1.8

Phase 2: Triangle API
1.8 → 2.1 → 2.2 → 2.3 → 2.4 → 2.5

Phase 3: Input & Loop
2.5 → 3.1 → 3.2 → 3.3 → 3.4

Phase 4: Headless
3.4 → 4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7

Phase 5: Web
4.7 → 5.1 → 5.2 → 5.3 → 5.4 → 5.5 → 5.6 → 5.7
```

---

## Notes

- **zgpu/zglfw:** Assumed compatible. Revisit if issues arise during 1.1.
- **PNG library:** Evaluate zigimg vs stb_image_write during 4.5.1.
- **Web testing:** Requires browser with WebGPU support (Chrome 113+, Edge, Firefox nightly).
- **Future work:** Additional primitives (lines, rectangles, circles), keyboard input, fixed timestep game loop.
