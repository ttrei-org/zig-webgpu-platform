#!/bin/bash
# Web Screenshot Script for zig-gui-experiment
#
# This script captures a screenshot of the web build using Playwright.
# It requires a WebGPU-capable browser environment.
#
# Usage:
#   ./scripts/web_screenshot.sh [output_path]
#
# Requirements:
#   - playwright-cli installed
#   - Python 3 for the web server
#   - A WebGPU-capable browser (Chrome 113+, Firefox with WebGPU enabled)
#   - For headless environments: xvfb-run
#
# Examples:
#   ./scripts/web_screenshot.sh /tmp/web_screenshot.png
#   xvfb-run ./scripts/web_screenshot.sh /tmp/web_screenshot.png

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_PATH="${1:-/tmp/web_screenshot.png}"

# Ensure web build exists
if [ ! -f "$PROJECT_DIR/zig-out/bin/zig_gui_experiment.wasm" ]; then
    echo "Building web target..."
    cd "$PROJECT_DIR"
    zig build -Dtarget=wasm32-emscripten
fi

# Create Playwright config for WebGPU
CONFIG_FILE=$(mktemp /tmp/playwright-webgpu-XXXXXX.json)
cat > "$CONFIG_FILE" << 'EOF'
{
  "browser": {
    "browserName": "chromium",
    "launchOptions": {
      "headless": false,
      "args": ["--enable-features=Vulkan,UseSkiaRenderer,WebGPU"]
    }
  }
}
EOF

# Start web server in background
cd "$PROJECT_DIR"
python serve.py &
SERVER_PID=$!
sleep 2

# Ensure server is stopped on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f "$CONFIG_FILE"
    playwright-cli session-stop 2>/dev/null || true
}
trap cleanup EXIT

# Take screenshot using Playwright
echo "Taking web screenshot..."
playwright-cli session-stop 2>/dev/null || true
playwright-cli config --config="$CONFIG_FILE"
playwright-cli open http://localhost:8000/
sleep 3  # Wait for WebGPU initialization and first frame
playwright-cli run-code "async page => await page.screenshot({ path: '$OUTPUT_PATH', type: 'png' })"
playwright-cli session-stop

echo "Screenshot saved to: $OUTPUT_PATH"
