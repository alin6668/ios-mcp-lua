-- Take Screenshot: Capture and save screenshot info
-- The screenshot base64 data is returned in the result

print("Taking screenshot...")
local b64 = ios.screenshot()
if b64 then
    print("Screenshot captured! Length: " .. #b64 .. " bytes (base64)")
    print("First 100 chars: " .. string.sub(b64, 1, 100))
else
    print("Screenshot failed")
end
