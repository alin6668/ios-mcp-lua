-- Auto Tap: Find and tap a UI element by text
-- Usage: modify target_text below, then run

local target_text = "Settings"  -- Change this to your target text

print("Looking for: " .. target_text)

-- Get UI elements
local ui = ios.get_ui_elements(200, true, true)
if not ui or not ui.elements then
    print("No UI elements found")
    return
end

print("Found " .. #ui.elements .. " clickable elements")

-- Find the target
for i, elem in ipairs(ui.elements) do
    if elem.text and string.find(string.lower(elem.text), string.lower(target_text)) then
        print("Found '" .. elem.text .. "' at index " .. i)
        if elem.tap then
            ios.tap(elem.tap.x, elem.tap.y)
            print("Tapped!")
            ios.sleep(500)
            return
        end
    end
end

print("Element '" .. target_text .. "' not found")
