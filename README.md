# Unified Remote fixes for Linux Wayland

Fixes mouse movement, clicks, scrolling and dragging in Unified Remote on Linux
Wayland. Optional **KDE Plasma Wayland keyboard input** supports accents, symbols
and Unicode through LuaJIT FFI.

Mouse and keyboard do not require Python. Screen-capture remotes are maintained
separately by [KDE Screen Remote](https://github.com/laurorual/unified-remote-kde-screen).

## Install or update

Run as your desktop user, **without sudo**. No clone is required:

```bash
curl -fsSL https://raw.githubusercontent.com/laurorual/Unified-Remote-Linux-Wayland-Fix/main/install.sh -o install.sh
bash install.sh
```

The installer downloads its source files temporarily, finds your server, asks
whether to include the KDE keyboard fix and creates a backup before installation.
It restarts an active user service only when it runs the selected server binary.
Close and reopen the remote in the mobile app afterward.

To specify a path and include the keyboard without prompts:

```bash
bash install.sh --server-dir "$HOME/Downloads/UnifiedRemoteServer" --keyboard --yes
```

Use `--mouse-only` on other desktops. It preserves an existing keyboard fix.

## Requirements

- Unified Remote Server for Linux with a user-writable remotes directory.
- Bash 4.4+, standard Linux utilities and permission to write `/dev/uinput`.
- `curl` and `tar` for the standalone download.
- For the keyboard: KDE Plasma Wayland, embedded LuaJIT FFI, and
  `libxkbcommon.so.0`, `libdbus-1.so.3`, `libevdev.so.2` matching the server's
  architecture, plus the desktop's keyboard/compose data.

The installer checks requirements but does not install/remove packages or change
device permissions or keyboard layouts. Characters unavailable in the current
layout use Klipper and Ctrl+V; that fallback replaces the clipboard and requires
the target application to accept paste.

## Options and restore

```bash
bash install.sh --help
bash install.sh --keyboard --check          # Preview without changing installed files
bash install.sh --keyboard --no-restart     # Restart the server yourself
bash install.sh --keyboard --install-service --yes
```

`--remotes-dir`, `--backup-dir`, `--service` and `--library-dir` support custom
installations. The installer prints the backup location and restore command:

```bash
bash /path/to/backup/restore.sh --restart
```

## Development

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh
```

Developer tests use Python and standalone LuaJIT. Neither is required to run
the installed mouse/keyboard remotes.
See [CHANGELOG.md](CHANGELOG.md) for version history.
