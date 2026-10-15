-- MC-OS window manager.
-- Runs programs as coroutines, each inside its own window, and draws a
-- desktop, taskbar and start menu around them.

local wm = {}

local VERSION = "0.1.0"

local parentTerm, root
local W, H
local base, outerShell

local procs = {}      -- z-order: last entry is drawn on top
local focused = nil   -- proc receiving keyboard input
local current = nil   -- proc whose coroutine is running right now
local nextId = 1
local running = true

local startOpen = false
local drag = nil      -- { p = proc, dx = offset of the grab point }
local capture = nil   -- proc that gets mouse_drag/mouse_up after a click
local clockTimer = nil

local apps = {}
local menuItems = {}
local taskRegions = {}
local iconRegions = {}

local api        -- the `mcos` table handed to programs
local msApi      -- multishell-compatible table handed to programs
local programShell -- shell handed to programs (see below)

--------------------------------------------------------------------------
-- Helpers

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function fit(text, width)
  if #text > width then return text:sub(1, width) end
  return text .. string.rep(" ", width - #text)
end

local function background()
  return settings.get("mcos.background", colors.cyan)
end

local function byId(id)
  for _, p in ipairs(procs) do
    if p.id == id then return p end
  end
end

local function indexOf(p)
  for i, q in ipairs(procs) do
    if q == p then return i end
  end
end

local function topVisible()
  for i = #procs, 1, -1 do
    if not procs[i].minimized then return procs[i] end
  end
end

local function raise(p)
  local i = indexOf(p)
  if i then
    table.remove(procs, i)
    table.insert(procs, p)
  end
  p.minimized = false
  focused = p
end

local function minimize(p)
  p.minimized = true
  if focused == p then focused = topVisible() end
end

local function kill(p)
  p.dead = true
  if capture == p then capture = nil end
  if drag and drag.p == p then drag = nil end
end

--------------------------------------------------------------------------
-- Processes

local function resume(p, ...)
  if p.dead then return end
  local ev = ...
  if p.started and p.filter ~= nil and p.filter ~= ev and ev ~= "terminate" then
    return
  end
  p.started = true

  local prevTerm = term.redirect(p.term)
  local prevProc = current
  current = p
  local ok, res = coroutine.resume(p.co, ...)
  current = prevProc
  p.term = term.current()
  term.redirect(prevTerm)

  if not ok then
    -- The wrapper below catches program errors, so this is rare.
    p.dead = true
    p.err = res
  elseif coroutine.status(p.co) == "dead" then
    p.dead = true
  else
    p.filter = res
  end
end

local function sendMouse(p, ev, btn, x, y)
  resume(p, ev, btn, x - p.x + 1, y - p.y)
end

local function placeNew()
  local w = math.min(38, W - 2)
  local h = math.min(12, H - 4)
  local offset = (#procs % 4) * 2
  local x = clamp(4 + offset * 2, 1, math.max(1, W - w + 1))
  local y = clamp(2 + offset, 1, math.max(1, H - h - 1))
  return x, y, w, h
end

-- opts: path (string), args (table, may have .n), title, env, focus (bool)
function wm.launch(opts)
  local args = opts.args or { n = 0 }
  args.n = args.n or #args

  local p = {
    id = nextId,
    title = opts.title or fs.getName(opts.path):gsub("%.lua$", ""),
  }
  nextId = nextId + 1
  p.x, p.y, p.w, p.h = placeNew()
  p.window = window.create(root, p.x, p.y + 1, p.w, p.h, true)
  p.term = p.window

  local env = opts.env or {}
  if env.shell == nil then env.shell = programShell end
  env.multishell = msApi
  env.mcos = api

  p.co = coroutine.create(function()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    local ok = os.run(env, opts.path, table.unpack(args, 1, args.n))
    if not ok then
      -- os.run already printed the error; keep it on screen.
      term.setTextColor(colors.lightGray)
      print("Press any key to close.")
      os.pullEvent("key")
    end
  end)

  if opts.focus == false and focused then
    table.insert(procs, #procs, p)
  else
    table.insert(procs, p)
    focused = p
  end
  resume(p)
  return p.id
end

local function launchApp(app)
  return wm.launch({ path = app.path, args = app.args, title = app.name })
end

local function toggleMaximize(p)
  if p.restore then
    p.x, p.y, p.w, p.h = table.unpack(p.restore)
    p.restore = nil
  else
    p.restore = { p.x, p.y, p.w, p.h }
    p.x, p.y, p.w, p.h = 1, 1, W, H - 2
  end
  p.window.reposition(p.x, p.y + 1, p.w, p.h)
  resume(p, "term_resize")
end

--------------------------------------------------------------------------
-- APIs given to programs

msApi = {
  getFocus = function() return focused and focused.id end,
  setFocus = function(id)
    local p = byId(id)
    if p then raise(p) return true end
    return false
  end,
  getTitle = function(id) local p = byId(id) return p and p.title end,
  setTitle = function(id, title)
    local p = byId(id)
    if p then p.title = title end
  end,
  getCurrent = function() return current and current.id end,
  getCount = function() return #procs end,
  launch = function(env, path, ...)
    return wm.launch({ env = env, path = path, args = table.pack(...), focus = false })
  end,
}

api = {
  version = VERSION,
  launch = function(path, ...)
    return wm.launch({ path = path, args = table.pack(...) })
  end,
  edit = function(path)
    return wm.launch({ path = "/rom/programs/edit.lua", args = { path, n = 1 }, title = fs.getName(path) })
  end,
  apps = function() return apps end,
  close = function() if current then kill(current) end end,
}

-- The shell handed to programs that don't bring their own. It is the shell
-- MC-OS started from, except that new tabs open as MC-OS windows.
programShell = setmetatable({
  openTab = function(...)
    return msApi.launch({}, "/rom/programs/shell.lua", ...)
  end,
  switchTab = function(id) msApi.setFocus(id) end,
}, { __index = function(_, k) return outerShell[k] end })

--------------------------------------------------------------------------
-- App list

local function loadApps()
  apps = {
    { name = "Shell", path = "/rom/programs/shell.lua", desktop = true },
    { name = "Files", path = fs.combine(base, "apps/files.lua"), desktop = true },
    { name = "Mac", path = fs.combine(base, "apps/mac.lua"), desktop = true },
    { name = "Lua", path = "/rom/programs/lua.lua" },
    { name = "Worm", path = "/rom/programs/fun/worm.lua" },
    { name = "Settings", path = fs.combine(base, "apps/settings.lua"), desktop = true },
    { name = "About", path = fs.combine(base, "apps/about.lua") },
  }
  -- Any program dropped into /apps shows up in the start menu.
  if fs.isDir("/apps") then
    local names = fs.list("/apps")
    table.sort(names)
    for _, name in ipairs(names) do
      local full = fs.combine("/apps", name)
      if not fs.isDir(full) then
        table.insert(apps, { name = name:gsub("%.lua$", ""), path = "/" .. full })
      end
    end
  end

  menuItems = {}
  for _, app in ipairs(apps) do
    table.insert(menuItems, { label = app.name, action = function() launchApp(app) end })
  end
  table.insert(menuItems, { separator = true })
  table.insert(menuItems, { label = "Exit to CraftOS", action = function() running = false end })
  table.insert(menuItems, { label = "Reboot", action = function() os.reboot() end })
  table.insert(menuItems, { label = "Shut down", action = function() os.shutdown() end })
end

--------------------------------------------------------------------------
-- Drawing

local function drawDesktop()
  root.setBackgroundColor(background())
  root.clear()

  local mark = "MC-OS " .. VERSION
  root.setTextColor(colors.white)
  root.setCursorPos(W - #mark, 1)
  root.write(mark)

  iconRegions = {}
  local y = 2
  for _, app in ipairs(apps) do
    if app.desktop and y < H - 1 then
      local label = " " .. app.name .. " "
      root.setCursorPos(2, y)
      root.setBackgroundColor(colors.lightGray)
      root.setTextColor(colors.black)
      root.write(label)
      table.insert(iconRegions, { x1 = 2, x2 = 1 + #label, y = y, app = app })
      y = y + 2
    end
  end
end

local function drawFrame(p)
  local bar = p == focused and colors.blue or colors.gray
  root.setCursorPos(p.x, p.y)
  root.setBackgroundColor(bar)
  root.setTextColor(colors.white)
  root.write(fit(" " .. p.title, math.max(0, p.w - 6)))
  -- Buttons: minimize, maximize, close.
  root.write(" ")
  root.setTextColor(colors.yellow)
  root.write("-")
  root.write(" ")
  root.setTextColor(colors.lime)
  root.write("+")
  root.write(" ")
  root.setBackgroundColor(colors.red)
  root.setTextColor(colors.white)
  root.write("x")
end

local function drawTaskbar()
  root.setCursorPos(1, H)
  root.setBackgroundColor(colors.gray)
  root.clearLine()

  root.setBackgroundColor(startOpen and colors.lime or colors.green)
  root.setTextColor(colors.white)
  root.write(" Start ")

  local clock = textutils.formatTime(os.time(), false)
  local clockX = W - #clock

  taskRegions = {}
  local x = 9
  for _, p in ipairs(procs) do
    local label = " " .. p.title:sub(1, 8) .. " "
    if x + #label > clockX - 1 then break end
    root.setCursorPos(x, H)
    if p == focused and not p.minimized then
      root.setBackgroundColor(colors.lightGray)
      root.setTextColor(colors.black)
    else
      root.setBackgroundColor(colors.gray)
      root.setTextColor(p.minimized and colors.lightGray or colors.white)
    end
    root.write(label)
    table.insert(taskRegions, { x1 = x, x2 = x + #label - 1, p = p })
    x = x + #label + 1
  end

  root.setCursorPos(clockX, H)
  root.setBackgroundColor(colors.gray)
  root.setTextColor(colors.white)
  root.write(clock)
end

local function menuGeometry()
  local width = 0
  for _, item in ipairs(menuItems) do
    if item.label then width = math.max(width, #item.label) end
  end
  width = width + 2
  local top = H - #menuItems
  return 1, top, width
end

local function drawMenu()
  local x, top, width = menuGeometry()
  for i, item in ipairs(menuItems) do
    root.setCursorPos(x, top + i - 1)
    root.setBackgroundColor(colors.white)
    if item.separator then
      root.setTextColor(colors.lightGray)
      root.write(string.rep("-", width))
    else
      root.setTextColor(colors.black)
      root.write(fit(" " .. item.label, width))
    end
  end
end

local function composite()
  drawDesktop()
  for _, p in ipairs(procs) do
    if not p.minimized then
      drawFrame(p)
      p.window.redraw()
    end
  end
  drawTaskbar()
  if startOpen then drawMenu() end

  root.setVisible(true)
  if focused and not focused.minimized and not startOpen then
    focused.window.restoreCursor()
  else
    root.setCursorBlink(false)
  end
end

--------------------------------------------------------------------------
-- Input

local function procAt(x, y)
  for i = #procs, 1, -1 do
    local p = procs[i]
    if not p.minimized and x >= p.x and x < p.x + p.w and y >= p.y and y <= p.y + p.h then
      return p
    end
  end
end

local function onClick(btn, x, y)
  if startOpen then
    startOpen = false
    local mx, top, width = menuGeometry()
    local item = menuItems[y - top + 1]
    if x >= mx and x < mx + width and item and item.action then item.action() end
    return
  end

  if y == H then
    if x <= 7 then
      startOpen = true
      return
    end
    for _, r in ipairs(taskRegions) do
      if x >= r.x1 and x <= r.x2 then
        if r.p == focused and not r.p.minimized then minimize(r.p) else raise(r.p) end
        return
      end
    end
    return
  end

  local p = procAt(x, y)
  if p then
    raise(p)
    if y == p.y then
      local right = p.x + p.w - 1
      if x == right then
        kill(p)
      elseif x == right - 2 then
        toggleMaximize(p)
      elseif x == right - 4 then
        minimize(p)
      else
        drag = { p = p, dx = x - p.x }
      end
    else
      capture = p
      sendMouse(p, "mouse_click", btn, x, y)
    end
    return
  end

  for _, r in ipairs(iconRegions) do
    if y == r.y and x >= r.x1 and x <= r.x2 then
      launchApp(r.app)
      return
    end
  end
end

local function onDrag(btn, x, y)
  if drag then
    local p = drag.p
    p.x = clamp(x - drag.dx, 4 - p.w, W - 3)
    p.y = clamp(y, 1, H - 2)
    p.restore = nil
    p.window.reposition(p.x, p.y + 1)
  elseif capture and not capture.dead then
    sendMouse(capture, "mouse_drag", btn, x, y)
  end
end

local function onUp(btn, x, y)
  if drag then
    drag = nil
  elseif capture then
    if not capture.dead then sendMouse(capture, "mouse_up", btn, x, y) end
    capture = nil
  end
end

local function onResize()
  W, H = parentTerm.getSize()
  root.reposition(1, 1, W, H)
  for _, p in ipairs(procs) do
    if p.restore then
      p.w, p.h = W, H - 2
      p.window.reposition(p.x, p.y + 1, p.w, p.h)
      resume(p, "term_resize")
    else
      p.x = clamp(p.x, 4 - p.w, W - 3)
      p.y = clamp(p.y, 1, H - 2)
      p.window.reposition(p.x, p.y + 1)
    end
  end
end

local function broadcast(...)
  local snapshot = { table.unpack(procs) }
  for _, p in ipairs(snapshot) do resume(p, ...) end
end

local function handle(ev)
  local name = ev[1]
  if name == "timer" and ev[2] == clockTimer then
    clockTimer = os.startTimer(1)
  elseif name == "mouse_click" then
    onClick(ev[2], ev[3], ev[4])
  elseif name == "mouse_drag" then
    onDrag(ev[2], ev[3], ev[4])
  elseif name == "mouse_up" then
    onUp(ev[2], ev[3], ev[4])
  elseif name == "mouse_scroll" then
    local p = procAt(ev[3], ev[4])
    if p and ev[4] > p.y then sendMouse(p, "mouse_scroll", ev[2], ev[3], ev[4]) end
  elseif name == "key" or name == "key_up" or name == "char" or name == "paste" or name == "terminate" then
    if focused and not focused.minimized then
      resume(focused, table.unpack(ev, 1, ev.n))
    end
  elseif name == "term_resize" then
    onResize()
  else
    broadcast(table.unpack(ev, 1, ev.n))
  end
end

local function reap()
  for i = #procs, 1, -1 do
    if procs[i].dead then table.remove(procs, i) end
  end
  if focused and focused.dead then focused = topVisible() end
end

--------------------------------------------------------------------------
-- Main loop

-- shell: the shell that started MC-OS, handed to programs so they can
-- resolve paths. dir: the MC-OS install directory.
function wm.run(shell, dir)
  outerShell = shell
  base = dir
  parentTerm = term.current()
  W, H = parentTerm.getSize()
  root = window.create(parentTerm, 1, 1, W, H, false)
  running = true

  loadApps()
  clockTimer = os.startTimer(1)

  composite()
  while running do
    local ev = table.pack(os.pullEventRaw())
    root.setVisible(false)
    handle(ev)
    reap()
    composite()
  end

  term.redirect(parentTerm)
  parentTerm.setBackgroundColor(colors.black)
  parentTerm.setTextColor(colors.white)
  parentTerm.clear()
  parentTerm.setCursorPos(1, 1)
end

wm.version = VERSION

return wm
