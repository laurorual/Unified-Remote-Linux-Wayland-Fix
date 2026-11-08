# Changelog

## 2026-11-08 — Separate installer responsibilities

- Keep the Wayland installer limited to mouse/keyboard input. Remove capture-helper
  checks, launcher repair and their option; they belong to KDE Screen Remote.
- Preserve standalone source downloads, native LuaJIT/FFI keyboard behavior and
  transactional backup/restore.
- Shorten README to the current requirements and installation steps.

## 2026-11-08 — Standalone installation and screen-helper compatibility

- Allow a downloaded `install.sh` to fetch and use a matching source snapshot,
  with argument forwarding, temporary-file cleanup and no git dependency.
- Check Bazzite Screen/KDE Screen copied Python helpers before installing or
  restarting; keep their capture dependencies separate from the retired keyboard
  worker's requirements.
- Repair a recognized launcher's broken interpreter path only when an existing,
  compatible helper and its KWin authorization are available; back up and restore
  that change with the rest of the installation.
- Refuse installation before mutation when an installed screen helper is broken
  and no suitable replacement exists. Add `--keep-screen-helpers` for intentional
  offline staging without screen checks.
- Verified the local failure was a copied Python 3.14 interpreter requiring the
  missing `libpython3.14.so.1.0` on a Python 3.15 host; restored live capture using
  the already installed and authorized Python 3.15 helper.
- Preserve the direct LuaJIT/FFI keyboard backend and existing mouse behavior.

## 2026-11-06 — Direct Lua/FFI keyboard and automated installation

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

## 2026-11-05 — Symbols and accented text

- Added layout-aware text input for symbols, Portuguese accents and composed text
  on KDE Wayland, including Shift and AltGr combinations.
- Updated both Core text APIs and Unicode codepoint handling.
- Added clipboard fallback for Unicode characters outside the keyboard layout.
- Waited for KWin keyboard discovery to prevent loss of the first text request.
- Published the source overlay and replaced ZIP-only installation instructions.

## Initial version

- Mouse input fixes for Unified Remote on Wayland.
- Optional user systemd service for automatic startup.
