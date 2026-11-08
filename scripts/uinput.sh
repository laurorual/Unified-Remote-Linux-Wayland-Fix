#!/usr/bin/env bash
# Loaded by install.sh after its standalone bootstrap. No work occurs when sourced.
# Dedicated group grants access only to uinput, never the broader "input" group.

UINPUT_NODE=/dev/uinput
UINPUT_GROUP=unified-remote-uinput
UINPUT_RULE=/etc/udev/rules.d/99-unified-remote-uinput.rules
UINPUT_MODULE=/etc/modules-load.d/unified-remote-uinput.conf

uinput_rule_contents() {
    printf '%s\n' 'KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="unified-remote-uinput", MODE="0660"'
}

uinput_device_exists() { [[ -c $UINPUT_NODE ]]; }
uinput_access_ok() { uinput_device_exists && [[ -w $UINPUT_NODE ]]; }

uinput_group_exists() { getent group "$UINPUT_GROUP" >/dev/null 2>&1; }
uinput_session_member() {
    id -nG | tr ' ' '\n' | grep -Fxq -- "$UINPUT_GROUP"
}
uinput_persistent_member() {
    local account
    account=$(id -un) || return 1
    id -nG "$account" | tr ' ' '\n' | grep -Fxq -- "$UINPUT_GROUP"
}

uinput_check_managed_file() {
    local dest=$1 expected=$2
    if [[ -e $dest || -L $dest ]]; then
        [[ -f $dest && ! -L $dest ]] ||
            die "Refusing to replace a non-regular file or symlink: $dest"
        [[ $(cat -- "$dest") == "$expected" ]] ||
            die "Conflicting configuration at $dest; inspect it manually. No changes were made."
    fi
}

uinput_install_text() {
    local target=$1 value=$2 tmp
    tmp=$(mktemp) || die "Could not stage uinput configuration"
    printf '%s\n' "$value" > "$tmp"
    if ! as_root install -D -m 0644 -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        die "Could not install $target"
    fi
    rm -f -- "$tmp"
}

uinput_confirm_changes() {
    local answer
    warn "/dev/uinput is not writable by this desktop session."
    warn "With your approval, the installer may create the dedicated $UINPUT_GROUP group,"
    warn "add only the current user to it, and install a narrowly scoped /etc/udev rule."
    warn "If /dev/uinput is missing, it will also load the uinput kernel module"
    warn "and configure that module to load at boot. No rpm-ostree changes are needed."
    warn "A full logout/login may be required to activate a new group membership."
    [[ -t 0 ]] ||
        die "Run interactively to approve /dev/uinput configuration; --yes does not grant system permission."
    read -r -p 'Configure /dev/uinput for Unified Remote? [y/N] ' answer || answer=n
    case $answer in
        y|Y|yes|YES) ;;
        *) die "Permission setup declined. No uinput system settings were changed.";;
    esac
}

ensure_uinput_access() {
    if uinput_access_ok; then
        log "Input permissions: /dev/uinput is already accessible; no changes necessary."
        return 0
    fi

    if (( check )); then
        die "/dev/uinput is not accessible; --check never changes permissions. Run the installer interactively to configure it."
    fi

    [[ $EUID -ne 0 ]] ||
        die "Configure /dev/uinput as your normal desktop account, not root."
    for tool in getent id tr grep groupadd usermod udevadm install mktemp; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "Cannot configure /dev/uinput: required command missing: $tool"
    done
    command -v sudo >/dev/null 2>&1 ||
        die "Cannot configure /dev/uinput without sudo. No settings were changed."
    if ! uinput_device_exists; then
        command -v modprobe >/dev/null 2>&1 ||
            die "No /dev/uinput device and modprobe is unavailable; install/load kernel support manually."
    fi

    # Avoid replacing pre-existing third-party policies, even with the same filename.
    uinput_check_managed_file "$UINPUT_RULE" "$(uinput_rule_contents)"
    if ! uinput_device_exists; then
        uinput_check_managed_file "$UINPUT_MODULE" uinput
    fi

    # If our own policy is already in place and the account is already in the
    # dedicated group, a stale graphical session may be the only problem.
    if uinput_group_exists && uinput_persistent_member &&
       [[ -f $UINPUT_RULE ]] && ! uinput_session_member; then
        die "Your user is already in $UINPUT_GROUP, but this session has not picked it up. Log out completely, log in, then rerun install.sh."
    fi

    uinput_confirm_changes

    # Authenticate before making changes to reduce partial installations.
    as_root true || die "Administrator authorization was not granted."
    local account
    account=$(id -un) || die "Could not identify current desktop user"
    if ! uinput_group_exists; then
        as_root groupadd --system "$UINPUT_GROUP" ||
            die "Could not create the dedicated uinput group."
    fi
    if ! uinput_persistent_member; then
        as_root usermod -aG "$UINPUT_GROUP" "$account" ||
            die "Could not add $account to $UINPUT_GROUP."
    fi
    if [[ ! -e $UINPUT_RULE ]]; then
        uinput_install_text "$UINPUT_RULE" "$(uinput_rule_contents)"
    fi

    if ! uinput_device_exists; then
        as_root modprobe uinput ||
            die "The kernel did not load uinput. Existing group/rule settings can remain until kernel support is available."
        if [[ ! -e $UINPUT_MODULE ]]; then
            uinput_install_text "$UINPUT_MODULE" uinput
        fi
    fi

    as_root udevadm control --reload-rules ||
        die "Could not reload udev rules after creating uinput permission settings."
    as_root udevadm trigger --action=change --subsystem-match=misc --sysname-match=uinput ||
        die "Could not apply udev permissions to uinput."
    as_root udevadm settle --timeout=10 ||
        die "udev did not settle; check /dev/uinput permissions."

    if ! uinput_device_exists; then
        die "The uinput device is still absent; check kernel support and rerun install.sh."
    fi
    if ! uinput_access_ok; then
        if ! uinput_session_member && uinput_persistent_member; then
            die "uinput permissions were configured successfully, but your current session lacks the new group. Log out fully, log back in, and rerun install.sh. No remotes were changed."
        fi
        die "/dev/uinput is still not writable. Inspect the active udev policy and rerun install.sh. No remotes were changed."
    fi
    log "Input permissions: /dev/uinput is accessible."
}
