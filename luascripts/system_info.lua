-- System Info: Comprehensive device information dump

print("=== iOS MCP System Info ===")

-- Basic device info
local info = ios.get_device_info()
print(string.format("Device  : %s %s", info.model or "?", info.systemVersion or "?"))
print(string.format("Machine : %s", info.machine or "?"))

-- Screen
local screen = ios.get_screen_info()
if screen then
    print(string.format("Screen  : %.0fx%.0f @%.0fx", screen.width or 0, screen.height or 0, screen.scale or 1))
end

-- Brightness
local brightness = ios.get_brightness()
print(string.format("Bright  : %.0f%%", brightness * 100))

-- Volume
local volume = ios.get_volume()
print(string.format("Volume  : %.0f%%", volume * 100))

-- Clipboard
local clip = ios.get_clipboard()
if clip then
    print("Clipboard: " .. (clip.text or "(empty)"))
end

-- Frontmost app
local app = ios.get_frontmost_app()
if app then
    print(string.format("App     : %s (pid=%s)", app.bundleId or "?", tostring(app.pid or "?")))
end

-- Running apps count
local running = ios.list_running_apps()
if running then
    print("Running apps: " .. #running)
end

-- Storage via shell
local result = ios.run_command("df -h /var | tail -1", 5)
if result and result.stdout then
    print("Disk: " .. result.stdout:gsub("%s+", " "):sub(1, 80))
end

-- Uptime
local uptime = ios.run_command("uptime", 3)
if uptime and uptime.stdout then
    print("Uptime: " .. uptime.stdout:gsub("\n", ""))
end

print("=== Done ===")
