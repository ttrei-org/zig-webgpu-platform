#!/usr/bin/env python3
"""
Simple HTTP server for serving the WebGPU web build locally.

WebGPU requires a secure context (HTTPS) in production, but browsers
make an exception for localhost, so this simple HTTP server works
for local development.

Usage:
    python serve.py [port]

The server serves files from zig-out/web/ on http://localhost:8000 by default.
The web/ directory contains index.html which is copied to zig-out/web/ at build time.
"""

import http.server
import os
import sys
from functools import partial

# Default port for the server
DEFAULT_PORT = 8000


class WebGPURequestHandler(http.server.SimpleHTTPRequestHandler):
    """Custom handler that serves with correct MIME types for WASM."""

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "application/javascript",
        ".mjs": "application/javascript",
    }


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT

    # Change to the web build output directory
    # Note: WASM build outputs to zig-out/ with .custom="." install path
    web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zig-out")

    if not os.path.isdir(web_dir):
        print(f"Error: Web build directory not found: {web_dir}")
        print("Run 'zig build -Dtarget=wasm32-emscripten' first to build the web version.")
        sys.exit(1)

    os.chdir(web_dir)

    handler = partial(WebGPURequestHandler, directory=".")
    server = http.server.HTTPServer(("0.0.0.0", port), handler)

    print(f"Serving web build from: {web_dir}")
    print(f"Open http://localhost:{port} in your browser")
    print("Press Ctrl+C to stop")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
