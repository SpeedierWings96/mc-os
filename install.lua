-- MC-OS installer. In game, on an Advanced Computer, run:
--   wget run https://raw.githubusercontent.com/SpeedierWings96/mc-os/main/install.lua
-- Pass a branch name to install from somewhere other than main.

local branch = ... or "main"
local baseUrl = "https://raw.githubusercontent.com/SpeedierWings96/mc-os/" .. branch .. "/"

local files = {
  "startup.lua",
  "mcos/boot.lua",
  "mcos/wm.lua",
  "mcos/apps/files.lua",
  "mcos/apps/settings.lua",
  "mcos/apps/about.lua",
  "mcos/apps/mac.lua",
  "mcos/apps/macview.lua",
}

if not http then
  printError("HTTP is disabled on this server, so MC-OS can't be downloaded.")
  return
end

print("Installing MC-OS from " .. branch .. "...")
for _, file in ipairs(files) do
  write("  " .. file .. " ")
  local response, err = http.get(baseUrl .. file .. "?t=" .. os.epoch("utc"))
  if not response then
    print()
    printError("Download failed: " .. tostring(err))
    return
  end
  local body = response.readAll()
  response.close()
  local handle = fs.open("/" .. file, "w")
  handle.write(body)
  handle.close()
  print("ok")
end

print("Done. Rebooting into MC-OS...")
sleep(1)
os.reboot()
