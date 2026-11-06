-- KDE Wayland text input, entirely inside the Unified Remote Lua VM.
-- No shell, Python, socket server or clipboard subprocess is used.
local ffi = require("ffi");
local bit = require("bit");
assert(ffi.os == "Linux", "Direct Wayland text input requires Linux");
if not pcall(ffi.typeof, "ur_keyboard_dbus_iter") then ffi.cdef[[
typedef struct {
    void *dummy1; void *dummy2; unsigned int dummy3;
    int dummy4, dummy5, dummy6, dummy7, dummy8, dummy9, dummy10, dummy11, pad1;
    void *pad2; void *pad3;
} ur_keyboard_dbus_iter;
typedef struct { const char *rules, *model, *layout, *variant, *options; } ur_keyboard_xkb_names;
typedef struct { long seconds; long nanoseconds; } ur_keyboard_timespec;
int open(const char *path, int flags, ...);
int close(int fd);
int flock(int fd, int operation);
unsigned int getuid(void);
int nanosleep(const ur_keyboard_timespec *request, ur_keyboard_timespec *remaining);
int clock_gettime(int clock, ur_keyboard_timespec *time);
int dbus_threads_init_default(void);
void *dbus_bus_get_private(int type, void *error);
int dbus_connection_get_is_connected(void *connection);
void dbus_connection_set_exit_on_disconnect(void *connection, int enabled);
void dbus_connection_close(void *connection);
void dbus_connection_unref(void *connection);
void *dbus_message_new_method_call(const char *destination, const char *path, const char *interface, const char *method);
void dbus_message_unref(void *message);
void dbus_message_iter_init_append(void *message, ur_keyboard_dbus_iter *iter);
int dbus_message_iter_append_basic(ur_keyboard_dbus_iter *iter, int type, const void *value);
int dbus_message_iter_init(void *message, ur_keyboard_dbus_iter *iter);
int dbus_message_iter_get_arg_type(ur_keyboard_dbus_iter *iter);
int dbus_message_iter_get_element_type(ur_keyboard_dbus_iter *iter);
int dbus_message_iter_next(ur_keyboard_dbus_iter *iter);
void dbus_message_iter_recurse(ur_keyboard_dbus_iter *iter, ur_keyboard_dbus_iter *sub);
void dbus_message_iter_get_basic(ur_keyboard_dbus_iter *iter, void *value);
void *dbus_connection_send_with_reply_and_block(void *connection, void *message, int timeout_ms, void *error);
void *libevdev_new(void);
void libevdev_free(void *device);
void libevdev_set_name(void *device, const char *name);
void libevdev_set_id_bustype(void *device, int type);
int libevdev_enable_event_type(void *device, unsigned int type);
int libevdev_enable_event_code(void *device, unsigned int type, unsigned int code, const void *data);
int libevdev_uinput_create_from_device(const void *device, int fd, void **output);
void libevdev_uinput_destroy(void *device);
const char *libevdev_uinput_get_devnode(void *device);
int libevdev_uinput_write_event(void *device, unsigned int type, unsigned int code, int value);
void *xkb_context_new(int flags);
void xkb_context_unref(void *context);
void *xkb_keymap_new_from_names(void *context, const ur_keyboard_xkb_names *names, int flags);
void xkb_keymap_unref(void *keymap);
unsigned int xkb_keymap_min_keycode(void *keymap);
unsigned int xkb_keymap_max_keycode(void *keymap);
unsigned int xkb_keymap_num_levels_for_key(void *keymap, unsigned int key, unsigned int layout);
unsigned int xkb_keymap_mod_get_index(void *keymap, const char *name);
int xkb_keymap_key_get_syms_by_level(void *keymap, unsigned int key, unsigned int layout, unsigned int level, const unsigned int **symbols);
unsigned long xkb_keymap_key_get_mods_for_level(void *keymap, unsigned int key, unsigned int layout, unsigned int level, unsigned int *masks, unsigned long size);
unsigned int xkb_keysym_to_utf32(unsigned int symbol);
int xkb_keysym_get_name(unsigned int symbol, char *buffer, unsigned long size);
void *xkb_compose_table_new_from_locale(void *context, const char *locale, int flags);
void xkb_compose_table_unref(void *table);
void *xkb_compose_state_new(void *table, int flags);
void xkb_compose_state_unref(void *state);
int xkb_compose_state_feed(void *state, unsigned int symbol);
int xkb_compose_state_get_status(void *state);
int xkb_compose_state_get_utf8(void *state, char *buffer, unsigned long size);
void xkb_compose_state_reset(void *state);
]]; end
local dbus = ffi.load("libdbus-1.so.3");
local ev = ffi.load("libevdev.so.2");
local xkb = ffi.load("libxkbcommon.so.0");
assert(dbus.dbus_threads_init_default() ~= 0, "Cannot initialize D-Bus");
local M, buses = {}, {};
local device, lock_fd, keymap, layout_id;

local function pointer(value, message)
    if value == nil then error(message, 0); end
    return value;
end
local function release_bus(connection)
    dbus.dbus_connection_close(connection);
    dbus.dbus_connection_unref(connection);
end
local function bus(kind)
    local connection = buses[kind];
    if connection ~= nil and dbus.dbus_connection_get_is_connected(connection) == 0 then
        release_bus(ffi.gc(connection, nil));
        buses[kind], connection = nil, nil;
    end
    if connection == nil then
        connection = pointer(dbus.dbus_bus_get_private(kind, nil), "Cannot connect to KDE/system D-Bus");
        dbus.dbus_connection_set_exit_on_disconnect(connection, 0);
        buses[kind] = ffi.gc(connection, release_bus);
    end
    return connection;
end
local function value(iter, depth)
    assert(depth < 12, "D-Bus response nesting is too deep");
    local kind = dbus.dbus_message_iter_get_arg_type(iter);
    if kind == 115 or kind == 111 or kind == 103 then -- string, object path, signature
        local output = ffi.new("const char *[1]");
        dbus.dbus_message_iter_get_basic(iter, output);
        return ffi.string(pointer(output[0], "Invalid D-Bus string"));
    elseif kind == 117 or kind == 98 or kind == 105 then -- uint32, boolean, int32
        local output = ffi.new(kind == 105 and "int[1]" or "unsigned int[1]");
        dbus.dbus_message_iter_get_basic(iter, output);
        return tonumber(output[0]);
    elseif kind == 97 or kind == 118 or kind == 114 or kind == 101 then
        local sub = ffi.new("ur_keyboard_dbus_iter[1]");
        dbus.dbus_message_iter_recurse(iter, sub);
        if kind == 118 then return value(sub, depth + 1); end
        local output = {};
        local dictionary = kind == 97 and dbus.dbus_message_iter_get_element_type(iter) == 101;
        while dbus.dbus_message_iter_get_arg_type(sub) ~= 0 do
            local item = value(sub, depth + 1);
            if dictionary then output[item[1]] = item[2]; else output[#output + 1] = item; end
            if dbus.dbus_message_iter_next(sub) == 0 then break; end
        end
        return output;
    end
    error("Unsupported KDE D-Bus response type", 0);
end
local function call(kind, destination, path, interface, method, arguments)
    local connection = bus(kind);
    local message = ffi.gc(pointer(dbus.dbus_message_new_method_call(destination, path, interface, method),
                                   "Cannot allocate D-Bus request"), dbus.dbus_message_unref);
    local iter = ffi.new("ur_keyboard_dbus_iter[1]");
    dbus.dbus_message_iter_init_append(message, iter);
    for _, argument in ipairs(arguments or {}) do
        assert(not argument:find("%z"), "D-Bus strings cannot contain NUL");
        local input = ffi.new("const char *[1]", {argument});
        assert(dbus.dbus_message_iter_append_basic(iter, 115, input) ~= 0, "Cannot encode D-Bus request");
    end
    local reply = dbus.dbus_connection_send_with_reply_and_block(connection, message, 2000, nil);
    dbus.dbus_message_unref(ffi.gc(message, nil));
    reply = ffi.gc(pointer(reply, "KDE D-Bus call failed: " .. destination .. "/" .. method), dbus.dbus_message_unref);
    local result;
    if dbus.dbus_message_iter_init(reply, iter) ~= 0 then result = value(iter, 0); end
    dbus.dbus_message_unref(ffi.gc(reply, nil));
    return result;
end

local function split(text, separator)
    local output = {};
    for part in (text .. separator):gmatch("(.-)" .. separator) do output[#output + 1] = part; end
    return output;
end
local function trim(text) return text:match("^%s*(.-)%s*$"); end
function M.read_config(paths)
    local output = {};
    for _, path in ipairs(paths) do
        local file = io.open(path, "r");
        if file then
            local section;
            for line in file:lines() do
                line = trim(line);
                if line:sub(1, 1) == "[" then section = line:match("^%[([^%]]+)%]");
                elseif section == "Layout" and not line:match("^[#;]") then
                    local key, entry = line:match("^([^=]+)=(.*)$");
                    if key then output[trim(key):lower()] = trim(entry); end
                end
            end
            file:close();
        end
    end
    return output;
end
function M.layout()
    local directories = split(os.getenv("XDG_CONFIG_DIRS") or "/etc/xdg", ":");
    local paths = {};
    for index = #directories, 1, -1 do
        if directories[index] ~= "" then paths[#paths + 1] = directories[index] .. "/kxkbrc"; end
    end
    paths[#paths + 1] = (os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")) .. "/kxkbrc";
    local config = M.read_config(paths);
    local layout, variant, options, model = config.layoutlist or "", config.variantlist or "", config.options or "", config.model or "pc105";
    if layout == "" then
        local defaults = call(1, "org.freedesktop.locale1", "/org/freedesktop/locale1",
                              "org.freedesktop.DBus.Properties", "GetAll", {"org.freedesktop.locale1"});
        layout = defaults.X11Layout;
        if not layout or layout == "" then layout = os.getenv("XKB_DEFAULT_LAYOUT") or "us"; end
        variant, options = defaults.X11Variant or "", defaults.X11Options or "";
        if defaults.X11Model and defaults.X11Model ~= "" then model = defaults.X11Model; end
    end
    local index = call(0, "org.kde.keyboard", "/Layouts", "org.kde.KeyboardLayouts", "getLayout") + 1;
    local layouts, variants = split(layout, ","), split(variant, ",");
    assert(layouts[index] and layouts[index] ~= "", "Active KDE layout is absent from the keyboard configuration");
    return layouts[index], variants[index] or "", options, model;
end
function M.encode(cp)
    assert(type(cp) == "number" and cp >= 0 and cp <= 0x10ffff and cp % 1 == 0 and
           not (cp >= 0xd800 and cp <= 0xdfff), "Invalid Unicode codepoint");
    if cp < 0x80 then return string.char(cp); end
    if cp < 0x800 then return string.char(0xc0 + math.floor(cp / 64), 0x80 + cp % 64); end
    if cp < 0x10000 then return string.char(0xe0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64); end
    return string.char(0xf0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
                       0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64);
end
function M.characters(text)
    local characters, index = {}, 1;
    while index <= #text do
        local first = text:byte(index);
        local size, cp, minimum;
        if first < 0x80 then size, cp, minimum = 1, first, 0;
        elseif first >= 0xc2 and first <= 0xdf then size, cp, minimum = 2, first - 0xc0, 0x80;
        elseif first >= 0xe0 and first <= 0xef then size, cp, minimum = 3, first - 0xe0, 0x800;
        elseif first >= 0xf0 and first <= 0xf4 then size, cp, minimum = 4, first - 0xf0, 0x10000;
        else error("Invalid UTF-8 text", 0); end
        for offset = 1, size - 1 do
            local byte = text:byte(index + offset);
            assert(byte and byte >= 0x80 and byte <= 0xbf, "Invalid UTF-8 text");
            cp = cp * 64 + byte - 0x80;
        end
        assert(cp >= minimum and cp <= 0x10ffff and not (cp >= 0xd800 and cp <= 0xdfff), "Invalid UTF-8 text");
        characters[#characters + 1] = text:sub(index, index + size - 1);
        index = index + size;
    end
    return characters;
end

function M.keymap(layout, variant, options, model)
    local context = ffi.gc(pointer(xkb.xkb_context_new(0), "Cannot create XKB context"), xkb.xkb_context_unref);
    local names = ffi.new("ur_keyboard_xkb_names");
    names.layout, names.variant, names.options, names.model = layout, variant or "", options or "", model or "pc105";
    local map = ffi.gc(pointer(xkb.xkb_keymap_new_from_names(context, names, 0), "Cannot compile KDE keyboard layout"), xkb.xkb_keymap_unref);
    local shift_index, altgr_index = xkb.xkb_keymap_mod_get_index(map, "Shift"), xkb.xkb_keymap_mod_get_index(map, "Mod5");
    local shift = shift_index < 32 and bit.lshift(1, shift_index) or 0;
    local altgr = altgr_index < 32 and bit.lshift(1, altgr_index) or 0;
    local symbols, characters = {}, {};
    local syms, masks = ffi.new("const unsigned int *[1]"), ffi.new("unsigned int[64]");
    for key = math.max(8, xkb.xkb_keymap_min_keycode(map)), math.min(263, xkb.xkb_keymap_max_keycode(map)) do
        for level = 0, xkb.xkb_keymap_num_levels_for_key(map, key, 0) - 1 do
            if xkb.xkb_keymap_key_get_syms_by_level(map, key, 0, level, syms) == 1 then
                local count = tonumber(xkb.xkb_keymap_key_get_mods_for_level(map, key, 0, level, masks, 64));
                local modifiers;
                for index = 0, math.min(count, 64) - 1 do
                    local mask = masks[index];
                    if bit.band(mask, bit.bnot(bit.bor(shift, altgr))) == 0 then
                        local candidate = {};
                        if bit.band(mask, shift) ~= 0 then candidate[#candidate + 1] = 42; end
                        if bit.band(mask, altgr) ~= 0 then candidate[#candidate + 1] = 100; end
                        if not modifiers or #candidate < #modifiers then modifiers = candidate; end
                    end
                end
                if modifiers then
                    local symbol = tonumber(syms[0][0]);
                    if not symbols[symbol] or #modifiers < #symbols[symbol].modifiers then
                        symbols[symbol] = {modifiers = modifiers, key = key - 8};
                    end
                end
            end
        end
    end
    for symbol, stroke in pairs(symbols) do
        local cp = tonumber(xkb.xkb_keysym_to_utf32(symbol));
        if cp >= 32 and cp ~= 127 then characters[M.encode(cp)] = {stroke}; end
    end
    local locale = os.getenv("LC_ALL");
    if not locale or locale == "" then locale = os.getenv("LC_CTYPE"); end
    if not locale or locale == "" then locale = os.getenv("LANG") or "C"; end
    local compose_table = xkb.xkb_compose_table_new_from_locale(context, locale, 0);
    if compose_table ~= nil then
        compose_table = ffi.gc(compose_table, xkb.xkb_compose_table_unref);
        local state = xkb.xkb_compose_state_new(compose_table, 0);
        if state ~= nil then
            state = ffi.gc(state, xkb.xkb_compose_state_unref);
            local buffer = ffi.new("char[64]");
            for dead, dead_stroke in pairs(symbols) do
                xkb.xkb_keysym_get_name(dead, buffer, 64);
                if ffi.string(buffer):sub(1, 5) == "dead_" then
                    for base, base_stroke in pairs(symbols) do
                        xkb.xkb_compose_state_reset(state);
                        xkb.xkb_compose_state_feed(state, dead);
                        xkb.xkb_compose_state_feed(state, base);
                        if xkb.xkb_compose_state_get_status(state) == 2 then
                            local length = xkb.xkb_compose_state_get_utf8(state, buffer, 64);
                            if length > 0 and length < 64 then
                                local text = ffi.string(buffer, length);
                                if not characters[text] and #M.characters(text) == 1 then
                                    characters[text] = {dead_stroke, base_stroke};
                                end
                            end
                        end
                    end
                end
            end
            xkb.xkb_compose_state_unref(ffi.gc(state, nil));
        end
        xkb.xkb_compose_table_unref(ffi.gc(compose_table, nil));
    end
    for character, key in pairs({["\n"] = 28, ["\r"] = 28, ["\t"] = 15, ["\b"] = 14}) do
        characters[character] = {{modifiers = {}, key = key}};
    end
    xkb.xkb_keymap_unref(ffi.gc(map, nil));
    xkb.xkb_context_unref(ffi.gc(context, nil));
    return characters;
end
local function now()
    local time = ffi.new("ur_keyboard_timespec[1]");
    assert(ffi.C.clock_gettime(1, time) == 0, "Cannot read monotonic clock");
    return tonumber(time[0].seconds) + tonumber(time[0].nanoseconds) / 1e9;
end
local function sleep(seconds)
    local request, remaining = ffi.new("ur_keyboard_timespec[1]"), ffi.new("ur_keyboard_timespec[1]");
    request[0].seconds = math.floor(seconds);
    request[0].nanoseconds = math.floor((seconds - math.floor(seconds)) * 1e9);
    while ffi.C.nanosleep(request, remaining) ~= 0 do
        assert(ffi.errno() == 4, "Cannot wait for keyboard input");
        request[0] = remaining[0];
    end
end
local function close_device()
    if device ~= nil then ev.libevdev_uinput_destroy(ffi.gc(device, nil)); device = nil; end
end
local function create_device()
    if device ~= nil then return; end
    local definition = ffi.gc(pointer(ev.libevdev_new(), "Cannot allocate virtual keyboard"), ev.libevdev_free);
    ev.libevdev_set_name(definition, "Unified Remote Lua Unicode Keyboard");
    ev.libevdev_set_id_bustype(definition, 3);
    assert(ev.libevdev_enable_event_type(definition, 1) == 0, "Cannot enable keyboard events");
    for code = 1, 255 do
        assert(ev.libevdev_enable_event_code(definition, 1, code, nil) == 0, "Cannot enable keyboard key");
    end
    local output = ffi.new("void *[1]");
    assert(ev.libevdev_uinput_create_from_device(definition, -2, output) == 0, "Cannot create virtual keyboard via /dev/uinput");
    device = ffi.gc(pointer(output[0], "Cannot identify virtual keyboard"), ev.libevdev_uinput_destroy);
    ev.libevdev_free(ffi.gc(definition, nil));
    local ok, failure = pcall(function ()
        local node = ffi.string(pointer(ev.libevdev_uinput_get_devnode(device), "Cannot identify keyboard event node"));
        local event = node:match("/(event%d+)$");
        assert(event, "Invalid keyboard event node");
        local deadline = now() + 3;
        while true do
            local keyboards = call(0, "org.kde.KWin", "/org/kde/KWin/InputDevice", "org.kde.KWin.InputDeviceManager", "ListKeyboards");
            for _, keyboard in ipairs(keyboards) do if keyboard == event then return; end; end
            assert(now() < deadline, "KWin did not attach the virtual keyboard");
            sleep(0.025);
        end
    end);
    if not ok then close_device(); error(failure, 0); end
end
local function emit(code, pressed)
    assert(ev.libevdev_uinput_write_event(device, 1, code, pressed) == 0, "Cannot write keyboard event");
    assert(ev.libevdev_uinput_write_event(device, 0, 0, 0) == 0, "Cannot synchronize keyboard event");
end
local function stroke(modifiers, key)
    local held = {};
    local ok, failure = pcall(function ()
        for _, code in ipairs(modifiers) do held[#held + 1] = code; emit(code, 1); end
        held[#held + 1] = key; emit(key, 1);
        sleep(0.003);
    end);
    local released = true;
    for index = #held, 1, -1 do if not pcall(emit, held[index], 0) then released = false; end; end
    if not ok then error(failure, 0); end
    assert(released, "Cannot release keyboard key");
end
local function acquire()
    if not lock_fd then
        local runtime = os.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. tonumber(ffi.C.getuid()));
        -- Each VM opens its own fd: flock serializes Core.Input and Core.Keyboard.
        local fd = ffi.C.open(runtime .. "/unified-remote-lua-keyboard.lock", 655426, ffi.new("int", 384));
        assert(fd >= 0, "Cannot open keyboard serialization lock"); -- O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC
        lock_fd = ffi.gc(ffi.new("int[1]", fd), function (resource) ffi.C.close(resource[0]); end);
    end
    local deadline = now() + 15;
    while ffi.C.flock(lock_fd[0], 6) ~= 0 do -- LOCK_EX|LOCK_NB
        assert(ffi.errno() == 11 or ffi.errno() == 4, "Cannot lock keyboard input");
        assert(now() < deadline, "Keyboard input is busy");
        sleep(0.001);
    end
end
function M.send(text)
    if text == nil or text == "" then return; end
    text = tostring(text);
    assert(#text <= 1048576, "Wayland text request too large");
    local characters = M.characters(text); -- Validate the entire request before emitting anything.
    acquire();
    local ok, failure = pcall(function ()
        local layout, variant, options, model = M.layout();
        local identity = table.concat({layout, variant, options, model}, "\0");
        if identity ~= layout_id then
            local updated = M.keymap(layout, variant, options, model);
            keymap, layout_id = updated, identity;
        end
        local paste = false;
        for _, character in ipairs(characters) do if not keymap[character] then paste = true; break; end; end
        if paste then
            assert(not text:find("%z"), "Clipboard text cannot contain NUL");
            call(0, "org.kde.klipper", "/klipper", "org.kde.klipper.klipper", "setClipboardContents", {text});
        end
        create_device();
        if paste then stroke({29}, 47); sleep(0.1);
        else
            for _, character in ipairs(characters) do
                for _, combination in ipairs(keymap[character]) do stroke(combination.modifiers, combination.key); end
            end
        end
    end);
    ffi.C.flock(lock_fd[0], 8); -- LOCK_UN, including every error path.
    if not ok then close_device(); error(failure, 0); end
end
function M.close()
    close_device();
    if lock_fd then ffi.C.close(ffi.gc(lock_fd, nil)[0]); lock_fd = nil; end
    for kind, connection in pairs(buses) do release_bus(ffi.gc(connection, nil)); buses[kind] = nil; end
    keymap, layout_id = nil, nil;
end
return M;
