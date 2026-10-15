"""Boot MC-OS in a headless CC:Tweaked stand-in and click through it.

    pip install lupa && python3 tests/run.py
"""
import os
import shutil
import struct
import sys
import tempfile
import threading
import urllib.error
import urllib.request

try:
    import lupa.lua54 as lupa
except ImportError:
    import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "bridge"))
import mac_bridge  # noqa: E402
ROM = os.path.join(HERE, ".rom")
ROM_URL = ("https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/mc-1.20.x/"
           "projects/core/src/main/resources/data/computercraft/lua/rom/")
ROM_FILES = ["apis/window.lua", "apis/colors.lua", "apis/keys.lua",
             "modules/main/cc/expect.lua"]


def fetch_rom():
    for f in ROM_FILES:
        dest = os.path.join(ROM, f)
        if not os.path.exists(dest):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            urllib.request.urlretrieve(ROM_URL + f, dest)
    # Programs the start menu points at; they only need to exist.
    for f in ["programs/shell.lua", "programs/lua.lua", "programs/fun/worm.lua",
              "programs/edit.lua"]:
        dest = os.path.join(ROM, f)
        if not os.path.exists(dest):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w") as fh:
                fh.write('print("stub %s") while true do os.pullEvent() end\n' % f)


class HostFS:
    def exists(self, p): return os.path.exists(p)
    def isDir(self, p): return os.path.isdir(p)
    def getSize(self, p): return os.path.getsize(p)
    def makeDir(self, p): os.makedirs(p, exist_ok=True)
    def list(self, p): return "\n".join(sorted(os.listdir(p)))

    def delete(self, p):
        if os.path.isdir(p):
            shutil.rmtree(p)
        elif os.path.exists(p):
            os.remove(p)


class HostHTTP:
    def request(self, method, url, body, token):
        req = urllib.request.Request(url, method=method, headers={"X-Token": token},
                                     data=body.encode() if method == "POST" else None)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, resp.read().decode(), ""
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(), "HTTP response code %d" % e.code
        except OSError as e:
            return 0, "", str(e)


class FakeScreen:
    """Stands in for MacScreen: a 200x100 window, red on the left half and
    blue on the right, that records the input it receives."""

    def __init__(self):
        self.events = []

    def find_window(self, app_path):
        return {"id": 1, "pid": 2, "x": 0, "y": 0, "w": 200, "h": 100}

    def capture(self, win, width, height):
        red, blue = (0xCC, 0x4C, 0x4C), (0x33, 0x66, 0xCC)
        return [[red if x < width // 2 else blue for x in range(width)] for _ in range(height)]

    def click(self, win, fx, fy):
        self.events.append(("click", round(fx, 1), round(fy, 1)))

    def scroll(self, win, fx, fy, amount):
        self.events.append(("scroll", amount))

    def type_text(self, win, text):
        self.events.append(("type", text))

    def key(self, win, name):
        self.events.append(("key", name))


def bmp(rows, bpp, top_down):
    """Build a BMP the way sips might: 24-bit, or 32-bit with bitfields."""
    h, w = len(rows), len(rows[0])
    step = bpp // 8
    stride = (w * step + 3) & ~3
    pixels = b""
    for row in (rows if top_down else reversed(rows)):
        line = b""
        for r, g, b in row:
            line += bytes([b, g, r]) if bpp == 24 else struct.pack("<I", 0xFF000000 | r << 16 | g << 8 | b)
        pixels += line + b"\0" * (stride - len(line))
    extra = struct.pack("<III", 0xFF0000, 0xFF00, 0xFF) if bpp == 32 else b""
    offset = 14 + 40 + len(extra)
    header = struct.pack("<2sIHHI", b"BM", offset + len(pixels), 0, 0, offset)
    info = struct.pack("<IiiHHIIiiII", 40, w, -h if top_down else h, 1, bpp,
                       3 if bpp == 32 else 0, len(pixels), 0, 0, 0, 0)
    return header + info + extra + pixels


def start_bridge(app_dir, token, opened, screen=None):
    handler = mac_bridge.make_handler(token, [app_dir], opened.append, screen)
    server = mac_bridge.http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def boot(root, bridge_url=None):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.HOST_ROM = ROM
    g.HOST_ROOT = root
    g.HOST_FS = HostFS()
    g.HOST_HTTP = HostHTTP()
    with open(os.path.join(HERE, "harness.lua")) as fh:
        h = lua.execute(fh.read())
    if bridge_url:
        lua.execute('settings.set("mcos.bridge.url", ...)', bridge_url)
    h.boot()
    return h


def screen(h):
    return h.screen()


failures = []


def check(cond, msg, h=None):
    if cond:
        print("  ok   " + msg)
    else:
        print("  FAIL " + msg)
        if h is not None:
            print(screen(h))
        failures.append(msg)


def find(h, needle):
    for y in range(1, 20):
        line = h.line(y)
        x = line.find(needle)
        if x >= 0:
            return x + 1, y
    return None


def title_row(h, name):
    """Row and column of a window title bar showing `name`, or None."""
    for y in range(1, 19):
        line = h.line(y)
        x = line.find(" " + name)
        if x >= 0 and h.bgLine(y)[x] in "b7":
            return x + 1, y
    return None


def main():
    fetch_rom()
    root = tempfile.mkdtemp()
    for item in ["startup.lua", "mcos"]:
        src = os.path.join(REPO, item)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(root, item))
        else:
            shutil.copy(src, root)
    with open(os.path.join(root, "notes.txt"), "w") as fh:
        fh.write("hello")
    os.makedirs(os.path.join(root, "apps"))
    with open(os.path.join(root, "apps", "crash.lua"), "w") as fh:
        fh.write('error("boom")\n')

    h = boot(root)
    print("desktop:")
    check(h.alive(), "boots without crashing", h)
    check(" Start " in h.line(19), "taskbar shows Start", h)
    check("MC-OS" in h.line(1), "desktop watermark", h)
    check(" Shell " in h.line(2) and " Files " in h.line(4), "desktop icons", h)

    print("start menu:")
    h.click(2, 19)
    check(find(h, " Shut down") is not None, "menu opens", h)
    check(find(h, " crash") is not None, "lists programs in /apps", h)
    h.click(2, 19 - 20)  # click outside the menu closes it
    check(find(h, " Shut down") is None, "menu closes on outside click", h)

    print("files app:")
    x, y = find(h, " Files ")
    h.click(x + 1, y)
    check(find(h, " Files ") is not None and find(h, " /") is not None, "Files opens a window", h)
    check(find(h, "notes.txt") is not None, "Files lists the root", h)
    check(find(h, "mcos/") is not None, "Files shows folders", h)
    # Enter the mcos folder by double click.
    x, y = find(h, "mcos/")
    h.click(x, y)
    h.click(x, y)
    check(find(h, "wm.lua") is not None, "double click opens a folder", h)
    h.key("backspace")
    check(find(h, "notes.txt") is not None, "backspace goes up", h)
    # New file via N; the 'n' must not leak into the name.
    h.send("char", "n")
    h.type("todo.txt")
    h.key("enter")
    check(os.path.exists(os.path.join(root, "todo.txt")), "N creates a file", h)
    check(not os.path.exists(os.path.join(root, "ntodo.txt")), "command letter doesn't leak into prompt", h)
    check(title_row(h, "todo.txt") is not None, "new file opens in editor window", h)

    print("window management:")
    # Close the editor window via its x button.
    bar = title_row(h, "todo.txt")
    h.click(h.line(bar[1]).rfind("x") + 1, bar[1])
    check(title_row(h, "todo.txt") is None, "x closes a window", h)
    title = title_row(h, "Files")
    check(title is not None, "Files window still open", h)
    tx, ty = title
    h.drag(tx + 2, ty, tx + 2, ty + 3)
    check(h.line(ty + 3).find(" Files") == tx - 1, "dragging the title bar moves the window", h)
    ty += 3
    right = h.line(ty).rfind("x") + 1
    h.click(right - 2, ty)  # maximize
    check(h.line(1).startswith(" Files"), "maximize fills the screen", h)
    h.click(right_now := h.line(1).rfind("x") + 1 - 4, 1)  # minimize
    check(not h.line(1).startswith(" Files"), "minimize hides the window", h)
    tb = h.line(19).find(" Files")
    h.click(tb + 2, 19)
    check(h.line(1).startswith(" Files"), "taskbar button restores it", h)

    print("crashing program:")
    h.click(2, 19)
    x, y = find(h, " crash")
    h.click(x + 1, y)
    check(find(h, "boom") is not None, "error shown in its window", h)
    check(h.alive(), "OS survives a crashing program", h)
    h.key("a")
    check(find(h, "boom") is None, "any key closes the crashed window", h)

    print("settings:")
    tb = h.line(19).find(" Files")
    h.click(tb + 2, 19)  # minimize Files so the desktop shows
    x, y = find(h, " Settings ")  # desktop icon
    h.click(x + 1, y)
    check(title_row(h, "Settings") is not None, "desktop icon opens Settings", h)
    for _ in range(5):
        h.key("down")
    h.key("enter")
    check("e" in h.bgLine(2)[:1], "picking red changes the desktop", h)

    print("mac bridge:")
    app_dir = tempfile.mkdtemp()
    for name in ["Safari.app", "Notes.app", "Visual Studio Code.app", "notes.txt"]:
        os.makedirs(os.path.join(app_dir, name))
    opened = []
    screen = FakeScreen()
    server = start_bridge(app_dir, "abc123", opened, screen)
    base = "http://127.0.0.1:%d" % server.server_address[1]

    def call(method, path, token, body=None):
        return HostHTTP().request(method, base + path, body or "", token)

    check(call("GET", "/apps", "abc123")[1] == "Notes\nSafari\nVisual Studio Code", "bridge lists only .app bundles")
    check(call("GET", "/apps", "wrong")[0] == 403, "bridge rejects a wrong token")
    check(call("POST", "/open", "abc123", "../../bin/sh")[0] == 404 and not opened,
          "bridge refuses anything that isn't a listed app")

    h = boot(root, base)
    x, y = find(h, " Mac ")
    h.click(x + 1, y)
    check(find(h, "Token:") is not None, "Mac app asks for the token first", h)
    h.type("abc123")
    h.key("enter")
    check(find(h, "Visual Studio Code") is not None, "Mac app lists the Mac's apps", h)
    h.type("saf")
    check(find(h, "Notes") is None and find(h, "Safari") is not None, "typing filters the list", h)
    h.key("enter")
    check(opened == [os.path.join(app_dir, "Safari.app")], "Enter opens the app on the Mac", h)
    view = title_row(h, "Safari")
    check(view is not None, "opening an app shows it in a viewer window", h)
    vx, vy = view
    row = h.bgLine(vy + 6)[vx - 1:vx + 37]
    inner = row.strip("f")  # letterbox bars are black
    check(inner.startswith("e") and inner.endswith("b") and set(inner) <= set("eb"),
          "viewer draws the app's window (red | blue)", h)
    h.click(vx + 18, vy + 6)
    check(("click", 0.5, 0.5) in screen.events, "clicking the viewer clicks the app", h)
    h.type("hi")
    h.key("enter")
    check(("type", "h") in screen.events and ("key", "enter") in screen.events,
          "typing in the viewer types into the app", h)

    server.shutdown()
    mac = title_row(h, "Mac")
    h.click(mac[0] + 2, mac[1])  # focus the Mac app window
    h.click(*find(h, "[Reload]"))
    check(find(h, "Can't reach your Mac") is not None, "Mac app explains when the bridge is down", h)

    print("frame encoding:")
    rows = [[(10 * x, 20 * y, 5) for x in range(5)] for y in range(3)]
    check(mac_bridge.read_bmp(bmp(rows, 24, False)) == rows, "reads 24-bit bottom-up BMP")
    check(mac_bridge.read_bmp(bmp(rows, 32, True)) == rows, "reads 32-bit top-down bitfield BMP")
    check(mac_bridge.fit(200, 100, 10, 10) == (0, 10, 20, 10), "letterboxes a wide window")
    # A 2x3 cell, white with a black top-left pixel, in the fixed palette.
    img = [[(0, 0, 0), (255, 255, 255)], [(255, 255, 255)] * 2, [(255, 255, 255)] * 2]
    frame = mac_bridge.encode_frame(img, 1, 1, False).split("\n")
    check(frame[2:5] == ["1", "f", "0"], "encodes a cell as a teletext character")

    print("exit:")
    h.click(2, 19)
    x, y = find(h, " Exit to CraftOS")
    h.click(x + 1, y)
    check(not h.alive(), "Exit to CraftOS returns to the shell", h)

    print()
    if failures:
        print("%d check(s) failed" % len(failures))
        sys.exit(1)
    print("all checks passed")


main()
