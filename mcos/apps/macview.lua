-- Shows a Mac app live, through bridge/mac_bridge.py. Draws on an attached
-- monitor if there is one (bigger and in full colour), otherwise in this
-- window. Clicks, scrolling and typing are passed on to the app.
-- Usage: macview <app name>

local appName = ...
if not appName then
  printError("Usage: macview <app name>")
  return
end
if not http then
  printError("HTTP is disabled on this server.")
  return
end

local url = settings.get("mcos.bridge.url", "http://127.0.0.1:8765")
local headers = { ["X-Token"] = settings.get("mcos.bridge.token") or "" }

if multishell then multishell.setTitle(multishell.getCurrent(), appName) end

local monitor = peripheral.find("monitor", function(_, m) return m.isColour() end)
local monitorName = monitor and peripheral.getName(monitor)
local out = monitor or term.current()
local adaptive = monitor ~= nil
if monitor then monitor.setTextScale(0.5) end

local cellChar = {}
local codes = "0123456789abcdefghijklmnopqrstuv"
for i = 1, #codes do cellChar[codes:sub(i, i)] = string.char(127 + i) end

local pending, retryTimer
local frames = 0
local message = "Opening " .. appName .. " on your Mac..."

local function query(path, extra)
  return url .. path .. "?app=" .. textutils.urlEncode(appName) .. (extra or "")
end

-- In monitor mode this window shows what's going on.
local function drawInfo()
  if not monitor then return end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Showing " .. appName .. " on monitor " .. monitorName .. ".")
  print()
  term.setTextColor(colors.lightGray)
  print(message or ("Frames: " .. frames))
  print()
  print("Touch the monitor to click.")
  print("Type here to type into the app.")
end

local function drawMessage()
  if monitor then drawInfo() return end
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setTextColor(colors.lightGray)
  term.setCursorPos(math.max(1, math.floor((w - #message) / 2) + 1), math.floor(h / 2))
  term.write(message)
end

local function drawFrame(body)
  local lines = {}
  for line in body:gmatch("[^\n]+") do lines[#lines + 1] = line end
  if adaptive and lines[2] then
    local i = 0
    for hex in lines[2]:gmatch("%x+") do
      out.setPaletteColour(2 ^ i, tonumber(hex, 16))
      i = i + 1
    end
  end
  local w = out.getSize()
  local rows = math.floor((#lines - 2) / 3)
  for y = 1, rows do
    local text = (lines[y * 3]:gsub(".", cellChar))
    local fg, bg = lines[y * 3 + 1], lines[y * 3 + 2]
    out.setCursorPos(1, y)
    out.blit(text:sub(1, w), fg:sub(1, w), bg:sub(1, w))
  end
end

local function requestFrame()
  local w, h = out.getSize()
  frames = frames + 1
  pending = query("/frame", string.format("&w=%d&h=%d&palette=%s&n=%d",
    w, h, adaptive and "adaptive" or "fixed", frames))
  http.request(pending, nil, headers)
end

local function send(path, extra, body)
  http.request(query(path, extra), body or "", headers)
end

local function sendCell(path, x, y, extra)
  local w, h = out.getSize()
  send(path, string.format("&x=%d&y=%d&w=%d&h=%d", x, y, w, h) .. (extra or ""))
end

local passKeys = {
  enter = true, backspace = true, tab = true, delete = true, up = true, down = true,
  left = true, right = true, home = true, ["end"] = true, pageUp = true, pageDown = true,
}

http.post(url .. "/open", appName, headers)
drawMessage()
requestFrame()

while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "http_success" and a == pending then
    drawFrame(b.readAll())
    b.close()
    if message then message = nil end
    drawInfo()
    requestFrame()
  elseif ev == "http_failure" and a == pending then
    local code = c and c.getResponseCode()
    if c then c.close() end
    if code == 409 then
      message = "Waiting for " .. appName .. " to open a window..."
    elseif code == 403 then
      message = "Your Mac rejected the token. Set it again in the Mac app."
    elseif code == 501 then
      message = "The bridge isn't running on a Mac."
    else
      message = "Can't reach your Mac: " .. tostring(b)
    end
    drawMessage()
    pending = nil
    retryTimer = os.startTimer(1)
  elseif ev == "timer" and a == retryTimer then
    requestFrame()
  elseif ev == "mouse_click" and not monitor then
    sendCell("/click", b, c)
  elseif ev == "monitor_touch" and a == monitorName then
    sendCell("/click", b, c)
  elseif ev == "mouse_scroll" and not monitor then
    sendCell("/scroll", b, c, "&dir=" .. a)
  elseif ev == "char" or ev == "paste" then
    send("/type", nil, a)
  elseif ev == "key" then
    local name = keys.getName(a)
    if passKeys[name] then send("/key", "&name=" .. name) end
  elseif ev == "term_resize" and not monitor then
    drawMessage()
  end
end
