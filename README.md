# Unified Remote Fix for Wayland on Linux

Mouse input fixes for Unified Remote on Linux Wayland, plus symbol and accented
text input for **KDE Plasma on Wayland**. The keyboard helper uses KDE's active
layout and KWin's input device interface; it requires KDE Plasma.

The source files are available directly in this repository. The old ZIP in the
repository root has been replaced by the `remotes/` and `systemd/` directories.

## Requirements for symbols and accents

- Unified Remote Server for Linux and a KDE Plasma Wayland session.
- Python 3 at `/usr/bin/python3`, `dbus-python`, `evdev` and `libxkbcommon`.
- Access to `/dev/uinput`, as required by Unified Remote's Wayland input backend.
- `wl-clipboard` for characters outside the active keyboard layout.

Fedora:

```bash
sudo dnf install python3 python3-dbus python3-evdev libxkbcommon wl-clipboard
```

On Bazzite and other rpm-ostree systems, install missing packages with
`rpm-ostree install` instead of `dnf`; a reboot may be needed. Debian/Ubuntu
package names are `python3`, `python3-dbus`, `python3-evdev`, `libxkbcommon0` and
`wl-clipboard`. Arch uses `python`, `dbus-python`, `python-evdev`, `libxkbcommon`
and `wl-clipboard`.

## Apply or update the fixes

1. Clone this repository, or use **Code > Download ZIP** and extract it.
2. Open a terminal inside the downloaded source directory.
3. Set your actual Unified Remote Server path, back up the existing remotes,
   then copy the fixes:

```bash
UR_DIR="$HOME/Downloads/UnifiedRemoteServer"
test -x "$UR_DIR/urserver" || { echo 'Check UR_DIR'; exit 1; }
BACKUP_DIR="$HOME/unified-remote-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a "$UR_DIR/remotes" "$BACKUP_DIR/remotes"
cp -a remotes/. "$UR_DIR/remotes/"
```

Copy the whole `remotes/` overlay, including **Core/Keyboard/wayland_text.py**
and both Core Lua files. Copying only `Core/Input/remote.lua` is insufficient.

4. Restart Unified Remote Server. If it runs as the supplied user service:

```bash
systemctl --user restart unified-remote.service
```

5. Close and reopen the mobile remote, then type:

```text
Olá, ação! ç ã é @ # $ % & * ( ) [ ] { } / ? + = €
```

The original mouse, click, scroll and drag fixes remain included.

## Optional automatic startup

The supplied service assumes the server is at
`$HOME/Downloads/UnifiedRemoteServer/urserver`. Edit `WorkingDirectory` and
`ExecStart` in `systemd/unified-remote.service` if your path differs. Back up an
existing service before replacing it:

```bash
mkdir -p "$HOME/.config/systemd/user"
if test -e "$HOME/.config/systemd/user/unified-remote.service"; then
    cp -a "$HOME/.config/systemd/user/unified-remote.service" \
        "$BACKUP_DIR/unified-remote.service"
fi
cp systemd/unified-remote.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now unified-remote.service
```

## How text input works

`Core.Input.Text`, `Core.Keyboard.text` and `Core.Keyboard.character` use a
private Python worker. It reads the active KDE keyboard layout and uses XKB to
select ordinary keys, Shift, AltGr and dead-key compose sequences. It waits for
KWin to attach its virtual keyboard before sending the first request.

The worker closes after two minutes without input. Typed text is not saved to
files or logs. If a request contains characters unavailable in the layout, the
whole request is pasted using `wl-copy` and Ctrl+V. **That fallback replaces the
clipboard and requires the target application to accept paste.** Common symbols
and Portuguese accents were tested natively on the `us intl` layout.

## Changelog

Regression checks (no desktop input is sent):

```bash
python3 -m unittest discover -s tests -v
```

### 2026-11-05 — Symbols and accented text

- Added layout-aware text input for symbols, Portuguese accents and composed text
  on KDE Wayland, including Shift and AltGr combinations.
- Updated both Core text APIs and Unicode codepoint handling.
- Added clipboard fallback for Unicode characters outside the keyboard layout.
- Wait for KWin keyboard discovery to prevent loss of the first text request.
- Kept the existing mouse, scrolling, click and drag fixes.
- Published the source tree directly and replaced ZIP-only installation steps.
- Verified symbols and accents in a native Wayland window through both Lua APIs.

### Initial version

- Mouse input fixes for Unified Remote on Wayland.
- Optional user systemd service for automatic startup.
