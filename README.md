# MC-OS

A desktop operating system for [CC:Tweaked](https://tweaked.cc/) computers in Minecraft.
It boots into a desktop with draggable windows, a taskbar, a start menu and a few built-in apps.

## Install

On an **Advanced Computer** (gold, colour screen and mouse), run:

```
wget run https://raw.githubusercontent.com/SpeedierWings96/mc-os/main/install.lua
```

The installer downloads MC-OS into `/mcos`, writes `/startup.lua` (replacing any existing one) and reboots.
To try another branch, pass its name: `wget run <url-to-install.lua> my-branch`.

The server needs CC:Tweaked's HTTP API enabled (it is by default), and the repository must be public for `raw.githubusercontent.com` to serve it.

## Using it

- **Start** (bottom left) opens the menu: apps, Exit to CraftOS, Reboot, Shut down.
- Click a desktop icon to open that app.
- Drag a window by its title bar. The buttons on the right are minimize `-`, maximize `+` and close `x`.
- Taskbar buttons switch between windows; clicking the active one minimizes it.
- Hold Ctrl+T to stop the focused program, as in CraftOS.

## Apps

| App | What it does |
| --- | --- |
| Shell | The CraftOS shell in a window. `fg` and `bg` open new windows. |
| Files | Browse folders. Enter or double-click opens; `.lua` files run, other files open in the editor. `N` new file, `M` new folder, `E` edit, `D` delete. |
| Lua | The Lua prompt. |
| Worm | The built-in snake game. |
| Mac | Lists the apps on your real Mac and opens them there. Needs the Mac bridge below. |
| Settings | Desktop background colour. |
| About | Version and computer details. |

Any program you put in `/apps` appears in the start menu.

Programs run inside MC-OS get an `mcos` table: `mcos.launch(path, ...)` opens a program in a new window, `mcos.edit(path)` opens a file in the editor, and `mcos.version` is the OS version.
The standard `multishell` API also works, so existing programs that open tabs open windows instead.

## Opening apps on your Mac

The Mac app talks to a small helper, `bridge/mac_bridge.py`, that runs on the Mac where you play Minecraft.

1. Download [`bridge/mac_bridge.py`](bridge/mac_bridge.py) and run it in Terminal: `python3 mac_bridge.py`.
   It prints a token; keep the window open while you play.
2. Let CC:Tweaked reach your own Mac. It blocks local addresses by default.
   Open `computercraft-server.toml` (in your world's `serverconfig` folder, or in `.minecraft/config` on Fabric) and add this rule **above** the existing `$private` deny rule, then restart the world:

   ```toml
   [[http.rules]]
       host = "127.0.0.1"
       action = "allow"
   ```
3. In MC-OS, open **Mac**, type the token, then type to search and press Enter (or double-click) to open an app.

The bridge only listens on your Mac, needs the token, and only opens `.app` bundles from your Applications folders; it never runs commands sent from the game.
If Minecraft runs on a different computer, start the bridge with `--host 0.0.0.0`, allow that address instead, and point MC-OS at it from the Shell: `set mcos.bridge.url http://<mac-ip>:8765`.

## Layout

```
install.lua          installer
startup.lua          boots MC-OS
mcos/boot.lua        splash screen, then starts the window manager
mcos/wm.lua          window manager, desktop, taskbar, start menu
mcos/apps/*.lua      built-in apps
bridge/mac_bridge.py helper that runs on your Mac for the Mac app
tests/               headless test run
```

## Tests

`tests/run.py` boots MC-OS in a headless stand-in for an Advanced Computer that uses CC:Tweaked's real `window`, `colors` and `keys` APIs, then clicks and types through the desktop, Files, window controls, a crashing program, Settings, and the Mac app against a real bridge server.

```
pip install lupa
python3 tests/run.py
```
