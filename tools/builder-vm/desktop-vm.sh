#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Desktop VM: try the Apex image the builder VM built, in a window on this host. The
# image is installed with the qualification's install code onto a disk laid out like the
# laptop minus LUKS (ESP + ext4 /boot + btrfs root), and boots with UEFI, KVM,
# virtio-gpu with OpenGL (virgl) and PipeWire sound (playback only by default). The
# first boot runs gnome-initial-setup, where you create your user. QEMU runs as your
# normal user; nothing needs root on the host.
#
#   desktop-vm.sh install [--replace] [IMAGE]
#                          install IMAGE (default localhost/apex:build, the result of
#                          builder-vm.sh image) onto a new disk in the builder VM, then
#                          copy the disk here. The builder VM is started for this and
#                          stopped again if it was not running. --replace discards an
#                          existing desktop disk and everything done in it
#   desktop-vm.sh start    open the VM window (QEMU runs in the background)
#   desktop-vm.sh stop     shut the guest down: systemctl poweroff over SSH (it finalizes
#                          staged updates), else the ACPI power button; after 180 s QEMU
#                          is stopped hard, like pulling the power
#   desktop-vm.sh status   running or not, the installed image, disk use
#   desktop-vm.sh ssh [CMD...]
#                          root shell (or CMD) in the guest: key-only, 127.0.0.1 only
#   desktop-vm.sh screenshot [FILE]
#                          save the guest screen as PNG (default: a timestamped file in
#                          the VM directory) and print its path; needs APEX_DESKTOP_GL=off
#   desktop-vm.sh destroy --yes
#                          delete the desktop disk, firmware variables and SSH key
#
# In the window (titled "QEMU (Apex desktop)"): Ctrl+Alt+G grabs keyboard and mouse, so
# Super and other shortcuts reach the guest; press it again to release. Ctrl+Alt+F
# toggles full screen. The close button is disabled, because closing the window would
# cut the power; Machine > Quit (Ctrl+Alt+Q) and Machine > Reset still do, so avoid
# them. Shut down from GNOME, with Machine > Power Down, or with `desktop-vm.sh stop`.
#
# Environment (defaults in brackets):
#   APEX_DESKTOP_DIR       [${XDG_DATA_HOME:-~/.local/share}/apex/desktop] VM files
#   APEX_DESKTOP_MEM       [4G]   guest RAM; free pages go back to the host (balloon)
#   APEX_DESKTOP_CPUS      [4]    vCPUs
#   APEX_DESKTOP_DISK_GB   [64]   virtual disk size at install (qcow2, grows on demand)
#   APEX_DESKTOP_SSH_PORT  [2223] host port for the guest's sshd, bound to 127.0.0.1
#   APEX_DESKTOP_GL        [on]   off: virtio-vga without OpenGL (software rendering)
#   APEX_DESKTOP_AUDIO     [pipewire] pipewire, pa, alsa or none
#   APEX_DESKTOP_MIC       [0]    1: also give the guest the host's default microphone
#   APEX_DESKTOP_SHARP     [0]    1: render the guest at the window's device pixels on a
#                                 HiDPI or fractionally scaled host (see "Sharpness")
#
# Sharpness: QEMU's GTK window reports its size to the guest in logical pixels. On a
# scaled host (this laptop: 166 %, which GTK 3 draws at 2x) the guest image is then
# stretched, so text is soft. APEX_DESKTOP_SHARP=1 sets the window's zoom to 1/scale
# (QEMU `-display gtk,scale=`, zoom-to-fit off): the guest renders at the resolution of
# GTK's 2x window buffer, and QEMU does not stretch it. GNOME still scales the window to
# 166 %, as it does every GTK 3 app. In this mode the window follows the guest's mode, so
# it opens small and shrinks back at every guest reboot: maximize it (the guest follows
# within a second) and keep it maximized, then set Settings > Displays > Scale to 200 %
# in the guest once. Full screen gives the guest logical pixels again.
#
# The guest's sshd accepts only the key made here for root (password logins stay as the
# image ships them), and QEMU forwards it on the host's loopback only. User-mode
# networking lets the guest reach the internet, and also every service listening on the
# host's 127.0.0.1, at 10.0.2.2.
set -euo pipefail

readonly OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
readonly OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
readonly DEFAULT_IMAGE=localhost/apex:build
# Where desktop-disk.sh leaves its output in the builder VM (relative to ~builder).
readonly REMOTE_OUT=apex-fedora/_build/desktop

VM_DIR=${APEX_DESKTOP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/apex/desktop}
MEM=${APEX_DESKTOP_MEM:-4G}
CPUS=${APEX_DESKTOP_CPUS:-4}
DISK_GB=${APEX_DESKTOP_DISK_GB:-64}
SSH_PORT=${APEX_DESKTOP_SSH_PORT:-2223}
GL=${APEX_DESKTOP_GL:-on}
AUDIO=${APEX_DESKTOP_AUDIO:-pipewire}
MIC=${APEX_DESKTOP_MIC:-0}
SHARP=${APEX_DESKTOP_SHARP:-0}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
BUILDER=$HERE/builder-vm.sh

DISK=$VM_DIR/disk.qcow2
VARS=$VM_DIR/OVMF_VARS.fd
INFO=$VM_DIR/image.json
KEY=$VM_DIR/ssh/id_ed25519
KNOWN_HOSTS=$VM_DIR/ssh/known_hosts
PIDFILE=$VM_DIR/qemu.pid
MONITOR=$VM_DIR/monitor.sock
SERIAL=$VM_DIR/serial.log
LOCK=$VM_DIR/lock

log() { printf '[desktop-vm] %s\n' "$*" >&2; }
die() { printf '[desktop-vm] error: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local t missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
}

# is_vm PID: PID is this VM's QEMU (`-name ...,process=apex-desktop` sets its comm).
is_vm() { [[ $(cat "/proc/$1/comm" 2>/dev/null) == apex-desktop ]]; }

# running: true while the QEMU of the pidfile runs. QEMU removes the pidfile only when it
# exits cleanly; a stale one (QEMU killed, host session ended) is dropped here, so its
# PID, which another process may have by now, is never signalled.
running() {
    local pid
    [[ -s $PIDFILE ]] || return 1
    pid=$(<"$PIDFILE")
    if [[ $pid =~ ^[0-9]+$ ]] && is_vm "$pid"; then return 0; fi
    rm -f -- "$PIDFILE"
    return 1
}

# lock: one install or start at a time. install holds it to the end, so no VM can boot
# the disk it is about to replace.
lock() {
    mkdir -p "$VM_DIR"
    exec 9>"$LOCK"
    flock -n 9 || die "another desktop-vm.sh install or start is running"
}

monitor() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MONITOR"; }

# gtk_scale: the integer scale GTK 3 renders QEMU's window with (the largest of the
# host's monitors; 2 for a fractional 166 %), or 1 when it cannot be told.
gtk_scale() {
    local s
    s=$(python3 -c 'import gi
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk
d = Gdk.Display.get_default()
print(max(d.get_monitor(i).get_scale_factor() for i in range(d.get_n_monitors())))' 2>/dev/null) || s=1
    [[ $s =~ ^[1-4]$ ]] || s=1
    printf '%s\n' "$s"
}

vm_ssh() {
    # shellcheck disable=SC2029 # the arguments are a remote command, expanded remotely on purpose
    ssh -i "$KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o ServerAliveInterval=30 \
        -o LogLevel=ERROR root@127.0.0.1 "$@"
}

# ---- install ------------------------------------------------------------------------

install() {
    local replace=0 image=$DEFAULT_IMAGE
    while (($#)); do
        case $1 in
            --replace) replace=1 ;;
            -*) die "unknown option '$1' (usage: $0 install [--replace] [IMAGE])" ;;
            *) image=$1 ;;
        esac
        shift
    done
    require_tools qemu-img ssh ssh-keygen rsync socat jq flock
    lock
    running && die "the desktop VM is running; stop it first ($0 stop)"
    if [[ -e $DISK ]] && ((!replace)); then
        die "$DISK exists; '$0 install --replace' discards it and everything done in the VM"
    fi
    [[ -r $OVMF_VARS_TEMPLATE ]] || die "OVMF firmware not found under /usr/share/OVMF"
    mkdir -p "$VM_DIR/ssh"
    chmod 0700 "$VM_DIR" "$VM_DIR/ssh"
    [[ -s $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C apex-desktop -f "$KEY"

    if ! "$BUILDER" running; then
        log "starting the builder VM for the install"
        trap '"$BUILDER" stop' EXIT
        "$BUILDER" start
    fi

    log "installing $image in the builder VM (about 5 minutes)"
    "$BUILDER" run env "DESKTOP_DISK_GB=$DISK_GB" tools/builder-vm/desktop-disk.sh "$image" "$(cat "$KEY.pub")"

    log "copying the disk to $VM_DIR"
    "$BUILDER" fetch "$REMOTE_OUT/desktop.json" "$VM_DIR/image.json.part"
    "$BUILDER" fetch "$REMOTE_OUT/desktop.qcow2" "$DISK.part"
    qemu-img check -q "$DISK.part" || die "the copied disk fails qemu-img check; run install again"
    "$BUILDER" ssh rm -f "$REMOTE_OUT/desktop.qcow2"

    # The lock keeps start out, but a QEMU run by hand could still hold the old disk.
    running && die "the desktop VM was started during the install; stop it, then run install --replace again"
    cp -- "$OVMF_VARS_TEMPLATE" "$VARS.part"
    mv -f -- "$DISK.part" "$DISK"
    mv -f -- "$VARS.part" "$VARS"
    mv -f -- "$VM_DIR/image.json.part" "$INFO"
    rm -f -- "$KNOWN_HOSTS" "$SERIAL"
    log "installed $(jq -r '"\(.image) \(.version) \(.digest)"' "$INFO")"
    log "disk: $(du -h "$DISK" | cut -f1) used of ${DISK_GB} GiB; start it with: $0 start"
}

# ---- start / stop -------------------------------------------------------------------

start() {
    require_tools qemu-system-x86_64 socat flock
    lock
    [[ -e $DISK ]] || die "no desktop disk yet ($0 install)"
    running && die "the desktop VM is already running (pid $(cat "$PIDFILE"))"
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable by $(id -un)"
    [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]] ||
        die "no graphical session (WAYLAND_DISPLAY and DISPLAY are unset); run it from your desktop"
    [[ -r $OVMF_CODE && -f $VARS ]] || die "firmware files missing; run $0 install --replace"

    local gpu display audio=()
    case $GL in
        on) gpu=virtio-vga-gl display=gtk,gl=on ;;
        off) gpu=virtio-vga display=gtk,gl=off ;;
        *) die "APEX_DESKTOP_GL must be on or off" ;;
    esac
    # A click on the close button would stop QEMU like a power cut; the guest shuts
    # down from GNOME, the Machine menu or `desktop-vm.sh stop` instead.
    display+=,window-close=off
    case $SHARP in
        0) ;;
        1)
            local gs zoom
            gs=$(gtk_scale)
            # Zoom 1/gs: a window W logical pixels wide asks the guest for W*gs pixels and
            # draws them unscaled into GTK's buffer (QEMU ui/gtk.c gd_resize_event). The
            # values are literal: printf would follow LC_NUMERIC and write 0,5.
            case $gs in
                2) zoom=0.5 ;;
                3) zoom=0.333333 ;;
                4) zoom=0.25 ;;
                *) zoom= ;;
            esac
            if [[ -n $zoom ]]; then
                display+=",zoom-to-fit=off,scale=$zoom"
                log "sharp: host scale ${gs}x. Maximize the window (not full screen) and keep it maximized; then set Scale to $((gs * 100)) % in the guest's Settings > Displays"
            else
                log "sharp: the host is not scaled; nothing to do"
            fi
            ;;
        *) die "APEX_DESKTOP_SHARP must be 0 or 1" ;;
    esac
    # hda-output is playback only; hda-micro adds a microphone fed by the host's default
    # source, so the guest can record the room only when asked to.
    local codec
    case $MIC in
        0) codec=hda-output ;;
        1) codec=hda-micro ;;
        *) die "APEX_DESKTOP_MIC must be 0 or 1" ;;
    esac
    case $AUDIO in
        pipewire | pa | alsa)
            audio=(-audiodev "$AUDIO,id=snd0" -device ich9-intel-hda -device "$codec,audiodev=snd0") ;;
        none) ;;
        *) die "APEX_DESKTOP_AUDIO must be pipewire, pa, alsa or none" ;;
    esac

    # shellcheck disable=SC2054 # QEMU option values are comma-separated key=value lists
    local args=(-name "Apex desktop,process=apex-desktop"
        -machine q35,accel=kvm,vmport=off -cpu host -smp "$CPUS" -m "$MEM"
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$VARS"
        -drive "file=$DISK,if=virtio,format=qcow2,discard=unmap,detect-zeroes=unmap,cache=writeback"
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
        -device virtio-net-pci,netdev=n0
        -device virtio-rng-pci
        -device virtio-balloon-pci,free-page-reporting=on
        -device "$gpu" -display "$display"
        -device virtio-tablet-pci -device virtio-keyboard-pci
        "${audio[@]}"
        -serial "file:$SERIAL"
        -monitor "unix:$MONITOR,server=on,wait=off"
        -pidfile "$PIDFILE" -daemonize)
    "$BUILDER" running 2>/dev/null && log "note: the builder VM is running too (stop it with: $BUILDER stop)"
    # 9>&-: the daemonized QEMU must not keep holding the lock.
    qemu-system-x86_64 "${args[@]}" 9>&-
    log "started (pid $(cat "$PIDFILE")); the window is titled 'QEMU (Apex desktop)'"
    log "first boot: gnome-initial-setup creates your user; Flathub apps install in the background"
}

wait_exit() { # PID SECONDS
    local deadline=$((SECONDS + $2))
    while is_vm "$1"; do
        ((SECONDS < deadline)) || return 1
        sleep 2
    done
}

stop_vm() {
    running || { log "not running"; rm -f "$PIDFILE"; return 0; }
    local pid
    pid=$(cat "$PIDFILE")
    # systemctl poweroff runs the whole shutdown (ostree finalizes a staged update there).
    # Without SSH, the ACPI power button, which powers a VM off at once: in a VM
    # gnome-settings-daemon honours only power-button-action 'nothing', and logind acts
    # where no session holds the key.
    if vm_ssh true >/dev/null 2>&1; then
        log "shutting down (systemctl poweroff)"
        # The connection drops while the guest goes down; that is not a failure.
        vm_ssh 'systemctl poweroff' >/dev/null 2>&1 || true
    else
        log "no SSH; pressing the ACPI power button"
        monitor system_powerdown >/dev/null 2>&1 || true
    fi
    if ! wait_exit "$pid" 180; then
        log "still running after 180 s; stopping QEMU hard (like pulling the power)"
        monitor quit >/dev/null 2>&1 || { is_vm "$pid" && kill "$pid"; } || true
        wait_exit "$pid" 20 || { is_vm "$pid" && kill -9 "$pid"; } || true
    fi
    rm -f "$PIDFILE"
    log "stopped"
}

# ---- status / screenshot / destroy --------------------------------------------------

status() {
    if running; then
        log "running (pid $(cat "$PIDFILE")), ssh: $0 ssh"
        vm_ssh 'uptime; bootc status --format=humanreadable 2>/dev/null | sed -n 1,12p' 2>/dev/null ||
            log "ssh not answering yet"
    else
        log "stopped"
    fi
    [[ -f $INFO ]] && log "image: $(jq -r '"\(.image) \(.version) \(.digest)"' "$INFO")"
    [[ -e $DISK ]] && log "disk: $(du -h "$DISK" | cut -f1) used on the host, $DISK"
    return 0
}

screenshot() {
    running || die "the desktop VM is not running ($0 start)"
    local file=${1:-$VM_DIR/screenshots/$(date +%Y%m%d-%H%M%S).png}
    [[ $file == /* ]] || file=$PWD/$file
    # The monitor reads the file name as one unquoted word.
    [[ $file != *[[:space:]\"\'\\]* ]] ||
        die "the screenshot path must not contain spaces, quotes or backslashes: $file"
    mkdir -p "$(dirname -- "$file")"
    rm -f -- "$file"
    local reply i
    reply=$(monitor "screendump $file -f png" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    # QEMU cannot read back an OpenGL scanout; the guest's own screenshot (Print Screen
    # in GNOME) works in every mode.
    [[ $reply != *"no surface"* ]] ||
        die "QEMU cannot capture an OpenGL display; start with APEX_DESKTOP_GL=off, or use Print Screen in the guest"
    for ((i = 0; i < 20; i++)); do [[ -s $file ]] && break; sleep 0.25; done
    [[ -s $file ]] || die "QEMU wrote no screenshot to $file; the monitor said: $(tail -n 2 <<<"$reply" | tr '\n' ' ')"
    printf '%s\n' "$file"
}

destroy() {
    [[ ${1:-} == --yes ]] || die "destroy deletes $DISK, its firmware variables and SSH key; run: $0 destroy --yes"
    running && stop_vm
    rm -f -- "$DISK" "$DISK.part" "$VARS" "$VARS.part" "$INFO" "$VM_DIR/image.json.part" \
        "$SERIAL" "$LOCK" "$KNOWN_HOSTS" "$KEY" "$KEY.pub"
    log "deleted the desktop VM (screenshots stay in $VM_DIR/screenshots)"
}

main() {
    [[ $(id -u) -ne 0 ]] || die "run as your normal user; the VM needs no root on the host"
    local cmd=${1:-help}
    shift || true
    case $cmd in
        install) install "$@" ;;
        start) start ;;
        stop) stop_vm ;;
        status) status ;;
        ssh) running || die "the desktop VM is not running ($0 start)"; vm_ssh "$@" ;;
        screenshot) screenshot "$@" ;;
        destroy) destroy "$@" ;;
        help | -h | --help) sed -n '/^# Desktop VM/,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
}

main "$@"
