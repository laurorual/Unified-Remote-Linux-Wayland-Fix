local keyboard = libs.keyboard;
local mouse = libs.mouse;
local fs = libs.fs;

local function quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'";
end

local function send_text(text)
    if not OS_LINUX then
        return keyboard.text(text);
    end
    if text == nil or text == "" then return; end
    local helper = fs.combine(fs.remotedir(), "../Keyboard/wayland_text.py");
    local out = libs.script.shell(
        "printf '%s' " .. quote(text) .. " | /usr/bin/python3 " .. quote(helper) .. " --send"
    );
    if out == nil or not tostring(out):match("^OK") then
        error("KDE Wayland text input failed");
    end
end

actions.KeyDown = function (...)
	keyboard.down(unpack({...}));
end

actions.KeyUp = function (...)
	keyboard.up(unpack({...}));
end

actions.Press = function (...)
	keyboard.press(unpack({...}));
end

actions.Stroke = function (...)
	keyboard.stroke(unpack({...}));
end

actions.Text = function (text)
    send_text(text);
end

actions.MouseDown = function(...)
	mouse.down(unpack({...}));
end

actions.MouseUp = function(...)
	mouse.up(unpack({...}));
end

actions.Click = function(...)
	local buttons = {...};
	mouse.down(unpack(buttons));
	mouse.up(unpack(buttons));
end

actions.DblClick = function(...)
	mouse.double(unpack({...}));
end

actions.MoveBy = function(x, y)
	mouse.moveraw(x,y);
end

actions.MoveTo = function (x, y, display)
	mouse.moveto(x, y, display);
end

actions.MoveToPx = function (x, y)
	mouse.moveto(x, y);
end

actions.Vert = function(amount)
	mouse.vscroll(amount);
end

actions.Horz = function(amount)
	mouse.hscroll(amount);
end

actions.ZoomIn = function ()
	mouse.zoomin();
end

actions.ZoomOut = function ()
	mouse.zoomout();
end
