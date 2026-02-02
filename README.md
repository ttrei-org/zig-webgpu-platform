# Zig GUI Experiment

A cross-platform GUI rendering experiment using Zig and WebGPU.

## Building

### Desktop (Native)

```bash
zig build
zig build run
```

### Web (WASM)

**Note**: The web build requires the Emscripten SDK to be installed. See [Prerequisites](#web-build-prerequisites) below.

```bash
zig build -Dtarget=wasm32-emscripten
```

This produces output in `zig-out/web/` including:
- `bin/zig_gui_experiment.wasm` - The compiled WebAssembly module
- `zig_gui_experiment.js` - JavaScript glue code
- `index.html` - Web page that loads and runs the WASM

#### Web Build Prerequisites

The web build targets `wasm32-emscripten` which requires the Emscripten SDK:

1. **Install Emscripten SDK**:
   ```bash
   git clone https://github.com/emscripten-core/emsdk.git
   cd emsdk
   ./emsdk install latest
   ./emsdk activate latest
   source ./emsdk_env.sh
   ```

2. **Verify installation**:
   ```bash
   emcc --version
   ```

The `std.os.emscripten` module in Zig requires Emscripten's libc implementation. Without the SDK installed, the build will fail with errors like "dependency on libc must be explicitly specified" or "unable to provide libc for target".

**Current Status**: The web build infrastructure (JavaScript glue, HTML loader) is in place, but requires Emscripten SDK installation to compile. Native builds work without any additional dependencies.

## Running the Web Build

Use the included Python server script:

```bash
python serve.py        # Serves on http://localhost:8000
python serve.py 3000   # Use a custom port
```

Then open http://localhost:8000 in a WebGPU-capable browser (Chrome 113+, Edge, Firefox Nightly).

## WebGPU and HTTPS Requirements

WebGPU requires a **secure context** to function. This is a security requirement enforced by browsers.

### What is a Secure Context?

A secure context includes:
- Pages served over HTTPS
- Pages served from `localhost` or `127.0.0.1` (treated as secure for development)
- Pages served from `file://` URLs (in some browsers)

### Local Development

For local development, use `localhost` which browsers treat as secure:

```bash
python serve.py        # Serves on http://localhost:8000
```

Do **not** use your machine's IP address (e.g., `http://192.168.1.100:8000`) as this will fail the secure context check.

### Browser Support

| Browser | WebGPU Support | Notes |
|---------|---------------|-------|
| Chrome 113+ | Full | Enabled by default |
| Edge 113+ | Full | Enabled by default |
| Firefox Nightly | Experimental | Enable via `dom.webgpu.enabled` in `about:config` |
| Safari 17+ | Full | Enabled by default on macOS Sonoma+ |

### Production Deployment

For production, you **must** serve over HTTPS. Options include:
- Use a reverse proxy (nginx, Caddy) with SSL certificates
- Deploy to platforms that provide HTTPS (GitHub Pages, Cloudflare Pages, etc.)
- Use Let's Encrypt for free SSL certificates

### Troubleshooting "WebGPU not available"

If you encounter WebGPU availability issues:

1. **Check secure context**: Ensure you're using `localhost` or HTTPS
   - Open browser console and check: `window.isSecureContext` should be `true`

2. **Verify browser support**: 
   - Check: `navigator.gpu !== undefined`
   - WebGPU is not available in older browsers or mobile browsers

3. **Check GPU/driver compatibility**:
   - WebGPU requires compatible GPU drivers
   - Update your graphics drivers
   - In Chrome, check `chrome://gpu` for WebGPU status

4. **Hardware acceleration**:
   - Ensure hardware acceleration is enabled in browser settings
   - Some virtual machines may not support WebGPU

5. **Firefox-specific**:
   - Navigate to `about:config`
   - Set `dom.webgpu.enabled` to `true`
   - Restart the browser

6. **Chrome flags** (if WebGPU is disabled):
   - Navigate to `chrome://flags`
   - Search for "WebGPU"
   - Enable "Unsafe WebGPU" for testing (not recommended for production)

## Testing

```bash
zig build test
```

## Taking Screenshots

For headless testing/verification:

```bash
xvfb-run zig build run -- --screenshot=/tmp/screenshot.png
```
