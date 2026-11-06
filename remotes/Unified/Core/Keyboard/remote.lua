
local keyboard = libs.keyboard;
local fs = libs.fs;
local native_keyboard;

local function send_text(text)
    if not OS_LINUX then return keyboard.text(text); end
    if text == nil or text == "" then return; end
    if not native_keyboard then
        native_keyboard = dofile(fs.combine(fs.remotedir(), "wayland_ffi.lua"));
    end
    native_keyboard.send(text);
end

local function utf8_codepoint(cp)
    cp = tonumber(cp);
    if cp == nil or cp < 0 or cp > 0x10ffff or cp % 1 ~= 0
        or (cp >= 0xd800 and cp <= 0xdfff) then
        error("Invalid Unicode codepoint");
    end
    if cp < 0x80 then
        return string.char(cp);
    elseif cp < 0x800 then
        return string.char(0xc0 + math.floor(cp / 64), 0x80 + cp % 64);
    elseif cp < 0x10000 then
        return string.char(0xe0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64);
    end
    return string.char(0xf0 + math.floor(cp / 262144),
        0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64);
end

--@help Hold down key(s)
--@param keys:keys Keys to hold down
actions.down = function (...)
	keyboard.down(unpack({...}));
end

--@help Release key(s)
--@param keys:keys Keys to release
actions.up = function (...)
	keyboard.up(unpack({...}));
end

--@help Press key(s)
--@param keys:keys Keys to press down and release one by one
actions.press = function (...)
	keyboard.press(unpack({...}));
end

--@help Press key stroke
--@param keys:keys Keys to press down and release at the same time
actions.stroke = function (...)
	keyboard.stroke(unpack({...}));
end

--@help Send character
--@param chr:number UTF-8 character to press
actions.character = function (chr)
    if OS_LINUX then
        send_text(utf8_codepoint(chr));
    else
        keyboard.character(chr);
    end
end

--@help Send text
--@param text:string Text to write on screen
actions.text = function (text)
    send_text(text);
end
