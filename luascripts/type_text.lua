-- Type Text: Input text on the device
-- Usage: modify the text below

local text = "Hello from Lua!"  -- Text to type
local delay_ms = 50  -- Delay between keystrokes

print("Typing: " .. text)
local ok = ios.input_text(text)
if ok then
    print("Text input successful")
else
    print("input_text failed, trying type_text fallback...")
    ok = ios.type_text(text, delay_ms)
    if ok then
        print("type_text successful")
    else
        print("Both methods failed")
    end
end
