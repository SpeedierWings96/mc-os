-- Settings: pick the desktop background colour.

local names = {
  "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
  "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

local function currentIndex()
  local value = settings.get("mcos.background", colors.cyan)
  for i, name in ipairs(names) do
    if colors[name] == value then return i end
  end
  return 10
end

local sel = currentIndex()
local scroll = 0

local function draw()
  local w, h = term.getSize()
  local rows = h - 2
  if sel <= scroll then scroll = sel - 1 end
  if sel > scroll + rows then scroll = sel - rows end

  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  term.write("Desktop background")

  local active = currentIndex()
  for row = 1, rows do
    local i = scroll + row
    local name = names[i]
    if not name then break end
    term.setCursorPos(1, row + 1)
    term.setBackgroundColor(i == sel and colors.gray or colors.black)
    term.setTextColor(colors.white)
    term.write(i == active and "* " or "  ")
    term.setBackgroundColor(colors[name])
    term.write("  ")
    term.setBackgroundColor(i == sel and colors.gray or colors.black)
    term.write(" " .. name .. string.rep(" ", w))
  end

  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.lightGray)
  term.write("Click or Enter to apply")
end

local function apply()
  settings.set("mcos.background", colors[names[sel]])
  settings.save()
end

while true do
  draw()
  local ev, a, b, c = os.pullEvent()
  if ev == "key" then
    if a == keys.up then sel = math.max(1, sel - 1)
    elseif a == keys.down then sel = math.min(#names, sel + 1)
    elseif a == keys.enter then apply()
    end
  elseif ev == "mouse_click" then
    local i = scroll + c - 1
    if c > 1 and names[i] then
      sel = i
      apply()
    end
  elseif ev == "mouse_scroll" then
    sel = math.max(1, math.min(#names, sel + a))
  end
end
