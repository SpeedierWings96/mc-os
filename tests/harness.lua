-- A small headless stand-in for a CC:Tweaked Advanced Computer, enough to
-- boot MC-OS and drive it with events. Uses the real window/colors/keys
-- APIs from CC:Tweaked's ROM (downloaded by run.py).
--
-- Expects globals from the host: HOST_ROM, HOST_ROOT (directories) and
-- HOST_FS (list/isDir/exists/makeDir/delete/getSize helpers).

local W, H = 51, 19
local hexOf = {}
for i = 0, 15 do hexOf[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end

---------------------------------------------------------------------------
-- Native terminal

local text, fgs, bgs = {}, {}, {}
local cx, cy, fg, bg, blink = 1, 1, 1, 2 ^ 15, false
local function clearRow(y)
  text[y] = (" "):rep(W)
  fgs[y] = hexOf[fg]:rep(W)
  bgs[y] = hexOf[bg]:rep(W)
end
for y = 1, H do clearRow(y) end

local function put(row, x, s)
  if x > W or x + #s - 1 < 1 then return row end
  if x < 1 then s = s:sub(2 - x); x = 1 end
  s = s:sub(1, W - x + 1)
  return row:sub(1, x - 1) .. s .. row:sub(x + #s)
end

local native = {}
function native.blit(t, f, b)
  if cy >= 1 and cy <= H then
    text[cy] = put(text[cy], cx, t)
    fgs[cy] = put(fgs[cy], cx, f)
    bgs[cy] = put(bgs[cy], cx, b)
  end
  cx = cx + #t
end
function native.write(t)
  t = tostring(t)
  native.blit(t, hexOf[fg]:rep(#t), hexOf[bg]:rep(#t))
end
function native.clear() for y = 1, H do clearRow(y) end end
function native.clearLine() if cy >= 1 and cy <= H then clearRow(cy) end end
function native.getCursorPos() return cx, cy end
function native.setCursorPos(x, y) cx, cy = math.floor(x), math.floor(y) end
function native.setCursorBlink(b) blink = b end
function native.getCursorBlink() return blink end
function native.isColor() return true end
native.isColour = native.isColor
function native.getSize() return W, H end
function native.scroll(n)
  for _ = 1, n do
    table.remove(text, 1); table.remove(fgs, 1); table.remove(bgs, 1)
    text[H], fgs[H], bgs[H] = "", "", ""
    clearRow(H)
  end
end
function native.setTextColor(c) fg = c end
function native.getTextColor() return fg end
function native.setBackgroundColor(c) bg = c end
function native.getBackgroundColor() return bg end
function native.setPaletteColor() end
function native.getPaletteColor() return 0, 0, 0 end
native.setTextColour = native.setTextColor
native.getTextColour = native.getTextColor
native.setBackgroundColour = native.setBackgroundColor
native.getBackgroundColour = native.getBackgroundColor
native.setPaletteColour = native.setPaletteColor
native.getPaletteColour = native.getPaletteColor

local currentTerm = native
term = {}
function term.redirect(t)
  local old = currentTerm
  currentTerm = t
  return old
end
function term.current() return currentTerm end
function term.native() return native end
for k in pairs(native) do
  term[k] = function(...) return currentTerm[k](...) end
end

---------------------------------------------------------------------------
-- Filesystem

local function canon(path)
  local parts = {}
  for part in path:gmatch("[^/\\]+") do
    if part == ".." then
      table.remove(parts)
    elseif part ~= "." then
      table.insert(parts, part)
    end
  end
  return table.concat(parts, "/")
end

local function host(path)
  path = canon(path)
  if path == "rom" or path:sub(1, 4) == "rom/" then
    return HOST_ROM .. "/" .. path:sub(5)
  end
  return HOST_ROOT .. "/" .. path
end

fs = {}
function fs.combine(...) return canon(table.concat({ ... }, "/")) end
function fs.getName(p)
  p = canon(p)
  return p:match("([^/]+)$") or "root"
end
function fs.getDir(p)
  p = canon(p)
  return p:match("^(.*)/[^/]*$") or ""
end
function fs.exists(p) return HOST_FS.exists(host(p)) end
function fs.isDir(p) return HOST_FS.isDir(host(p)) end
function fs.isReadOnly(p) return canon(p):sub(1, 3) == "rom" end
function fs.getSize(p) return HOST_FS.getSize(host(p)) end
function fs.getFreeSpace() return 1000000 end
function fs.makeDir(p) HOST_FS.makeDir(host(p)) end
function fs.delete(p)
  if fs.isReadOnly(p) then error("/" .. canon(p) .. ": Access denied", 2) end
  HOST_FS.delete(host(p))
end
function fs.list(p)
  if not fs.isDir(p) then error("/" .. canon(p) .. ": Not a directory", 2) end
  local out = {}
  for name in HOST_FS.list(host(p)):gmatch("[^\n]+") do table.insert(out, name) end
  if canon(p) == "" then table.insert(out, "rom") end
  return out
end
function fs.open(p, mode)
  local f, err = io.open(host(p), mode)
  if not f then return nil, err end
  return {
    readAll = function() return f:read("a") end,
    readLine = function() return f:read("l") end,
    write = function(s) f:write(s) end,
    writeLine = function(s) f:write(s, "\n") end,
    flush = function() f:flush() end,
    close = function() f:close() end,
  }
end

local luaLoad = load
function loadfile(path, mode, env)
  local h = fs.open(path, "r")
  if not h then return nil, "File not found" end
  local src = h.readAll()
  h.close()
  return luaLoad(src, "@/" .. canon(path), mode, env or _G)
end
function dofile(path)
  local fn = assert(loadfile(path, nil, _G))
  return fn()
end

---------------------------------------------------------------------------
-- APIs

bit32 = {
  bor = function(a, b) return a | b end,
  band = function(a, b) return a & b end,
  bnot = function(a) return ~a end,
}

local function loadAPI(path)
  local env = setmetatable({}, { __index = _G })
  assert(loadfile(path, nil, env))()
  return env
end
colors = loadAPI("rom/apis/colors.lua")
colours = colors
keys = loadAPI("rom/apis/keys.lua")
window = loadAPI("rom/apis/window.lua")

textutils = {
  formatTime = function(t, twentyFour)
    local h = math.floor(t)
    local m = math.floor((t - h) * 60)
    return string.format("%d:%02d %s", (h - 1) % 12 + 1, m, h < 12 and "AM" or "PM")
  end,
}

local settingsStore = {}
settings = {
  get = function(k, d) local v = settingsStore[k] if v == nil then return d end return v end,
  set = function(k, v) settingsStore[k] = v end,
  save = function() return true end,
}

_HOST = "MC-OS headless harness"

local nextTimer, timers = 1, {}
local clock = 0
os.pullEventRaw = coroutine.yield
function os.pullEvent(filter)
  local ev = table.pack(coroutine.yield(filter))
  if ev[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(ev, 1, ev.n)
end
function os.startTimer() local id = nextTimer nextTimer = id + 1 timers[id] = true return id end
function os.cancelTimer(id) timers[id] = nil end
function os.time() return 14.5 end
function os.clock() return clock end
function os.epoch() return 0 end
function os.getComputerID() return 1 end
function os.getComputerLabel() return nil end
function os.reboot() error("reboot requested", 0) end
function os.shutdown() error("shutdown requested", 0) end
function sleep(n)
  local id = os.startTimer(n)
  repeat local _, t = os.pullEvent("timer") until t == id
end

function write(s)
  s = tostring(s)
  local w, h = term.getSize()
  for piece, nl in s:gmatch("([^\n]*)(\n?)") do
    local chunk = piece
    while #chunk > 0 do
      local x, y = term.getCursorPos()
      local room = w - x + 1
      term.write(chunk:sub(1, room))
      chunk = chunk:sub(room + 1)
      if #chunk > 0 then term.setCursorPos(1, y + 1) end
    end
    if nl == "\n" then
      local _, y = term.getCursorPos()
      if y >= h then term.scroll(1) term.setCursorPos(1, h) else term.setCursorPos(1, y + 1) end
    end
  end
end
function print(...)
  local parts = table.pack(...)
  for i = 1, parts.n do parts[i] = tostring(parts[i]) end
  write(table.concat(parts, "\t", 1, parts.n) .. "\n")
end
function printError(...)
  local old = term.getTextColor()
  term.setTextColor(colors.red)
  print(...)
  term.setTextColor(old)
end
function read()
  local s = ""
  while true do
    local ev, a = os.pullEvent()
    if ev == "char" then s = s .. a; term.write(a)
    elseif ev == "key" and a == keys.enter then print() return s
    end
  end
end

function os.run(env, path, ...)
  setmetatable(env, { __index = _G })
  local fn, err = loadfile(path, nil, env)
  if not fn then printError(err) return false end
  local ok, e = pcall(fn, ...)
  if not ok then
    if e and e ~= "" then printError(e) end
    return false
  end
  return true
end

shell = {
  resolve = function(p) return canon(p) end,
  getRunningProgram = function() return "mcos/boot.lua" end,
  run = function(path, ...) return os.run({ shell = shell }, path, ...) end,
}

---------------------------------------------------------------------------
-- Driver

local main = coroutine.create(function() shell.run("startup.lua") end)
local filter

local harness = {}
function harness.send(...)
  if coroutine.status(main) == "dead" then return false end
  local ev = ...
  if filter ~= nil and filter ~= ev and ev ~= "terminate" then return true end
  local ok, res = coroutine.resume(main, ...)
  if not ok then error(res, 0) end
  filter = res
  return coroutine.status(main) ~= "dead"
end
function harness.fireTimers()
  local pending = {}
  for id in pairs(timers) do table.insert(pending, id) end
  table.sort(pending)
  timers = {}
  clock = clock + 1
  for _, id in ipairs(pending) do harness.send("timer", id) end
end
function harness.boot()
  harness.send()
  for _ = 1, 40 do harness.fireTimers() end
end
function harness.screen() return table.concat(text, "\n") end
function harness.line(y) return text[y] end
function harness.fgLine(y) return fgs[y] end
function harness.bgLine(y) return bgs[y] end
function harness.alive() return coroutine.status(main) ~= "dead" end
function harness.click(x, y)
  harness.send("mouse_click", 1, x, y)
  harness.send("mouse_up", 1, x, y)
end
function harness.drag(x1, y1, x2, y2)
  harness.send("mouse_click", 1, x1, y1)
  harness.send("mouse_drag", 1, x2, y2)
  harness.send("mouse_up", 1, x2, y2)
end
function harness.type(s)
  for c in s:gmatch(".") do harness.send("char", c) end
end
function harness.key(name) harness.send("key", keys[name], false) end
return harness
