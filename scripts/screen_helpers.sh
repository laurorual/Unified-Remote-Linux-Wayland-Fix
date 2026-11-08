#!/usr/bin/env bash
# Sourced by install.sh. Only known screen launchers with a literal python_bin
# assignment can be repaired, and only an existing, usable capture helper is reused.

screen_python_ok() {
    [[ -x $1 ]] || return 1
    timeout 5s "$1" -c 'import dbus; from PIL import Image; from gi.repository import GLib' \
        </dev/null >/dev/null 2>&1
}

screen_python_authorized() {
    local directory desktop name
    for directory in "${XDG_DATA_HOME:-$HOME/.local/share}" /usr/local/share /usr/share; do
        for name in org.bazzitescreen.helper org.kdescreenremote.helper; do
            desktop=$directory/applications/$name.desktop
            [[ -f $desktop ]] || continue
            if grep -Fxq -- 'X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2' "$desktop" &&
                { grep -Fxq -- "Exec=$1" "$desktop" || grep -Fxq -- "Exec=\"$1\"" "$desktop"; }; then
                return 0
            fi
        done
    done
    return 1
}

prepare_screen_helpers() {
    local name launcher configured candidate replacement path line index count=0
    local declaration='^[[:space:]]*local[[:space:]]+python_bin[[:space:]]*=[[:space:]]*"([^"]+)";?[[:space:]]*$'
    local -a launchers=() interpreters=() candidates=()
    for name in 'Bazzite Screen' 'KDE Screen Remote'; do
        launcher=$remotes_dir/Custom/$name/remote.lua
        [[ -f $launcher && ! -L $launcher ]] || continue
        if [[ $name == 'Bazzite Screen' ]]; then
            [[ -f $remotes_dir/Custom/$name/bazzite_screen_streamer.py ]] || continue
        else [[ -f $remotes_dir/Custom/$name/kde_screen_remote_streamer.py ]] || continue; fi
        configured=''
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ $declaration ]]; then configured=${BASH_REMATCH[1]}; break; fi
        done < "$launcher"
        if [[ -z $configured ]]; then
            warn "Preserving unfamiliar screen launcher: $launcher"
            continue
        fi
        launchers+=("$launcher"); interpreters+=("$configured"); candidates+=("$configured")
    done
    (( ${#launchers[@]} )) || return 0
    command -v timeout >/dev/null || die 'timeout (coreutils) is required to check installed screen helpers'
    candidates+=(/usr/local/libexec/bazzite-screen-python /usr/local/libexec/kde-screen-remote-python)
    for index in "${!launchers[@]}"; do
        launcher=${launchers[index]}; configured=${interpreters[index]}
        if screen_python_ok "$configured"; then
            log "Screen helper OK: $configured"
            continue
        fi
        replacement=''
        for candidate in "${candidates[@]}"; do
            if screen_python_authorized "$candidate" && screen_python_ok "$candidate"; then
                replacement=$candidate; break
            fi
        done
        if [[ -z $replacement ]]; then
            die "Screen helper is unusable: $configured. Refresh the authorized Python helper with the KDE Screen installer, then retry. No files have been changed. The keyboard no longer needs Python, but screen capture still does."
        fi
        # Avoid turning a literal Lua string into escapes or expressions.
        [[ $replacement != *$'\n'* && $replacement != *$'\r'* && $replacement != *'"'* && $replacement != *\'* && $replacement != *\\* ]] ||
            die 'Capture helper path cannot be represented safely in this launcher'
        [[ -n $screen_stage ]] || screen_stage=$(mktemp -d)
        path=$screen_stage/$count.lua
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ $declaration ]]; then
                printf 'local python_bin = "%s";\n' "$replacement"
            else printf '%s\n' "$line"; fi
        done < "$launcher" > "$path"
        sources+=("$path"); keys+=("remotes/${launcher#"$remotes_dir/"}")
        log "Repair screen launcher after backup: $launcher"
        log "  Unusable copied Python: $configured"
        log "  Existing capture helper: $replacement"
        count=$((count + 1))
    done
}
