-- About MC-OS: version and computer details.

local function line(label, value)
  term.setTextColor(colors.lightGray)
  write(label .. ": ")
  term.setTextColor(colors.white)
  print(tostring(value))
end

term.setTextColor(colors.lime)
print("MC-OS " .. (mcos and mcos.version or "?"))
print()
line("Host", _HOST)
line("Computer ID", os.getComputerID())
line("Label", os.getComputerLabel() or "(none)")
line("Free space", math.floor(fs.getFreeSpace("/") / 1024) .. " KB")
line("Uptime", math.floor(os.clock()) .. " s")
print()
term.setTextColor(colors.lightGray)
print("Press any key to close.")
os.pullEvent("key")
