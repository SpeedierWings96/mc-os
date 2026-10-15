-- MC-OS boot: splash screen, then the desktop.

local dir = fs.getDir(shell.getRunningProgram())

if not term.isColour() then
  printError("MC-OS needs an Advanced Computer (colour screen and mouse).")
  print("Starting CraftOS instead.")
  return
end

local wm = dofile(fs.combine(dir, "wm.lua"))

local w, h = term.getSize()
local function centre(y, text, fg)
  term.setCursorPos(math.floor((w - #text) / 2) + 1, y)
  term.setTextColor(fg)
  term.write(text)
end

term.setBackgroundColor(colors.black)
term.clear()
local mid = math.floor(h / 2)
centre(mid - 1, "MC-OS", colors.lime)
centre(mid, "version " .. wm.version, colors.lightGray)

local barWidth = math.min(20, w - 4)
local barX = math.floor((w - barWidth) / 2) + 1
for i = 1, barWidth do
  term.setCursorPos(barX + i - 1, mid + 2)
  term.setBackgroundColor(colors.lime)
  term.write(" ")
  sleep(0.03)
end
term.setBackgroundColor(colors.black)

wm.run(shell, dir)
print("MC-OS exited. Type 'mcos/boot' to start it again.")
