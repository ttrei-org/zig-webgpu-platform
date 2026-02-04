#!/usr/bin/env python3
"""
Simple HTTP/HTTPS server for serving the WebGPU web build locally.

WebGPU requires a secure context (HTTPS or localhost). When accessing from
another device on the LAN (e.g. a phone), you need HTTPS. Use --https to
enable TLS with an auto-generated self-signed certificate.

Usage:
    python serve.py [port]            # HTTP on localhost (default)
    python serve.py --https [port]    # HTTPS with self-signed cert

The server serves files from zig-out/ on the specified port (default 8000).

For mobile testing: accept the certificate warning in Chrome on first visit,
then WebGPU will work because the page is served over a secure context.
"""

import http.server
import os
import ssl
import subprocess
import sys
from functools import partial

DEFAULT_PORT = 8000
CERT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "certs")
CERT_FILE = os.path.join(CERT_DIR, "cert.pem")
KEY_FILE = os.path.join(CERT_DIR, "key.pem")


class WebGPURequestHandler(http.server.SimpleHTTPRequestHandler):
    """Custom handler that serves with correct MIME types for WASM."""

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "application/javascript",
        ".mjs": "application/javascript",
    }


def get_lan_ips():
    """Get local IPv4 addresses for SAN entries in the certificate."""
    ips = ["127.0.0.1"]
    try:
        output = subprocess.check_output(
            ["ip", "-4", "addr", "show"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        for line in output.splitlines():
            line = line.strip()
            if line.startswith("inet "):
                addr = line.split()[1].split("/")[0]
                if addr not in ips:
                    ips.append(addr)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return ips


def generate_cert():
    """Generate a self-signed certificate with SAN entries for LAN IPs."""
    os.makedirs(CERT_DIR, exist_ok=True)

    ips = get_lan_ips()
    san_entries = ["DNS:localhost"]
    san_entries.extend(f"IP:{ip}" for ip in ips)
    san = ",".join(san_entries)

    print(f"Generating self-signed certificate...")
    print(f"  SAN entries: {san}")

    subprocess.check_call(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            KEY_FILE,
            "-out",
            CERT_FILE,
            "-days",
            "365",
            "-nodes",
            "-subj",
            "/CN=zig-gui-experiment-dev",
            "-addext",
            f"subjectAltName={san}",
        ],
        stderr=subprocess.DEVNULL,
    )
    print(f"  Certificate written to {CERT_DIR}/")


def main():
    use_https = "--https" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--https"]
    port = int(args[0]) if args else DEFAULT_PORT

    web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zig-out")

    if not os.path.isdir(web_dir):
        print(f"Error: Web build directory not found: {web_dir}")
        print("Run 'zig build -Dtarget=wasm32-emscripten' first to build the web version.")
        sys.exit(1)

    os.chdir(web_dir)

    handler = partial(WebGPURequestHandler, directory=".")
    server = http.server.HTTPServer(("0.0.0.0", port), handler)

    if use_https:
        if not os.path.exists(CERT_FILE) or not os.path.exists(KEY_FILE):
            generate_cert()
        else:
            print(f"Using existing certificate from {CERT_DIR}/")

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT_FILE, KEY_FILE)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)

        protocol = "https"
    else:
        protocol = "http"

    print(f"Serving web build from: {web_dir}")
    print(f"Open {protocol}://localhost:{port} in your browser")
    if use_https:
        ips = get_lan_ips()
        for ip in ips:
            if ip != "127.0.0.1":
                print(f"  or {protocol}://{ip}:{port} from other devices")
        print()
        print("NOTE: You will need to accept the self-signed certificate warning")
        print("in your browser on first visit.")
    print("Press Ctrl+C to stop")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
