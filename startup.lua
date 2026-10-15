-- Boots MC-OS when the computer starts. Delete this file to boot into
-- plain CraftOS instead.
if fs.exists("/mcos/boot.lua") then
  shell.run("/mcos/boot.lua")
end
