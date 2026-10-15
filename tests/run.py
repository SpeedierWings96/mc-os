"""Boot MC-OS in a headless CC:Tweaked stand-in and click through it.

    pip install lupa && python3 tests/run.py
"""
import os
import shutil
import sys
import tempfile
import urllib.request

try:
    import lupa.lua54 as lupa
except ImportError:
    import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
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


def boot(root):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.HOST_ROM = ROM
    g.HOST_ROOT = root
    g.HOST_FS = HostFS()
    with open(os.path.join(HERE, "harness.lua")) as fh:
        h = lua.execute(fh.read())
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
