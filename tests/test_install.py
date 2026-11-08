"""Installer integration checks: fake installations/services in temporary directories."""
import fcntl
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'install.sh'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.installer = INSTALLER
        self.home = self.base / 'home'
        self.home.mkdir()
        self.server = self.home / 'UR server with spaces'
        self.server.mkdir()
        self.binary = self.server / 'urserver'
        self.binary.write_text('#!/bin/sh\nexit 0\n')
        self.binary.chmod(0o755)
        self.remotes = self.server / 'remotes'
        for name in ('Core/Input', 'Core/Keyboard', 'Core/Mouse', 'Main/Basic Input', 'Main/Basic Input MT'):
            directory = self.remotes / 'Unified' / name
            directory.mkdir(parents=True)
            (directory / 'remote.lua').write_text('-- original ' + name + '\n')
            (directory / 'remote.lua').chmod(0o640)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.record = self.base / 'service-calls'
        self.runtime = self.base / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_STATE_HOME=str(self.home / '.local/state'), XDG_RUNTIME_DIR=str(self.runtime),
                        PATH=str(self.bin) + ':' + os.environ['PATH'], TEST_SERVICE_RECORD=str(self.record),
                        TEST_ACTIVE='0', TEST_ENABLED='0', TEST_MAINPID='0', TEST_PGREP_PID='',
                        TEST_DOWNLOADS=str(self.home / 'Transferências'))
        self.env.pop('SUDO_USER', None)
        self.script('systemctl', '''#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_SERVICE_RECORD"
case $2 in
 is-active) [[ $TEST_ACTIVE == 1 ]];;
 is-enabled) [[ $TEST_ENABLED == 1 ]];;
 show) printf '%s\\n' "$TEST_MAINPID";;
 *) exit 0;;
esac
''')
        self.script('pgrep', '''#!/bin/bash
[[ -n $TEST_PGREP_PID ]] || exit 1
case " $* " in *" -f "*) printf '%s\\n' "$TEST_PGREP_PID";; *) exit 1;; esac
''')
        self.script('xdg-user-dir', '#!/bin/bash\nprintf "%s\\n" "$TEST_DOWNLOADS"\n')
        for name in ('sudo', 'dnf', 'apt', 'rpm-ostree', 'pip', 'brew'):
            self.script(name, '#!/bin/bash\necho "UNEXPECTED PACKAGE MUTATION" >&2\nexit 88\n')

    def script(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_install(self, *options, success=True, detect=False, runtime_checks=False):
        args = ['bash', str(self.installer), '--yes', '--backup-dir', str(self.base / 'backups')]
        if not detect:
            args.extend(['--server-dir', str(self.server)])
        if not runtime_checks:
            args.append('--skip-checks')
        result = subprocess.run(args + list(options), capture_output=True, text=True, env=self.env, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('UNEXPECTED PACKAGE MUTATION', result.stderr)
        return result

    def backup(self):
        backups = sorted((self.base / 'backups').iterdir())
        self.assertTrue(backups)
        return backups[-1]

    def restore(self, backup):
        result = subprocess.run(['bash', str(backup / 'restore.sh')], capture_output=True, text=True,
                                env=self.env, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def keyboard_path(self, filename):
        return self.remotes / 'Unified/Core/Keyboard' / filename

    def test_keyboard_install_and_exact_restore(self):
        original = (self.remotes / 'Unified/Core/Input/remote.lua').read_bytes()
        result = self.run_install('--keyboard', '--no-restart')
        self.assertIn('Backup:', result.stdout)
        self.assertEqual(self.keyboard_path('wayland_ffi.lua').read_bytes(),
                         (ROOT / 'remotes/Unified/Core/Keyboard/wayland_ffi.lua').read_bytes())
        self.assertEqual(self.keyboard_path('remote.lua').stat().st_mode & 0o777, 0o644)
        self.restore(self.backup())
        self.assertEqual((self.remotes / 'Unified/Core/Input/remote.lua').read_bytes(), original)
        self.assertEqual(self.keyboard_path('remote.lua').stat().st_mode & 0o777, 0o640)
        self.assertFalse(self.keyboard_path('wayland_ffi.lua').exists())

    def test_mouse_only_keeps_keyboard_untouched(self):
        original = self.keyboard_path('remote.lua').read_bytes()
        self.run_install('--mouse-only', '--no-restart')
        self.assertEqual(self.keyboard_path('remote.lua').read_bytes(), original)
        self.assertFalse(self.keyboard_path('wayland_ffi.lua').exists())
        self.assertNotIn('wayland_', (self.remotes / 'Unified/Core/Input/remote.lua').read_text())

    def test_check_does_not_create_backups_or_change_files(self):
        original = (self.remotes / 'Unified/Core/Input/remote.lua').read_bytes()
        self.run_install('--keyboard', '--check')
        self.assertFalse((self.base / 'backups').exists())
        self.assertEqual((self.remotes / 'Unified/Core/Input/remote.lua').read_bytes(), original)
        calls = self.record.read_text()
        self.assertNotIn('restart', calls)
        self.assertNotIn(' stop ', calls)

    def test_custom_remotes_directory(self):
        external = self.base / 'custom remotes'
        self.remotes.rename(external)
        self.remotes = external
        self.run_install('--mouse-only', '--remotes-dir', str(external), '--no-restart')
        self.assertEqual((external / 'Unified/Core/Mouse/remote.lua').read_bytes(),
                         (ROOT / 'remotes/Unified/Core/Mouse/remote.lua').read_bytes())

    def test_localized_download_directory_autodetection(self):
        target = Path(self.env['TEST_DOWNLOADS']) / 'UnifiedRemoteServer'
        target.parent.mkdir()
        self.server.rename(target)
        self.server = target
        self.remotes = target / 'remotes'
        self.run_install('--mouse-only', '--no-restart', detect=True)
        self.assertTrue((self.remotes / 'Unified/Core/Mouse/remote.lua').is_file())

    def test_retired_files_and_only_their_caches_are_backed_up_and_removed(self):
        for name in ('wayland_text.py', 'wayland_client.lua'):
            self.keyboard_path(name).write_text('obsolete: ' + name)
        cache = self.keyboard_path('__pycache__')
        cache.mkdir()
        (cache / 'wayland_text.cpython-311.pyc').write_bytes(b'old cache')
        (cache / 'other_module.pyc').write_bytes(b'keep')
        self.run_install('--keyboard', '--no-restart')
        for name in ('wayland_text.py', 'wayland_client.lua'):
            self.assertFalse(self.keyboard_path(name).exists())
        self.assertFalse((cache / 'wayland_text.cpython-311.pyc').exists())
        self.assertTrue((cache / 'other_module.pyc').exists())
        self.restore(self.backup())
        self.assertEqual(self.keyboard_path('wayland_text.py').read_text(), 'obsolete: wayland_text.py')
        self.assertEqual((cache / 'wayland_text.cpython-311.pyc').read_bytes(), b'old cache')

    def test_orphaned_cache_is_removed_even_after_old_helper_was_deleted(self):
        cache = self.keyboard_path('__pycache__')
        cache.mkdir()
        old = cache / 'wayland_text.cpython-312.pyc'
        old.write_bytes(b'obsolete')
        self.run_install('--keyboard', '--no-restart')
        self.assertFalse(old.exists())

    def test_legacy_cleanup_can_be_disabled(self):
        old = self.keyboard_path('wayland_text.py')
        old.write_text('keep')
        self.run_install('--keyboard', '--keep-legacy-files', '--no-restart')
        self.assertTrue(old.exists())

    def test_mouse_only_preserves_an_existing_python_keyboard(self):
        core_input = self.remotes / 'Unified/Core/Input/remote.lua'
        core_input.write_text('-- existing wayland_text.py keyboard\n')
        self.keyboard_path('wayland_text.py').write_text('still in use')
        self.keyboard_path('remote.lua').write_text('-- wayland_text.py')
        self.run_install('--mouse-only', '--no-restart')
        self.assertEqual(core_input.read_text(), '-- existing wayland_text.py keyboard\n')
        self.assertEqual(self.keyboard_path('wayland_text.py').read_text(), 'still in use')

    def test_mouse_only_preserves_an_existing_native_keyboard(self):
        core_input = self.remotes / 'Unified/Core/Input/remote.lua'
        core_input.write_text('-- existing wayland_ffi.lua keyboard\n')
        self.keyboard_path('wayland_ffi.lua').write_text('native backend')
        self.run_install('--mouse-only', '--no-restart')
        self.assertEqual(core_input.read_text(), '-- existing wayland_ffi.lua keyboard\n')
        self.assertEqual(self.keyboard_path('wayland_ffi.lua').read_text(), 'native backend')

    def test_symlink_escape_is_rejected_before_mutation(self):
        outside = self.base / 'outside'
        outside.mkdir()
        (outside / 'remote.lua').write_text('private')
        mouse = self.remotes / 'Unified/Core/Mouse'
        shutil.rmtree(mouse)
        mouse.symlink_to(outside, target_is_directory=True)
        self.run_install('--mouse-only', '--no-restart', success=False)
        self.assertEqual((outside / 'remote.lua').read_text(), 'private')
        self.assertFalse((self.base / 'backups').exists())

    def test_bad_path_and_conflicting_modes_are_rejected(self):
        self.run_install('--keyboard', '--mouse-only', success=False)
        self.run_install('--mouse-only', '--server-dir', str(self.base / 'missing'), success=False)

    def test_foreign_service_is_never_restarted(self):
        self.env.update(TEST_ACTIVE='1', TEST_MAINPID=str(os.getpid()))
        self.run_install('--mouse-only', '--restart', success=False)
        self.assertNotIn('restart', self.record.read_text())
        self.assertFalse((self.base / 'backups').exists())

    def test_auto_restart_requires_the_exact_server_executable(self):
        shutil.copy2('/usr/bin/sleep', self.binary)
        process = subprocess.Popen([str(self.binary), '60'])
        self.addCleanup(lambda: (process.terminate(), process.wait()) if process.poll() is None else None)
        self.env.update(TEST_ACTIVE='1', TEST_MAINPID=str(process.pid))
        self.run_install('--mouse-only')
        calls = self.record.read_text()
        self.assertIn('--user stop unified-remote.service', calls)
        self.assertIn('--user restart unified-remote.service', calls)

    def test_failed_copy_rolls_back_all_changed_files(self):
        original = (self.remotes / 'Unified/Core/Input/remote.lua').read_bytes()
        self.script('cp', '''#!/bin/bash
if [[ $1 == -- && $2 == */wayland_ffi.lua ]]; then exit 77; fi
exec /usr/bin/cp "$@"
''')
        result = self.run_install('--keyboard', '--no-restart', success=False)
        self.assertIn('rolling back', result.stderr)
        self.assertEqual((self.remotes / 'Unified/Core/Input/remote.lua').read_bytes(), original)
        self.assertFalse(self.keyboard_path('wayland_ffi.lua').exists())
        self.assertFalse(list(self.remotes.rglob('.ur-fix-*')))

    def test_backup_integrity_is_checked_before_restore(self):
        self.run_install('--mouse-only', '--no-restart')
        backup = self.backup()
        (backup / 'remotes/Unified/Core/Input/remote.lua').write_text('tampered')
        installed = (self.remotes / 'Unified/Core/Input/remote.lua').read_bytes()
        result = subprocess.run(['bash', str(backup / 'restore.sh')], capture_output=True, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.remotes / 'Unified/Core/Input/remote.lua').read_bytes(), installed)

    def test_busy_legacy_runtime_is_not_removed(self):
        runtime = self.runtime / 'unified-remote-text'
        runtime.mkdir(mode=0o700)
        lock = runtime / 'worker.lock'
        lock.write_text('')
        with lock.open('r+') as file:
            fcntl.flock(file, fcntl.LOCK_EX)
            self.run_install('--keyboard', '--no-restart')
            self.assertTrue(lock.exists())

    def test_matching_old_worker_is_stopped_but_another_installation_is_not(self):
        old = self.keyboard_path('wayland_text.py')
        old.write_text('import time\nwhile True: time.sleep(1)\n')
        other = self.base / 'other_installation/wayland_text.py'
        other.parent.mkdir()
        other.write_text(old.read_text())
        own = subprocess.Popen([sys.executable, str(old), '--worker'])
        foreign = subprocess.Popen([sys.executable, str(other), '--worker'])
        self.addCleanup(lambda: (own.terminate(), own.wait()) if own.poll() is None else None)
        self.addCleanup(lambda: (foreign.terminate(), foreign.wait()) if foreign.poll() is None else None)
        time.sleep(.05)
        self.env['TEST_PGREP_PID'] = str(own.pid) + '\n' + str(foreign.pid)
        self.run_install('--keyboard', '--no-restart')
        self.assertIsNotNone(own.poll())
        self.assertIsNone(foreign.poll())

    def test_leading_tilde_is_expanded_without_evaluating_shell_text(self):
        self.run_install('--mouse-only', '--server-dir', '~/UR server with spaces', '--no-restart')
        self.assertIn('mouse.down', (self.remotes / 'Unified/Core/Input/remote.lua').read_text())

    def test_repeat_install_creates_distinct_restorable_backups(self):
        self.run_install('--keyboard', '--no-restart')
        first = self.backup()
        self.run_install('--keyboard', '--no-restart')
        backups = list((self.base / 'backups').iterdir())
        self.assertEqual(len(backups), 2)
        second = next(path for path in backups if path != first)
        self.restore(second)
        self.assertTrue(self.keyboard_path('wayland_ffi.lua').exists())
        self.restore(first)
        self.assertFalse(self.keyboard_path('wayland_ffi.lua').exists())

    def test_shared_packages_are_detected_without_uninstalling(self):
        self.script('rpm', '#!/bin/bash\n[[ $1 == -q ]] || exit 88\nexit 0\n')
        result = self.run_install('--keyboard', '--no-restart')
        self.assertIn('Detected shared package (retained): python3-evdev', result.stdout)

    def test_private_library_prefix_is_recorded_in_custom_service(self):
        private = self.base / 'private libraries'
        private.mkdir()
        self.run_install('--keyboard', '--library-dir', str(private), '--install-service',
                         '--service', 'ur-custom.service', '--no-restart')
        unit = self.home / '.config/systemd/user/ur-custom.service'
        self.assertIn('LD_LIBRARY_PATH=' + str(private), unit.read_text())
        self.restore(self.backup())
        self.assertFalse(unit.exists())

    def test_separate_remotes_do_not_generate_a_guessed_service(self):
        external = self.base / 'custom remotes'
        self.remotes.rename(external)
        self.remotes = external
        self.run_install('--keyboard', '--remotes-dir', str(external), '--install-service', success=False)
        self.assertFalse((self.base / 'backups').exists())

    def test_generated_service_escapes_paths_and_restore_removes_it(self):
        strange = self.home / 'UR 100% $cost "quote" \\ slash'
        self.server.rename(strange)
        self.server = strange
        self.remotes = strange / 'remotes'
        self.run_install('--mouse-only', '--install-service', '--no-restart')
        unit = self.home / '.config/systemd/user/unified-remote.service'
        contents = unit.read_text()
        self.assertIn('100%%', contents)
        self.assertIn('$$cost', contents)
        self.assertIn('\\"quote\\"', contents)
        self.assertNotIn('Downloads', contents)
        if shutil.which('systemd-analyze'):
            result = subprocess.run(['systemd-analyze', '--user', 'verify', str(unit)], capture_output=True, text=True, env=self.env)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.restore(self.backup())
        self.assertFalse(unit.exists())

    def test_broken_screen_helpers_are_outside_wayland_installation_scope(self):
        marker = self.base / 'screen-helper-was-executed'
        helper = self.base / 'broken-screen-python'
        helper.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 1\n')
        helper.chmod(0o755)
        originals = {}
        for name, script in [('Bazzite Screen', 'bazzite_screen_streamer.py'),
                             ('KDE Screen Remote', 'kde_screen_remote_streamer.py')]:
            folder = self.remotes / 'Custom' / name
            folder.mkdir(parents=True)
            launcher = folder / 'remote.lua'
            launcher.write_text('local python_bin = "' + str(helper) + '";\n')
            (folder / script).write_text('# preserve capture code\n')
            originals[launcher] = launcher.read_bytes()
        self.run_install('--keyboard', '--no-restart')
        self.assertFalse(marker.exists())
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertNotIn('Custom/', (self.backup() / 'manifest.tsv').read_text())

    def test_wayland_restore_preserves_independent_screen_changes(self):
        folder = self.remotes / 'Custom/Bazzite Screen'
        folder.mkdir(parents=True)
        launcher = folder / 'remote.lua'
        launcher.write_text('-- original screen launcher\n')
        self.run_install('--keyboard', '--no-restart')
        launcher.write_text('-- independently updated screen launcher\n')
        self.restore(self.backup())
        self.assertEqual(launcher.read_text(), '-- independently updated screen launcher\n')

    def standalone(self, unsafe=None):
        directory = self.base / 'standalone'
        directory.mkdir()
        self.installer = directory / 'install.sh'
        shutil.copy2(INSTALLER, self.installer)
        archive = self.base / 'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as bundle:
            if unsafe:
                entry = tarfile.TarInfo(unsafe)
                if unsafe.endswith('link'):
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = '/tmp'
                    bundle.addfile(entry)
                else:
                    entry.size = 1
                    bundle.addfile(entry, io.BytesIO(b'x'))
            else:
                bundle.add(ROOT, arcname='Wayland-Fix-main',
                           filter=lambda item: None if '__pycache__' in item.name else item)
        temporary = self.base / 'downloads'
        temporary.mkdir()
        self.env.update(TEST_ARCHIVE=str(archive), TMPDIR=str(temporary),
                        TEST_CURL_RECORD=str(self.base / 'curl-calls'))
        self.script('curl', '''#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_CURL_RECORD"
while (( $# )); do
    if [[ $1 == --output ]]; then cp -- "$TEST_ARCHIVE" "$2"; exit; fi
    shift
done
exit 1
''')
        return temporary

    def test_standalone_downloads_snapshot_and_preserves_arguments(self):
        temporary = self.standalone()
        self.run_install('--keyboard', '--no-restart')
        self.assertIn('wayland_ffi.lua', (self.remotes / 'Unified/Core/Input/remote.lua').read_text())
        self.assertIn('codeload.github.com/laurorual/Unified-Remote-Linux-Wayland-Fix',
                      Path(self.env['TEST_CURL_RECORD']).read_text())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_standalone_check_does_not_mutate_installation(self):
        temporary = self.standalone()
        self.run_install('--keyboard', '--check')
        self.assertFalse((self.base / 'backups').exists())
        self.assertFalse(self.keyboard_path('wayland_ffi.lua').exists())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_standalone_help_does_not_download(self):
        self.standalone()
        self.run_install('--help')
        self.assertFalse(Path(self.env['TEST_CURL_RECORD']).exists())

    def test_standalone_download_failure_preserves_installation(self):
        temporary = self.standalone()
        self.script('curl', '#!/bin/bash\nexit 22\n')
        self.run_install('--keyboard', '--no-restart', success=False)
        self.assertFalse((self.base / 'backups').exists())
        self.assertFalse(self.keyboard_path('wayland_ffi.lua').exists())
        self.assertEqual(list(temporary.iterdir()), [])

    def test_standalone_rejects_archive_traversal_and_links(self):
        temporary = self.standalone(unsafe='repository/../escape')
        self.run_install('--mouse-only', '--no-restart', success=False)
        self.assertEqual(list(temporary.iterdir()), [])
        self.assertFalse((self.base / 'backups').exists())
        with tarfile.open(self.env['TEST_ARCHIVE'], 'w:gz') as bundle:
            entry = tarfile.TarInfo('repository/link')
            entry.type = tarfile.SYMTYPE
            entry.linkname = '/tmp'
            bundle.addfile(entry)
        self.run_install('--mouse-only', '--no-restart', success=False)
        self.assertEqual(list(temporary.iterdir()), [])









if __name__ == '__main__':
    unittest.main()
