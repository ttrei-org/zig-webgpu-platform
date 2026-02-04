#!/bin/bash
# Backend Comparison Test
#
# Renders the demo scene on both desktop (headless) and web backends,
# then compares the screenshots to catch rendering regressions.
#
# Usage:
#   ./scripts/compare_backends.sh
#
# Exit code:
#   0  Both screenshots match within tolerance
#   1  Screenshots differ beyond tolerance or a step failed
#
# Requirements:
#   - ImageMagick (compare command)
#   - xvfb (xvfb-run)
#   - playwright-cli + Firefox with WebGPU
#   - Python 3 for web server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Output directory for test artifacts
OUT_DIR="/tmp/backend-compare"
mkdir -p "$OUT_DIR"

DESKTOP_IMG="$OUT_DIR/desktop.png"
WEB_IMG="$OUT_DIR/web.png"
WEB_RESIZED="$OUT_DIR/web_resized.png"
DIFF_IMG="$OUT_DIR/diff.png"

# Maximum allowed pixel difference (percentage of total pixels).
# Desktop uses software rasterizer (llvmpipe), web uses Firefox's WebGPU —
# minor anti-aliasing differences are expected.
MAX_DIFF_PERCENT=5

echo "=== Backend Comparison Test ==="
echo ""

# Step 1: Build both targets
echo "[1/5] Building native and web targets..."
cd "$PROJECT_DIR"
zig build 2>&1
zig build -Dtarget=wasm32-emscripten 2>&1
echo "  Builds complete."

# Step 2: Take desktop screenshot (headless)
echo "[2/5] Taking desktop screenshot..."
xvfb-run zig build run -- --screenshot="$DESKTOP_IMG" > /dev/null 2>&1
if [ ! -f "$DESKTOP_IMG" ]; then
    echo "  FAIL: Desktop screenshot not created"
    exit 1
fi
DESKTOP_SIZE=$(identify -format "%wx%h" "$DESKTOP_IMG")
echo "  Desktop: $DESKTOP_IMG ($DESKTOP_SIZE)"

# Step 3: Take web screenshot
echo "[3/5] Taking web screenshot..."
"$SCRIPT_DIR/web_screenshot.sh" "$WEB_IMG" > /dev/null 2>&1
if [ ! -f "$WEB_IMG" ]; then
    echo "  FAIL: Web screenshot not created"
    exit 1
fi
WEB_SIZE=$(identify -format "%wx%h" "$WEB_IMG")
echo "  Web: $WEB_IMG ($WEB_SIZE)"

# Step 4: Normalize sizes (resize web to match desktop if needed)
echo "[4/5] Comparing screenshots..."
if [ "$DESKTOP_SIZE" != "$WEB_SIZE" ]; then
    echo "  Sizes differ ($DESKTOP_SIZE vs $WEB_SIZE), resizing web to match desktop"
    magick "$WEB_IMG" -resize "$DESKTOP_SIZE!" "$WEB_RESIZED"
    WEB_CMP="$WEB_RESIZED"
else
    WEB_CMP="$WEB_IMG"
fi

# Step 5: Pixel comparison with ImageMagick
# AE = Absolute Error (number of different pixels)
# Use fuzz factor to tolerate minor color differences from different rasterizers
TOTAL_PIXELS=$(identify -format "%[fx:w*h]" "$DESKTOP_IMG")
# compare outputs the count to stderr; extract just the integer
DIFF_PIXELS=$(compare -metric AE -fuzz 10% "$DESKTOP_IMG" "$WEB_CMP" "$DIFF_IMG" 2>&1 || true)
# Strip anything after the first number (e.g. "7251 (0.015)")
DIFF_PIXELS=$(echo "$DIFF_PIXELS" | grep -o '^[0-9]*')
DIFF_PIXELS=${DIFF_PIXELS:-0}

# Calculate percentage using awk (more reliable than bc for this)
DIFF_PERCENT=$(awk "BEGIN { printf \"%.2f\", $DIFF_PIXELS * 100.0 / $TOTAL_PIXELS }")

echo ""
echo "[5/5] Results:"
echo "  Total pixels:     $TOTAL_PIXELS"
echo "  Different pixels: $DIFF_PIXELS"
echo "  Difference:       ${DIFF_PERCENT}%"
echo "  Threshold:        ${MAX_DIFF_PERCENT}%"
echo "  Diff image:       $DIFF_IMG"

# Check threshold
if echo "$DIFF_PERCENT $MAX_DIFF_PERCENT" | awk '{exit !($1 <= $2)}'; then
    echo ""
    echo "PASS: Screenshots match within ${MAX_DIFF_PERCENT}% tolerance"
    exit 0
else
    echo ""
    echo "FAIL: Screenshots differ by ${DIFF_PERCENT}% (threshold: ${MAX_DIFF_PERCENT}%)"
    exit 1
fi
