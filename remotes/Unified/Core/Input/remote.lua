local keyboard = libs.keyboard;
local mouse = libs.mouse;
local fs = libs.fs;
local native_keyboard;

local function send_text(text)
    if not OS_LINUX then return keyboard.text(text); end
    if text == nil or text == "" then return; end
    if not native_keyboard then
        native_keyboard = dofile(fs.combine(fs.remotedir(), "../Keyboard/wayland_ffi.lua"));
    end
    native_keyboard.send(text);
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
