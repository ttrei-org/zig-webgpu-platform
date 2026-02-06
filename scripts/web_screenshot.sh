#!/bin/bash
# Web Screenshot Script for zig-webgpu-platform
#
# Captures a screenshot of the web build using Playwright with Firefox
# and xvfb. Firefox with WebGPU prefs enabled works without GPU hardware,
# unlike Chromium which requires a real GPU for WebGPU.
#
# Usage:
#   ./scripts/web_screenshot.sh [output_path]
#
# Requirements:
#   - playwright-cli installed
#   - Python 3 for the web server
#   - xvfb (xvfb-run)
#
# Examples:
#   ./scripts/web_screenshot.sh /tmp/web_screenshot.png
#   ./scripts/web_screenshot.sh /tmp/web_screenshot.png 8

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_PATH="${1:-/tmp/web_screenshot.png}"
WAIT_SECS="${2:-5}"

# Ensure web build exists
if [ ! -f "$PROJECT_DIR/zig-out/bin/zig_webgpu_platform.wasm" ]; then
    echo "Building web target..."
    cd "$PROJECT_DIR"
    zig build -Dtarget=wasm32-emscripten
fi

# Create Playwright config for Firefox with WebGPU enabled
CONFIG_FILE=$(mktemp /tmp/playwright-webgpu-XXXXXX.json)
cat > "$CONFIG_FILE" << 'EOF'
{
  "browser": {
    "browserName": "firefox",
    "launchOptions": {
      "headless": false,
      "firefoxUserPrefs": {
        "dom.webgpu.enabled": true
      }
    }
  }
}
EOF

# Start web server in background
cd "$PROJECT_DIR"
python serve.py > /dev/null 2>&1 &
SERVER_PID=$!
sleep 2

# Ensure server is stopped on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f "$CONFIG_FILE"
}
trap cleanup EXIT

# Take screenshot using xvfb + Firefox with WebGPU
echo "Taking web screenshot (Firefox + xvfb)..."
xvfb-run --auto-servernum bash << SCRIPT
playwright-cli session-stop 2>/dev/null || true
playwright-cli config --config="$CONFIG_FILE"
playwright-cli open "http://localhost:8000/"
sleep $WAIT_SECS
playwright-cli run-code 'async page => { await page.screenshot({ path: "$OUTPUT_PATH", type: "png" }); return "saved"; }'
playwright-cli session-stop
SCRIPT

echo "Screenshot saved to: $OUTPUT_PATH"
