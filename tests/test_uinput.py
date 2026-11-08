"""Regression tests for consent-gated /dev/uinput configuration.

All privileged commands are mocked and all managed paths point into a
temporary directory. No test modifies the actual /etc or /dev directories.
"""
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/uinput.sh"

HARNESS = r'''
set -Eeuo pipefail
source "$UINPUT_HELPER"
log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 12; }
check="$TEST_CHECK"
UINPUT_RULE="$TEST_HOME/99-unified-remote-uinput.rules"
UINPUT_MODULE="$TEST_HOME/unified-remote-uinput.conf"
UINPUT_NODE="$TEST_HOME/uinput"
uinput_device_exists() { [[ -e "$TEST_HOME/device-exists" ]]; }
uinput_access_ok() { [[ -e "$TEST_HOME/device-access" ]]; }
uinput_group_exists() { [[ -e "$TEST_HOME/group-created" ]]; }
uinput_persistent_member() { [[ -e "$TEST_HOME/member-persistent" ]]; }
uinput_session_member() { [[ -e "$TEST_HOME/member-active" ]]; }
as_root() {
    printf '%s\n' "$*" >> "$TEST_HOME/root-commands"
    case "$1" in
        true) ;;
        groupadd) touch "$TEST_HOME/group-created" ;;
        usermod) touch "$TEST_HOME/member-persistent" ;;
        modprobe) touch "$TEST_HOME/device-exists" ;;
        install)
            while (( $# > 2 )); do shift; done
            cp -- "$1" "$2"
            ;;
        udevadm) ;;
        *) return 91 ;;
    esac
}
ensure_uinput_access
'''

class UinputTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # These executables only satisfy command -v; privileged actions are mocked.
        for executable in ("sudo", "udevadm", "groupadd", "usermod", "modprobe"):
            fake = self.bin / executable
            fake.write_text("#!/bin/sh\nexit 95\n")
            fake.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + ":" + os.environ["PATH"],
            "TEST_HOME": str(self.root),
            "UINPUT_HELPER": str(HELPER),
        }

    def run_shell(self, *, check=False, reply=None):
        if os.geteuid() == 0:
            self.skipTest("Production installer refuses root desktop sessions")
        env = dict(self.env, TEST_CHECK="1" if check else "0")
        if reply is None:
            return subprocess.run(
                ["bash", "-c", HARNESS],
                env=env, input="", text=True, capture_output=True, timeout=10)
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                ["bash", "-c", HARNESS],
                env=env, stdin=slave, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
            )
            os.close(slave)
            slave = -1
            os.write(master, reply.encode())
            stdout, stderr = process.communicate(timeout=10)
            return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        finally:
            os.close(master)
            if slave >= 0:
                os.close(slave)

    def test_already_accessible_is_noop(self):
        (self.root / "device-access").touch()
        result = self.run_shell()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "root-commands").exists())
        self.assertFalse((self.root / "99-unified-remote-uinput.rules").exists())

    def test_dry_run_never_prompts_or_mutates(self):
        result = self.run_shell(check=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--check never changes permissions", result.stderr)
        self.assertFalse((self.root / "root-commands").exists())

    def test_noninteractive_requires_explicit_consent_even_with_yes(self):
        result = self.run_shell()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run interactively", result.stderr)
        self.assertFalse((self.root / "root-commands").exists())

    def test_declined_permission_changes_nothing(self):
        result = self.run_shell(reply="n\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Permission setup declined", result.stderr)
        self.assertFalse((self.root / "root-commands").exists())

    def test_conflicting_rule_is_rejected_before_consent(self):
        (self.root / "99-unified-remote-uinput.rules").write_text("MODE=0666\n")
        result = self.run_shell(reply="y\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflicting configuration", result.stderr)
        self.assertFalse((self.root / "root-commands").exists())

    def test_authorized_setup_creates_only_scoped_rule_and_module(self):
        result = self.run_shell(reply="y\n")
        self.assertNotEqual(result.returncode, 0)  # Group addition requires relogin.
        self.assertIn("Log out fully", result.stderr)
        rule = (self.root / "99-unified-remote-uinput.rules").read_text()
        self.assertIn('GROUP="unified-remote-uinput"', rule)
        self.assertIn('MODE="0660"', rule)
        self.assertNotIn('MODE="0666"', rule)
        self.assertEqual((self.root / "unified-remote-uinput.conf").read_text(), "uinput\n")
        self.assertTrue((self.root / "member-persistent").exists())
        calls = (self.root / "root-commands").read_text()
        self.assertIn("groupadd --system unified-remote-uinput", calls)
        self.assertIn("usermod -aG unified-remote-uinput", calls)
        self.assertIn("modprobe uinput", calls)
        self.assertNotIn("chmod", calls)
        self.assertNotIn("rpm-ostree", calls)

    def test_existing_persistent_group_requires_relogin_not_changes(self):
        (self.root / "group-created").touch()
        (self.root / "member-persistent").touch()
        (self.root / "device-exists").touch()
        rule = self.root / "99-unified-remote-uinput.rules"
        rule.write_text('KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="unified-remote-uinput", MODE="0660"\n')
        result = self.run_shell()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Log out completely", result.stderr)
        self.assertFalse((self.root / "root-commands").exists())

    def test_relogged_user_does_not_change_existing_permissions(self):
        for item in ("group-created", "member-persistent", "member-active", "device-exists", "device-access"):
            (self.root / item).touch()
        result = self.run_shell()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "root-commands").exists())

if __name__ == "__main__":
    unittest.main()
