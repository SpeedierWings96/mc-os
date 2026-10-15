-- Mac: open apps on your real Mac through bridge/mac_bridge.py and show
-- them in game. Type to search, Enter or double-click to open.

local url = settings.get("mcos.bridge.url", "http://127.0.0.1:8765")
local apps, shown = {}, {}
local filter = ""
local sel, scroll = 1, 0
local status, statusColour = nil, colors.white
local problem = nil -- multi-line help shown instead of the list
local buttons = {}
local lastClick = { index = nil, time = 0 }

local function token()
  return settings.get("mcos.bridge.token")
end

local function headers()
  return { ["X-Token"] = token() or "" }
end

local function askToken()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("Run this on your Mac:")
  term.setTextColor(colors.yellow)
  print("  python3 mac_bridge.py")
  term.setTextColor(colors.white)
  print("and type the token it prints.")
  print()
  write("Token: ")
  local value = read()
  if value ~= "" then
    settings.set("mcos.bridge.token", value)
    settings.save()
  end
end

local function setFilter(text)
  filter = text
  shown = {}
  local needle = filter:lower()
  for _, name in ipairs(apps) do
    if name:lower():find(needle, 1, true) then table.insert(shown, name) end
  end
  sel, scroll = 1, 0
end

local function reload()
  problem = nil
  if not http then
    problem = { "HTTP is disabled on this server,", "so MC-OS can't reach your Mac." }
    return
  end
  local response, err, failed = http.get(url .. "/apps", headers())
  if not response then
    if failed and failed.getResponseCode() == 403 then
      failed.close()
      problem = { "Your Mac rejected the token.", "Click Token to enter it again." }
    else
      problem = {
        "Can't reach your Mac at " .. url,
        tostring(err),
        "",
        "Is mac_bridge.py running on your Mac?",
        "CC:Tweaked also blocks local addresses",
        "by default: see the README to allow it.",
      }
    end
    return
  end
  apps = {}
  for line in response.readAll():gmatch("[^\n]+") do table.insert(apps, line) end
  response.close()
  setFilter(filter)
end

-- Opens the app on the Mac and shows it in a viewer window (or on an
-- attached monitor).
local function open(name)
  mcos.launch(mcos.path("apps/macview.lua"), name)
end

local function rows()
  local _, h = term.getSize()
  return h - 2
end

local function button(label, x, y, action)
  term.setCursorPos(x, y)
  term.write(label)
  table.insert(buttons, { x1 = x, x2 = x + #label - 1, y = y, action = action })
  return x + #label + 1
end

local function draw()
  local w, h = term.getSize()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()

  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.lightGray)
  term.setTextColor(colors.black)
  term.clearLine()
  local search = " Search: " .. filter
  term.write(search)
  local bx = w - 15
  if bx > #search + 1 then
    bx = button("[Reload]", bx, 1, reload)
    button("[Token]", bx, 1, function() askToken() reload() end)
  end

  term.setBackgroundColor(colors.black)
  if problem then
    for i, line in ipairs(problem) do
      term.setCursorPos(2, i + 2)
      term.setTextColor(i == 1 and colors.orange or colors.lightGray)
      term.write(line)
    end
  else
    local n = rows()
    if sel <= scroll then scroll = sel - 1 end
    if sel > scroll + n then scroll = sel - n end
    scroll = math.max(0, scroll)
    for row = 1, n do
      local i = scroll + row
      if not shown[i] then break end
      term.setCursorPos(1, row + 1)
      term.setBackgroundColor(i == sel and colors.blue or colors.black)
      term.setTextColor(colors.white)
      term.write(" " .. shown[i] .. string.rep(" ", w))
    end
    if #shown == 0 then
      term.setCursorPos(2, 3)
      term.setTextColor(colors.lightGray)
      term.write(#apps == 0 and "No apps found." or "No apps match.")
    end
  end

  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(status and statusColour or colors.white)
  local hint = status or "Type to search, Enter to open"
  term.write(hint:sub(1, w) .. string.rep(" ", w - #hint))
  status = nil

  term.setCursorPos(#search + 1, 1)
  term.setTextColor(colors.black)
  term.setCursorBlink(not problem)
end

if not token() and http then askToken() end
reload()

while true do
  draw()
  local ev, a, b, c = os.pullEvent()
  if ev == "char" and not problem then
    setFilter(filter .. a)
  elseif ev == "paste" and not problem then
    setFilter(filter .. a)
  elseif ev == "key" then
    if a == keys.backspace and #filter > 0 then setFilter(filter:sub(1, -2))
    elseif a == keys.up then sel = math.max(1, sel - 1)
    elseif a == keys.down then sel = math.min(#shown, sel + 1)
    elseif a == keys.enter and shown[sel] then open(shown[sel])
    end
  elseif ev == "mouse_click" then
    local handled = false
    for _, btn in ipairs(buttons) do
      if c == btn.y and b >= btn.x1 and b <= btn.x2 then
        btn.action()
        handled = true
        break
      end
    end
    local i = scroll + c - 1
    if not handled and not problem and c > 1 and shown[i] then
      local now = os.clock()
      sel = i
      if lastClick.index == i and now - lastClick.time < 0.5 then
        lastClick.index = nil
        open(shown[i])
      else
        lastClick.index, lastClick.time = i, now
      end
    end
  elseif ev == "mouse_scroll" and not problem then
    sel = math.max(1, math.min(#shown, sel + a))
  end
end
