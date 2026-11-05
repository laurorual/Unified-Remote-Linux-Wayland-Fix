"""Run with: python3 -m unittest discover -s tests -v (no desktop input is sent)."""
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


text_input = load("text_input", "remotes/Unified/Core/Keyboard/wayland_text.py")



class KeyboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keymap = text_input.Keymap("us", "intl", "")

    def test_symbols_and_portuguese_accents_are_native(self):
        expected = ('!@#$%&*()_+-=[]{};:\'"\\|,<.>/?`~ €£¢ '
                    'áàâãäéèêëíìîïóòôõöúùûüç ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ')
        for char in expected:
            with self.subTest(char=char):
                self.assertIn(char, self.keymap.characters)
                for modifiers, key in self.keymap.characters[char]:
                    self.assertTrue(1 <= key <= 255)
                    self.assertTrue(all(1 <= code <= 255 for code in modifiers))

    def test_layout_without_dead_keys_uses_unicode_fallback_for_accents(self):
        keymap = text_input.Keymap("us", "", "")
        self.assertNotIn("ã", keymap.characters)
        self.assertIn("$", keymap.characters)

    def test_unmapped_unicode_pastes_whole_request_in_order(self):
        keyboard = object.__new__(text_input.Keyboard)
        keyboard.layout = ("us", "intl", "")
        keyboard.keymap = self.keymap
        text = "ação 😀"
        with patch.object(text_input, "current_layout", return_value=keyboard.layout), \
             patch.object(text_input.os, "environ", {"WAYLAND_DISPLAY": "wayland-0"}), \
             patch.object(text_input.shutil, "which", return_value="/usr/bin/wl-copy"), \
             patch.object(text_input.subprocess, "run") as copy, \
             patch.object(keyboard, "stroke") as stroke, \
             patch.object(text_input.time, "sleep"):
            keyboard.send(text)
        self.assertEqual(copy.call_args.kwargs["input"], text.encode())
        stroke.assert_called_once_with((text_input.E.KEY_LEFTCTRL,), text_input.E.KEY_V)


if __name__ == "__main__":
    unittest.main()
