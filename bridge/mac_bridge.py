#!/usr/bin/env python3
"""MC-OS Mac bridge: lets MC-OS in Minecraft open apps on this Mac and
show them live on an in-game screen.

Run it on your Mac (it needs only Python 3; if macOS offers to install
developer tools the first time you type python3, accept):

    python3 mac_bridge.py

It prints a token. In MC-OS, open the Mac app and enter that token once.

Showing an app in game needs two macOS permissions for the program you run
this from (usually Terminal), in System Settings > Privacy & Security:
Screen Recording (to capture the app's window) and Accessibility (to pass
your in-game clicks and typing to it). macOS asks the first time.

The bridge only listens on this computer (127.0.0.1) unless you pass
--host. It only ever opens, shows and controls .app bundles from the
Applications folders, and it never runs commands sent by the game.
"""
import argparse
import http.server
import os
import plistlib
import secrets
import struct
import subprocess
import sys
import tempfile
import urllib.parse

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


# ---------------------------------------------------------------------------
# Turning a picture into something a CC:Tweaked screen can draw.
#
# A CC character cell can show a 2x3 grid of square "pixels" in two colours
# using characters 128-159, so a W x H cell screen is a 2W x 3H image with
# at most two colours per cell and 16 colours overall.

# CC:Tweaked's default palette, in colour order (white = 0 ... black = 15).
CC_PALETTE = [
    (0xF0, 0xF0, 0xF0), (0xF2, 0xB2, 0x33), (0xE5, 0x7F, 0xD8), (0x99, 0xB2, 0xF2),
    (0xDE, 0xDE, 0x6C), (0x7F, 0xCC, 0x19), (0xF2, 0xB2, 0xCC), (0x4C, 0x4C, 0x4C),
    (0x99, 0x99, 0x99), (0x4C, 0x99, 0xB2), (0xB2, 0x66, 0xE5), (0x33, 0x66, 0xCC),
    (0x7F, 0x66, 0x4C), (0x57, 0xA6, 0x4E), (0xCC, 0x4C, 0x4C), (0x11, 0x11, 0x11),
]
HEX = "0123456789abcdef"
# Cell characters 128..159 are sent as one ASCII character each.
CELL_CODES = "0123456789abcdefghijklmnopqrstuv"


def read_bmp(data):
    """Decode an uncompressed 24/32-bit BMP into rows of (r, g, b)."""
    if data[:2] != b"BM":
        raise ValueError("not a BMP file")
    offset = struct.unpack_from("<I", data, 10)[0]
    _, width, height, _, bpp, compression = struct.unpack_from("<IiiHHI", data, 14)
    if bpp not in (24, 32) or compression not in (0, 3):
        raise ValueError("unsupported BMP (%d bpp, compression %d)" % (bpp, compression))
    masks = (0x00FF0000, 0x0000FF00, 0x000000FF)
    if compression == 3:
        # Right after a 40-byte header, or inside a V4/V5 header: same offset.
        masks = struct.unpack_from("<III", data, 14 + 40)

    def channel(mask):
        shift = (mask & -mask).bit_length() - 1
        return shift, mask >> shift

    chans = [channel(m) for m in masks]
    step = bpp // 8
    stride = (width * step + 3) & ~3
    top_down = height < 0
    height = abs(height)
    rows = []
    for y in range(height):
        src = y if top_down else height - 1 - y
        base = offset + src * stride
        row = []
        for x in range(width):
            if bpp == 24:
                b, g, r = data[base + x * 3:base + x * 3 + 3]
            else:
                v = struct.unpack_from("<I", data, base + x * 4)[0]
                r, g, b = (((v >> s) & m) * 255 // (m or 1) for s, m in chans)
            row.append((r, g, b))
        rows.append(row)
    return rows


def median_cut(pixels, count=16):
    """Pick `count` representative colours for a list of (r, g, b)."""
    def spread(box):
        return max(max(p[c] for p in box) - min(p[c] for p in box) for c in range(3))

    boxes = [(spread(pixels), pixels)]
    while len(boxes) < count:
        boxes.sort(key=lambda b: b[0])
        rng, box = boxes[-1]
        if rng == 0 or len(box) < 2:
            break
        boxes.pop()
        c = max(range(3), key=lambda c: max(p[c] for p in box) - min(p[c] for p in box))
        box = sorted(box, key=lambda p: p[c])
        mid = len(box) // 2
        for half in (box[:mid], box[mid:]):
            boxes.append((spread(half), half))
    palette = []
    for _, box in boxes:
        n = len(box)
        palette.append(tuple(sum(p[c] for p in box) // n for c in range(3)))
    while len(palette) < count:
        palette.append((0, 0, 0))
    return palette


def dist(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def fit(src_w, src_h, cells_w, cells_h):
    """Where an src_w x src_h picture sits, letterboxed, on a cell screen."""
    pw, ph = cells_w * 2, cells_h * 3
    scale = min(pw / src_w, ph / src_h)
    iw, ih = max(1, round(src_w * scale)), max(1, round(src_h * scale))
    return (pw - iw) // 2, (ph - ih) // 2, iw, ih


def encode_frame(image, cells_w, cells_h, adaptive):
    """Encode rows of (r, g, b) (already sized to fit()) as an MC-OS frame.

    Format: "W H", a line of 16 palette colours (rrggbb), then for each
    cell row three lines: cell characters, foreground and background
    colours (hex digits, one per cell).
    """
    pw, ph = cells_w * 2, cells_h * 3
    image = [row[:pw] for row in image[:ph]]
    ih, iw = len(image), len(image[0]) if image else 0
    ox, oy = (pw - iw) // 2, (ph - ih) // 2

    if adaptive:
        sample = [p for row in image[::2] for p in row[::2]] or [(0, 0, 0)]
        palette = median_cut(sample + [(0, 0, 0)], 16)
    else:
        palette = CC_PALETTE
    cache = {}

    def nearest(p):
        i = cache.get(p)
        if i is None:
            i = min(range(16), key=lambda k: dist(p, palette[k]))
            cache[p] = i
        return i

    black = nearest((0, 0, 0))
    grid = [[black] * pw for _ in range(ph)]
    for y, row in enumerate(image):
        out = grid[oy + y]
        for x, p in enumerate(row):
            out[ox + x] = nearest(p)

    pdist = [[dist(a, b) for b in palette] for a in palette]
    lines = ["%d %d" % (cells_w, cells_h),
             " ".join("%02x%02x%02x" % c for c in palette)]
    for cy in range(cells_h):
        text, fgs, bgs = [], [], []
        r0, r1, r2 = grid[cy * 3], grid[cy * 3 + 1], grid[cy * 3 + 2]
        for cx in range(cells_w):
            x = cx * 2
            px = (r0[x], r0[x + 1], r1[x], r1[x + 1], r2[x], r2[x + 1])
            counts = {}
            for c in px:
                counts[c] = counts.get(c, 0) + 1
            ranked = sorted(counts, key=counts.get, reverse=True)
            if len(ranked) == 1:
                text.append(CELL_CODES[0])
                fgs.append(HEX[ranked[0]])
                bgs.append(HEX[ranked[0]])
                continue
            a, b = ranked[0], ranked[1]
            # The bottom-right pixel always shows the background colour.
            bg = a if pdist[px[5]][a] <= pdist[px[5]][b] else b
            fg = b if bg == a else a
            code = 0
            for i in range(5):
                if pdist[px[i]][fg] < pdist[px[i]][bg]:
                    code |= 1 << i
            text.append(CELL_CODES[code])
            fgs.append(HEX[fg])
            bgs.append(HEX[bg])
        lines += ["".join(text), "".join(fgs), "".join(bgs)]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# macOS window capture and input, through the system frameworks (ctypes).

KEYCODES = {
    "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "delete": 117,
    "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
}


class MacScreen:
    def __init__(self):
        import ctypes
        self.c = ctypes
        cf = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        vp = ctypes.c_void_p
        for name, args, res in [
            ("CFArrayGetCount", [vp], ctypes.c_long),
            ("CFArrayGetValueAtIndex", [vp, ctypes.c_long], vp),
            ("CFDictionaryGetValue", [vp, vp], vp),
            ("CFStringCreateWithCString", [vp, ctypes.c_char_p, ctypes.c_uint32], vp),
            ("CFStringGetCString", [vp, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32], ctypes.c_bool),
            ("CFNumberGetValue", [vp, ctypes.c_long, vp], ctypes.c_bool),
            ("CFRelease", [vp], None),
        ]:
            fn = getattr(cf, name)
            fn.argtypes, fn.restype = args, res

        class CGPoint(ctypes.Structure):
            _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
        self.CGPoint = CGPoint

        for name, args, res in [
            ("CGWindowListCopyWindowInfo", [ctypes.c_uint32, ctypes.c_uint32], vp),
            ("CGEventCreateMouseEvent", [vp, ctypes.c_uint32, CGPoint, ctypes.c_uint32], vp),
            ("CGEventCreateKeyboardEvent", [vp, ctypes.c_uint16, ctypes.c_bool], vp),
            ("CGEventKeyboardSetUnicodeString", [vp, ctypes.c_ulong, ctypes.POINTER(ctypes.c_uint16)], None),
            ("CGEventPostToPid", [ctypes.c_int, vp], None),
        ]:
            fn = getattr(cg, name)
            fn.argtypes, fn.restype = args, res
        self.scroll_fn = getattr(cg, "CGEventCreateScrollWheelEvent2", None)
        if self.scroll_fn is not None:
            self.scroll_fn.argtypes = [vp, ctypes.c_uint32, ctypes.c_uint32,
                                       ctypes.c_int32, ctypes.c_int32, ctypes.c_int32]
            self.scroll_fn.restype = vp
        self.cf, self.cg = cf, cg
        self.keys = {k: cf.CFStringCreateWithCString(None, k.encode(), 0x08000100) for k in [
            "kCGWindowOwnerName", "kCGWindowOwnerPID", "kCGWindowNumber", "kCGWindowLayer",
            "kCGWindowBounds", "X", "Y", "Width", "Height"]}

    def _get(self, d, key):
        return self.cf.CFDictionaryGetValue(d, self.keys[key])

    def _num(self, ref, double=False):
        c = self.c
        out = c.c_double() if double else c.c_int64()
        if not ref or not self.cf.CFNumberGetValue(ref, 6 if double else 4, c.byref(out)):
            return None
        return out.value

    def _str(self, ref):
        if not ref:
            return ""
        buf = self.c.create_string_buffer(512)
        self.cf.CFStringGetCString(ref, buf, 512, 0x08000100)
        return buf.value.decode("utf-8", "replace")

    def windows(self):
        info = self.cg.CGWindowListCopyWindowInfo(1 | 16, 0)  # on screen, no desktop
        out = []
        try:
            for i in range(self.cf.CFArrayGetCount(info)):
                d = self.cf.CFArrayGetValueAtIndex(info, i)
                bounds = self._get(d, "kCGWindowBounds")
                if not bounds:
                    continue
                out.append({
                    "owner": self._str(self._get(d, "kCGWindowOwnerName")),
                    "pid": self._num(self._get(d, "kCGWindowOwnerPID")),
                    "id": self._num(self._get(d, "kCGWindowNumber")),
                    "layer": self._num(self._get(d, "kCGWindowLayer")),
                    "x": self._num(self.cf.CFDictionaryGetValue(bounds, self.keys["X"]), True),
                    "y": self._num(self.cf.CFDictionaryGetValue(bounds, self.keys["Y"]), True),
                    "w": self._num(self.cf.CFDictionaryGetValue(bounds, self.keys["Width"]), True),
                    "h": self._num(self.cf.CFDictionaryGetValue(bounds, self.keys["Height"]), True),
                })
        finally:
            self.cf.CFRelease(info)
        return out

    def find_window(self, app_path):
        names = {os.path.basename(app_path)[:-4]}
        try:
            with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as fh:
                plist = plistlib.load(fh)
            for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
                if plist.get(key):
                    names.add(plist[key])
        except (OSError, ValueError, plistlib.InvalidFileException):
            pass
        wins = [w for w in self.windows()
                if w["owner"] in names and w["layer"] == 0 and (w["w"] or 0) > 50 and (w["h"] or 0) > 50]
        return max(wins, key=lambda w: w["w"] * w["h"]) if wins else None

    def capture(self, win, width, height):
        with tempfile.TemporaryDirectory() as tmp:
            png, bmp = os.path.join(tmp, "w.png"), os.path.join(tmp, "w.bmp")
            subprocess.run(["screencapture", "-x", "-o", "-l%d" % win["id"], png],
                           check=True, capture_output=True)
            subprocess.run(["sips", "-s", "format", "bmp", "-z", str(height), str(width), png,
                            "--out", bmp], check=True, capture_output=True)
            with open(bmp, "rb") as fh:
                return read_bmp(fh.read())

    def click(self, win, fx, fy):
        point = self.CGPoint(win["x"] + fx * win["w"], win["y"] + fy * win["h"])
        for kind in (1, 2):  # left mouse down, up
            ev = self.cg.CGEventCreateMouseEvent(None, kind, point, 0)
            self.cg.CGEventPostToPid(win["pid"], ev)
            self.cf.CFRelease(ev)

    def scroll(self, win, fx, fy, amount):
        if self.scroll_fn is None:
            return
        ev = self.scroll_fn(None, 0, 1, -amount * 3, 0, 0)  # line units
        self.cg.CGEventPostToPid(win["pid"], ev)
        self.cf.CFRelease(ev)

    def _key(self, pid, code, text=None):
        for down in (True, False):
            ev = self.cg.CGEventCreateKeyboardEvent(None, code, down)
            if text:
                chars = (self.c.c_uint16 * len(text))(*[ord(ch) for ch in text])
                self.cg.CGEventKeyboardSetUnicodeString(ev, len(text), chars)
            self.cg.CGEventPostToPid(pid, ev)
            self.cf.CFRelease(ev)

    def type_text(self, win, text):
        for ch in text:
            if ord(ch) < 0x10000:
                self._key(win["pid"], 0, ch)

    def key(self, win, name):
        if name in KEYCODES:
            self._key(win["pid"], KEYCODES[name])


# ---------------------------------------------------------------------------
# HTTP server

def make_handler(token, app_dirs=None, opener=open_app, screen=None):
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

        def _body(self):
            length = min(int(self.headers.get("Content-Length") or 0), 4096)
            return self.rfile.read(length).decode("utf-8", "replace")

        def _window(self, query):
            """The on-screen window of the app named in the query, or None
            after sending an error response."""
            if screen is None:
                self._send(501, "showing apps needs the bridge running on a Mac")
                return None
            name = query.get("app", [""])[0]
            path = find_apps(app_dirs).get(name)
            if path is None:
                self._send(404, "no app called " + name)
                return None
            win = screen.find_window(path)
            if win is None:
                self._send(409, "no window")
            return win

        def _cell(self, query, win):
            """Map a clicked cell to a 0..1 point in the window, or None."""
            try:
                cx, cy, w, h = (int(query[k][0]) for k in ("x", "y", "w", "h"))
            except (KeyError, ValueError):
                return None
            ox, oy, iw, ih = fit(win["w"], win["h"], w, h)
            fx = ((cx - 1) * 2 + 1 - ox) / iw
            fy = ((cy - 1) * 3 + 1.5 - oy) / ih
            if 0 <= fx <= 1 and 0 <= fy <= 1:
                return fx, fy
            return None

        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path == "/ping":
                self._send(200, "mcos-bridge")
            elif url.path == "/apps":
                if self._authorised():
                    self._send(200, "\n".join(find_apps(app_dirs)))
            elif url.path == "/frame":
                if not self._authorised():
                    return
                win = self._window(query)
                if win is None:
                    return
                try:
                    w = max(1, min(400, int(query["w"][0])))
                    h = max(1, min(200, int(query["h"][0])))
                except (KeyError, ValueError):
                    self._send(400, "need w and h")
                    return
                _, _, iw, ih = fit(win["w"], win["h"], w, h)
                try:
                    image = screen.capture(win, iw, ih)
                except (OSError, ValueError, subprocess.CalledProcessError) as e:
                    self._send(500, "capture failed: %s" % e)
                    return
                adaptive = query.get("palette", ["adaptive"])[0] == "adaptive"
                self._send(200, encode_frame(image, w, h, adaptive))
            else:
                self._send(404, "not found")

        def do_POST(self):
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            if not self._authorised():
                return
            if url.path == "/open":
                name = self._body().strip()
                path = find_apps(app_dirs).get(name)
                if path is None:
                    self._send(404, "no app called " + name)
                    return
                opener(path)
                self._send(200, "opened " + name)
                return
            if url.path not in ("/click", "/scroll", "/key", "/type"):
                self._send(404, "not found")
                return
            win = self._window(query)
            if win is None:
                return
            if url.path == "/type":
                screen.type_text(win, self._body())
            elif url.path == "/key":
                screen.key(win, query.get("name", [""])[0])
            else:
                point = self._cell(query, win)
                if point is not None:
                    if url.path == "/click":
                        screen.click(win, *point)
                    else:
                        amount = 1 if query.get("dir", ["1"])[0] == "1" else -1
                        screen.scroll(win, point[0], point[1], amount)
            self._send(200, "ok")

        def log_message(self, fmt, *args):
            if os.environ.get("MCOS_BRIDGE_VERBOSE"):
                sys.stderr.write("[mcos-bridge] " + (fmt % args) + "\n")

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on (default: this Mac only)")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    token = load_token()
    screen = None
    if sys.platform == "darwin":
        try:
            screen = MacScreen()
        except (OSError, AttributeError) as e:
            print("Showing apps in game is unavailable: %s" % e)
    server = http.server.ThreadingHTTPServer(
        (args.host, args.port), make_handler(token, screen=screen))
    print("MC-OS bridge running on http://%s:%d" % (args.host, args.port))
    print("Token: " + token)
    print("Found %d apps. Press Ctrl+C to stop." % len(find_apps()))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
