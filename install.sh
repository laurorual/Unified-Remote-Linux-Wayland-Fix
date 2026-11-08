#!/usr/bin/env bash
# Install only the mouse/keyboard overlay. No packages, ACLs, groups or layouts are changed.
set -Eeuo pipefail
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { printf '%s\n' 'Bash 4.4 or newer is required.' >&2; exit 1; }
SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
original_args=("$@")
server_dir='' remotes_dir='' keyboard='' yes=0 check=0 skip_checks=0
install_service=0 restart=auto cleanup=1 service=unified-remote.service library_dir=''
backup_base=${XDG_STATE_HOME:-$HOME/.local/state}/unified-remote-wayland-fix/backups
backup='' service_file='' stopped=0 mutation=0
log() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: ./install.sh [options]
  --server-dir PATH     Directory containing urserver (autodetected when possible).
  --remotes-dir PATH    Separate remotes tree; defaults to SERVER_DIR/remotes.
  --keyboard            Install the optional KDE Plasma Wayland keyboard fix.
  --mouse-only          Install mouse fixes; preserve an already installed keyboard fix.
  --check               Show the plan and check requirements, without changing files.
  --skip-checks         Skip Core runtime/session checks (offline/test use).
  --backup-dir PATH     Parent directory for a unique, private installation backup.
  --library-dir PATH    Optional private native libraries; see README before using.
  --install-service     Generate and enable a user service for this server's actual path.
  --service NAME        User service name (default: unified-remote.service).
  --restart             Restart the selected user service; refuse a different running server.
  --no-restart          Do not stop/start the server (restart it manually after installing).
                        Default: restart only an active service running this exact binary.
  --keep-legacy-files   Do not remove retired helper files/caches or stop old workers.
  --yes                 Accept the plan; without a mode, select mouse-only.
  -h, --help            Show this help.
Run in the desktop user's host terminal, without sudo. No packages are installed or removed.
HELP
}
need_value() { (( $# >= 2 )) && [[ -n $2 ]] || die "$1 requires a value"; }
while (( $# )); do
    case $1 in
        --server-dir) need_value "$@"; server_dir=$2; shift 2;;
        --remotes-dir) need_value "$@"; remotes_dir=$2; shift 2;;
        --backup-dir) need_value "$@"; backup_base=$2; shift 2;;
        --library-dir) need_value "$@"; library_dir=$2; shift 2;;
        --service) need_value "$@"; service=$2; shift 2;;
        --keyboard) [[ $keyboard != 0 ]] || die 'Choose only one keyboard mode'; keyboard=1; shift;;
        --mouse-only) [[ $keyboard != 1 ]] || die 'Choose only one keyboard mode'; keyboard=0; shift;;
        --yes) yes=1; shift;;
        --check) check=1; shift;;
        --skip-checks) skip_checks=1; shift;;
        --install-service) install_service=1; shift;;
        --restart) restart=yes; shift;;
        --no-restart) restart=no; shift;;
        --keep-legacy-files) cleanup=0; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown option: $1 (use --help)";;
    esac
done
[[ $service =~ ^[a-zA-Z0-9_@][a-zA-Z0-9_.@-]*\.service$ ]] || die 'Invalid user service name'
for tool in realpath mktemp cp mv sha256sum; do command -v "$tool" >/dev/null || die "Required command missing: $tool"; done
# shellcheck disable=SC2088 # Literal tilde patterns are expanded without eval.
expand_path() { case $1 in '~') printf '%s' "$HOME";; '~/'*) printf '%s/%s' "$HOME" "${1#\~/}";; *) printf '%s' "$1";; esac; }
clean_path() { [[ $1 != *$'\n'* && $1 != *$'\r'* ]] || die 'Paths containing newlines are not supported'; }
for path in "$server_dir" "$remotes_dir" "$backup_base" "$library_dir"; do clean_path "$path"; done
if [[ -n ${SUDO_USER:-} && $EUID == 0 ]]; then die 'Run as your desktop user, without sudo; use a user-writable server copy'; fi

# A downloaded install.sh can bootstrap a coherent source snapshot without git.
# Run its matching installer as a child, keeping the temporary files until it exits.
if [[ ! -f $SOURCE_DIR/remotes/Unified/Core/Keyboard/wayland_ffi.lua ||
      ! -f $SOURCE_DIR/variants/mouse-only/Unified/Core/Input/remote.lua ]]; then
    command -v curl >/dev/null || die 'curl is required when running the standalone installer'
    command -v tar >/dev/null || die 'tar is required when running the standalone installer'
    download_dir=$(mktemp -d)
    trap 'rm -rf -- "$download_dir"' EXIT
    url='https://codeload.github.com/laurorual/Unified-Remote-Linux-Wayland-Fix/tar.gz/refs/heads/main'
    log 'Downloading the current Wayland Fix source snapshot (no git clone required)...'
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
        --max-time 60 --output "$download_dir/source.tar.gz" "$url"
    tar -tzf "$download_dir/source.tar.gz" > "$download_dir/entries"
    awk 'BEGIN { valid=1 } /^\// { valid=0 } { n=split($0,a,"/"); for(i=1;i<=n;i++) if(a[i]=="..") valid=0 } END { exit !valid }' \
        "$download_dir/entries" || die 'Unsafe source archive path'
    tar -tvzf "$download_dir/source.tar.gz" > "$download_dir/types"
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { exit 1 }' \
        "$download_dir/types" || die 'Source archive contains unsupported links or special files'
    mkdir -- "$download_dir/source"
    tar -xzf "$download_dir/source.tar.gz" --strip-components=1 --no-same-owner \
        --no-same-permissions -C "$download_dir/source"
    for required in install.sh remotes/Unified/Core/Keyboard/wayland_ffi.lua \
                    variants/mouse-only/Unified/Core/Input/remote.lua; do
        [[ -f $download_dir/source/$required ]] || die "Source archive is missing $required"
    done
    bash "$download_dir/source/install.sh" "${original_args[@]}"
    exit 0
fi

# Discover the executable, not a fixed English Downloads path. Never eval a service command.
declare -a candidates=()
add_candidate() {
    local path=$1 existing
    [[ -x $path/urserver && -d $path/remotes ]] || return 0
    path=$(realpath -e -- "$path")
    for existing in "${candidates[@]}"; do [[ $existing != "$path" ]] || return 0; done
    candidates+=("$path")
}
if [[ -z $server_dir ]]; then
    if command -v pgrep >/dev/null; then
        while IFS= read -r pid; do
            exe=$(readlink -e -- "/proc/$pid/exe" 2>/dev/null || true)
            [[ -z $exe ]] || add_candidate "${exe%/*}"
        done < <(pgrep -u "$EUID" -x urserver || true)
    fi
    if command -v urserver >/dev/null; then exe=$(realpath -e -- "$(command -v urserver)"); add_candidate "${exe%/*}"; fi
    downloads=$HOME/Downloads
    if command -v xdg-user-dir >/dev/null; then downloads=$(xdg-user-dir DOWNLOAD 2>/dev/null || printf '%s' "$downloads"); fi
    for path in "$downloads/UnifiedRemoteServer" "$HOME/Downloads/UnifiedRemoteServer" "$HOME/UnifiedRemoteServer" \
                "$HOME/.local/share/UnifiedRemoteServer" /opt/urserver /opt/unifiedremote /usr/share/urserver; do add_candidate "$path"; done
    if (( ${#candidates[@]} == 1 )); then server_dir=${candidates[0]};
    elif [[ -t 0 && $yes == 0 ]]; then
        for path in "${candidates[@]}"; do log "Found: $path"; done
        read -r -p 'Unified Remote Server directory: ' server_dir || die 'No server directory supplied'
    else die 'Server not found uniquely; specify --server-dir PATH'; fi
fi
server_dir=$(expand_path "$server_dir")
clean_path "$server_dir"
[[ -d $server_dir && -x $server_dir/urserver ]] || die 'The server directory must contain an executable urserver'
server_dir=$(realpath -e -- "$server_dir")
remotes_dir=$(expand_path "${remotes_dir:-$server_dir/remotes}")
backup_base=$(expand_path "$backup_base")
[[ -d $remotes_dir ]] || die 'Remotes directory does not exist; use --remotes-dir for a separate tree'
remotes_dir=$(realpath -e -- "$remotes_dir")
[[ -f $remotes_dir/Unified/Core/Input/remote.lua && -f $remotes_dir/Unified/Core/Keyboard/remote.lua ]] || die 'This does not look like a Unified Remote remotes tree'
[[ $remotes_dir != "$SOURCE_DIR/remotes" ]] || die 'Destination is this repository, not an installed server'
[[ -w $remotes_dir ]] || die 'Remotes tree is not writable; use a user-writable server copy instead of sudo'
if [[ -z $keyboard ]]; then
    if [[ -t 0 && $yes == 0 ]]; then
        read -r -p 'Also install keyboard input for KDE Plasma Wayland? [y/N] ' answer || answer=n
        case $answer in y|Y|yes|YES) keyboard=1;; *) keyboard=0;; esac
    elif (( yes )); then keyboard=0;
    else die 'Specify --keyboard or --mouse-only for noninteractive use'; fi
fi
# --yes never silently enables a user service.
if (( ! install_service && ! yes && ! check )) && [[ -t 0 ]]; then
    read -r -p 'Configure automatic startup via a systemd user service? [y/N] ' answer || answer=n
    case $answer in y|Y|yes|YES) install_service=1;; esac
fi
if [[ -n $library_dir ]]; then
    library_dir=$(expand_path "$library_dir")
    [[ -d $library_dir ]] || die '--library-dir must be an existing directory'
    library_dir=$(realpath -e -- "$library_dir")
    export LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
service_file=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$service
clean_path "$service_file"

has_owner() {
    command -v busctl >/dev/null || return 2
    [[ $(busctl --user --timeout=2s call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus NameHasOwner s "$1" 2>/dev/null) == 'b true' ]]
}
# Native FFI libraries are loaded by urserver, not by Python.
native_lib_present() {
    local soname=$1 dir
    if [[ -n $library_dir && -f $library_dir/$soname ]]; then return 0; fi
    for dir in /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu /lib64 /lib /lib/x86_64-linux-gnu; do
        [[ -f $dir/$soname ]] && return 0
    done
    if command -v ldconfig >/dev/null; then
        ldconfig -p 2>/dev/null | grep -Fq -- "$soname " && return 0
    fi
    return 1
}
confirm_dependency_change() {
    local message=$1 answer
    warn "$message"
    # --yes only approves the installation plan, not package or system changes.
    [[ -t 0 ]] || die 'Missing native libraries; rerun interactively to approve dependency installation'
    read -r -p 'Install these missing dependencies? [y/N] ' answer || answer=n
    case $answer in y|Y|yes|YES) :;; *) die 'Dependency installation declined; no packages were installed';; esac
}
as_root() {
    if (( EUID == 0 )); then "$@"
    else command -v sudo >/dev/null || die 'sudo is required for system package installation'; sudo "$@"
    fi
}
ensure_native_libraries() {
    (( keyboard )) || return 0
    local soname formula package manager='' immutable=0 index prefix candidate
    local -a missing=() formulas=() packages=()
    for soname in libxkbcommon.so.0 libdbus-1.so.3 libevdev.so.2; do
        native_lib_present "$soname" || missing+=("$soname")
    done
    (( ${#missing[@]} )) || return 0
    warn "Missing native keyboard libraries: ${missing[*]}"
    (( ! check )) || die 'Dependency check failed; --check never installs packages'

    if [[ -f /run/ostree-booted ]] && command -v rpm-ostree >/dev/null; then
        immutable=1; manager=rpm-ostree
    elif command -v dnf >/dev/null; then manager=dnf
    elif command -v apt-get >/dev/null; then manager=apt-get
    elif command -v pacman >/dev/null; then manager=pacman
    else die 'Unsupported package manager. Install the missing libraries manually or use --library-dir'; fi

    # Prefer isolated user-local Homebrew dependencies over rpm-ostree on immutable systems.
    # The generated service records the library prefix; a non-systemd launcher must be configured manually.
    if (( immutable && install_service )) && command -v brew >/dev/null; then
        for soname in "${missing[@]}"; do
            case $soname in
                libxkbcommon.so.0) formula=libxkbcommon;;
                libdbus-1.so.3) formula=dbus;;
                libevdev.so.2) formula=libevdev;;
            esac
            formulas+=("$formula")
        done
        confirm_dependency_change "Immutable host: install ${formulas[*]} using user-local Homebrew (no rpm-ostree) and configure the systemd service to load them."
        brew install "${formulas[@]}"
        local private_dir=${XDG_DATA_HOME:-$HOME/.local/share}/unified-remote-wayland-fix/native-libs
        mkdir -p -- "$private_dir"
        for index in "${!missing[@]}"; do
            soname=${missing[index]}; formula=${formulas[index]}
            prefix=$(brew --prefix "$formula")
            candidate="$prefix/lib/$soname"
            [[ -f $candidate ]] || die "Homebrew did not supply $candidate"
            [[ ! -e $private_dir/$soname || -L $private_dir/$soname ]] ||
                die "Refusing to replace user file: $private_dir/$soname"
            ln -sfn -- "$candidate" "$private_dir/$soname"
        done
        library_dir="$private_dir"
        export LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    else
        for soname in "${missing[@]}"; do
            case $manager:$soname in
                rpm-ostree:libxkbcommon.so.0|dnf:libxkbcommon.so.0) package=libxkbcommon;;
                rpm-ostree:libdbus-1.so.3|dnf:libdbus-1.so.3) package=dbus-libs;;
                rpm-ostree:libevdev.so.2|dnf:libevdev.so.2) package=libevdev;;
                apt-get:libxkbcommon.so.0) package=libxkbcommon0;;
                apt-get:libdbus-1.so.3) package=libdbus-1-3;;
                apt-get:libevdev.so.2) package=libevdev2;;
                pacman:libxkbcommon.so.0) package=libxkbcommon;;
                pacman:libdbus-1.so.3) package=dbus;;
                pacman:libevdev.so.2) package=libevdev;;
            esac
            packages+=("$package")
        done
        if (( immutable )); then
            confirm_dependency_change "Homebrew+systemd integration is unavailable or not selected. rpm-ostree must LAYER ${packages[*]} into the immutable system and may require a reboot."
        else
            confirm_dependency_change "Install ${packages[*]} with $manager (system package manager)."
        fi
        case $manager in
            rpm-ostree) as_root rpm-ostree install --apply-live "${packages[@]}";;
            dnf) as_root dnf install -y "${packages[@]}";;
            apt-get) as_root apt-get update; as_root apt-get install -y "${packages[@]}";;
            pacman) as_root pacman -S --needed --noconfirm "${packages[@]}";;
        esac
    fi
    for soname in "${missing[@]}"; do
        native_lib_present "$soname" ||
            die "$soname is still unavailable. Reboot if needed and rerun the installer."
    done
}
check_runtime() {
    [[ $(uname -s) == Linux ]] || die 'This fix is for Linux'
    [[ -c /dev/uinput && -w /dev/uinput ]] || die 'This user cannot write /dev/uinput; configure Unified Remote input permissions first (see README)'
    (( keyboard )) || return 0
    [[ ${XDG_SESSION_TYPE:-wayland} == wayland ]] || die 'Keyboard input requires a KDE Plasma Wayland session'
    if has_owner org.kde.KWin; then :
    elif [[ ${XDG_CURRENT_DESKTOP:-} != *KDE* ]]; then die 'KDE KWin was not detected; use --mouse-only on other desktops'
    else warn 'Could not confirm KWin through busctl; verify your desktop session'; fi
    if ! has_owner org.kde.klipper; then warn 'Klipper was not detected; characters outside the layout need its clipboard service'; fi
    local diagnostic_luajit=${LUAJIT_BIN:-luajit}
    if command -v "$diagnostic_luajit" >/dev/null; then
        # Diagnostics only: the installed Unified Remote supplies LuaJIT at runtime.
        local bits=unknown architecture=unknown header machine
        if command -v od >/dev/null; then
            header=$(od -An -tx1 -N5 "$server_dir/urserver" | tr -d ' \n')
            case $header in 7f454c4601) bits=32;; 7f454c4602) bits=64;; esac
            if [[ $bits != unknown ]]; then
                machine=$(od -An -tx1 -j18 -N2 "$server_dir/urserver" | tr -d ' \n')
                case $machine in 3e00|003e) architecture=x64;; 0300|0003) architecture=x86;; b700|00b7) architecture=arm64;; 2800|0028) architecture=arm;; esac
            fi
        fi
        "$diagnostic_luajit" -e 'local ffi=require("ffi"); local bits=ffi.abi("64bit") and "64" or "32"; assert(arg[1]=="unknown" or arg[1]==bits,"Diagnostic LuaJIT bitness differs from urserver; use matching native libraries/interpreter"); assert(arg[2]=="unknown" or arg[2]==ffi.arch,"Diagnostic LuaJIT CPU architecture differs from urserver"); local m=dofile(arg[0]); local l,v,o,d=m.layout(); m.keymap(l,v,o,d); print("Detected layout:",l,v,o,d); m.close(); os.exit(0)' \
            "$SOURCE_DIR/remotes/Unified/Core/Keyboard/wayland_ffi.lua" "$bits" "$architecture" || die 'Native keyboard checks failed; see README requirements'
    else
        local soname cache
        cache=$(ldconfig -p 2>/dev/null || true)
        for soname in libxkbcommon.so.0 libdbus-1.so.3 libevdev.so.2; do
            if [[ $cache != *"$soname "* && $cache != *"$soname ("* && ! -f ${library_dir:-/nonexistent}/$soname ]]; then
                die "Cannot locate $soname; see README. Standalone luajit is optional for a more exact check."
            fi
        done
        warn 'No standalone luajit: sonames were found, but embedded LuaJIT/target architecture must be verified in the server'
    fi
    if command -v file >/dev/null; then log "Server architecture: $(LC_ALL=C file -Lb -- "$server_dir/urserver")"; fi
}
if (( skip_checks )); then
    warn 'Runtime/session checks skipped; installation alone does not prove compatibility'
else
    ensure_native_libraries
    check_runtime
fi

# Sources and destination keys are parallel arrays. Keyboard-free legacy Input keeps native text.
declare -a sources=() keys=() obsolete=()
add_overlay() { sources+=("$SOURCE_DIR/$1"); keys+=("remotes/$2"); }
for relative in 'Unified/Core/Mouse/remote.lua' 'Unified/Main/Basic Input/remote.lua' 'Unified/Main/Basic Input MT/remote.lua'; do
    add_overlay "remotes/$relative" "$relative"
done
if (( keyboard )); then
    for relative in Unified/Core/Input/remote.lua Unified/Core/Keyboard/remote.lua Unified/Core/Keyboard/wayland_ffi.lua; do
        add_overlay "remotes/$relative" "$relative"
    done
elif grep -Eq 'wayland_(ffi\.lua|text\.py|client\.lua)' "$remotes_dir/Unified/Core/Input/remote.lua"; then
    log 'Keeping the existing keyboard-enabled Core.Input; mouse-only does not uninstall a previous keyboard fix.'
else add_overlay variants/mouse-only/Unified/Core/Input/remote.lua Unified/Core/Input/remote.lua; fi

retire_python=0
if (( cleanup )); then
    if (( keyboard )) || ! grep -Fq 'wayland_text.py' "$remotes_dir/Unified/Core/Input/remote.lua" "$remotes_dir/Unified/Core/Keyboard/remote.lua"; then retire_python=1; fi
    for retired in wayland_text.py wayland_client.lua; do
        path=Unified/Core/Keyboard/$retired
        [[ -e $remotes_dir/$path || -L $remotes_dir/$path ]] || continue
        if (( ! keyboard )) && grep -Fq "$retired" "$remotes_dir/Unified/Core/Input/remote.lua" "$remotes_dir/Unified/Core/Keyboard/remote.lua"; then
            log "Keeping $path: the retained keyboard fix still references it."
        else obsolete+=("remotes/$path"); fi
    done
    if (( retire_python )); then
        shopt -s nullglob
        for path in "$remotes_dir"/Unified/Core/Keyboard/__pycache__/wayland_text.*.pyc; do
            obsolete+=("remotes/${path#"$remotes_dir/"}")
        done
        shopt -u nullglob
    fi
fi
if (( install_service )); then keys+=(service/unit); sources+=(''); fi
key_target() {
    case $1 in remotes/*) printf '%s/%s' "$remotes_dir" "${1#remotes/}";; service/unit) printf '%s' "$service_file";; *) die 'Invalid installation key';; esac
}
for key in "${keys[@]}" "${obsolete[@]}"; do
    target=$(key_target "$key")
    [[ ! -L $target ]] || die "Refusing to replace a symlink: $target"
    if [[ $key == remotes/* ]]; then
        resolved=$(realpath -m -- "$target")
        [[ $resolved == "$remotes_dir/"* ]] || die "Destination escapes the remotes tree: $target"
    fi
    ancestor=${target%/*}
    while [[ ! -d $ancestor ]]; do ancestor=${ancestor%/*}; done
    [[ -w $ancestor ]] || die "Destination is not writable: $target"
done
for path in "${sources[@]}"; do [[ -z $path || -f $path ]] || die "Missing source file: $path"; done

matching_service=0 active_service=0 service_was_enabled=0
if command -v systemctl >/dev/null && systemctl --user is-enabled --quiet "$service" 2>/dev/null; then service_was_enabled=1; fi
if command -v systemctl >/dev/null && systemctl --user is-active --quiet "$service" 2>/dev/null; then
    active_service=1
    pid=$(systemctl --user show "$service" -p MainPID --value 2>/dev/null || true)
    exe=$(readlink -e -- "/proc/${pid:-0}/exe" 2>/dev/null || true)
    [[ $exe != "$(realpath -e -- "$server_dir/urserver")" ]] || matching_service=1
fi
if [[ $restart == yes ]] && (( active_service && ! matching_service )); then die 'The selected service is running a different server; refusing to restart it'; fi
if (( install_service && active_service && ! matching_service )); then die 'Existing service runs a different server; choose another --service name'; fi
if [[ $restart == auto ]]; then if (( matching_service )); then restart=yes; else restart=no; fi; fi
if (( install_service )) && [[ $remotes_dir != "$(realpath -m -- "$server_dir/remotes")" ]]; then die 'A separate --remotes-dir must already be configured in your existing launcher; omit --install-service'; fi
if (( install_service )); then command -v systemctl >/dev/null || die 'systemctl is required for --install-service'; fi
if [[ $restart == yes ]]; then command -v systemctl >/dev/null || die 'systemctl is required for --restart'; fi
if [[ -n $library_dir && $restart == yes && $install_service == 0 ]]; then die 'Use --install-service to record --library-dir, or --no-restart and update your launcher manually'; fi
log "Server: $server_dir"
log "Remotes: $remotes_dir"
log "Keyboard fix: $([[ $keyboard == 1 ]] && printf enabled || printf 'not installed/changed')"
for key in "${keys[@]}"; do log "Install: $(key_target "$key")"; done
for key in "${obsolete[@]}"; do log "Retire after backup: $(key_target "$key")"; done
if (( keyboard && cleanup )); then
    log 'Retired dependency requirements: Python/dbus-python/python-evdev/wl-clipboard. Shared OS packages will NOT be uninstalled.'
    for package in python3-dbus python3-evdev wl-clipboard; do
        if command -v rpm >/dev/null && rpm -q -- "$package" >/dev/null 2>&1; then
            log "Detected shared package (retained): $package"
        elif command -v dpkg-query >/dev/null && [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then
            log "Detected shared package (retained): $package"
        fi
    done
    if command -v pacman >/dev/null; then
        for package in dbus-python python-evdev wl-clipboard; do
            if pacman -Q -- "$package" >/dev/null 2>&1; then log "Detected shared package (retained): $package"; fi
        done
    fi
fi
if (( check )); then log 'Check completed; no files or services changed.'; exit 0; fi
if [[ -t 0 && $yes == 0 ]]; then
    read -r -p 'Apply this plan and create a backup? [y/N] ' answer || answer=n
    case $answer in y|Y|yes|YES) :;; *) log 'Cancelled; no files changed.'; exit 0;; esac
fi

umask 077
mkdir -p -- "$backup_base"
backup=$(mktemp -d -- "$backup_base/$(date +%Y%m%d-%H%M%S)-XXXXXX")
backup=$(realpath -e -- "$backup")
: > "$backup/manifest.tsv"
: > "$backup/SHA256SUMS"
for key in "${keys[@]}" "${obsolete[@]}"; do
    target=$(key_target "$key")
    if [[ -f $target ]]; then
        mkdir -p -- "$backup/${key%/*}"
        cp -p -- "$target" "$backup/$key"
        printf 'present\t%s\n' "$key" >> "$backup/manifest.tsv"
        (cd -- "$backup"; sha256sum -- "$key") >> "$backup/SHA256SUMS"
    elif [[ -e $target ]]; then die "Expected a regular file: $target"
    else printf 'absent\t%s\n' "$key" >> "$backup/manifest.tsv"; fi
done
(cd -- "$backup"; sha256sum -- manifest.tsv) >> "$backup/SHA256SUMS"
# The self-contained restore script uses quoted literals; it never evals paths or manifests.
{
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'remotes_dir=%q\nservice_file=%q\nservice=%q\nexpected_executable=%q\n' "$remotes_dir" "$service_file" "$service" "$(realpath -e -- "$server_dir/urserver")"
    printf 'installed_service=%q\nservice_was_enabled=%q\n' "$install_service" "$service_was_enabled"
    cat <<'RESTORE'
backup=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
(cd -- "$backup"; sha256sum --check SHA256SUMS)
# Only an explicit --restart touches the user's service during a later restore.
restart=0
case ${1:-} in '') :;; --restart) restart=1;; *) printf 'Usage: %s [--restart]\n' "$0" >&2; exit 1;; esac
if (( restart )); then
    if systemctl --user is-active --quiet "$service"; then
        pid=$(systemctl --user show "$service" -p MainPID --value)
        current=$(readlink -e -- "/proc/${pid:-0}/exe" || true)
        [[ $current == "$expected_executable" ]] || { printf '%s\n' 'Selected service now runs another server; restore without --restart.' >&2; exit 1; }
    fi
    systemctl --user stop "$service"
fi
if (( installed_service && ! service_was_enabled )); then systemctl --user disable "$service" 2>/dev/null || true; fi
while IFS=$'\t' read -r state key; do
    [[ $key != *'..'* ]] || { printf '%s\n' 'Invalid backup entry' >&2; exit 1; }
    case $key in
        remotes/*) target=$remotes_dir/${key#remotes/};;
        service/unit) target=$service_file;;
        *) printf '%s\n' 'Invalid backup entry' >&2; exit 1;;
    esac
    case $state in
        present) mkdir -p -- "${target%/*}"; cp -p -- "$backup/$key" "$target";;
        absent) rm -f -- "$target";;
        *) printf '%s\n' 'Invalid backup state' >&2; exit 1;;
    esac
done < "$backup/manifest.tsv"
if (( installed_service )); then
    systemctl --user daemon-reload
    if [[ ! -f $service_file ]]; then systemctl --user disable "$service" 2>/dev/null || true; fi
fi
if (( restart )); then
    if systemctl --user cat "$service" >/dev/null 2>&1; then systemctl --user start "$service";
    else printf '%s\n' 'No previous service unit exists after restore; start the original server manually.'; fi
fi
printf '%s\n' 'Files restored. Restart Unified Remote if you did not use --restart.'
RESTORE
} > "$backup/restore.sh"
chmod 700 "$backup/restore.sh"
log "Backup: $backup"
# If an installation step fails, restore files before trying to bring the old server back.
on_error() {
    local status=${1:-$?}
    trap - ERR INT TERM
    if [[ -n ${staged:-} && -f ${staged:-} ]]; then rm -f -- "$staged"; fi
    if (( mutation )); then
        warn 'Installation failed; rolling back the backed-up files.'
        bash "$backup/restore.sh" || warn "Automatic rollback failed; run: bash '$backup/restore.sh'"
    fi
    if (( stopped )); then systemctl --user start "$service" || true; fi
    exit "$status"
}
trap 'on_error 130' INT
trap 'on_error 143' TERM
trap on_error ERR
if [[ $restart == yes && $active_service == 1 ]]; then systemctl --user stop "$service"; stopped=1; fi
mutation=1
unit_escape() { local text=$1; text=${text//\\/\\\\}; text=${text//\"/\\\"}; text=${text//%/%%}; printf '%s' "$text"; }
command_escape() { local text; text=$(unit_escape "$1"); printf '%s' "${text//\$/\$\$}"; }
write_service() {
    printf '[Unit]\nDescription=Unified Remote Server\nAfter=graphical-session-pre.target\nPartOf=graphical-session.target\n\n[Service]\nType=forking\n'
    printf 'WorkingDirectory=%s\n' "$(unit_escape "$server_dir")"
    printf 'ExecStart=/usr/bin/env -- "%s" --daemon "--pidfile=%%h/.urserver/urserver.pid"\n' "$(command_escape "$server_dir/urserver")"
    printf 'PIDFile=%%h/.urserver/urserver.pid\nEnvironment=XDG_SESSION_TYPE=wayland\n'
    if [[ -n $library_dir ]]; then printf 'Environment="LD_LIBRARY_PATH=%s"\n' "$(unit_escape "$LD_LIBRARY_PATH")"; fi
    printf 'Restart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=graphical-session.target\n'
}
for index in "${!keys[@]}"; do
    key=${keys[index]}; target=$(key_target "$key")
    mkdir -p -- "${target%/*}"
    staged=$(mktemp -- "${target%/*}/.ur-fix-XXXXXX")
    if [[ $key == service/unit ]]; then write_service > "$staged"; else cp -- "${sources[index]}" "$staged"; fi
    chmod 644 "$staged"
    mv -f -- "$staged" "$target"
done
for key in "${obsolete[@]}"; do rm -f -- "$(key_target "$key")"; done

# Retire only workers whose complete argv identifies THIS installation's old helper.
# Packages shared with the desktop are deliberately outside this project's ownership.
if (( cleanup && retire_python )); then
    other_worker=0
    if command -v pgrep >/dev/null; then
        while IFS= read -r pid; do
            argv=()
            while IFS= read -r -d '' argument; do argv+=("$argument"); done < "/proc/$pid/cmdline" 2>/dev/null || continue
            if (( ${#argv[@]} == 3 )) && [[ ${argv[2]} == --worker && ${argv[1]} == "$remotes_dir/Unified/Core/Keyboard/wayland_text.py" ]]; then
                kill -TERM "$pid" 2>/dev/null || true
                deadline=$((SECONDS + 2))
                while (( SECONDS < deadline )); do
                    [[ -r /proc/$pid/stat ]] || break
                    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
                    [[ $state != Z ]] || break
                    sleep 0.025
                done
                log "Stopped retired Python keyboard worker: $pid"
            elif [[ " ${argv[*]} " == *'wayland_text.py --worker'* ]]; then other_worker=1; fi
        done < <(pgrep -u "$EUID" -f 'wayland_text.py' || true)
    else other_worker=1; fi
    runtime=${XDG_RUNTIME_DIR:-/run/user/$EUID}/unified-remote-text
    if (( ! other_worker )) && [[ -d $runtime && -O $runtime && ! -L $runtime ]] && command -v flock >/dev/null; then
        if [[ -f $runtime/worker.lock && -O $runtime/worker.lock && ! -L $runtime/worker.lock ]]; then
            if (exec 9<> "$runtime/worker.lock"; flock -n 9 || exit 1; [[ ! -S $runtime/input.sock ]] || rm -f -- "$runtime/input.sock"; rm -f -- "$runtime/worker.lock"); then
                rmdir -- "$runtime" 2>/dev/null || true
            fi
        fi
    fi
fi
if (( install_service )); then
    mkdir -p -- "$HOME/.urserver"
    systemctl --user daemon-reload
    if (( ! service_was_enabled )); then systemctl --user enable "$service"; fi
fi
if [[ $restart == yes ]]; then systemctl --user restart "$service"; stopped=0;
else log 'Restart Unified Remote manually to load the changed remotes.'; fi
mutation=0
trap - ERR INT TERM
log 'Installation completed. Close and reopen the remote in the mobile app.'
printf 'Restore files with: bash %q\n' "$backup/restore.sh"
if [[ -n $library_dir && $install_service == 0 ]]; then
    printf 'Start the host server with LD_LIBRARY_PATH=%q (also set this in its launcher/service).\n' "$LD_LIBRARY_PATH"
fi
