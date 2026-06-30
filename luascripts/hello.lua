-- Hello World example for iOS MCP Lua Scripting
-- Demonstrates basic ios.* API usage

print("=== iOS MCP Lua Script ===")

-- Get device info
local info = ios.get_device_info()
print("Device: " .. (info.systemName or "?") .. " " .. (info.systemVersion or "?"))

-- Get frontmost app
local app = ios.get_frontmost_app()
if app then
    print("Frontmost app: " .. (app.bundleId or "unknown"))
end

-- Get screen info
local screen = ios.get_screen_info()
if screen then
    print(string.format("Screen: %.0fx%.0f", screen.width or 0, screen.height or 0))
end

-- Read clipboard
local clip = ios.get_clipboard()
if clip and clip.text then
    print("Clipboard: " .. clip.text)
end

print("=== Done ===")
