#!/usr/bin/env python3
"""MC-OS Mac bridge: lets MC-OS in Minecraft open apps on this Mac.

Run it on your Mac (it needs only Python 3, which macOS ships):

    python3 mac_bridge.py

It prints a token. In MC-OS, open the Mac app and enter that token once.

The bridge only listens on this computer (127.0.0.1) unless you pass
--host, and it only ever opens .app bundles from the Applications folders.
It never runs commands sent by the game.
"""
import argparse
import http.server
import json
import os
import secrets
import subprocess
import sys

APP_DIRS = [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    os.path.expanduser("~/Applications"),
]
TOKEN_FILE = os.path.expanduser("~/.mcos-bridge-token")


def find_apps(dirs=None):
    """Map display name -> .app path for every app in the Applications folders."""
    apps = {}
    for d in dirs or APP_DIRS:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in names:
            if name.endswith(".app") and not name.startswith("."):
                apps.setdefault(name[:-4], os.path.join(d, name))
    return dict(sorted(apps.items(), key=lambda kv: kv[0].lower()))


def load_token():
    try:
        with open(TOKEN_FILE) as fh:
            token = fh.read().strip()
            if token:
                return token
    except OSError:
        pass
    token = secrets.token_hex(4)
    with open(TOKEN_FILE, "w") as fh:
        fh.write(token)
    os.chmod(TOKEN_FILE, 0o600)
    return token


def open_app(path):
    subprocess.Popen(["open", path])


def make_handler(token, app_dirs=None, opener=open_app):
    class Handler(http.server.BaseHTTPRequestHandler):
        def _send(self, status, body):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _authorised(self):
            if secrets.compare_digest(self.headers.get("X-Token", ""), token):
                return True
            self._send(403, "bad token")
            return False

        def do_GET(self):
            if self.path == "/ping":
                self._send(200, "mcos-bridge")
            elif self.path == "/apps":
                if self._authorised():
                    self._send(200, "\n".join(find_apps(app_dirs)))
            else:
                self._send(404, "not found")

        def do_POST(self):
            if self.path != "/open":
                self._send(404, "not found")
                return
            if not self._authorised():
                return
            length = min(int(self.headers.get("Content-Length") or 0), 1024)
            name = self.rfile.read(length).decode("utf-8", "replace").strip()
            path = find_apps(app_dirs).get(name)
            if path is None:
                self._send(404, "no app called " + name)
                return
            opener(path)
            self._send(200, "opened " + name)

        def log_message(self, fmt, *args):
            sys.stderr.write("[mcos-bridge] " + (fmt % args) + "\n")

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on (default: this Mac only)")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    token = load_token()
    server = http.server.ThreadingHTTPServer((args.host, args.port), make_handler(token))
    print("MC-OS bridge running on http://%s:%d" % (args.host, args.port))
    print("Token: " + token)
    print("Found %d apps. Press Ctrl+C to stop." % len(find_apps()))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
