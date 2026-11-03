#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
The desktop VM's half of app-dev.sh, which installs it as
/var/lib/apex-app-dev/bin/app-dev-guest.sh and runs it as root in the guest.

  receive PKG   replace /var/lib/apex-app-dev/PKG with the tar archive on stdin
  build PKG     as the user logged in to GNOME, in an F45 toolbox: rpmbuild -rc of the
                received SRPM once, then ninja and meson install from its tree; then
                bootc usroverlay and the result unpacked over /usr
  run PKG       stop PKG's running instance and start it in that user's session
EOF
}

readonly ROOT=/var/lib/apex-app-dev
readonly TOOLBOX=apex-app-dev
readonly FEDORA_RELEASE=45
readonly BUILD_DIR=redhat-linux-build

SESSION_USER=
SESSION_UID=
SESSION_HOME=

log() { printf '[app-dev guest] %s\n' "$*" >&2; }
die() { printf '[app-dev guest] error: %s\n' "$*" >&2; exit 1; }

check_pkg() {
    case $1 in
        gnome-control-center | nautilus | ptyxis) ;;
        *) die "PKG must be gnome-control-center, nautilus or ptyxis, not '$1'" ;;
    esac
}

# The process name ps shows (15 characters at most) and the command that starts PKG.
process_name() {
    case $1 in
        gnome-control-center) printf 'gnome-control-c\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

launch_command() {
    case $1 in
        gnome-control-center) printf '%s\n' gnome-control-center ;;
        *) printf '%s\n' "$1" --new-window ;;
    esac
}

input() {
    local pkg=$1 name=$2 value
    value=$(sed -n "s/^$name=//p" "$ROOT/$pkg/source.env" 2>/dev/null | head -n 1)
    [[ $value =~ ^[A-Za-z0-9._:+~^-]+$ ]] ||
        die "$ROOT/$pkg/source.env has no valid $name; run app-dev.sh $pkg fetch, then push"
    printf '%s\n' "$value"
}

installed_vr() {
    local vr
    vr=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1" 2>/dev/null) || return 0
    printf '%s\n' "$vr"
}

receive() {
    local pkg=$1 target=$ROOT/$1 incoming=$ROOT/.$1.incoming
    install -d -m 0755 "$ROOT"
    rm -rf -- "$incoming"
    mkdir -p -- "$incoming"
    tar -C "$incoming" --no-same-owner -xf -
    chmod -R a+rX -- "$incoming"
    rm -rf -- "$target"
    mv -T -- "$incoming" "$target"
}

resolve_session_user() {
    local users
    mapfile -t users < <(loginctl list-sessions --no-legend | awk '{print $1}' | while read -r id; do
        [[ $(loginctl show-session "$id" --property=Type --value) == wayland ]] || continue
        [[ $(loginctl show-session "$id" --property=Class --value) == user ]] || continue
        loginctl show-session "$id" --property=Name --value
    done | sort -u)
    case ${#users[@]} in
        1) SESSION_USER=${users[0]} ;;
        0) die "nobody is logged in to GNOME in the VM; log in in the VM window first" ;;
        *) die "several users are logged in to GNOME (${users[*]}); log out all but one" ;;
    esac
    SESSION_UID=$(id -u "$SESSION_USER")
    SESSION_HOME=$(getent passwd "$SESSION_USER" | cut -d: -f6)
}

as_session_user() {
    setpriv --reuid="$SESSION_UID" --regid="$(id -g "$SESSION_USER")" --init-groups --reset-env \
        env HOME="$SESSION_HOME" XDG_RUNTIME_DIR="/run/user/$SESSION_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SESSION_UID/bus" "$@"
}

in_toolbox() { as_session_user toolbox run -c "$TOOLBOX" "$@"; }

usr_is_writable() {
    local probe=/usr/.apex-app-dev-probe
    touch "$probe" 2>/dev/null && rm -f "$probe"
}

# The toolbox sees the user's home, not /var/lib, so the SRPM and its tree live there.
build() {
    local pkg=$1 srpm vr work tree started
    srpm=$(input "$pkg" srpm)
    vr=$(input "$pkg" vr)
    [[ $(installed_vr "$pkg") == "$vr" ]] ||
        die "the VM runs $pkg $(installed_vr "$pkg"), the SRPM is $vr: run app-dev.sh $pkg fetch while the VM runs, then push"
    resolve_session_user
    work=$SESSION_HOME/apex-app-dev/$pkg
    as_session_user mkdir -p "$work"
    as_session_user cp -- "$ROOT/$pkg/rpms/$srpm" "$work/"
    if ! as_session_user podman container exists "$TOOLBOX"; then
        log "creating the toolbox $TOOLBOX (Fedora $FEDORA_RELEASE) for $SESSION_USER"
        as_session_user toolbox create --distro fedora --release "$FEDORA_RELEASE" "$TOOLBOX" >&2
    fi
    if [[ $(as_session_user cat "$work/.prepared" 2>/dev/null) != "$srpm" ]]; then
        log "rpmbuild -rc of $srpm, once per SRPM (minutes)"
        in_toolbox sudo dnf -y -q install rpm-build dnf5-plugins >&2
        in_toolbox sudo dnf -y -q builddep "$work/$srpm" >&2
        as_session_user rm -rf -- "$work/BUILD"
        in_toolbox rpmbuild -rc --noclean --nocheck --define "_topdir $work" --define "_package_note_status 0" \
            "$work/$srpm" >&2
        # shellcheck disable=SC2016 # expanded by the user's shell
        as_session_user sh -c 'printf "%s\n" "$1" >"$2"' sh "$srpm" "$work/.prepared"
    fi
    tree=$(as_session_user find "$work/BUILD" -mindepth 3 -maxdepth 3 -type d -name "$BUILD_DIR" -printf '%h\n' | head -n 1)
    [[ -n $tree ]] || die "no $BUILD_DIR under $work/BUILD; remove $work/.prepared and build again"
    started=$(date +%s)
    in_toolbox ninja -C "$tree/$BUILD_DIR" >&2
    as_session_user rm -rf -- "$work/root"
    in_toolbox meson install -C "$tree/$BUILD_DIR" --no-rebuild --quiet --destdir "$work/root" >&2
    if ! usr_is_writable; then
        log "bootc usroverlay: /usr is writable until the next reboot, which drops the build"
        bootc usroverlay >&2
        usr_is_writable || die "/usr is still read-only after bootc usroverlay"
    fi
    tar -C "$work/root" -cf - usr | tar -C / --no-same-owner --no-overwrite-dir -xf -
    log "$pkg built and installed over /usr in $(($(date +%s) - started)) s; the tree: $tree"
}

run() {
    local pkg=$1 command
    resolve_session_user
    pkill -u "$SESSION_UID" -x "$(process_name "$pkg")" || true
    read -ra command <<<"$(launch_command "$pkg")"
    as_session_user systemd-run --user --collect --quiet --unit="apex-app-dev-$pkg-$(date +%s)" "${command[@]}"
    log "$pkg started for $SESSION_USER"
}

main() {
    local cmd=${1:-}
    case $cmd in
        help | -h | --help) usage; return ;;
    esac
    [[ $(id -u) -eq 0 ]] || die "run it as root in the desktop VM, as app-dev.sh does"
    (($# == 2)) || die "usage: $0 receive|build|run PKG"
    check_pkg "$2"
    case $cmd in
        receive) receive "$2" ;;
        build) build "$2" ;;
        run) run "$2" ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
