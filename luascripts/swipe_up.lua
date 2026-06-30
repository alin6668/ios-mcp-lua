-- Swipe Up: Scroll up/down on screen
-- Usage: modify direction and distance below

local direction = "up"  -- "up" or "down"
local distance_pct = 0.6  -- percentage of screen height to swipe

local screen = ios.get_screen_info()
if not screen then
    print("Cannot get screen info")
    return
end

local w = screen.width or 375
local h = screen.height or 812
local cx = w / 2

local from_y, to_y
if direction == "up" then
    from_y = h * 0.7
    to_y = h * (0.7 - distance_pct * 0.8)
else
    from_y = h * 0.3
    to_y = h * (0.3 + distance_pct * 0.8)
end

print(string.format("Swiping %s from (%.0f, %.0f) to (%.0f, %.0f)", direction, cx, from_y, cx, to_y))
ios.swipe(cx, from_y, cx, to_y, 400)
print("Done")
