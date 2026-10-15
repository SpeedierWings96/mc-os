-- Files: browse, open, edit, create and delete files.
-- Enter or double-click opens: folders open, .lua files run in a new
-- window, anything else opens in the editor.

local path = shell and shell.resolve(({ ... })[1] or "/") or ""
local entries = {}
local sel, scroll = 1, 0
local status = nil
local lastClick = { index = nil, time = 0 }

local function display(p)
  return "/" .. p
end

local function refresh()
  entries = {}
  if path ~= "" then
    table.insert(entries, { name = "..", dir = true })
  end
  local ok, list = pcall(fs.list, path)
  if not ok then
    status = list
    list = {}
  end
  local dirs, files = {}, {}
  for _, name in ipairs(list) do
    local full = fs.combine(path, name)
    if fs.isDir(full) then
      table.insert(dirs, { name = name, dir = true })
    else
      table.insert(files, { name = name, size = fs.getSize(full) })
    end
  end
  table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
  for _, e in ipairs(dirs) do table.insert(entries, e) end
  for _, e in ipairs(files) do table.insert(entries, e) end
  sel = math.max(1, math.min(sel, #entries))
end

local function sizeText(n)
  if n >= 1024 then return string.format("%.1fK", n / 1024) end
  return tostring(n) .. "B"
end

local function listRows()
  local _, h = term.getSize()
  return h - 2
end

local function draw()
  local w, h = term.getSize()
  local rows = listRows()
  if sel <= scroll then scroll = sel - 1 end
  if sel > scroll + rows then scroll = sel - rows end
  scroll = math.max(0, scroll)

  term.setBackgroundColor(colors.black)
  term.clear()

  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.lightGray)
  term.setTextColor(colors.black)
  local title = " " .. display(path)
  term.write(title .. string.rep(" ", w - #title))

  for row = 1, rows do
    local i = scroll + row
    local e = entries[i]
    if not e then break end
    term.setCursorPos(1, row + 1)
    term.setBackgroundColor(i == sel and colors.blue or colors.black)
    term.setTextColor(e.dir and colors.yellow or colors.white)
    local name = e.dir and (e.name .. "/") or e.name
    local size = e.size and sizeText(e.size) or ""
    local room = w - #size - 2
    if #name > room then name = name:sub(1, room - 1) .. "~" end
    term.write(" " .. name .. string.rep(" ", w - #name - #size - 2) .. size .. " ")
  end

  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(status and colors.orange or colors.white)
  local hint = status or "Enter open  E edit  N new  M folder  D delete"
  term.write(hint:sub(1, w) .. string.rep(" ", w - #hint))
  status = nil
end

local function prompt(label)
  local w, h = term.getSize()
  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.white)
  term.write(string.rep(" ", w))
  term.setCursorPos(1, h)
  term.write(label)
  local value = read()
  if value == "" then return nil end
  return value
end

local function selected()
  local e = entries[sel]
  if not e then return nil end
  return e, fs.combine(path, e.name)
end

local function open()
  local e, full = selected()
  if not e then return end
  if e.name == ".." then
    path = fs.getDir(path)
    sel, scroll = 1, 0
  elseif e.dir then
    path = full
    sel, scroll = 1, 0
  elseif full:match("%.lua$") then
    mcos.launch("/" .. full)
  else
    mcos.edit("/" .. full)
  end
  refresh()
end

local function edit()
  local e, full = selected()
  if e and not e.dir then mcos.edit("/" .. full) end
end

local function newFile(isDir)
  local name = prompt(isDir and "Folder name: " or "File name: ")
  if not name then return end
  local full = fs.combine(path, name)
  if fs.exists(full) then
    status = name .. " already exists"
    return
  end
  local ok, err = pcall(function()
    if isDir then
      fs.makeDir(full)
    else
      fs.open(full, "w").close()
    end
  end)
  if not ok then status = err end
  refresh()
  if ok and not isDir then mcos.edit("/" .. full) end
end

local function delete()
  local e, full = selected()
  if not e or e.name == ".." then return end
  local answer = prompt("Delete " .. e.name .. "? (y/n) ")
  if answer and answer:lower():sub(1, 1) == "y" then
    local ok, err = pcall(fs.delete, full)
    if not ok then status = err end
    refresh()
  end
end

refresh()
while true do
  draw()
  local ev, a, b, c = os.pullEvent()
  if ev == "key" then
    if a == keys.up then sel = math.max(1, sel - 1)
    elseif a == keys.down then sel = math.min(#entries, sel + 1)
    elseif a == keys.pageUp then sel = math.max(1, sel - listRows())
    elseif a == keys.pageDown then sel = math.min(#entries, sel + listRows())
    elseif a == keys.enter then open()
    elseif a == keys.backspace and path ~= "" then
      path = fs.getDir(path)
      sel, scroll = 1, 0
      refresh()
    elseif a == keys.delete then delete()
    end
  elseif ev == "char" then
    -- Letter commands use char events so the letter doesn't leak into a
    -- prompt opened by the command.
    a = a:lower()
    if a == "e" then edit()
    elseif a == "n" then newFile(false)
    elseif a == "m" then newFile(true)
    elseif a == "d" then delete()
    end
  elseif ev == "mouse_click" then
    local i = scroll + c - 1
    if c > 1 and entries[i] then
      local now = os.clock()
      if lastClick.index == i and now - lastClick.time < 0.5 then
        sel = i
        lastClick.index = nil
        open()
      else
        sel = i
        lastClick.index, lastClick.time = i, now
      end
    end
  elseif ev == "mouse_scroll" then
    sel = math.max(1, math.min(#entries, sel + a))
  elseif ev == "term_resize" then
    -- redrawn at the top of the loop
  end
end
