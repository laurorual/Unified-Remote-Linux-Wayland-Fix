#!/usr/bin/env python3
"""Unicode text for Unified Remote on KDE Wayland, using the active XKB layout.

The short-lived --send client talks to an idle-expiring, private uinput worker.
Text is never written to disk or logged. Clipboard paste is used only for text
that cannot be produced by the current layout and its compose sequences.
"""
from __future__ import annotations

import configparser
import ctypes as C
import fcntl
import json
import locale
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import time

import dbus
from evdev import UInput, ecodes as E

RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
DIRECTORY = RUNTIME / "unified-remote-text"
SOCKET = DIRECTORY / "input.sock"
MAX_MESSAGE = 1024 * 1024


class Keymap:
    def __init__(self, layout, variant, options):
        self.x = C.CDLL("libxkbcommon.so.0")
        ptr, uint = C.c_void_p, C.c_uint

        def bind(name, result, *args):
            fn = getattr(self.x, name)
            fn.restype, fn.argtypes = result, args
            return fn

        bind("xkb_context_new", ptr, uint)
        bind("xkb_context_unref", None, ptr)
        bind("xkb_keymap_new_from_names", ptr, ptr, ptr, uint)
        bind("xkb_keymap_unref", None, ptr)
        bind("xkb_keymap_min_keycode", uint, ptr)
        bind("xkb_keymap_max_keycode", uint, ptr)
        bind("xkb_keymap_num_levels_for_key", uint, ptr, uint, uint)
        bind("xkb_keymap_mod_get_index", uint, ptr, C.c_char_p)
        bind("xkb_keymap_key_get_syms_by_level", C.c_int, ptr, uint, uint, uint,
             C.POINTER(C.POINTER(uint)))
        bind("xkb_keymap_key_get_mods_for_level", C.c_size_t, ptr, uint, uint,
             uint, C.POINTER(uint), C.c_size_t)
        bind("xkb_keysym_to_utf32", uint, uint)
        bind("xkb_keysym_get_name", C.c_int, uint, C.c_char_p, C.c_size_t)
        bind("xkb_compose_table_new_from_locale", ptr, ptr, C.c_char_p, uint)
        bind("xkb_compose_table_unref", None, ptr)
        bind("xkb_compose_state_new", ptr, ptr, uint)
        bind("xkb_compose_state_unref", None, ptr)
        bind("xkb_compose_state_feed", C.c_int, ptr, uint)
        bind("xkb_compose_state_get_status", C.c_int, ptr)
        bind("xkb_compose_state_get_utf8", C.c_int, ptr, C.c_char_p, C.c_size_t)
        bind("xkb_compose_state_reset", None, ptr)

        class Names(C.Structure):
            _fields_ = [(name, C.c_char_p) for name in
                        ("rules", "model", "layout", "variant", "options")]

        names = Names(None, None, layout.encode(), variant.encode(), options.encode())
        ctx = self.x.xkb_context_new(0)
        keymap = self.x.xkb_keymap_new_from_names(ctx, C.byref(names), 0)
        if not keymap:
            self.x.xkb_context_unref(ctx)
            raise RuntimeError("cannot compile the KDE keyboard layout")
        self.characters = {}
        symbols = {}
        try:
            shift = 1 << self.x.xkb_keymap_mod_get_index(keymap, b"Shift")
            altgr = 1 << self.x.xkb_keymap_mod_get_index(keymap, b"Mod5")
            for key in range(self.x.xkb_keymap_min_keycode(keymap),
                             min(self.x.xkb_keymap_max_keycode(keymap), 255 + 8) + 1):
                if key < 8:
                    continue
                for level in range(self.x.xkb_keymap_num_levels_for_key(keymap, key, 0)):
                    syms = C.POINTER(uint)()
                    count = self.x.xkb_keymap_key_get_syms_by_level(
                        keymap, key, 0, level, C.byref(syms))
                    if count != 1:
                        continue
                    masks = (uint * 64)()
                    total = self.x.xkb_keymap_key_get_mods_for_level(
                        keymap, key, 0, level, masks, len(masks))
                    valid = [mask for mask in masks[:total] if not mask & ~(shift | altgr)]
                    if not valid:
                        continue
                    mask = min(valid, key=int.bit_count)
                    modifiers = tuple(code for flag, code in
                                      ((shift, E.KEY_LEFTSHIFT), (altgr, E.KEY_RIGHTALT))
                                      if mask & flag)
                    stroke = (modifiers, key - 8)  # XKB keycodes include the evdev +8 offset.
                    symbol = syms[0]
                    if symbol not in symbols or len(modifiers) < len(symbols[symbol][0]):
                        symbols[symbol] = stroke
            for symbol, stroke in symbols.items():
                cp = self.x.xkb_keysym_to_utf32(symbol)
                if cp >= 32 and cp != 127:
                    self.characters[chr(cp)] = (stroke,)
            self._add_compose(ctx, symbols)
        finally:
            self.x.xkb_keymap_unref(keymap)
            self.x.xkb_context_unref(ctx)
        for char, key in (("\n", E.KEY_ENTER), ("\r", E.KEY_ENTER),
                          ("\t", E.KEY_TAB), ("\b", E.KEY_BACKSPACE)):
            self.characters[char] = (((), key),)

    def _add_compose(self, ctx, symbols):
        table = self.x.xkb_compose_table_new_from_locale(
            ctx, locale.setlocale(locale.LC_CTYPE).encode(), 0)
        if not table:
            return
        state = self.x.xkb_compose_state_new(table, 0)
        if not state:
            self.x.xkb_compose_table_unref(table)
            return
        try:
            buffer = C.create_string_buffer(64)
            for dead in symbols:
                self.x.xkb_keysym_get_name(dead, buffer, len(buffer))
                if not buffer.value.startswith(b"dead_"):
                    continue
                for base in symbols:
                    self.x.xkb_compose_state_reset(state)
                    self.x.xkb_compose_state_feed(state, dead)
                    self.x.xkb_compose_state_feed(state, base)
                    if self.x.xkb_compose_state_get_status(state) == 2:  # COMPOSED
                        self.x.xkb_compose_state_get_utf8(state, buffer, len(buffer))
                        text = buffer.value.decode("utf-8")
                        if len(text) == 1 and text not in self.characters:
                            self.characters[text] = (symbols[dead], symbols[base])
        finally:
            self.x.xkb_compose_state_unref(state)
            self.x.xkb_compose_table_unref(table)


def current_layout():
    config = configparser.ConfigParser(interpolation=None)
    config.read(Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "kxkbrc")
    layouts = config.get("Layout", "LayoutList", fallback="us").split(",")
    variants = config.get("Layout", "VariantList", fallback="").split(",")
    bus = dbus.SessionBus()
    obj = bus.get_object("org.kde.keyboard", "/Layouts")
    index = int(dbus.Interface(obj, "org.kde.KeyboardLayouts").getLayout())
    return (layouts[index], variants[index] if index < len(variants) else "",
            config.get("Layout", "Options", fallback=""))


class Keyboard:
    def __init__(self):
        self.device = UInput({E.EV_KEY: list(range(1, 256))},
                             name="Unified Remote Unicode Keyboard")
        self.layout = None
        self.keymap = None
        # udev discovery is asynchronous. Do not lose the first request while
        # KWin is still attaching the new device (notably after worker idle expiry).
        try:
            if self.device.device is None:
                raise RuntimeError("cannot identify the virtual keyboard")
            name = Path(self.device.device.path).name
            bus = dbus.SessionBus()
            manager = dbus.Interface(bus.get_object("org.kde.KWin", "/org/kde/KWin/InputDevice"),
                                     "org.kde.KWin.InputDeviceManager")
            deadline = time.monotonic() + 3
            while name not in manager.ListKeyboards():
                if time.monotonic() >= deadline:
                    raise RuntimeError("KWin did not attach the virtual keyboard")
                time.sleep(0.025)
        except Exception:
            self.device.close()
            raise

    def stroke(self, modifiers, key):
        held = []
        try:
            for code in (*modifiers, key):
                self.device.write(E.EV_KEY, code, 1)
                held.append(code)
                self.device.syn()
            time.sleep(0.003)
        finally:
            for code in reversed(held):
                self.device.write(E.EV_KEY, code, 0)
                self.device.syn()

    def send(self, text):
        layout = current_layout()
        if self.layout != layout:
            self.keymap = Keymap(*layout)
            self.layout = layout
        if any(char not in self.keymap.characters for char in text):
            # Paste the entire request to keep mixed Unicode text in order.
            env = dict(os.environ)
            if not env.get("WAYLAND_DISPLAY"):
                displays = sorted(RUNTIME.glob("wayland-*"))
                displays = [p for p in displays if p.is_socket()]
                if len(displays) != 1:
                    raise RuntimeError("cannot identify the Wayland display for Unicode paste")
                env["WAYLAND_DISPLAY"] = displays[0].name
            if not shutil.which("wl-copy"):
                raise RuntimeError("wl-copy is required for characters outside the keyboard layout")
            subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"],
                           input=text.encode("utf-8"), env=env, check=True, timeout=2,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.stroke((E.KEY_LEFTCTRL,), E.KEY_V)
            time.sleep(0.1)  # Allow the focused application to consume this clipboard offer.
        else:
            for char in text:
                for modifiers, key in self.keymap.characters[char]:
                    self.stroke(modifiers, key)


def receive(conn):
    data = bytearray()
    while len(data) <= MAX_MESSAGE:
        part = conn.recv(4096)
        if not part:
            raise ValueError("incomplete request")
        data.extend(part)
        if b"\n" in part:
            return bytes(data).split(b"\n", 1)[0]
    raise ValueError("request too large")


def serve():
    with (DIRECTORY / "worker.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        keyboard = Keyboard()
        SOCKET.unlink(missing_ok=True)
        try:
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(SOCKET))
                listener.listen(16)
                listener.settimeout(120)
                while True:
                    try:
                        conn, _ = listener.accept()
                    except socket.timeout:
                        break
                    with conn:
                        conn.settimeout(5)
                        try:
                            _, uid, _ = struct.unpack("3i", conn.getsockopt(
                                socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                            if uid != os.getuid():
                                raise ValueError("wrong peer uid")
                            text = json.loads(receive(conn))
                            if not isinstance(text, str):
                                raise ValueError("text must be a string")
                            keyboard.send(text)
                            conn.sendall(b"OK\n")
                        except Exception as exc:
                            # Never include typed content or subprocess arguments in errors.
                            try:
                                conn.sendall(f"ERROR {type(exc).__name__}\n".encode())
                            except OSError:
                                pass
        finally:
            SOCKET.unlink(missing_ok=True)
            keyboard.device.close()


def send(text):
    payload = json.dumps(text, ensure_ascii=True).encode() + b"\n"
    if len(payload) > MAX_MESSAGE:
        raise ValueError("request too large")
    for attempt in range(200):
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(15)
        try:
            conn.connect(str(SOCKET))
        except (FileNotFoundError, ConnectionRefusedError):
            conn.close()
            if attempt == 0:
                subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--worker"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(0.025)
            continue
        with conn:
            conn.sendall(payload)
            if receive(conn) != b"OK":
                raise RuntimeError("Wayland text worker could not send text")
        return
    raise RuntimeError("Wayland text worker did not start")


if __name__ == "__main__":
    DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    if DIRECTORY.stat().st_uid != os.getuid() or DIRECTORY.stat().st_mode & 0o077:
        raise RuntimeError("text runtime directory must be private")
    if sys.argv[1:] == ["--worker"]:
        serve()
    elif sys.argv[1:] == ["--send"]:
        send(sys.stdin.read())
        print("OK")
    else:
        raise SystemExit("usage: wayland_text.py --send < text")
