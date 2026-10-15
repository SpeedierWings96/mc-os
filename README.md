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
| Settings | Desktop background colour. |
| About | Version and computer details. |

Any program you put in `/apps` appears in the start menu.

Programs run inside MC-OS get an `mcos` table: `mcos.launch(path, ...)` opens a program in a new window, `mcos.edit(path)` opens a file in the editor, and `mcos.version` is the OS version.
The standard `multishell` API also works, so existing programs that open tabs open windows instead.

## Layout

```
install.lua          installer
startup.lua          boots MC-OS
mcos/boot.lua        splash screen, then starts the window manager
mcos/wm.lua          window manager, desktop, taskbar, start menu
mcos/apps/*.lua      built-in apps
tests/               headless test run
```

## Tests

`tests/run.py` boots MC-OS in a headless stand-in for an Advanced Computer that uses CC:Tweaked's real `window`, `colors` and `keys` APIs, then clicks and types through the desktop, Files, window controls, a crashing program and Settings.

```
pip install lupa
python3 tests/run.py
```
