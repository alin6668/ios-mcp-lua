-- App Cycle: Launch app, wait, take screenshot, kill
-- Usage: modify bundle_id below

local bundle_id = "com.apple.Preferences"  -- Settings app

print("=== App Cycle ===")
print("Target: " .. bundle_id)

-- Launch
print("Launching...")
local ok = ios.launch_app(bundle_id)
if not ok then
    print("Failed to launch " .. bundle_id)
    return
end
print("Launched successfully")

-- Wait for app to load
ios.sleep(2000)

-- Take screenshot
print("Taking screenshot...")
local b64 = ios.screenshot()
if b64 then
    print("Screenshot OK (" .. #b64 .. " bytes)")
end

-- Get frontmost to confirm
local app = ios.get_frontmost_app()
if app then
    print("Frontmost: " .. (app.bundleId or "?"))
end

-- Kill (optional)
-- ios.kill_app(bundle_id)
-- print("Killed")

print("=== Done ===")
