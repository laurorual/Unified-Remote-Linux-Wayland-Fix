# Unified Remote fixes for Linux Wayland

This overlay fixes mouse movement, clicks, scrolling, and dragging in the
Unified Remote Server for Linux on Wayland. An optional **KDE Plasma Wayland
keyboard fix** handles accents, symbols, and Unicode through native LuaJIT FFI.

The screen-capture remote lives in the separate
[KDE Screen Remote](https://github.com/laurorual/unified-remote-kde-screen)
repository. Neither installer modifies the other project's remote files.

## Install or update

Run as your desktop user, **not as root**. Unified Remote Server must already
be installed, and its remotes directory must be writable by your user.

```bash
curl -fsSL https://raw.githubusercontent.com/laurorual/Unified-Remote-Linux-Wayland-Fix/main/install.sh -o install.sh
bash install.sh
```

The standalone script downloads a coherent snapshot of the **current `main`
branch**. It locates your server (or asks for its directory), offers the
optional KDE keyboard fix, checks its requirements, and creates a private
backup before installing. Rerun this command whenever you want to update.
No automatic updater is installed.

For an explicit server location and keyboard fix:

```bash
bash install.sh --server-dir "$HOME/Downloads/UnifiedRemoteServer" --keyboard --yes
```

Use `--mouse-only` on other desktops. It preserves an existing keyboard
configuration. Close and reopen the remote on your phone after installation.

## Native dependencies and permissions

- Bash 4.4+, Linux, `curl` and `tar` for standalone installation.
- A Unified Remote Server with a user-writable `remotes` directory.
- Working write access to `/dev/uinput`; the installer checks but **does not
  silently modify udev rules or user groups**.
- For the KDE keyboard: native `libxkbcommon.so.0`, `libdbus-1.so.3`,
  and `libevdev.so.2` compatible with the server's architecture, plus KDE
  Wayland's keyboard services and compose/layout data.

The keyboard backend itself does **not** need Python, dbus-python,
python-evdev, or wl-clipboard. Python and standalone LuaJIT are only useful
for developer tests or additional diagnostics.

When native libraries are missing, the installer **asks for your permission
before installing anything**, even if you pass `--yes`. For standard Linux
distributions it supports `dnf`, `apt-get`, and `pacman`. On immutable
rpm-ostree hosts (including Bazzite), when Homebrew is available **and the
server uses a managed systemd user service**, it first offers a user-local
Homebrew installation and configures that service's library environment.
If this cannot be used, it explains the rpm-ostree package-layering fallback,
including its potential reboot requirement, before seeking permission. It
never silently layers RPM packages.

If you decline package installation, the existing installation is left
untouched. You can instead provide compatible private libraries using
`--library-dir PATH`. Characters unavailable in the active layout use
Klipper and Ctrl+V as a fallback, potentially replacing the clipboard contents.

## Start Unified Remote automatically with systemd

During **interactive installation**, the script offers to configure automatic
startup through `systemd --user` **only if no known startup configuration was
detected**. It checks the selected enabled systemd service, other enabled
user services that explicitly launch the same `urserver`, and active XDG
autostart `.desktop` entries containing that executable path.

If the selected service is already enabled, it is preserved. If another
startup mechanism is detected, the installer will **not create a duplicate
service**. Other startup methods such as custom login scripts or external
process supervisors cannot always be detected; check those manually.

You can explicitly request a service for the selected server:

```bash
bash install.sh --server-dir "$HOME/Downloads/UnifiedRemoteServer" --keyboard --install-service
```

A new unit uses the actual server path and is enabled under your user session
(no system-wide service). An already enabled matching service is not replaced.
If user-local Homebrew libraries are needed with an existing enabled unit, the
installer uses a reversible systemd environment drop-in rather than creating
another service.

For noninteractive scripts, `--yes` does **not** enable a new service by
itself; include `--install-service` if you want one.

## Preflight, backups and restore

```bash
bash install.sh --keyboard --check          # Read-only requirement and installation-plan check
bash install.sh --keyboard --no-restart     # Restart the server manually
bash install.sh --help                     # All options
```

`--remotes-dir`, `--backup-dir`, `--service`, `--library-dir`, and
`--keep-legacy-files` are available for advanced installations. The
installer uses backups with SHA-256 manifests and supplies a restore script
with each installation:

```bash
bash /path/to/backup/restore.sh
# Optionally restart the selected service:
bash /path/to/backup/restore.sh --restart
```

Restoration preserves KDE Screen Remote custom files. The installer only
restarts an active user service when it confirms that service runs the
selected server executable.

## Development

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

Standalone LuaJIT is optional for normal use but enables extra FFI regression
tests. See [CHANGELOG.md](CHANGELOG.md) for the history.
