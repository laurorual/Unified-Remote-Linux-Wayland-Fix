"""Native Lua/FFI checks. These tests never call send() or create input devices."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'remotes/Unified/Core/Keyboard/wayland_ffi.lua'


@unittest.skipUnless(shutil.which('luajit'), 'LuaJIT test interpreter is unavailable')
@unittest.skipUnless('wayland_ffi.lua' in (ROOT / 'remotes/Unified/Core/Input/remote.lua').read_text(),
                     'Lua/FFI backend is inactive after rollback')
class LuaFFITests(unittest.TestCase):
    def run_lua(self, code, data=b'', env=None):
        result = subprocess.run(['luajit', '-e', 'local m=dofile(arg[0]); ' + code + '; m.close(); os.exit(0)', str(MODULE)],
                                input=data, capture_output=True, timeout=8,
                                env=dict(os.environ, **(env or {})))
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    def test_brazilian_accents_and_symbols(self):
        self.run_lua('local map=m.keymap("br","",""); '
                     'for _,c in ipairs(m.characters(io.read("*a"))) do assert(map[c],"unmapped character"); end',
                     'Olá, ação! ç ã é @ # $ % & * ( ) [ ] { } / ? + ='.encode())

    def test_us_international_compose_sequences(self):
        self.run_lua('local map=m.keymap("us","intl",""); '
                     'for _,c in ipairs(m.characters(io.read("*a"))) do assert(map[c],"unmapped character"); end',
                     'Olá, ação! ç ã é É à õ ü'.encode())

    def test_plain_us_requires_clipboard_for_accents(self):
        self.run_lua('local map=m.keymap("us","",""); assert(map.a); '
                     'assert(not map[m.encode(0xe3)]); assert(not map[m.encode(0x1f642)])')

    def test_german_altgr_symbol(self):
        self.run_lua('local map=m.keymap("de","",""); assert(map["@"][1].modifiers[1]==100)')

    def test_control_keys(self):
        self.run_lua('local map=m.keymap("br","",""); assert(map["\\n"][1].key==28); '
                     'assert(map["\\t"][1].key==15); assert(map["\\b"][1].key==14)')

    def test_unicode_round_trip(self):
        self.run_lua('for _,c in ipairs({0,65,0x7ff,0x800,0xd7ff,0xe000,0xffff,0x10000,0x1f642,0x10ffff}) do '
                     'local s=m.encode(c); assert(#m.characters(s)==1); end')

    def test_invalid_utf8_is_rejected(self):
        for data in (b'\x80', b'\xc0\x80', b'\xc2', b'\xe0\x80\x80', b'\xed\xa0\x80', b'\xf4\x90\x80\x80'):
            self.run_lua('assert(not pcall(m.characters,io.read("*a")))', data)

    def test_invalid_codepoints_are_rejected(self):
        self.run_lua('for _,c in ipairs({-1,1.5,0xd800,0xdfff,0x110000}) do assert(not pcall(m.encode,c)); end')

    def test_config_precedence_and_empty_variant(self):
        with tempfile.TemporaryDirectory() as directory:
            system = Path(directory, 'system'); user = Path(directory, 'user')
            system.write_text('[Layout]\nLayoutList=br,us\nVariantList=,intl\nOptions=caps:escape\n')
            user.write_text('[Other]\nOptions=wrong\n[Layout]\nOptions=compose:ralt\n')
            paths = '{' + json.dumps(str(system)) + ',' + json.dumps(str(user)) + '}'
            self.run_lua('local c=m.read_config(' + paths + '); assert(c.layoutlist=="br,us"); '
                         'assert(c.variantlist==",intl"); assert(c.options=="compose:ralt")')

    def test_config_changes_are_read_immediately(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, 'kxkbrc')
            path.write_text('[Layout]\nLayoutList=br\n')
            p = json.dumps(str(path))
            self.run_lua('assert(m.read_config({' + p + '}).layoutlist=="br"); '
                         'local f=assert(io.open(' + p + ',"w")); f:write("[Layout]\\nLayoutList=us\\n"); f:close(); '
                         'assert(m.read_config({' + p + '}).layoutlist=="us")')

    def test_repeated_load_and_close_are_safe(self):
        self.run_lua('m.close(); m.close(); local other=dofile(arg[0]); '
                     'assert(other.keymap("br","","")["a"]); other.close()')

    def test_invalid_text_is_rejected_before_layout_or_device_access(self):
        self.run_lua('local calls=0; m.layout=function() calls=calls+1; error("unexpected layout access") end; '
                     'assert(not pcall(m.send,string.char(0xc0,0x80))); assert(calls==0)')

    def test_failed_keymap_build_releases_lock_for_other_lua_context(self):
        self.run_lua('m.layout=function() return "unified_remote_nonexistent_layout","","","pc105" end; '
                     'assert(not pcall(m.send,"a")); local other=dofile(arg[0]); '
                     'other.layout=m.layout; assert(not pcall(other.send,"a")); other.close()')

    def test_non_linux_remotes_keep_native_keyboard_api(self):
        for name, action in [('Input', 'Text'), ('Keyboard', 'text')]:
            remote = str(ROOT / 'remotes/Unified/Core' / name / 'remote.lua')
            code = 'OS_LINUX=false; actions={}; local called; '
            code += 'libs={keyboard={text=function(t) called=t end},mouse={},fs={}}; '
            code += 'dofile(' + json.dumps(remote) + '); dofile=function() error("should not load Linux backend") end; '
            code += 'actions[' + json.dumps(action) + ']("test"); assert(called=="test"); os.exit(0)'
            result = subprocess.run(['luajit', '-e', code], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_legacy_numeric_values_are_converted_to_text(self):
        for name, action in [('Input', 'Text'), ('Keyboard', 'text')]:
            remote = str(ROOT / 'remotes/Unified/Core' / name / 'remote.lua')
            code = 'OS_LINUX=true; actions={}; libs={keyboard={},mouse={},fs={remotedir=function() return "." end,combine=function(a,b) return b end}}; '
            code += 'dofile(' + json.dumps(remote) + '); local sent; dofile=function() return {send=function(t) sent=t end} end; '
            code += 'actions[' + json.dumps(action) + '](1234); assert(tostring(sent)=="1234"); os.exit(0)'
            result = subprocess.run(['luajit', '-e', code], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
