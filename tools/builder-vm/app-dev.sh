#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
The app dev loop (S2c's dev tier): an Apex app's C, rebuilt incrementally in the desktop
VM and run over a transient /usr, from the Apex SRPM of the build the VM runs. PKG is
gnome-control-center, nautilus or ptyxis. None of it enters the image.

  app-dev.sh PKG fetch   copy from the builder VM the Apex SRPM of PKG's build that the
                         desktop VM runs (the builder's rpms.lock.next when the VM is
                         off). The builder VM is started for this and stopped again if
                         it was not running
  app-dev.sh PKG push    send the SRPM to the VM, into /var/lib/apex-app-dev/PKG
  app-dev.sh PKG build   in an F45 toolbox of the user logged in to GNOME in the VM:
                         rpmbuild -rc once per SRPM (minutes; the tree is
                         ~/apex-app-dev/PKG/BUILD/), then ninja and meson install, and
                         the result unpacked over /usr, made writable until the next
                         reboot with bootc usroverlay. Edit the tree, build again
  app-dev.sh PKG run     start PKG as that user, after stopping a running instance

The VM is the one desktop-vm.sh targets (APEX_DESKTOP_DIR, APEX_DESKTOP_THROWAWAY), and
the fetched SRPM stays in its directory, under app-dev/PKG/. Files reach the VM as tar
over desktop-vm.sh's ssh.
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
readonly DESKTOP=$HERE/desktop-vm.sh
readonly BUILDER=$HERE/builder-vm.sh
readonly GUEST_SCRIPT=$HERE/app-dev-guest.sh
readonly GUEST_ROOT=/var/lib/apex-app-dev
readonly GUEST_SCRIPT_PATH=$GUEST_ROOT/bin/app-dev-guest.sh
readonly VM_LOCK=/usr/share/apex/rpms.lock
readonly BUILDER_STORE=apex-store/pkgs
readonly BUILDER_LOCK_NEXT=apex-store/rpms.lock.next
readonly PACKAGES=(gnome-control-center nautilus ptyxis)

STOP_BUILDER=0
STAGING=

log() { printf '[app-dev] %s\n' "$*" >&2; }
die() { printf '[app-dev] error: %s\n' "$*" >&2; exit 1; }

is_safe_word() { [[ $1 =~ ^[A-Za-z0-9._:+~^-]+$ ]]; }
is_rpm_file() { [[ $1 =~ ^[A-Za-z0-9._+~^-]+\.rpm$ ]]; }
sha256_is() { [[ $(sha256sum -- "$1" | cut -d' ' -f1) == "$2" ]]; }

lock_family() {
    local lock=$1 family=$2
    awk -v family="$family" '$1 == "family" && $2 == family { print $3, $4; exit }' <<<"$lock"
}

manifest_entry() {
    local manifest=$1 kind=$2 name=$3
    awk -v kind="$kind" -v prefix="$name-" '
        $1 == kind && index($2, prefix) == 1 && substr($2, length(prefix) + 1) ~ /^[0-9]+:/ {
            print $2, $3, $4
            exit
        }' <<<"$manifest"
}

version_release() {
    local nevra=$1
    local version_release_arch=${nevra#*:}
    printf '%s\n' "${version_release_arch%.*}"
}

guest_command() { printf '%q ' bash "$GUEST_SCRIPT_PATH" "$@"; }
guest() { "$DESKTOP" exec "$(guest_command "$@")"; }

on_exit() {
    if [[ -n $STAGING ]]; then rm -rf -- "$STAGING"; fi
    if ((STOP_BUILDER)); then "$BUILDER" stop; fi
}

fetch() {
    local pkg=$1 inputs=$TARGET_VM_DIR/app-dev/$1
    if ! "$BUILDER" running; then
        log "starting the builder VM for the fetch; it stops again afterwards"
        STOP_BUILDER=1
        "$BUILDER" start
    fi
    local lock origin state key
    if "$DESKTOP" running; then
        origin="the VM's $VM_LOCK"
        lock=$("$DESKTOP" exec cat "$VM_LOCK") || die "cannot read $origin"
    else
        origin="the builder VM's ~/$BUILDER_LOCK_NEXT (the desktop VM is off)"
        lock=$("$BUILDER" ssh cat "$BUILDER_LOCK_NEXT") || die "cannot read $origin; build the image first (just vm-image)"
    fi
    read -r state key <<<"$(lock_family "$lock" "$pkg")"
    case $state in
        built | held) ;;
        stock) die "$origin has Fedora's own $pkg (the owner chose stock): there is no Apex $pkg to develop against" ;;
        *) die "$origin has no $pkg family" ;;
    esac
    is_safe_word "$key" || die "unexpected store key '$key' in $origin"

    local manifest nevra srpm_sha srpm_file
    manifest=$("$BUILDER" ssh cat "$BUILDER_STORE/$pkg/$key/manifest.txt") ||
        die "the builder VM's store has no ~/$BUILDER_STORE/$pkg/$key/manifest.txt"
    read -r nevra _ _ <<<"$(manifest_entry "$manifest" built "$pkg")"
    read -r _ srpm_sha srpm_file <<<"$(manifest_entry "$manifest" apex-srpm "$pkg")"
    if ! is_safe_word "$nevra" || ! is_rpm_file "$srpm_file"; then
        die "the manifest of store key $key lacks $pkg or its Apex SRPM"
    fi
    log "$pkg $(version_release "$nevra") (store key $key, named by $origin)"

    STAGING=$(mktemp -d "$TARGET_VM_DIR/.app-dev.XXXXXX")
    mkdir -p "$STAGING/rpms"
    if [[ -f $inputs/rpms/$srpm_file ]] && sha256_is "$inputs/rpms/$srpm_file" "$srpm_sha"; then
        cp -- "$inputs/rpms/$srpm_file" "$STAGING/rpms/"
    else
        "$BUILDER" fetch "$BUILDER_STORE/$pkg/$key/$srpm_file" "$STAGING/rpms/$srpm_file" >&2
    fi
    sha256_is "$STAGING/rpms/$srpm_file" "$srpm_sha" || die "$srpm_file does not match its sha256 in the lane's manifest"
    printf 'pkg=%s\nkey=%s\nvr=%s\nsrpm=%s\n' "$pkg" "$key" "$(version_release "$nevra")" "$srpm_file" >"$STAGING/source.env"
    mkdir -p -- "${inputs%/*}"
    rm -rf -- "$inputs"
    mv -T -- "$STAGING" "$inputs"
    STAGING=
    log "the SRPM is in $inputs; next: just app-dev $pkg push"
}

require_inputs() {
    [[ -s $1/source.env ]] || die "no inputs for $2 yet: run 'just app-dev $2 fetch' first (it uses the builder VM)"
    "$DESKTOP" running || die "the desktop VM is not running: just desktop, then log in to GNOME in it"
}

push() {
    local pkg=$1 inputs=$TARGET_VM_DIR/app-dev/$1
    require_inputs "$inputs" "$pkg"
    "$DESKTOP" exec "install -d -m 0755 $GUEST_ROOT ${GUEST_SCRIPT_PATH%/*} && cat >$GUEST_SCRIPT_PATH" <"$GUEST_SCRIPT"
    tar -C "$inputs" -cf - source.env rpms | guest receive "$pkg"
    log "sent; in the VM: $GUEST_ROOT/$pkg/"
}

confirm_target_vm() {
    TARGET_VM_DIR=$("$DESKTOP" target)
    # desktop-vm.sh let this caller reach the VM; the piped calls that follow have no terminal to show it.
    export APEX_DESKTOP_THROWAWAY=${APEX_DESKTOP_THROWAWAY:-0}
}

main() {
    case ${1:-} in
        help | -h | --help | '') usage; return ;;
    esac
    local pkg=$1 cmd=${2:-}
    [[ " ${PACKAGES[*]} " == *" $pkg "* ]] || die "PKG must be one of ${PACKAGES[*]}, not '$pkg'"
    (($# == 2)) || die "usage: $0 PKG fetch|push|build|run"
    case $cmd in
        fetch | push | build | run) ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
    trap on_exit EXIT
    trap 'exit 130' INT TERM
    confirm_target_vm
    case $cmd in
        fetch) fetch "$pkg" ;;
        push) push "$pkg" ;;
        build | run) require_inputs "$TARGET_VM_DIR/app-dev/$pkg" "$pkg"; guest "$cmd" "$pkg" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
