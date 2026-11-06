# Unified Remote fixes for Linux Wayland

Mouse click, movement, scroll and drag fixes for Unified Remote on Linux Wayland,
with **optional layout-aware keyboard input for KDE Plasma Wayland**.

The keyboard runs entirely inside Unified Remote through LuaJIT FFI. There is no
Python worker, shell per keystroke, socket server, or `wl-copy` subprocess.
The mouse fix can be installed independently on other Wayland desktops.

## Install or update

Download this repository with **Code → Download ZIP**, extract it, and open a
terminal in the extracted directory. Alternatively:

```bash
git clone https://github.com/laurorual/Unified-Remote-Linux-Wayland-Fix.git
cd Unified-Remote-Linux-Wayland-Fix
```

Run the interactive installer as your desktop user, **without sudo**:

```bash
./install.sh
```

If ZIP extraction did not preserve executable permissions, use `bash install.sh` instead.

It finds running/PATH installations and common directories, including the localized
Downloads directory. If the location is ambiguous, it asks for the folder containing
`urserver`. It then asks whether to include the KDE keyboard fix, checks the
requirements, shows its plan and creates a backup before changing anything.
Your installation does **not** have to be named `UnifiedRemoteServer` or live in
`~/Downloads`. Supply an explicit location when needed:

```bash
# Preview only: no files, packages, workers or services are changed.
./install.sh --server-dir "$HOME/Applications/Unified Remote" --keyboard --check

# Mouse and KDE Wayland keyboard.
./install.sh --server-dir "$HOME/Applications/Unified Remote" --keyboard --yes

# Mouse only: no KDE-specific keyboard dependencies are required.
./install.sh --server-dir "$HOME/Applications/Unified Remote" --mouse-only --yes
```

The installer does not download packages, change your keyboard layout, grant
input-device permissions, or change groups/udev rules. A missing requirement
produces an explanation before installation. `--skip-checks` is available for
staging files offline; it does not make an unsupported environment compatible.

If the server is a system-owned/read-only installation, use a user-writable copy
or have its administrator apply the specific files. Do not run the whole installer
with sudo: that would check the wrong desktop session and use root's user settings.

### Options

Run `./install.sh --help` for all options.

| Option | Purpose |
| --- | --- |
| `--server-dir PATH` | Folder containing the executable `urserver`; spaces are supported. |
| `--remotes-dir PATH` | A separate remotes tree already used by your existing server configuration. |
| `--keyboard` | Include the native KDE Wayland text fix. |
| `--mouse-only` | Install mouse fixes without replacing an existing keyboard setup. |
| `--check` | Read-only preflight and installation/cleanup plan. |
| `--backup-dir PATH` | Parent directory for a unique backup of this installation. |
| `--library-dir PATH` | Optional private native-library directory; see immutable systems below. |
| `--install-service` | Generate and enable a user service using this installation's real path. |
| `--service NAME.service` | Select a different user-service name. |
| `--restart` / `--no-restart` | Explicitly restart the selected user service, or leave restart to you. |
| `--keep-legacy-files` | Opt out of retiring obsolete helper files and workers. |
| `--skip-checks` | Skip runtime checks for staging/offline use. |
| `--yes` | Accept the displayed plan. With no keyboard mode, defaults to mouse-only. |

A separate `--remotes-dir` does not reconfigure the server's search paths. Preserve
its existing launcher; the installer refuses to generate a guessed service for
that combination. Relative paths and leading `~/` are accepted. Paths with line
breaks are rejected.

**Mouse-only is not an uninstaller.** On a fresh installation it retains native
text input. If a previous keyboard-enabled `Core.Input` is detected, that file
and the keyboard remotes are preserved. Legacy helpers still referenced by that
retained keyboard are also preserved. Use the relevant backup to undo a prior fix.

### Restart and optional automatic startup

By default, the installer stops/restarts an active `unified-remote.service` only
when its main process is executing **the exact selected `urserver` binary**.
It refuses an explicit restart of a service running a different installation.
For a manually launched server or an unrecognized service, restart it yourself;
`--no-restart` always leaves process/service control to you.

To create an autostart service for your actual path:

```bash
./install.sh --server-dir "$HOME/Applications/Unified Remote" \
  --keyboard --install-service --restart --yes
```

The generated unit goes in `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, uses
`graphical-session.target`, and records the selected path rather than assuming an
English Downloads folder. An existing unit is backed up before replacement.
The installer does not touch a system-wide service. Choose another `--service`
name if its default name belongs to a different server.

Then close and reopen the mobile remote. For keyboard verification, focus a text
editor on the PC and type:

```text
Olá, ação! ç ã é @ # $ % & * ( ) [ ] { } / ? + = € 🙂
```

## Requirements

### Mouse fix

- Unified Remote Server for Linux, installed with its original remotes tree.
- A Linux Wayland session and input-device access required by Unified Remote.
- Bash **4.4+** and standard Linux/coreutils commands for the installer.
- Write access to the selected remotes tree.

The mouse scripts call Unified Remote's own mouse API and add no Python or
KDE-specific runtime requirement.

### Optional keyboard fix

- **KDE Plasma on Wayland** with KWin's keyboard-layout/input-device D-Bus interfaces.
  GNOME, Sway and other compositors are not supported by this keyboard backend;
  use `--mouse-only` there. X11 text input does not need this Wayland backend.
- LuaJIT FFI bundled with the Unified Remote Server. A standalone `luajit`
  executable is **optional**, useful for diagnostics/tests only.
- Native shared libraries, matching **the server's CPU architecture and bitness**:
  `libxkbcommon.so.0`, `libdbus-1.so.3`, and `libevdev.so.2`.
- Keyboard layout data usable by libxkbcommon, normally provided by the desktop's
  `xkeyboard-config` package, plus its compose/locale data.
- Permission for the desktop user to write `/dev/uinput`. Read access to
  `/dev/input/event*` is **not required**.
- The KDE **Klipper** clipboard service for characters unavailable in the current
  layout. Ordinary mapped characters work without clipboard paste; the installer
  warns if it cannot detect Klipper.

**Python, python-evdev, dbus-python and wl-clipboard are no longer runtime
requirements.** Python is used only to run the optional developer test scripts.
Do not install dependency packages just because they appear in an old tutorial:
check what is already available first.

With a standalone `luajit`, preflight actually loads the libraries, reads the
active layout and compiles its keymap without creating a device or sending keys.
It rejects a diagnostic interpreter whose architecture differs from an ELF server.
Set `LUAJIT_BIN=/path/to/matching/luajit` when using a non-default diagnostic
interpreter. Without one, the installer checks known library sonames and reports
that final embedded-runtime/architecture validation must happen in the server.

### Missing libraries on conventional distributions

Only install what the check reports missing. Typical package names are:

| Distribution | Runtime libraries | Layout data, if absent |
| --- | --- | --- |
| Fedora | `libxkbcommon dbus-libs libevdev` | `xkeyboard-config` |
| Debian/Ubuntu | `libxkbcommon0 libdbus-1-3 libevdev2` | `xkb-data` |
| Arch Linux | `libxkbcommon dbus libevdev` | `xkeyboard-config` |

For example, on a conventional Fedora installation **if those libraries are
actually missing**:

```bash
sudo dnf install libxkbcommon dbus-libs libevdev
```

Use your distribution's package manager and the packages for the server's
architecture. A 32-bit server does not load 64-bit libraries. Installing a separate
LuaJIT or development headers is not necessary to run the fix.

### Bazzite and other immutable systems

**The Bazzite KDE notebook used to validate this release already had all required
native libraries and layout data. No host packages or layered dependencies were
installed for this fix.** Images, desktop editions and versions can differ, so
start with `--keyboard --check` instead of installing packages preemptively.

If something is genuinely missing, prefer this order:

1. Check the existing image and your server's architecture first.
2. Use compatible native libraries in a private, user-owned prefix when feasible,
   with `--library-dir`. Obtain/build them for the host's ABI and server architecture;
   keep their required dependencies together, and do not copy a foreign `libc` over
   the host's libraries. This installer does not fetch or build them automatically.
3. Consider running the **whole server** in an appropriately configured Distrobox,
   with the libraries installed there. Verify `/dev/uinput` and KDE/session/system
   D-Bus access in that environment. This setup is not automated or claimed tested
   by this project. Installing packages inside a container does not make them
   available to a server still running on the host.
4. Use host package layering with `rpm-ostree` **only as a last resort**, for the
   specifically missing native dependency. A reboot may be required.

For a private library prefix, for example:

```bash
./install.sh --server-dir "$HOME/Applications/Unified Remote" --keyboard \
  --library-dir "$HOME/.local/share/unifiedremote-libs/lib" --check

# Record that library search path in a generated service:
./install.sh --server-dir "$HOME/Applications/Unified Remote" --keyboard \
  --library-dir "$HOME/.local/share/unifiedremote-libs/lib" \
  --install-service --restart --yes
```

If keeping an existing launcher, use `--no-restart` and set its `LD_LIBRARY_PATH`
to the value printed by the installer. Merely supplying `--library-dir` during
installation does not alter an existing service's environment.

Flatpak applications/runtimes and Homebrew packages do not automatically supply
libraries to this host process. Do not grant broad Flatpak/device/D-Bus permissions
as a blanket workaround for this host-native fix.

See [Bazzite's software guide](https://docs.bazzite.gg/Installing_and_Managing_Software/),
its [package-layering guidance](https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/),
and [Distrobox integration notes](https://distrobox.it/useful_tips/).

## Layouts, Unicode and behavior

The keyboard reads the active KDE layout on every request, taking personal/global
`kxkbrc`, layout variants/options/model and the system's `systemd-localed` defaults
into account. It does not force a Brazilian or US layout and does not modify your
settings. Configure layouts normally in KDE System Settings.

It maps text through libxkbcommon into ordinary keys, Shift, AltGr and dead-key
compose sequences. The two Core entry points are serialized to avoid overlapping
modifier combinations. Each Lua context creates its virtual keyboard on first use
and waits for KWin to recognize it. That first request can take about a second;
subsequent input reuses the device for the context's lifetime. There is no helper
that expires after two minutes. Closing the session/remote can destroy the context.

For text containing characters unavailable in the layout, the **whole request** is
sent to Klipper and pasted with Ctrl+V, keeping mixed text in order. **This replaces
the clipboard and requires the target application to accept paste.** It cannot
provide arbitrary Unicode to applications that reject paste when that character
has no producible key sequence in the active layout.

Typed text is not saved to files or logged by the fix. The serialization lock in
`$XDG_RUNTIME_DIR` contains no text. Clipboard history remains governed by KDE's
clipboard settings. The existing 3 ms key-combination timing and cleanup/release
on errors are retained.

## Updating older versions and cleanup

Run the current `install.sh` against the **same server installation**. Before
replacement/deletion it backs up each affected existing file, its permissions and
a restore manifest. The cleanup detector recognizes:

- Retired `Core/Keyboard/wayland_text.py` and `wayland_client.lua`.
- Only the Python bytecode caches belonging to `wayland_text`.
- Old Python workers whose complete command line identifies the selected
  installation's helper; another installation's worker is left alone.
- The former private runtime socket/lock when it is owned by this user and its
  worker lock can be acquired. Busy/foreign runtime state is preserved.

For a mouse-only update, helpers still referenced by the retained keyboard are
not removed. `--keep-legacy-files` disables this retirement step.

The installer reports installed legacy dependency packages when the host package
manager supports the query. **It does not uninstall shared OS packages**, even
when the fix no longer needs them: other applications and the desktop may still
use Python, dbus-python, python-evdev or wl-clipboard. An earlier install did not
record exclusive package ownership, so automatic package removal would be unsafe.
Remove a manually added package only after reviewing its other uses with your
system's package tools. Native `dbus`, `libevdev` and `libxkbcommon` are still needed.

No unrelated caches, other remotes, user configuration files, download archives,
or system packages are deleted. Backups are outside the remotes tree by default:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/unified-remote-wayland-fix/backups/<unique-installation>/
```

The full location and a restore command are printed after installation. Backups
are unique on every run, including repeated installations. To undo an update:

```bash
bash /the/printed/backup/directory/restore.sh

# Also stop/start the selected service while restoring:
bash /the/printed/backup/directory/restore.sh --restart
```

Restore verifies checksums before changing files and removes files newly added
by that installation. Installation failures automatically restore backed-up files
and attempt to restart a service that the installer had stopped. A manually
running/unrecognized server still needs a manual restart after restore.

## Troubleshooting

- **`/dev/uinput` unavailable:** configure the device access required by the
  Unified Remote Linux server using your distribution/vendor rules. The fix does
  not require reading physical keyboard events. Avoid blanket `chmod 666` or
  unrelated group/permission changes.
- **No keyboard on another desktop/X11:** select `--mouse-only`; the text backend
  specifically uses KDE Wayland interfaces.
- **Missing native library or wrong architecture:** check server architecture,
  the library prefix, and its launch environment. Standalone LuaJIT used for
  diagnostics must match the server; it is not a replacement for its embedded LuaJIT.
- **Ordinary text works, emoji/euro does not:** verify Klipper is available and
  the focused application accepts Ctrl+V.
- **Old Python errors after updating:** verify the selected remotes path, restart
  the correct server, then reconnect the mobile remote. Already loaded Lua files
  can keep referring to the previous implementation until restart.
- **An application changes the clipboard or focus while typing:** retest with a
  simple focused editor; clipboard fallback follows the desktop's normal behavior.

## Validation and development

Automated tests do not type on the desktop or modify a real installation:

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh
```

The installer tests use temporary server trees and stub service commands, covering
mouse-only and keyboard installs, separate/localized/quoted paths, legacy cleanup,
worker isolation, rollback, checksums, service matching and unit-file validation.
The keyboard tests require a standalone LuaJIT plus native libraries; they check
Unicode, layouts, AltGr, configuration precedence and failure handling.

An optional real-server test requires PySide6, opens a temporary editor and needs
it to keep focus. It sends known test text and restores the clipboard afterward:

```bash
python3 tests/wayland_keyboard_integration.py
```

On the validating Bazzite KDE Wayland x86-64 notebook, nine real-server checks passed, including
100 mixed events and editing keys. Complete character sets matched the previous
Python implementation for `br` (532), `us intl` (609) and `de` (504).

Local 30-event typing went from about **5.45 s** with the original per-event Python
path to **0.18–0.20 s** with a native socket client, then **0.15 s** with direct FFI.
These measurements exclude the phone/Wi-Fi and are not a cross-machine guarantee.

## Changelog

### 2026-11-06 — Direct Lua/FFI keyboard and automated installation

- Fixed the keyboard startup failure on systems that allow `/dev/uinput` injection
  but prohibit reading `/dev/input/event*`; that failure caused repeated multi-second
  waits and made the server appear unresponsive.
- Replaced the Python/socket implementation with direct LuaJIT FFI calls to
  libevdev, libxkbcommon and D-Bus, retaining accent/compose and Unicode behavior.
- Read the system's actual layout when personal KDE configuration is absent,
  rather than assuming US; preserved variants/options and active layout changes.
- Used the existing Klipper service for Unicode paste, eliminating `wl-copy`.
- Kept the keyboard available for the Lua context's lifetime, with serialized
  Core input, bounded D-Bus calls and release/resource cleanup on errors.
- Added an interactive/scriptable `install.sh`: path discovery/overrides, optional
  keyboard, dependency preflight, private library prefixes, backups/restore,
  conservative restart and optional service generation for the real server path.
- Added detection and backed-up retirement of unused legacy helpers/caches/workers;
  shared packages and helpers still referenced by a retained keyboard are preserved.
- Corrected dependency guidance: no package installation was needed on the tested
  Bazzite image; immutable-system layering is a last resort.
- Preserved the existing mouse, click, scroll and drag fixes.

### 2026-11-05 — Symbols and accented text

- Added layout-aware text input for symbols, Portuguese accents and composed text
  on KDE Wayland, including Shift and AltGr combinations.
- Updated both Core text APIs and Unicode codepoint handling.
- Added clipboard fallback for Unicode characters outside the keyboard layout.
- Waited for KWin keyboard discovery to prevent loss of the first text request.
- Published the source overlay and replaced ZIP-only installation instructions.

### Initial version

- Mouse input fixes for Unified Remote on Wayland.
- Optional user systemd service for automatic startup.
