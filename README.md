# Zig GUI Experiment

A cross-platform GUI rendering experiment using Zig and WebGPU.

## Building

### Desktop (Native)

```bash
zig build
zig build run
```

### Web (WASM)

```bash
zig build -Dtarget=wasm32-emscripten
```

This produces output in `zig-out/web/` including:
- `bin/zig_gui_experiment.wasm` - The compiled WebAssembly module
- `zig_gui_experiment.js` - JavaScript glue code
- `index.html` - Web page that loads and runs the WASM

## Running the Web Build

Use the included Python server script:

```bash
python serve.py        # Serves on http://localhost:8000
python serve.py 3000   # Use a custom port
```

Then open http://localhost:8000 in a WebGPU-capable browser (Chrome 113+, Edge, Firefox Nightly).

### Why localhost?

WebGPU requires a secure context (HTTPS) for security reasons. However, browsers make an exception for `localhost`, allowing HTTP connections for local development. This is why `serve.py` works without SSL certificates.

For deployment, you'll need to serve over HTTPS.

## Testing

```bash
zig build test
```

## Taking Screenshots

For headless testing/verification:

```bash
xvfb-run zig build run -- --screenshot=/tmp/screenshot.png
```
